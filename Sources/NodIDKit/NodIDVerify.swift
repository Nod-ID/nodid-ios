// Nod ID SDK: the one-liner for the quickstart (decision 55). Test keys only; live stays NodIDVerifyView(sessionId:).
//   let outcome = try await NodID.verify(key: "nod_pk_test_...")
// The host gets a `NodIDOutcome` and nothing else (rule 7). In a Release build the test engine does not exist: a valid test key
// returns `.technicalError` and logs one line, so a test key can never ship as an always-yes gate.
import Foundation
import os
import SwiftUI
import UIKit

extension NodID {
    /// Test key only. Presents the flow from the top view controller and returns the outcome.
    /// Throws `NodIDError` only for setup errors (secret key in the app, mistyped or placeholder key, a non-test key, nothing to present from).
    /// Cancel and failures come back as `.cancelled` and `.technicalError`. Release builds return `.technicalError` for a valid test key.
    @MainActor public static func verify(key: String) async throws -> NodIDOutcome {
        let parsed = try NodIDTestKey.parse(key)
        #if DEBUG
        return try await runTest(parsed, key: key).outcome
        #else
        _ = parsed
        Logger(subsystem: "app.nodid.sdk", category: "setup").error("[NodID setup] \(NodIDKeyText.releaseBuild, privacy: .public)")
        return .technicalError
        #endif
    }

    /// One-line opt-out of the debug-build test ping (does nothing in Release).
    public static func setTestTelemetry(_ on: Bool) { TelemetryState.setEnabled(on) }
    /// Test apps only: inject a transport (or a recorder).
    @_spi(Testing) public static func setTelemetryTransport(_ t: NodIDTelemetry) { TelemetryState.set(t) }
}

#if DEBUG
extension NodID {
    /// Debug only: like `verify(key:)` but returns the test result JSON shape (decision 47 keys plus `mode: "test"`). Compiled out of Release.
    @MainActor public static func verifyDetailed(key: String) async throws -> NodIDTestResult {
        let parsed = try NodIDTestKey.parse(key)
        return try await runTest(parsed, key: key).result
    }

    @MainActor fileprivate static func runTest(_ parsed: NodIDTestKey, key: String) async throws -> (outcome: NodIDOutcome, result: NodIDTestResult) {
        NodIDSetupCheck.runOnce(key: key)
        let services = TestServices(key: parsed, keyString: key.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let top = TestPresenter.topViewController() else { throw NodIDError.nothingToPresentFrom }
        let outcome: NodIDOutcome = await withCheckedContinuation { cont in
            TestPresenter.present(from: top, services: services) { cont.resume(returning: $0) }
        }
        let name: String
        switch outcome { case .verified: name = "verified"; case .notVerified: name = "not_verified"
        case .cancelled: name = "cancelled"; case .technicalError: name = "technical_error" }
        return (outcome, services.result(outcome: name))
    }
}

/// Presents `NodIDVerifyView` in a sheet and reports once, whether it finished or the member swiped it away.
@MainActor private final class TestPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    private var done: ((NodIDOutcome) -> Void)?
    private static var live: TestPresenter?

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first
        var vc = window?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }

    static func present(from top: UIViewController, services: TestServices, completion: @escaping (NodIDOutcome) -> Void) {
        let p = TestPresenter(); p.done = completion; live = p
        var host: UIHostingController<NodIDVerifyView>?
        let view = NodIDVerifyView(sessionId: "tst_" + UUID().uuidString.prefix(12).lowercased(), services: services) { outcome in
            host?.dismiss(animated: true)
            p.finish(outcome)
        }
        let h = UIHostingController(rootView: view)
        host = h
        h.modalPresentationStyle = .pageSheet
        h.presentationController?.delegate = p
        top.present(h, animated: true)
    }

    private func finish(_ o: NodIDOutcome) {
        guard let d = done else { return }
        done = nil; Self.live = nil
        d(o)
    }

    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        MainActor.assumeIsolated { finish(.cancelled) }
    }
}
#endif
