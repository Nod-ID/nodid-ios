import Foundation
import CryptoKit
import DeviceCheck
import Security

/// The SDK version the verifier records with each proof. `scripts/sdk-release.sh` refuses to build a release whose version differs.
enum NodIDVersion { static let sdk = "0.2.1" }

/// App Attest on every passport proof (docs/RESULT_AND_ATTESTATION.md section 2, decision 48).
/// The SDK attests a key once per install (the attestation travels with the first proof) and signs an assertion over
/// (session nonce, proof hash, SDK version) with every submission. The attested app is the host app. Nothing here touches passport data.
enum AttestHash {
    private static func sha(_ parts: [Data]) -> Data {
        var h = SHA256()
        for p in parts { h.update(data: p) }
        return Data(h.finalize())
    }
    static func be16(_ n: Int) -> Data { Data([UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]) }
    static func be32(_ n: Int) -> Data { Data([UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]) }

    /// `PH`: the raw proof bytes with their circuit versions and the path, in order (never the JSON text).
    static func proofHash(path: String, proofs: [(circuit: String, proof: Data)]) -> Data {
        var parts: [Data] = [Data("nodid.proof.v1".utf8), Data(path.utf8), Data([0])]
        for p in proofs { parts += [be16(p.circuit.utf8.count), Data(p.circuit.utf8), be32(p.proof.count), p.proof] }
        return sha(parts)
    }
    static func attestChallenge(nonce: Data) -> Data { sha([Data("nodid.attest.v1".utf8), nonce]) }
    static func assertionHash(nonce: Data, proofHash: Data, sdk: String) -> Data { sha([Data("nodid.assert.v1".utf8), nonce, proofHash, Data(sdk.utf8)]) }
}

/// Apple's side, behind a protocol so the logic can be tested without a device.
protocol AttestBackend {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}
struct DeviceCheckBackend: AttestBackend {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }
    func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash) }
}

/// Where the key id lives: this device only, not in backups and not synced. A reinstall keeps the Keychain item but loses the key
/// (decision from the face-match spike): the first assertion then fails with `invalidKey` and the SDK attests a new key.
protocol AttestKeyStore {
    func load() -> (keyId: String, attested: Bool)?
    func save(keyId: String, attested: Bool)
    func clear()
}
struct KeychainAttestStore: AttestKeyStore {
    let service = "app.nodid.sdk.attest"
    private func query(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    private func read(_ account: String) -> String? {
        var r: CFTypeRef?
        guard SecItemCopyMatching(query(account).merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    private func write(_ account: String, _ value: String) {
        SecItemDelete(query(account) as CFDictionary)
        SecItemAdd(query(account).merging([kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 } as CFDictionary, nil)
    }
    func load() -> (keyId: String, attested: Bool)? { read("keyId").map { ($0, read("attested") == "1") } }
    func save(keyId: String, attested: Bool) { write("keyId", keyId); write("attested", attested ? "1" : "0") }
    func clear() { SecItemDelete(query("keyId") as CFDictionary); SecItemDelete(query("attested") as CFDictionary) }
}

/// What goes into the proof body as `attest`.
struct AttestPayload { let keyId: String; let assertion: Data; let attestation: Data? }

actor AppAttest {
    private let backend: AttestBackend
    private let store: AttestKeyStore
    /// The key and attestation made for the current session (prepared while the proof is being made).
    private var prepared: (keyId: String, attestation: Data?)?
    private var preparedFor: Data?

    init(backend: AttestBackend = DeviceCheckBackend(), store: AttestKeyStore = KeychainAttestStore()) { self.backend = backend; self.store = store }

    var isSupported: Bool { backend.isSupported }

    /// Make sure a key exists and, the first time, attest it for this session's nonce. Takes about 1.5 s the first time, so it runs
    /// beside the proving. Returns nil when App Attest is not available (Simulator, unsupported device) or fails: the verifier then decides.
    @discardableResult
    func prepare(nonce: Data) async -> Bool {
        guard backend.isSupported else { return false }
        if preparedFor == nonce, prepared != nil { return true }
        for attempt in 0..<2 {
            do {
                var keyId: String
                var needsAttestation: Bool
                if let k = store.load() { keyId = k.keyId; needsAttestation = !k.attested }
                else { keyId = try await backend.generateKey(); store.save(keyId: keyId, attested: false); needsAttestation = true }
                var attestation: Data?
                if needsAttestation { attestation = try await backend.attestKey(keyId, clientDataHash: AttestHash.attestChallenge(nonce: nonce)) }
                prepared = (keyId, attestation); preparedFor = nonce
                return true
            } catch {
                // A key that cannot be attested again (attested earlier, upload lost) or is no longer valid: start over with a new key.
                store.clear()
                if attempt == 1 { return false }
            }
        }
        return false
    }

    /// The assertion for one submission, or nil. On `invalidKey` (reinstall) a new key is attested and the assertion made with it.
    func sign(nonce: Data, path: String, proofs: [(circuit: String, proof: Data)], sdk: String) async -> AttestPayload? {
        if preparedFor != nonce || prepared == nil { guard await prepare(nonce: nonce) else { return nil } }
        let cdh = AttestHash.assertionHash(nonce: nonce, proofHash: AttestHash.proofHash(path: path, proofs: proofs), sdk: sdk)
        for attempt in 0..<2 {
            guard let p = prepared else { return nil }
            do {
                let a = try await backend.generateAssertion(p.keyId, clientDataHash: cdh)
                return AttestPayload(keyId: p.keyId, assertion: a, attestation: p.attestation)
            } catch {
                store.clear(); prepared = nil; preparedFor = nil
                if attempt == 1 { return nil }
                let again = await prepare(nonce: nonce)
                if !again { return nil }
            }
        }
        return nil
    }

    /// Call after the verifier answered `verified`: the key is then known to the verifier, so later proofs send only the assertion.
    func markAttested() {
        if let p = prepared { store.save(keyId: p.keyId, attested: true); prepared = (p.keyId, nil) }
    }
}

/// The proof body with `sdk` and `attest` added. The proofs stay byte for byte what the Rust core produced.
enum AttestBody {
    static func parse(_ body: String) -> (path: String, proofs: [(circuit: String, proof: Data)])? {
        guard let d = body.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let path = j["path"] as? String, let items = j["proofs"] as? [[String: Any]] else { return nil }
        var out: [(String, Data)] = []
        for i in items {
            guard let c = i["circuit"] as? String, let h = i["proof"] as? String, let bytes = unhex(h) else { return nil }
            out.append((c, bytes))
        }
        return (path, out)
    }
    static func unhex(_ h: String) -> Data? {
        let u = Array(h.utf8)
        guard u.count % 2 == 0 else { return nil }
        var out = Data(capacity: u.count / 2)
        func v(_ c: UInt8) -> UInt8? { switch c { case 48...57: return c - 48; case 97...102: return c - 87; case 65...70: return c - 55; default: return nil } }
        var i = 0
        while i < u.count { guard let a = v(u[i]), let b = v(u[i + 1]) else { return nil }; out.append(a << 4 | b); i += 2 }
        return out
    }
    static func add(to body: String, sdk: String, attest: AttestPayload?) -> String {
        guard let d = body.data(using: .utf8), var j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return body }
        j["sdk"] = sdk
        if let a = attest {
            var o: [String: Any] = ["keyId": a.keyId, "assertion": a.assertion.base64EncodedString()]
            if let at = a.attestation { o["attestation"] = at.base64EncodedString() }
            j["attest"] = o
        }
        guard let out = try? JSONSerialization.data(withJSONObject: j), let s = String(data: out, encoding: .utf8) else { return body }
        return s
    }
}
