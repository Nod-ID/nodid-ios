// Nod ID SDK screens 05a (placement guide + NFC state) and 06/06b (proving).
import SwiftUI
import UIKit

enum Placement {
    struct Text3 { let body: String; let closer: String; let label: String; let art: String }
    static func text(for spot: PlacementSpot) -> Text3 {
        switch spot {
        case .backCover: return Text3(body: "Open your passport to the inside back cover and lay it flat. Rest the top of your iPhone on the barcode area.",
                                      closer: "Move the top of your iPhone closer to the barcode area.", label: "Top of iPhone on the barcode",
                                      art: "Illustration: an open passport showing the inside back cover, with the top of an iPhone over the barcode area.")
        case .photoPage: return Text3(body: "Open your passport to the photo page and lay it flat. Rest the top of your iPhone on the photo page.",
                                      closer: "Move the top of your iPhone closer to the photo page.", label: "Top of iPhone on the photo page",
                                      art: "Illustration: an open passport showing the photo page, with the top of an iPhone resting on it.")
        case .frontCover: return Text3(body: "Close your passport and lay it flat. Rest the top of your iPhone on the front cover.",
                                       closer: "Move your iPhone closer to the top of your passport.", label: "Top of iPhone",
                                       art: "Illustration: a closed passport lying flat, with the top of an iPhone over the upper half of the cover.")
        }
    }
}

/// Simple SwiftUI drawing of the three placements, with the accent pulse ring at the iPhone's top.
struct PlacementArt: View {
    let spot: PlacementSpot
    @Environment(\.nod) private var nod
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    private var page: Color { scheme == .dark ? Color(red: 0xCF / 255, green: 0xCC / 255, blue: 0xC3 / 255) : Color(red: 0xF7 / 255, green: 0xF5 / 255, blue: 0xEE / 255) }
    private var ink: Color { scheme == .dark ? Color(red: 0x4A / 255, green: 0x4D / 255, blue: 0x56 / 255) : Color(red: 0x5B / 255, green: 0x5E / 255, blue: 0x68 / 255) }
    private var cover: Color { scheme == .dark ? Color(red: 0x3A / 255, green: 0x42 / 255, blue: 0x54 / 255) : Color(red: 0x2B / 255, green: 0x31 / 255, blue: 0x40 / 255) }
    var body: some View {
        let text = Placement.text(for: spot)
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                passport.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 10)
                phone.frame(width: 70, height: 132).offset(x: spot == .frontCover ? 0 : 30, y: 4)
                Circle().stroke(nod.acc, lineWidth: 3).frame(width: 80, height: 80)
                    .scaleEffect(reduceMotion ? 1 : (pulse ? 1.7 : 0.55)).opacity(reduceMotion ? 0.6 : (pulse ? 0 : 0.9))
                    .offset(x: spot == .frontCover ? 0 : 30, y: -26)
            }.frame(height: 232).clipped()
            Text(text.label).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 14).frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .ignore).accessibilityLabel(text.art)
        .onAppear { if !reduceMotion { withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true } } }
    }
    private var phone: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground).opacity(0.9))
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.75), lineWidth: 3)
            Capsule().fill(Color.primary.opacity(0.75)).frame(width: 22, height: 5).padding(.top, 8)
        }
    }
    @ViewBuilder private var passport: some View {
        switch spot {
        case .frontCover:
            PassportCover(width: 150, height: 206, ring: nil)
        case .photoPage:
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 6).fill(page).frame(width: 110, height: 170).overlay(lines(4))
                RoundedRectangle(cornerRadius: 6).fill(page).frame(width: 110, height: 170).overlay(alignment: .top) {
                    VStack(spacing: 6) {
                        HStack(spacing: 8) { RoundedRectangle(cornerRadius: 3).fill(ink.opacity(0.35)).frame(width: 34, height: 44); lines(3) }.padding(.top, 70)
                        Spacer()
                        VStack(spacing: 4) { ForEach(0..<2, id: \.self) { _ in RoundedRectangle(cornerRadius: 1).fill(ink.opacity(0.6)).frame(height: 3) } }.padding(.bottom, 10)
                    }.padding(.horizontal, 10)
                }
            }
        case .backCover:
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 6).fill(page).frame(width: 110, height: 170).overlay(lines(5))
                RoundedRectangle(cornerRadius: 6).fill(cover).frame(width: 110, height: 170).overlay(alignment: .top) {
                    HStack(spacing: 2) { ForEach(0..<18, id: \.self) { i in Rectangle().fill(Color.white.opacity(0.8)).frame(width: i % 3 == 0 ? 3 : 1.5, height: 30) } }
                        .padding(8).background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4)).padding(.top, 52)
                }
            }
        }
    }
    private func lines(_ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) { ForEach(0..<n, id: \.self) { i in RoundedRectangle(cornerRadius: 1).fill(ink.opacity(0.35)).frame(width: i % 2 == 0 ? 60 : 44, height: 3) } }.padding(10)
    }
}

// MARK: 05a
struct PlacementScreen: View {
    let model: NodIDFlowModel
    @Environment(\.dynamicTypeSize) private var dts
    var body: some View {
        let spot = model.currentSpot
        let text = Placement.text(for: spot)
        NodScreen {
            VStack(alignment: .leading, spacing: 14) {
                NodTitle(text: "Hold your iPhone near your passport")
                Text(text.body).nodBody()
                NodTertiaryButton(title: "Try another spot", label: "Try another spot. Showing spot \(model.spotNumber) of 3.", value: "Showing spot \(model.spotNumber) of 3") { model.nextSpot() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !dts.isAccessibilitySize { PlacementArt(spot: spot).id(spot) }
                status
            }
        } footer: {
            if model.nfc == .idle { NodPrimaryButton(title: "Try Again") { model.startChip() } }
        }
    }
    @ViewBuilder private var status: some View {
        if let s = statusText {
            VStack(spacing: 6) {
                Text(s.0).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                if let dots = s.1 { Text(dots).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true) }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12).padding(.horizontal, 16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(s.2)
        }
    }
    /// (sentence, text dots, accessibility label)
    private var statusText: (String, String?, String)? {
        func dots(_ pct: Int) -> String { let n = min(10, max(0, pct / 10)); return String(repeating: "●", count: n) + String(repeating: "○", count: 10 - n) }
        switch model.nfc {
        case .idle: return nil
        case .searching: return ("Hold your iPhone near your passport.", nil, "Hold your iPhone near your passport.")
        case .closer: return (model.closerText, nil, model.closerText)
        case .reading(let p): return ("Reading your passport. Keep still.", dots(p), "Reading your passport. Keep still. \(p) percent.")
        case .hold(let p): return ("Almost done. Keep holding.", dots(p), "Almost done. Keep holding. \(p) percent.")
        case .done: return ("Passport read. Making your proof next.", dots(100), "Passport read. Making your proof next.")
        }
    }
}

// MARK: 06 / 06b
struct ProvingScreen: View {
    let model: NodIDFlowModel
    @Environment(\.nod) private var nod
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dts
    @State private var breathe = false
    private var idx: Int { switch model.proofStep { case .none, .some(.passportRead): return 0; case .some(.checkingRules): return 1; case .some(.makingProof): return 2 } }
    private var progress: Double { [0.15, 0.45, 0.78][idx] }
    var body: some View {
        let long = model.provingLong
        let app = model.app
        NodScreen {
            VStack(spacing: 16) {
                if !dts.isAccessibilitySize { ring.padding(.top, 8) }
                NodTitle(text: long ? "Still working" : "Making your proof").frame(maxWidth: .infinity, alignment: .center).multilineTextAlignment(.center)
                Text(long ? "Some iPhones take a little longer. Nothing is being uploaded." : "This happens on your iPhone. Nothing is being uploaded.").nodBody().multilineTextAlignment(.center)
                NodCard {
                    ForEach(0..<3, id: \.self) { i in
                        if i > 0 { Divider().padding(.leading, 52) }
                        stepRow(i, ["Passport read", "Checking \(app)'s rules", "Making your proof"][i])
                    }
                }
 if let p = model.downloadPercent {
                    Text("Getting ready for the first time: \(p)%. This one-time download is about 40 MB. Nothing about you is uploaded.")
                        .font(.footnote.weight(.medium)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Getting ready for the first time, \(p) percent")
                }
                Text(long ? "Keep this screen open. It usually finishes within 30 seconds." : "Usually takes a few seconds. Next, \(app) receives only the result.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity)
        }
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) { breathe = true } } }
    }
    private var ring: some View {
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 4)
            Circle().trim(from: 0, to: progress).stroke(nod.acc, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 0.3), value: progress)
            Circle().fill(nod.acc).padding(34)
                .scaleEffect(reduceMotion ? 1 : (breathe ? 1.08 : 0.86)).opacity(reduceMotion ? 0.12 : (breathe ? 0.22 : 0.10))
            Circle().stroke(nod.acc, lineWidth: 3).padding(70)
        }.frame(width: 180, height: 180)
        .accessibilityElement(children: .ignore).accessibilityLabel("Making your proof").accessibilityValue("Step \(idx + 1) of 3")
    }
    private func stepRow(_ i: Int, _ label: String) -> some View {
        let done = i < idx, now = i == idx
        let state = done ? "Done" : now ? "Now" : "Next"
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(done ? nod.acc : Color.clear)
                Circle().strokeBorder(done ? Color.clear : (now ? nod.acc : Color(.separator)), lineWidth: 2)
                if done { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(nod.onAcc) }
            }.frame(width: 24, height: 24).accessibilityHidden(true)
            Text(label).font(.body.weight(now ? .semibold : .regular)).foregroundStyle(done || now ? Color.primary : Color.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(state).font(.subheadline).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 44)
        .accessibilityElement(children: .ignore).accessibilityLabel("\(label), \(state)")
    }
}
