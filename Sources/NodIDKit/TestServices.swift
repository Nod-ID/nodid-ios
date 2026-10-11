// Nod ID SDK, test mode (quickstart, decision 55): `NodIDServices` that runs the whole member flow on a sample, with no passport,
// no NFC, no camera, no proof, no App Attest and no network. Compiled in DEBUG builds only: a Release build has no test engine.
// There is deliberately no path from here to `RealServices` or to the proof upload.
#if DEBUG
import CryptoKit
import Foundation

/// Test-only result (decision 47 keys plus `mode`). `NodID.verifyDetailed(key:)` returns it. Never produced in Release.
/// A sample B or C result carries no reason and no sample letter (rule 7): only `outcome` differs.
public struct NodIDTestResult: Codable, Equatable {
    public struct Versions: Codable, Equatable { public var circuit: String; public var vk: String; public var dscTree: String; public var sdk: String }
    public var mode: String            // always "test"
    public var outcome: String         // verified | not_verified | cancelled | technical_error
    public var assurance: String       // always "test": a value no live check accepts
    public var unique: Bool?           // verified only
    public var personCode: String?     // verified only: tst_pc_<12 hex>
    public var method: String          // always "test_sample"
    public var versions: Versions
}

final class TestChip: ChipHandle {
    private(set) var sample: TestSample?
    init(_ s: TestSample) { sample = s }
    func wipe() { sample = nil }
}

final class TestServices: NodIDServices {
    let key: NodIDTestKey
    private let keyString: String
    private let now: () -> Date
    private let stepDelay: UInt64
    private(set) var decision: TestDecision?
    private var startedSent = false

    var isTestMode: Bool { true }

    init(key: NodIDTestKey, keyString: String, now: @escaping () -> Date = Date.init, stepDelayNanoseconds: UInt64 = 450_000_000) {
        self.key = key; self.keyString = keyString; self.now = now; self.stepDelay = stepDelayNanoseconds
    }

    /// `tst_pc_` plus 12 hex of SHA-256("nodid.test.person.v1" | key id | sample "A"): stable per key, different across keys, never a live code.
    static func personCode(keyId: String) -> String {
        let d = SHA256.hash(data: Data("nodid.test.person.v1|\(keyId)|A".utf8))
        return "tst_pc_" + d.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    func placementOrder(issuingState: String?) -> [PlacementSpot] { PlacementSpot.allCases }

    func fetchPolicy(sessionId: String) async throws -> SessionPolicy {
        sendPing(.started)
        let info = Bundle.main.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? "Your app"
        return SessionPolicy(appName: name, accentHex: "#1F3C7A", minAge: 18, checkAge: true, checkExpiry: true, checkCountry: false, helpURL: nil)
    }

    func readChip(mrz: MRZData, onProgress: @escaping (ChipProgress) -> Void) async throws -> ChipHandle { throw ChipFailure.unsupported }

    func prove(chip: ChipHandle, sessionId: String, onStep: @escaping (ProofStep) -> Void) async throws -> ProofResult {
        guard let c = chip as? TestChip, let sample = c.sample else { throw ChipFailure.other }
        onStep(.passportRead); try await Task.sleep(nanoseconds: stepDelay)
        onStep(.checkingRules); try await Task.sleep(nanoseconds: stepDelay)
        onStep(.makingProof); try await Task.sleep(nanoseconds: stepDelay)   // no proof is made; the screen says so
        c.wipe()
        let d = TestRules.decide(sample, now: now(), minAge: 18, checkAge: true, checkExpiry: true)
        decision = d
        switch d {
        case .verified:
            sendPing(.verified)
            return .verified(reference: "NOD-TEST-" + String(format: "%04X", UInt16.random(in: 0...UInt16.max)))
        case .notVerified(let why): return .notVerified(why)
        }
    }

    /// The test-only result for what the flow handed back to the host.
    func result(outcome: String) -> NodIDTestResult {
        let ok = outcome == "verified"
        return NodIDTestResult(mode: "test", outcome: outcome, assurance: "test", unique: ok ? true : nil,
                               personCode: ok ? TestServices.personCode(keyId: key.id) : nil, method: "test_sample",
                               versions: .init(circuit: "test-sample-1", vk: "none", dscTree: "none", sdk: NodIDVersion.sdk))
    }

    private func sendPing(_ kind: NodIDTelemetryEvent.Kind) {
        if kind == .started { guard !startedSent else { return }; startedSent = true }
        guard TelemetryState.isEnabled else { return }
        #if targetEnvironment(simulator)
        let sim = true
        #else
        let sim = false
        #endif
        let e = NodIDTelemetryEvent(event: kind, sdk: NodIDVersion.sdk, simulator: sim), t = TelemetryState.current, k = keyString
        Task { await t.send(e, testKey: k) }
    }
}
#endif
