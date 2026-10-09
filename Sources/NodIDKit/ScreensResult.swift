// Nod ID SDK screens 07a to 07i, 08a, 08b and 09.
import SwiftUI
import PassKit

// MARK: 07a
struct SuccessScreen: View {
    let model: NodIDFlowModel
    @Environment(\.nod) private var nod
    var body: some View {
        let app = model.app
        NodScreen {
            VStack(spacing: 16) {
                ZStack { Circle().fill(nod.acc); Image(systemName: "checkmark").font(.system(size: 36, weight: .bold)).foregroundStyle(nod.onAcc) }
                    .frame(width: 76, height: 76).accessibilityHidden(true).padding(.top, 8)
                Text("Verified").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text(model.showAge ? "\(app) now knows you're over \(model.minAge), and nothing about who you are." : "\(app) now knows you passed the checks, and nothing about who you are.")
                    .nodBody().multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 6) {
                    Text("What \(app) received").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
                    NodCard {
                        HStack { Text("Result"); Spacer(); Text("Verified").foregroundStyle(.secondary) }
                            .padding(.horizontal, 16).frame(minHeight: 44).accessibilityElement(children: .combine)
                    }
                }
                Text("The details read from your passport have been deleted from this iPhone.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            NodPrimaryButton(title: "Done") { model.backToHost(.verified) }
            NodSecondaryButton(title: "View Receipt") { model.go(.receipt) }
        }
    }
}

// MARK: 09
struct ReceiptScreen: View {
    let model: NodIDFlowModel
    private var dateText: String { model.receiptDate.formatted(date: .long, time: .omitted) }
    private var shortDate: String { model.receiptDate.formatted(date: .abbreviated, time: .omitted) }
    private var rows: [(String, String)] {
        var r: [(String, String)] = []
        let p = model.policy
        if model.showAge { r.append(("Over \(model.minAge)", "Yes")) }
        if p?.checkExpiry ?? false { r.append(("Passport valid", "Yes")) }
        if p?.checkCountry ?? false { r.append(("Country accepted", "Yes")) }
        r.append(("Date", dateText)); r.append(("Reference", model.reference ?? ""))
        return r
    }
    private var shareText: String {
        (["Nod ID proof receipt", "For \(model.app)"] + rows.map { "\($0.0): \($0.1)" }).joined(separator: "\n")
    }
    var body: some View {
        NodScreen {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack { HStack(spacing: 6) { NodMark(height: 17.5); Text("Nod ID").font(.subheadline.weight(.semibold)) }.accessibilityElement(children: .combine); Spacer(); Text(shortDate).font(.subheadline).foregroundStyle(.secondary) }
                        .padding(16)
                    Divider()
                    Text("Proof receipt").font(.title2.weight(.bold)).padding(.horizontal, 16).padding(.top, 14).accessibilityAddTraits(.isHeader)
                    Text("For \(model.app)").font(.body).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        Divider().padding(.leading, 16)
                        HStack(alignment: .firstTextBaseline) { Text(r.0); Spacer(); Text(r.1).foregroundStyle(.secondary).monospacedDigit() }
                            .padding(.horizontal, 16).frame(minHeight: 44).accessibilityElement(children: .combine)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                Text("This receipt holds no personal data. It shows only what was proven, and when.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            ShareLink(item: shareText) {
                Label("Share Receipt", systemImage: "square.and.arrow.up").font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                    .modifier(PrimaryLabelStyle())
            }.buttonStyle(.plain)
            NodSecondaryButton(title: "Done") { model.backToHost(.verified) }
        }
    }
}
private struct PrimaryLabelStyle: ViewModifier {
    @Environment(\.nod) private var nod
    func body(content: Content) -> some View { content.foregroundStyle(nod.onAcc).background(Capsule().fill(nod.acc)) }
}

// MARK: 07b to 07i, 07g
struct FailureScreen: View {
    let model: NodIDFlowModel
    let kind: FlowFailure
    @Environment(\.openURL) private var openURL
    var body: some View {
        let app = model.app
        switch kind {
        case .chipUnreadable:
            // First-class fallback: specific retry help, then the digital ID (only when the app offers it), another document, and help.
            let offerWallet = model.policy?.offerDigitalId == true
            if model.lastChipFailure == .unsupported {
                StatusLayout(symbol: "exclamationmark", title: "This iPhone can't read passport chips",
                             reason: "Passport chips are read with NFC, and this iPhone doesn't support it. Nothing was shared.",
                             next: "You can confirm your age another way.") {
                    if offerWallet { NodPrimaryButton(title: "Use a Digital ID Instead") { model.go(.digitalId) } }
                    if offerWallet { NodSecondaryButton(title: "See Other Options") { model.go(.noPassport) } } else { NodPrimaryButton(title: "See Other Options") { model.go(.noPassport) } }
                    helpButton
                }
            } else if model.chipAttempts >= 2 {
                StatusLayout(symbol: "exclamationmark", title: "Still can't read the chip",
                             reason: "Nothing was shared or saved. A few chips are harder to read than others, and some older passports have no chip at all.",
                             next: "Look for the chip symbol on the cover. If it's there, try each spot once: the front cover, the back cover and the photo page. Take off any case, keep your phone still for the whole read, and keep cards or metal away from it. If your passport has no chip, or you have a second passport, use another way.") {
                    NodPrimaryButton(title: "Try Again") { model.retryChip() }
                    if offerWallet { NodSecondaryButton(title: "Use a Digital ID Instead") { model.go(.digitalId) } }
                    NodTertiaryButton(title: "Use Another Document") { model.go(.noPassport) }
                    helpButton
                }
            } else {
                StatusLayout(symbol: "exclamationmark", title: "We couldn't read the chip",
                             reason: "This can happen if your iPhone is in a thick case, or moves during the scan. Nothing was shared.",
                             next: "Take your iPhone out of its case. Close your passport and hold the top of your iPhone flat on the cover until it says Done. You can also try another spot on the passport.") {
                    NodPrimaryButton(title: "Try Again") { model.retryChip() }
                    if offerWallet { NodSecondaryButton(title: "Use a Digital ID Instead") { model.go(.digitalId) } }
                    NodTertiaryButton(title: "Use Another Document") { model.go(.noPassport) }
                    helpButton
                }
            }
        case .keyMismatch:
            StatusLayout(symbol: "exclamationmark", title: "These details don't open the chip",
                         reason: "One of the details you typed may not match your passport. Nothing was read or shared.",
                         next: "Check the passport number and dates against your photo page, or scan the page with the camera instead.") {
                NodPrimaryButton(title: "Check the Details") { model.go(.manual) }
                NodSecondaryButton(title: "Scan the Page Instead") { model.scanOrPermission() }
            }
        case .camDenied:
            StatusLayout(symbol: "camera", title: "Camera access is off",
                         reason: "Your iPhone needs the camera to read the two lines on your photo page. Nothing is recorded or saved.",
                         next: "Turn on camera access for \(app) in Settings, or type the two lines in yourself.") {
                NodPrimaryButton(title: "Open Settings") { model.openSettings() }
                NodSecondaryButton(title: "Type the Lines Instead") { model.go(.manual) }
            }
        case .expired:
            StatusLayout(symbol: "calendar", title: "This passport has expired",
                         reason: "\(app) needs a passport that is still valid. \(app) only learns that you weren't verified, not why.",
                         next: "If you have a newer passport, use that one. You can also use a digital ID instead.") {
                NodPrimaryButton(title: "Use Another Passport") { model.scanOrPermission() }
                NodSecondaryButton(title: "Use a Digital ID Instead") { model.go(.digitalId) }
            }
        case .underage:
            StatusLayout(symbol: "info", title: "You need to be \(model.minAge) or over to join \(app)",
                         reason: "We couldn't confirm that you're over \(model.minAge). \(app) only learns that you weren't verified, not why. Your passport details stay on your phone.",
                         next: "If you used a different passport by mistake, you can try again with your own.") {
                NodPrimaryButton(title: "Back to \(app)") { model.backToHost(.notVerified) }
                NodSecondaryButton(title: "Try Again") { model.scanOrPermission() }
            }
        case .used:
            StatusLayout(symbol: "person", title: "This passport is already linked to a \(app) account",
                         reason: "Each person can have one \(app) account. \(app) only learns that you weren't verified, not why.",
                         next: "If you already have an account, sign in to it. If you don't recognise it, contact \(app) support and they'll help.") {
                NodPrimaryButton(title: "Sign In Instead") { model.backToHost(.notVerified) }
                if let u = model.policy?.helpURL { NodSecondaryButton(title: "Contact \(app) Support") { openURL(u) } }
            }
        case .country:
            StatusLayout(symbol: "globe", title: "\(app) can't accept this passport yet",
                         reason: "\(app) accepts passports from a set list of countries. \(app) only learns that you weren't verified, not why or which country.",
                         next: "You can use a digital ID instead, or see what else \(app) accepts.") {
                if model.policy?.offerDigitalId == true { NodPrimaryButton(title: "Use a Digital ID Instead") { model.go(.digitalId) } }
                NodSecondaryButton(title: "See Other Options") { model.go(.noPassport) }
            }
        case .technical:
            // Copy for this screen is not in the copy deck; written to match its tone. Flagged in the report.
            StatusLayout(symbol: "xmark", title: "Something went wrong",
                         reason: "We couldn't finish the check. Nothing was shared with \(app).",
                         next: "Check your connection and try again. Your passport details stay on your phone.") {
                NodPrimaryButton(title: "Try Again") { model.retryTechnical() }
                NodSecondaryButton(title: "Back to \(app)") { model.backToHost(.technicalError) }
                helpButton
            }
        }
    }
    @ViewBuilder private var helpButton: some View {
        if let u = model.policy?.helpURL { NodTertiaryButton(title: "Get Help") { openURL(u) } }
    }
}

struct CancelledScreen: View {
    let model: NodIDFlowModel
    var body: some View {
        StatusLayout(symbol: "xmark", title: "Verification cancelled", reason: "Nothing was saved or shared with \(model.app).",
                     next: "You can start again whenever you're ready. You'll need your passport.") {
            NodPrimaryButton(title: "Start Again") { model.restart() }
            NodSecondaryButton(title: "Back to \(model.app)") { model.backToHost(.cancelled) }
        }
    }
}

// MARK: 08a
/// The button is Apple's `PKIdentityButton`. The request behind it waits for the Verify with Wallet entitlement (decision 23).
struct DigitalIDScreen: View {
    let model: NodIDFlowModel
    @State private var notAvailable = false
    var body: some View {
        NodScreen {
            VStack(alignment: .leading, spacing: 16) {
                NodTitle(text: "Use your digital ID")
                Text("If you've added an ID to Apple Wallet, you can confirm your age from there. \(model.app) still only learns that you're over \(model.minAge).").nodBody()
                NodCard {
                    HStack(spacing: 12) {
                        Image(systemName: "wallet.pass.fill").font(.system(size: 20)).foregroundStyle(IntroAccent()).frame(width: 40, height: 40)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ID in Apple Wallet").font(.body.weight(.semibold))
                            Text("Driver's licence, state ID or Digital ID").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(16).accessibilityElement(children: .combine)
                }
                Text("Wallet shows you what will be shared before you confirm. On Android phones, the same option uses Google Wallet.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if notAvailable { Text("Digital ID isn't available yet. Use your passport instead.").font(.subheadline.weight(.medium)).accessibilityAddTraits(.updatesFrequently) }
            }
        } footer: {
            // Apple's own button, unmodified (design 08a). It does nothing until Apple grants the Verify with Wallet entitlement
            // (decision 23): the tap tells the member so rather than failing silently.
            WalletButton {
                notAvailable = true
                UIAccessibility.post(notification: .announcement, argument: "Digital ID isn't available yet.")
            }.frame(maxWidth: .infinity, minHeight: 52).accessibilityLabel("Verify with Wallet")
            NodSecondaryButton(title: "Use My Passport Instead") { model.go(.need) }
        }
    }
}

// MARK: 08b
/// The options come from the app's dashboard settings, through the session policy: text rows, plus the Wallet when the app offers it.
struct NoPassportScreen: View {
    let model: NodIDFlowModel
    @Environment(\.openURL) private var openURL
    var body: some View {
        let p = model.policy
        let wallet = p?.offerDigitalId == true
        let others = p?.alternatives ?? []
        NodScreen {
            VStack(alignment: .leading, spacing: 16) {
                NodTitle(text: "No passport? Here's what else works")
                Text(wallet || !others.isEmpty ? "\(model.app) accepts these other ways to confirm your age." : "\(model.app) needs a passport with a chip for this check.").nodBody()
                NodCard {
                    if wallet { row("wallet.pass.fill", "A digital ID in Apple Wallet", nil) }
                    ForEach(Array(others.enumerated()), id: \.offset) { i, a in
                        if wallet || i > 0 { Divider().padding(.leading, 68) }
                        row("checkmark.circle.fill", a.title, a.detail.isEmpty ? nil : a.detail)
                    }
                    if wallet || !others.isEmpty { Divider().padding(.leading, 68) }
                    row("questionmark.circle.fill", "Ask \(model.app) about other options", "\(model.app)'s support team can tell you what else they accept.")
                }
                if wallet || !others.isEmpty { Text("\(model.app) chooses which options to offer.").font(.footnote).foregroundStyle(.secondary) }
            }
        } footer: {
            if wallet { NodPrimaryButton(title: "Use a Digital ID") { model.go(.digitalId) } }
            if let u = p?.helpURL { wallet ? AnyView(NodSecondaryButton(title: "Contact \(model.app) Support") { openURL(u) }) : AnyView(NodPrimaryButton(title: "Contact \(model.app) Support") { openURL(u) }) }
            NodSecondaryButton(title: "Back to Start") { model.go(.intro) }
        }
    }
    private func row(_ symbol: String, _ title: String, _ body: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(IntroAccent()).frame(width: 40, height: 40)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if let body { Text(body).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }.padding(16).accessibilityElement(children: .combine)
    }
}

/// Apple's Verify with Wallet button, unmodified.
struct WalletButton: UIViewRepresentable {
    let action: () -> Void
    func makeUIView(context: Context) -> PKIdentityButton {
        let b = PKIdentityButton(label: .verify, style: .black)
        b.addAction(UIAction { _ in action() }, for: UIControl.Event.touchUpInside)
        return b
    }
    func updateUIView(_ v: PKIdentityButton, context: Context) {}
}
