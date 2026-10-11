// Nod ID SDK: handoff to the Nod ID app (decision 56; wire contract in nodid-app docs/HANDOFF_PROTOCOL.md).
// When the app allows it and the Nod ID app is installed, the flow asks the verifier for a handoff (host App Attest over `nodid.handoff.v1`),
// opens https://nodid.app/r#<session>.<handoff> with `universalLinksOnly`, and waits. The Nod ID app proves and opens the host's registered
// return link with a single-use token; `NodID.handle(_:)` confirms it. If the Nod ID app is not installed, the usual flow runs.
// Nothing here touches passport data.
import SwiftUI
import UIKit

public extension NodID {
    /// Pass every universal link your app receives (SwiftUI `.onOpenURL`, or `scene(_:continue:)`). Returns `true` when it was a Nod ID return
    /// for the verification on screen; the sheet then finishes with the outcome. Links for any other session are ignored.
    @MainActor @discardableResult
    static func handle(_ url: URL) -> Bool { NodIDHandoff.shared.handle(url) }
}

/// The one verification that is waiting for the Nod ID app, if any.
@MainActor
final class NodIDHandoff {
    static let shared = NodIDHandoff()
    private weak var model: NodIDFlowModel?
    private var sessionId: String?

    func wait(_ m: NodIDFlowModel, sessionId: String) { model = m; self.sessionId = sessionId }
    func clear(_ m: NodIDFlowModel) { if model === m { model = nil; sessionId = nil } }

    func handle(_ url: URL) -> Bool {
        guard let (sid, token) = HandoffLink.parseReturn(url), let m = model, sid == sessionId else { return false }
        m.settleHandoff(token: token)
        return true
    }
}

extension NodIDFlowModel {
    /// After the policy: hand off when the app allows it and the Nod ID app opens; otherwise the passport flow on this screen.
    func beginAfterPolicy(_ p: SessionPolicy) async {
        guard p.appHandoff, let link = await services.startHandoff(sessionId: sessionId) else { go(.intro); return }
        handoffLink = link
        if await UIApplication.shared.open(link, options: [.universalLinksOnly: true]) {
            NodIDHandoff.shared.wait(self, sessionId: sessionId)
            go(.handoff)
        } else {
            go(.intro)                 // not installed: the handoff id simply expires; this flow submits as before
        }
    }

    func reopenNodIDApp() {
        guard let link = handoffLink else { return }
        Task { _ = await UIApplication.shared.open(link, options: [.universalLinksOnly: true]) }
    }

    /// The member chose to verify here: the verifier still accepts this app's own proof for the session.
    func verifyHereInstead() { NodIDHandoff.shared.clear(self); go(.intro) }

    func settleHandoff(token: String) {
        let (svc, id) = (services, sessionId)
        Task { [weak self] in
            let outcome = await svc.confirmHandoff(sessionId: id, returnToken: token)
            guard let self else { return }
            handoffSettled = outcome != nil
            switch outcome {
            case "verified": finish(.verified)
            case "not_verified": finish(.notVerified)
            case "cancelled": finish(.cancelled)
            case "technical_error": finish(.technicalError)
            default: finish(.notVerified)          // not accepted (expired, already used): never "verified"
            }
        }
    }
}

/// Waiting screen while the member is in the Nod ID app.
struct HandoffScreen: View {
    let model: NodIDFlowModel
    var body: some View {
        StatusLayout(symbol: "arrow.up.forward.app", title: "Continue in Nod ID",
                     reason: "Finish in the Nod ID app. It answers \(model.app) with Face ID and brings you back here.",
                     next: "Your passport stays on your iPhone. \(model.app) only learns the answer.") {
            NodPrimaryButton(title: "Open Nod ID Again") { model.reopenNodIDApp() }
            NodSecondaryButton(title: "Verify Here Instead") { model.verifyHereInstead() }
        }
    }
}

// MARK: Nod ID app support (SPI; used only by the Nod ID app)

/// How the Nod ID app submits a proof for a handed-off session: its own App Attest key for this app scope (never shared between scopes),
/// the handoff id, and the read mode (`fresh` = chip read during this request, `stored` = from data stored on this iPhone).
@_spi(NodIDApp) public struct AppSubmission {
    public enum Read: UInt8 { case fresh = 1, stored = 2 }
    public let handoffId: String
    public let read: UInt8
    let attest: AppAttest
    public init(handoffId: String, read: Read, appScope: String) {
        self.handoffId = handoffId; self.read = read.rawValue
        attest = AppAttest(store: KeychainAttestStore(service: "app.nodid.id.attest", scope: appScope))
    }
}

@_spi(NodIDApp) public extension RealChip {
    /// Copies of SOD and DG1 for the Nod ID app's encrypted store (decision 56). The caller wipes its copies.
    func copyBytes() -> (sod: [UInt8], dg1: [UInt8]) { (sod, dg1) }
}

@_spi(NodIDApp) public enum NodIDKitInfo {
    public static var sdkVersion: String { NodIDVersion.sdk }
    /// Test hooks for the Nod ID app's golden-vector test.
    public static func handoffHash(nonce: Data) -> Data { AttestHash.handoffHash(nonce: nonce) }
    public static func appAssertionHash(nonce: Data, proofHash: Data, handoffId: Data, read: UInt8, sdk: String) -> Data {
        AttestHash.appAssertionHash(nonce: nonce, proofHash: proofHash, handoffId: handoffId, read: read, sdk: sdk)
    }
}

/// The SDK's camera scan of the two lines, for the Nod ID app's add flow (frames in memory only, nothing saved; see `MRZScanner`).
@_spi(NodIDApp) public final class AppMRZScanner {
    private let scanner = MRZScanner()
    public init() {}
    public var onRead: ((MRZData) -> Void)? { get { scanner.onRead } set { scanner.onRead = newValue } }
    public var onUnavailable: (() -> Void)? { get { scanner.onUnavailable } set { scanner.onUnavailable = newValue } }
    public var hasTorch: Bool { scanner.hasTorch }
    public func start() { scanner.start() }
    public func stop() { scanner.stop() }
    public func setTorch(_ on: Bool) { scanner.setTorch(on) }
    public var preview: some View { CameraPreview(session: scanner.session) }
    /// Validates two typed lines' worth of details the same way as a scan (check digits are not available when typed).
    public static func parse(line1: String, line2: String) -> MRZData? { MRZParser.parse(line1: line1, line2: line2) }
}
