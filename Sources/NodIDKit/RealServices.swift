// Nod ID SDK: the real services behind the screens (M2). Chip read over NFC, the OPRF call, proving on the phone, and the proof upload.
// RULES: passport bytes stay in memory only. Nothing here prints, logs or stores them; the URL session is ephemeral (no disk cache,
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
    private let gate = ResourceGate.shared
    private var policyJSON: Data?
    private let attest = AppAttest()
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
        else if let cfg = Self.downloadConfig() {
            self.resources = cfg.dir.path; self.download = cfg
        } else { self.resources = bundle; self.download = nil }
    }

    // MARK: resources (one-time download when they are not in the app)
    /// Where the downloaded resources live and what they must match; nil when this build has no pinned release (development) or ships them in the app.
    static func downloadConfig() -> (dir: URL, base: URL, pin: String)? {
        if FileManager.default.fileExists(atPath: (Bundle.main.resourcePath ?? "") + "/served.json") { return nil }
        guard let pin = PinnedResources.manifestSHA256, let base = PinnedResources.baseURL,
              let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return (support.appendingPathComponent("NodID").appendingPathComponent(String(pin.prefix(16))), base, pin)
    }

    static func makeStore(_ d: (dir: URL, base: URL, pin: String), allowExpensive: Bool, waitForConnectivity: Bool = false) -> ResourceStore {
        ResourceStore(directory: d.dir, baseURL: d.base, pinnedManifestSHA256: d.pin,
                      fetcher: URLSessionFetcher(allowExpensive: allowExpensive, waitForConnectivity: waitForConnectivity),
                      fallbackURLs: PinnedResources.fallbackURLs)
    }

    private func resourceStore(allowExpensive: Bool) -> ResourceStore? {
        guard let d = download else { return nil }
        return Self.makeStore(d, allowExpensive: allowExpensive)
    }

    /// Starts the one-time download in the background (see `NodID.prefetch`). Does nothing when the files are in the app or already complete.
    static func prefetch(allowCellular: Bool) {
        guard let d = downloadConfig() else { return }
        let store = makeStore(d, allowExpensive: allowCellular, waitForConnectivity: true)
        guard !store.isComplete(tiers: prefetchTiers) else { NodTrace.log("prefetch: nothing to do"); return }
        NodTrace.log("prefetch: starting (cellular \(allowCellular))")
        PrefetchState.shared.start(allowCellular: allowCellular) {
            try? await ResourceGate.shared.run { try await store.ensure(tiers: prefetchTiers) { ResourceProgress.shared.publish($0) } }
        }
    }

    /// Makes sure the proving resources are on the phone. Nothing to do when they are in the app. Safe to call from several places at once.
    public func resourcesReady(progress: @escaping (Int) -> Void) async throws {
        guard let cheap = resourceStore(allowExpensive: false), let any = resourceStore(allowExpensive: true) else { return }
        if cheap.isComplete(tiers: baseTiers) { return }
        NodTrace.log("resourcesReady: shared files missing, starting download")
        PrefetchState.shared.stopWifiOnly()      // the member is waiting now: finish over any network (partial files are kept)
        let id = ResourceProgress.shared.observe(progress)
        defer { ResourceProgress.shared.remove(id) }
        try await gate.run { try await any.ensure(tiers: baseTiers) { ResourceProgress.shared.publish($0) } }
    }

    /// The circuit files for the passport being verified (known once the chip has been read and the signature type is clear). Usually already
    /// on the phone from the prefetch; otherwise only these files are fetched.
    func circuitsReady(names: [String]) async throws {
        guard let any = resourceStore(allowExpensive: true) else { return }
        let files = Set(names.map { $0 + ".json" })
        if any.isComplete(names: files) { NodTrace.log("circuitsReady: \(files.count) circuit files already on the phone"); return }
        NodTrace.log("circuitsReady: \(files.count) circuit files to get")
        PrefetchState.shared.stopWifiOnly()
        try await gate.run { try await any.ensure(names: files) { ResourceProgress.shared.publish($0) } }
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
        // App Attest: the key and, the first time, its attestation are made beside the proving (about 1.5 s once per install).
        let nonce = ((try? JSONSerialization.jsonObject(with: pj)) as? [String: Any])?["nonce"].flatMap { $0 as? String }.flatMap(AttestBody.unhex)
        let attestation = Task { if let n = nonce { await attest.prepare(nonce: n) } }
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
        NodTrace.log("prove: oprf request")
        let request = try ps.oprfRequest()
        async let answer = post(oprf.appendingPathComponent("v1/oprf"), body: request, type: "application/octet-stream")
        async let pk = get(oprf.appendingPathComponent("v1/public-key"))
        let (ans, ansStatus) = try await answer
        let (pubkey, pkStatus) = try await pk
        guard ansStatus == 200, ans.count == 128, pkStatus == 200, pubkey.count == 64 else { throw ServicesError.badAnswer }
        NodTrace.log("prove: oprf done")
        try ps.oprfComplete(response: ans, publicKey: pubkey)
        try Task.checkCancellation()

        let res = resources
        guard let rootText = try? String(contentsOfFile: res + "/\(cscaPrefix)-root.txt", encoding: .utf8),
              let servedData = FileManager.default.contents(atPath: res + "/served.json"),
              let served = try? JSONSerialization.jsonObject(with: servedData) as? [String] else { throw ServicesError.missingResource }
        let sessionBox = ps
        let prefix = cscaPrefix
        let circuitNames = try await Task.detached(priority: .userInitiated) {
            try sessionBox.prepare(certsPath: res + "/\(prefix)-certs.bin", leavesPath: res + "/\(prefix)-leaves.txt", rootHex: rootText, served: served)
        }.value
        NodTrace.log("prove: prepared (\(circuitNames.count) circuits)")
        try await circuitsReady(names: circuitNames)      // only the circuits this passport needs
        try Task.checkCancellation()

        onStep(.makingProof)
        let tProve = CFAbsoluteTimeGetCurrent()
        let body = try await Task.detached(priority: .userInitiated) {
            try sessionBox.prove(circuitsDir: res, vkDir: res, srsPath: res + "/nodid.srs", concurrent: true)
        }.value
        lastTimings = String(format: "swift prove call %.2f s; ", CFAbsoluteTimeGetCurrent() - tProve) + ps.timings()
        try Task.checkCancellation()
        proofObserver?(body)

        _ = await attestation.value
        var signed = body
        if let n = nonce, let parts = AttestBody.parse(body) {
            let payload = await attest.sign(nonce: n, path: parts.path, proofs: parts.proofs, sdk: NodIDVersion.sdk)
            NodTrace.log("prove: app attest \(payload == nil ? "not available" : payload?.attestation == nil ? "assertion" : "attestation and assertion")")
            signed = AttestBody.add(to: body, sdk: NodIDVersion.sdk, attest: payload)
        }
        let tUp = CFAbsoluteTimeGetCurrent()
        let (out, status) = try await post(api.appendingPathComponent("v1/sessions/\(sessionId)/proof"), body: Data(signed.utf8), type: "application/json")
        lastTimings += String(format: ", upload %.2f s (%d B)", CFAbsoluteTimeGetCurrent() - tUp, signed.utf8.count)
        guard status == 200, let j = try JSONSerialization.jsonObject(with: out) as? [String: Any], let outcome = j["outcome"] as? String else { throw ServicesError.badAnswer }
        if outcome == "verified" { await attest.markAttested() }
        return outcome == "verified" ? .verified(reference: RealServices.reference()) : .notVerified(.technical)
    }

    static func reference() -> String {
        let a = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        func part() -> String { String((0..<4).map { _ in a.randomElement()! }) }
        return "NOD-\(part())-\(part())"
    }

    // MARK: network
    public func warmUp() async {
        NodTrace.log("warmUp: start")
        // First open after install: fetch the resources in the background (not over mobile data; proving fetches them anyway if still missing).
        if let cheap = resourceStore(allowExpensive: false), !cheap.isComplete(tiers: prefetchTiers) { try? await gate.run { try await cheap.ensure(tiers: prefetchTiers) { ResourceProgress.shared.publish($0) } } }
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


/// What the first run needs for every passport, and what `prefetch()` and the flow's background start fetch ahead of time.
let baseTiers: Set<String> = ["base"]
let prefetchTiers: Set<String> = ["base", "common"]

/// Runs one download at a time: a second caller waits for the first and then checks again (the folder is complete, or it tries itself).
actor ResourceGate {
    static let shared = ResourceGate()
    private var running: Task<Void, Error>?
    func run(_ work: @escaping @Sendable () async throws -> Void) async throws {
        if running != nil { NodTrace.log("gate: waiting for another download") }
        while let t = running { _ = try? await t.value }
        try Task.checkCancellation()
        let t = Task { try await work() }
        running = t
        defer { running = nil }
        try await withTaskCancellationHandler { try await t.value } onCancel: { t.cancel() }
    }
}

/// Download progress (0...100), shared by every caller: the background start, `NodID.prefetch` and the proving step all see the same download.
final class ResourceProgress: @unchecked Sendable {
    static let shared = ResourceProgress()
    private let lock = NSLock()
    private var observers: [UUID: (Int) -> Void] = [:]
    private var percent: Int?
    func observe(_ f: @escaping (Int) -> Void) -> UUID {
        let id = UUID(); lock.lock(); observers[id] = f; let p = percent; lock.unlock()
        if let p { f(p) }
        return id
    }
    func remove(_ id: UUID) { lock.lock(); observers[id] = nil; lock.unlock() }
    func publish(_ fraction: Double) {
        let p = max(0, min(100, Int(fraction * 100)))
        if p % 10 == 0 { NodTrace.log("progress \(p)%") }
        lock.lock()
        guard p != percent else { lock.unlock(); return }
        percent = fraction >= 1 ? nil : p
        let fs = Array(observers.values); lock.unlock()
        fs.forEach { $0(p) }
    }
}

/// The app-launch download started by `NodID.prefetch`. A Wi-Fi-only one is stopped when the member's proof needs the files now.
final class PrefetchState: @unchecked Sendable {
    static let shared = PrefetchState()
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var allowsCellular = false
    func start(allowCellular: Bool, _ work: @escaping @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        allowsCellular = allowCellular
        task = Task.detached(priority: .utility) { [weak self] in
            await work()
            self?.lock.lock(); self?.task = nil; self?.lock.unlock()
        }
    }
    func stopWifiOnly() {
        lock.lock(); let t = allowsCellular ? nil : task; lock.unlock()
        t?.cancel()
    }
}
