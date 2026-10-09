// Nod ID SDK: the real services behind the screens (M2). Chip read over NFC, the OPRF call, proving on the phone, and the proof upload.
// RULES (CLAUDE.md): passport bytes stay in memory only. Nothing here prints, logs or stores them; the URL session is ephemeral (no disk cache,
// no cookies); chip data is overwritten as soon as the Rust side holds it; the Rust session is wiped when this returns or throws.
import Foundation
import NFCPassportReader

@_spi(Testing) public final class RealChip: ChipHandle {
    var sod: [UInt8]
    var dg1: [UInt8]
    public init(sod: [UInt8], dg1: [UInt8]) { self.sod = sod; self.dg1 = dg1 }
    public func wipe() {
        for i in sod.indices { sod[i] = 0 }
        for i in dg1.indices { dg1[i] = 0 }
        sod = []; dg1 = []
    }
    deinit { wipe() }
}

/// The Rust placement table (nodid_core::placement) through the generated bindings.
private func rustPlacementOrder(_ s: String?) -> [String] { placementOrder(issuingState: s) }

public enum ServicesError: Error { case network, badAnswer, missingResource, session }

public final class RealServices: NodIDServices {
    private let api: URL
    private let oprf: URL
    private let http: URLSession
    private let resources: String
    /// Set when the resources come as a one-time download (a release build with pinned hashes and no resources in the app bundle).
    private let download: (dir: URL, base: URL, pin: String)?
    private let gate = ResourceGate()
    private var policyJSON: Data?
    /// File-name prefix of the bundled CSCA files (`<prefix>-certs.bin`, `-leaves.txt`, `-root.txt`). Only the synthetic self-test changes it.
    @_spi(Testing) public var cscaPrefix = "csca"
    /// Called with the proof upload body before it is sent (self-test only; the body holds proofs and public outputs, no passport data).
    @_spi(Testing) public var proofObserver: ((String) -> Void)?
    /// The session policy as fetched (self-test only: it holds no passport data).
    @_spi(Testing) public var policyJSONForSelfTest: Data? { policyJSON }
    /// Stage timings of the last proof (seconds; no passport data).
    @_spi(Testing) public private(set) var lastTimings = ""

    /// - Parameter resources: the folder holding the circuits, verification keys, `nodid.srs`, `served.json` and the `csca-*` files.
    ///   Default: the host app's bundle (the folder reference named in docs/INTEGRATION.md).
    public init(api: URL = URL(string: "https://api.nodid.app")!, oprf: URL = URL(string: "https://oprf.nodid.app")!, resources: URL? = nil) {
        self.api = api; self.oprf = oprf
        let c = URLSessionConfiguration.ephemeral          // nothing cached to disk, no cookies
        c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 30; c.waitsForConnectivity = false
        self.http = URLSession(configuration: c)
        let bundle = Bundle.main.resourcePath ?? ""
        if let r = resources { self.resources = r.path; self.download = nil }
        else if FileManager.default.fileExists(atPath: bundle + "/served.json") { self.resources = bundle; self.download = nil }   // resources shipped in the app
        else if let pin = PinnedResources.manifestSHA256, let base = PinnedResources.baseURL,
                let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let dir = support.appendingPathComponent("NodID").appendingPathComponent(String(pin.prefix(16)))
            self.resources = dir.path; self.download = (dir, base, pin)
        } else { self.resources = bundle; self.download = nil }
    }

    // MARK: resources (one-time download when they are not in the app)
    private func resourceStore(allowExpensive: Bool) -> ResourceStore? {
        guard let d = download else { return nil }
        return ResourceStore(directory: d.dir, baseURL: d.base, pinnedManifestSHA256: d.pin, fetcher: URLSessionFetcher(allowExpensive: allowExpensive))
    }

    /// Makes sure the proving resources are on the phone. Nothing to do when they are in the app. Safe to call from several places at once.
    public func resourcesReady(progress: @escaping (Int) -> Void) async throws {
        guard let cheap = resourceStore(allowExpensive: false), let any = resourceStore(allowExpensive: true) else { return }
        if cheap.isComplete() { return }
        try await gate.run { try await any.ensure { progress(Int($0 * 100)) } }
    }

    // MARK: placement
    public func placementOrder(issuingState: String?) -> [PlacementSpot] {
        rustPlacementOrder(issuingState).compactMap { PlacementSpot(rawValue: $0) }
    }

    // MARK: session policy
    public func fetchPolicy(sessionId: String) async throws -> SessionPolicy {
        let (data, status) = try await get(api.appendingPathComponent("v1/sessions/\(sessionId)/policy"))
        guard status == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ServicesError.session }
        policyJSON = data
        let flags = (j["checkFlags"] as? Int) ?? 0
        return SessionPolicy(appName: (j["appName"] as? String) ?? "", accentHex: (j["accent"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "#1F3C7A",
                             minAge: (j["minAge"] as? Int) ?? 18, checkAge: flags & 2 != 0, checkExpiry: flags & 1 != 0, checkCountry: flags & 4 != 0,
                             helpURL: (j["helpUrl"] as? String).flatMap { URL(string: $0) },
                             offerDigitalId: (j["offerDigitalId"] as? Bool) ?? false, onePerPerson: (j["onePerPerson"] as? Bool) ?? false,
                             alternatives: ((j["alternatives"] as? [[String: Any]]) ?? []).compactMap { a in
                                 (a["title"] as? String).map { SessionPolicy.Alternative(title: $0, detail: (a["detail"] as? String) ?? "") } })
    }

    // MARK: chip
    public func readChip(mrz: MRZData, onProgress: @escaping (ChipProgress) -> Void) async throws -> ChipHandle {
        let key = mrzKey(passportNumber: mrz.documentNumber, birth: mrz.birthYYMMDD, expiry: mrz.expiryYYMMDD)
        let reader = PassportReader(masterListURL: nil)   // no passive check in the library: the proof does it
        var lastError: Error = ChipFailure.other
        for skipPACE in [false, true] {                    // PACE first; BAC once if that fails
            do {
                let model = try await reader.readPassport(mrzKey: key, tags: [.COM, .DG1, .SOD], skipSecureElements: true, skipCA: true, skipPACE: skipPACE,
                    customDisplayMessage: { msg in
                        switch msg {
                        case .requestPresentPassport: onProgress(.waiting); return "Hold your iPhone near your passport."
                        case .authenticatingWithPassport: onProgress(.authenticating); return "Reading your passport. Keep still.\n\n" + RealServices.dots(0)
                        case .readingDataGroupProgress(_, let p):
                            onProgress(.reading(percent: p))
                            return p >= 82 ? "Almost done. Keep holding." : "Reading your passport. Keep still.\n\n" + RealServices.dots(p)
                        case .successfulRead: onProgress(.done); return "Passport read. Making your proof next."
                        default: return nil
                        }
                    })
                guard let sod = model.getDataGroup(.SOD), let dg1 = model.getDataGroup(.DG1) else { throw ChipFailure.unsupported }
                return RealChip(sod: sod.data, dg1: dg1.data)
            } catch let e as NFCPassportReaderError {
                lastError = e
                if case .UserCanceled = e { throw ChipFailure.cancelled }
            } catch { lastError = error }
        }
        throw RealServices.map(lastError)
    }

    static func dots(_ percent: Int) -> String {
        let filled = max(0, min(10, percent / 10))
        return String(repeating: "●", count: filled) + String(repeating: "○", count: 10 - filled)
    }

    static func map(_ e: Error) -> ChipFailure {
        guard let r = e as? NFCPassportReaderError else { return (e as? ChipFailure) ?? .other }
        switch r {
        case .UserCanceled: return .cancelled
        case .InvalidMRZKey: return .keyMismatch
        case .ResponseError(_, let sw1, let sw2): return (sw1 == 0x69 && sw2 == 0x82) || sw1 == 0x63 ? .keyMismatch : .other
        case .NFCNotSupported: return .unsupported
        case .NoConnectedTag, .TagNotValid, .MoreThanOneTagFound: return .chipNotFound
        case .ConnectionError, .TimeOutError: return .tagLost
        default: return .other
        }
    }

    // MARK: prove
    public func prove(chip: ChipHandle, sessionId: String, onStep: @escaping (ProofStep) -> Void) async throws -> ProofResult {
        guard let c = chip as? RealChip, let pj = policyJSON else { throw ServicesError.session }
        onStep(.passportRead)
        let ps: ProofSession
        do { ps = try ProofSession(policyJson: pj, sod: Data(c.sod), dg1: Data(c.dg1)) } catch { c.wipe(); throw error }
        c.wipe()                                           // the Rust session holds the only copy now
        defer { ps.wipe() }
        try Task.checkCancellation()

        onStep(.checkingRules)
        if let reason = try ps.localCheck() {
            switch reason {
            case "expired": return .notVerified(.expired)
            case "underage": return .notVerified(.underage)
            case "country": return .notVerified(.countryNotAllowed)
            default: return .notVerified(.technical)
            }
        }
        // OPRF: a fixed-size request, then the answer, checked against the key the session pins.
        let request = try ps.oprfRequest()
        async let answer = post(oprf.appendingPathComponent("v1/oprf"), body: request, type: "application/octet-stream")
        async let pk = get(oprf.appendingPathComponent("v1/public-key"))
        let (ans, ansStatus) = try await answer
        let (pubkey, pkStatus) = try await pk
        guard ansStatus == 200, ans.count == 128, pkStatus == 200, pubkey.count == 64 else { throw ServicesError.badAnswer }
        try ps.oprfComplete(response: ans, publicKey: pubkey)
        try Task.checkCancellation()

        let res = resources
        guard let rootText = try? String(contentsOfFile: res + "/\(cscaPrefix)-root.txt", encoding: .utf8),
              let servedData = FileManager.default.contents(atPath: res + "/served.json"),
              let served = try? JSONSerialization.jsonObject(with: servedData) as? [String] else { throw ServicesError.missingResource }
        let sessionBox = ps
        let prefix = cscaPrefix
        _ = try await Task.detached(priority: .userInitiated) {
            try sessionBox.prepare(certsPath: res + "/\(prefix)-certs.bin", leavesPath: res + "/\(prefix)-leaves.txt", rootHex: rootText, served: served)
        }.value

        onStep(.makingProof)
        let tProve = CFAbsoluteTimeGetCurrent()
        let body = try await Task.detached(priority: .userInitiated) {
            try sessionBox.prove(circuitsDir: res, vkDir: res, srsPath: res + "/nodid.srs", concurrent: true)
        }.value
        lastTimings = String(format: "swift prove call %.2f s; ", CFAbsoluteTimeGetCurrent() - tProve) + ps.timings()
        try Task.checkCancellation()
        proofObserver?(body)

        let tUp = CFAbsoluteTimeGetCurrent()
        let (out, status) = try await post(api.appendingPathComponent("v1/sessions/\(sessionId)/proof"), body: Data(body.utf8), type: "application/json")
        lastTimings += String(format: ", upload %.2f s (%d B)", CFAbsoluteTimeGetCurrent() - tUp, body.utf8.count)
        guard status == 200, let j = try JSONSerialization.jsonObject(with: out) as? [String: Any], let outcome = j["outcome"] as? String else { throw ServicesError.badAnswer }
        return outcome == "verified" ? .verified(reference: RealServices.reference()) : .notVerified(.technical)
    }

    static func reference() -> String {
        let a = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        func part() -> String { String((0..<4).map { _ in a.randomElement()! }) }
        return "NOD-\(part())-\(part())"
    }

    // MARK: network
    public func warmUp() async {
        // First open after install: fetch the resources in the background (not over mobile data; proving fetches them anyway if still missing).
        if let cheap = resourceStore(allowExpensive: false), !cheap.isComplete() { try? await gate.run { try await cheap.ensure() } }
        let path = resources + "/nodid.srs"
        await Task.detached(priority: .utility) { warmNoirSrs(srsPath: path) }.value
    }

    public func report(sessionId: String, outcome: String) async {
        guard outcome == "cancelled" || outcome == "technical_error",
              let body = try? JSONSerialization.data(withJSONObject: ["outcome": outcome]) else { return }
        _ = try? await post(api.appendingPathComponent("v1/sessions/\(sessionId)/report"), body: body, type: "application/json")
    }

    private func get(_ url: URL) async throws -> (Data, Int) {
        var r = URLRequest(url: url); r.httpMethod = "GET"
        let (d, resp) = try await http.data(for: r)
        return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
    private func post(_ url: URL, body: Data, type: String) async throws -> (Data, Int) {
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.httpBody = body; r.setValue(type, forHTTPHeaderField: "Content-Type")
        let (d, resp) = try await http.data(for: r)
        return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}


/// Runs one download at a time: a second caller waits for the first and then checks again (the folder is complete, or it tries itself).
actor ResourceGate {
    private var running: Task<Void, Error>?
    func run(_ work: @escaping @Sendable () async throws -> Void) async throws {
        while let t = running { _ = try? await t.value; if running == nil { break } }
        let t = Task { try await work() }
        running = t
        defer { running = nil }
        try await t.value
    }
}
