// Nod ID SDK: the parts of the Nod ID app handoff that need only Foundation (decision 56), so the Mac check can compile them.
import Foundation

enum HandoffLink {
    /// `<return link>#nodid=<session id>.<return token>`, both hex. Anything else is not a Nod ID return.
    static func parseReturn(_ url: URL) -> (String, String)? {
        guard url.scheme == "https", let f = url.fragment, f.hasPrefix("nodid=") else { return nil }
        let parts = f.dropFirst(6).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 64 && $0.allSatisfy { $0.isHexDigit } }) else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
}

extension AttestBody {
    static func object(_ a: AttestPayload) -> [String: Any] {
        var o: [String: Any] = ["keyId": a.keyId, "assertion": a.assertion.base64EncodedString()]
        if let at = a.attestation { o["attestation"] = at.base64EncodedString() }
        return o
    }
    /// The Nod ID app's submission adds the handoff id and the read mode (1 fresh, 2 stored); both are covered by its assertion.
    static func addHandoff(to body: String, handoffId: String, read: UInt8) -> String {
        guard let d = body.data(using: .utf8), var j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return body }
        j["handoffId"] = handoffId
        j["read"] = read == 2 ? "stored" : "fresh"
        guard let out = try? JSONSerialization.data(withJSONObject: j), let s = String(data: out, encoding: .utf8) else { return body }
        return s
    }
}
