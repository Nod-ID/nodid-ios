// Nod ID SDK: public surface of the member flow and the privacy helpers around it.
// RULE: nothing in the UI files prints, logs, stores or transmits passport data (MRZ values, chip data).
import SwiftUI
import UIKit

/// The ONLY thing the host app learns. Never a reason (rule 7 in CLAUDE.md).
public enum NodIDOutcome { case verified, notVerified, cancelled, technicalError }

/// Host-app integration notes.
///
/// State restoration: the SDK cannot own the app delegate. The host's `UIApplicationDelegate` must opt out, so the
/// OS never writes view state (which could include text field contents) to disk:
/// ```
/// func application(_ app: UIApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool { NodID.disableStateRestoration() }
/// func application(_ app: UIApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool { NodID.disableStateRestoration() }
/// ```
public enum NodID {
    /// Call once at app launch. Downloads and checks the proving files (about 46 MB, first run only) in the background, so they are ready before
    /// a member opens the flow. Nothing happens when the files are already on the phone. It continues where it stopped if the app is closed,
    /// and by default waits for Wi-Fi; pass `allowCellular: true` to download over mobile data too. If a member opens the flow before it is done,
    /// the flow finishes the download over any network and shows the progress.
    public static func prefetch(allowCellular: Bool = false) { RealServices.prefetch(allowCellular: allowCellular) }

    /// Always `false`. Return it from both delegate methods above.
    public static func disableStateRestoration() -> Bool { false }
}

/// Covers the key window with an opaque view while the app is inactive, so the app-switcher snapshot never shows
/// the camera feed, the typed details or the receipt. Installed by `NodIDVerifyView` while it is on screen.
@MainActor
public final class SnapshotCover {
    public static let shared = SnapshotCover()
    private var observers: [NSObjectProtocol] = []
    private var cover: UIView?
    private init() {}

    public func install() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        })
    }

    public func remove() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        hide()
    }

    private func show() {
        guard cover == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first else { return }
        let v = UIView(frame: window.bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.backgroundColor = .systemBackground
        let icon = UIImageView(image: UIImage(systemName: "lock.shield.fill"))
        icon.tintColor = .secondaryLabel
        icon.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(icon)
        NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: v.centerXAnchor), icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                                     icon.widthAnchor.constraint(equalToConstant: 56), icon.heightAnchor.constraint(equalToConstant: 56)])
        window.addSubview(v)
        cover = v
    }

    private func hide() { cover?.removeFromSuperview(); cover = nil }
}
