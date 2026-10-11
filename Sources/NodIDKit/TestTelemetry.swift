// Nod ID SDK: the test-mode metric ping, as a contract only (quickstart design section 6).
// Nothing in this SDK sends it: the default is `NoopTelemetry`, and the call site exists only in Debug builds with a test key.
// Contract for the transport the server side will provide (not built here):
//   POST /v1/test/ping   Authorization: Bearer <publishable test key>
//   body {"event":"started"|"verified","sdk":"<version>","simulator":true|false}
// `verified` is sent only for a verified outcome. No device id, no sample letter, no reasons, no personal data.
// Opt out: `NodID.setTestTelemetry(false)`.
import Foundation

public struct NodIDTelemetryEvent: Codable, Equatable {
    public enum Kind: String, Codable { case started, verified }
    public let event: Kind
    public let sdk: String
    public let simulator: Bool
    public init(event: Kind, sdk: String, simulator: Bool) { self.event = event; self.sdk = sdk; self.simulator = simulator }
}

/// Implemented by a transport; the SDK ships only the no-op.
public protocol NodIDTelemetry: Sendable {
    func send(_ event: NodIDTelemetryEvent, testKey: String) async
}

/// Does nothing. The default.
public struct NoopTelemetry: NodIDTelemetry {
    public init() {}
    public func send(_ event: NodIDTelemetryEvent, testKey: String) async {}
}

enum TelemetryState {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var enabled = true
    nonisolated(unsafe) private static var sink: NodIDTelemetry = NoopTelemetry()
    static var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    static func setEnabled(_ on: Bool) { lock.lock(); enabled = on; lock.unlock() }
    static var current: NodIDTelemetry { lock.lock(); defer { lock.unlock() }; return sink }
    static func set(_ t: NodIDTelemetry) { lock.lock(); sink = t; lock.unlock() }
}
