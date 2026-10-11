// Nod ID SDK: publishable test key parsing and the setup errors a developer can hit (quickstart, decision 55).
// A test key is `nod_pk_test_<id>_<check>`: id = 22 characters of [A-Za-z0-9], check = first 4 lowercase hex characters of
// SHA-256 over the UTF-8 bytes of "nodid-test-key:" + id (the same as verifier/src/registry.rs test_key_check). The check only catches paste errors offline; it is not a secret and proves nothing.
// This file has no passport data and no network. It is compiled in every configuration (Release uses it to refuse keys with a clear error).
import CryptoKit
import Foundation

/// What a key string turned out to be.
enum NodIDKeyKind: Equatable {
    case test(id: String)          // a well-formed publishable test key
    case secret                    // nod_sk_...: belongs on the backend
    case placeholder               // empty or "PASTE_..."
    case mistyped                  // looks like a test key but length, characters or checksum are wrong
    case unsupportedPublishable    // nod_pk_ of another kind (there is no publishable live key)
    case notAKey
}

/// Why `NodID.verify(key:)` could not start. `errorDescription` is the exact fix text (the same text the debug setup checker prints).
public enum NodIDError: Error, Equatable, LocalizedError {
    case secretKeyInApp
    case placeholderKey
    case badKey
    case liveKeyNotSupported
    case notAKey
    case nothingToPresentFrom

    public var errorDescription: String? { fixText }

    /// Exact text shown to the developer.
    public var fixText: String {
        switch self {
        case .secretKeyInApp: return NodIDKeyText.secret
        case .placeholderKey: return NodIDKeyText.placeholder
        case .badKey: return NodIDKeyText.mistyped
        case .liveKeyNotSupported: return NodIDKeyText.liveKey
        case .notAKey: return NodIDKeyText.notAKey
        case .nothingToPresentFrom: return "Nothing to present from: no visible window. Call NodID.verify(key:) after your first screen has appeared, or show NodIDVerifyView yourself."
        }
    }
}

enum NodIDKeyText {
    static let secret = "Secret key (nod_sk_) found in the app. Remove it: it belongs on your backend only. For the Simulator use your test key: nod_pk_test_..."
    static let mistyped = "Key looks mistyped (checksum). Copy it again from dashboard.nodid.app > your app > Test key."
    static let placeholder = "Placeholder key still in place. Paste your test key in ContentView.swift."
    static let liveKey = "Only test keys (nod_pk_test_...) work in the app. A live verification needs a session id made by your backend with your secret key: use NodIDVerifyView(sessionId:)."
    static let notAKey = "That is not a Nod ID key. Test keys look like nod_pk_test_... (dashboard.nodid.app > your app > Test key)."
    static let releaseBuild = "Test keys do not run in Release builds. Remove the test key and use NodIDVerifyView(sessionId:) with a session made by your backend."
}

/// A parsed publishable test key.
struct NodIDTestKey: Equatable {
    static let prefix = "nod_pk_test_"
    let id: String

    static func check(forId id: String) -> String {
        let d = SHA256.hash(data: Data(("nodid-test-key:" + id).utf8))
        return d.prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    static func classify(_ raw: String) -> NodIDKeyKind {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty || k.uppercased().contains("PASTE") { return .placeholder }
        if k.hasPrefix("nod_sk_") { return .secret }
        if k.hasPrefix(prefix) {
            let rest = k.dropFirst(prefix.count)
            guard let us = rest.lastIndex(of: "_") else { return .mistyped }
            let id = String(rest[rest.startIndex..<us]), chk = String(rest[rest.index(after: us)...])
            let alnum = { (s: String) in s.unicodeScalars.allSatisfy { $0.isASCII && (("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)) } }
            guard id.count == 22, alnum(id), chk.count == 4, chk == check(forId: id) else { return .mistyped }
            return .test(id: id)
        }
        if k.hasPrefix("nod_pk_") { return .unsupportedPublishable }
        return .notAKey
    }

    /// Throws the exact-fix error for anything that is not a well-formed test key.
    static func parse(_ raw: String) throws -> NodIDTestKey {
        switch classify(raw) {
        case .test(let id): return NodIDTestKey(id: id)
        case .secret: throw NodIDError.secretKeyInApp
        case .placeholder: throw NodIDError.placeholderKey
        case .mistyped: throw NodIDError.badKey
        case .unsupportedPublishable: throw NodIDError.liveKeyNotSupported
        case .notAKey: throw NodIDError.notAKey
        }
    }
}
