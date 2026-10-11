import Foundation

/// The DG2 commitment's private inputs for the face prover (decision 52): `hi` and `lo` (the two halves of the DG2 digest from the signed SOD) and
/// the blinding value `r`, each a 32-byte big-endian field element. The face proof must use exactly these values so that its `C` equals the passport
/// proof's `C`.
///
/// Memory only. It is never logged, stored or sent; the SDK overwrites it when the proof session ends (`wipe()`), and again in `deinit`. A holder
/// reads it inside `withValues` and must not copy it out; a copy is the holder's to wipe.
@_spi(Face) public final class DG2Binding: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8]          // hi || lo || r

    init?(_ data: Data) {
        guard data.count == 96 else { return nil }
        bytes = [UInt8](data)
    }

    /// Calls `body(hi, lo, r)` with the values, or returns nil if the binding has been wiped.
    public func withValues<T>(_ body: (_ hi: ArraySlice<UInt8>, _ lo: ArraySlice<UInt8>, _ r: ArraySlice<UInt8>) throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard !bytes.isEmpty else { return nil }
        return try body(bytes[0..<32], bytes[32..<64], bytes[64..<96])
    }

    public var isWiped: Bool { lock.lock(); defer { lock.unlock() }; return bytes.isEmpty }

    /// Overwrite with zeros and drop. Safe to call twice.
    public func wipe() {
        lock.lock(); defer { lock.unlock() }
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
        bytes.removeAll()
    }

    deinit { wipe() }
}

/// The DG2 commitment `C` of the passport proof that was just made (public value index 9 of the data-stage proof, ten values in all; decision 52),
/// for the face flow to compare with the `C` of its own face proof. `C` is a public output of the proof, not a secret, but it follows the same rule as
/// `DG2Binding`: memory only, never logged, stored or sent by the SDK, wiped when the proof session ends. Not part of the public API.
@_spi(Face) public final class PassportCommitment: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8]          // 32 bytes, big-endian field element

    init?(_ data: Data) {
        guard data.count == 32 else { return nil }
        bytes = [UInt8](data)
    }

    /// `C` from one proof's bytes (4-byte big-endian count, then 32-byte public values). Nil unless the proof has exactly ten public values, so an
    /// `m2` proof (nine values, no commitment) and anything malformed give nil.
    static func from(proof: Data) -> PassportCommitment? {
        let p = [UInt8](proof)
        guard p.count >= 4 else { return nil }
        let n = Int(p[0]) << 24 | Int(p[1]) << 16 | Int(p[2]) << 8 | Int(p[3])
        guard n == 10, p.count >= 4 + 32 * n else { return nil }
        return PassportCommitment(Data(p[(4 + 32 * 9)..<(4 + 32 * 10)]))
    }

    /// Calls `body(c)` with the 32 bytes, or returns nil if it has been wiped.
    public func withValue<T>(_ body: (_ c: ArraySlice<UInt8>) throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard !bytes.isEmpty else { return nil }
        return try body(bytes[0..<32])
    }

    public var isWiped: Bool { lock.lock(); defer { lock.unlock() }; return bytes.isEmpty }

    public func wipe() {
        lock.lock(); defer { lock.unlock() }
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
        bytes.removeAll()
    }

    deinit { wipe() }
}
