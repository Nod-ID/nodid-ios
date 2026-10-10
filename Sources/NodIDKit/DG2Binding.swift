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
