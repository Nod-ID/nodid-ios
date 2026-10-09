// Nod ID SDK: shared UI pieces (palette, buttons, toolbar circles, screen scaffold, status layout).
import SwiftUI
import UIKit

extension Color {
    /// "#RRGGBB" or "RRGGBB". Falls back to the Nod ID ink when the string is not a hex colour.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = Color(red: 0x1F / 255, green: 0x3C / 255, blue: 0x7A / 255); return }
        self = Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    /// Mixes toward white for the generated dark-mode variant of the host accent.
    func lightened(_ amount: Double) -> Color {
        let u = UIColor(self); var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        u.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: r + (1 - r) * amount, green: g + (1 - g) * amount, blue: b + (1 - b) * amount)
    }
}

struct NodPalette {
    var acc: Color = Color(hex: "#1F3C7A")
    var onAcc: Color = .white
    var errorTint: Color = Color(red: 0xD7 / 255, green: 0, blue: 0x15 / 255)
    static func make(hex: String, dark: Bool) -> NodPalette {
        let a = AccentContrast.accent(hex: hex, dark: dark)   // readable whatever accent the host chose (AccentContrast.swift)
        return NodPalette(acc: Color(red: a.r, green: a.g, blue: a.b),
                          onAcc: dark ? Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x14 / 255) : .white,
                          errorTint: dark ? Color(red: 1, green: 0x69 / 255, blue: 0x61 / 255) : Color(red: 0xD7 / 255, green: 0, blue: 0x15 / 255))
    }
}
private struct PaletteKey: EnvironmentKey { static let defaultValue = NodPalette() }
extension EnvironmentValues { var nod: NodPalette { get { self[PaletteKey.self] } set { self[PaletteKey.self] = newValue } } }

extension View {
    /// Liquid Glass on iOS 26, material fallback before.
    @ViewBuilder func nodGlassCircle() -> some View {
        if #available(iOS 26, *) { self.glassEffect(.regular, in: .circle).contentShape(Circle()) }   // not .interactive(): on iOS 26 it swallowed the button's tap
        else { self.background(.regularMaterial, in: Circle()).overlay(Circle().strokeBorder(Color.primary.opacity(0.07))) }
    }
    @ViewBuilder func nodGlassCapsule() -> some View {
        if #available(iOS 26, *) { self.glassEffect(.regular, in: .capsule) }
        else { self.background(.regularMaterial, in: Capsule()) }
    }
}

// MARK: buttons
struct NodPrimaryButton: View {
    let title: String; var enabled = true; let action: () -> Void
    @Environment(\.nod) private var nod
    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(enabled ? nod.onAcc : Color.secondary)
                .background(Capsule().fill(enabled ? nod.acc : Color(.tertiarySystemFill)))
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }
}
struct NodSecondaryButton: View {
    let title: String; let action: () -> Void
    @Environment(\.nod) private var nod
    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).multilineTextAlignment(.center)
                .foregroundStyle(nod.acc).frame(maxWidth: .infinity, minHeight: 48)
        }.buttonStyle(.plain)
    }
}
struct NodTertiaryButton: View {
    let title: String; var label: String? = nil; var value: String? = nil; let action: () -> Void
    @Environment(\.nod) private var nod
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                .foregroundStyle(nod.acc).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? title)
        .accessibilityValue(value ?? "")
    }
}

// MARK: toolbar
struct NodToolbar: View {
    let showBack: Bool; let showClose: Bool; var onDark = false
    let back: () -> Void; let close: () -> Void
    var body: some View {
        HStack {
            if showBack {
                Button(action: back) { Image(systemName: "chevron.backward").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).nodGlassCircle() }
                    .accessibilityLabel("Back")
            }
            Spacer()
            if showClose {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).nodGlassCircle() }
                    .accessibilityLabel("Close")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(onDark ? Color.white : Color.primary)
        .padding(.horizontal, 16).padding(.top, 8)
    }
}

// MARK: scaffold
/// Content scrolls; footer buttons are pinned with a 22pt fade, except at accessibility text sizes where they scroll.
struct NodScreen<Content: View, Footer: View>: View {
    @Environment(\.dynamicTypeSize) private var dts
    let content: Content; let footer: Footer
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) { self.content = content(); self.footer = footer() }
    var body: some View {
        let ax = dts.isAccessibilitySize
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content.padding(.horizontal, 24).padding(.top, 68)
                if ax { footerBox.padding(.top, 24) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, ax ? 16 : 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !ax {
                VStack(spacing: 0) {
                    LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground)], startPoint: .top, endPoint: .bottom).frame(height: 22).allowsHitTesting(false)
                    footerBox.background(Color(.systemGroupedBackground))
                }
            }
        }
    }
    private var footerBox: some View { VStack(spacing: 4) { footer }.padding(.top, 16).padding(.horizontal, 24).padding(.bottom, 30) }
}
extension NodScreen where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) { self.init(content: content, footer: { EmptyView() }) }
}

/// A title at 28pt bold (Title 1), scaling with Dynamic Type but capped at 58pt.
struct NodTitle: View {
    let text: String
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 28
    var body: some View { Text(text).font(.system(size: min(size, 58), weight: .bold)).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader) }
}

extension View {
    func nodBody() -> some View { self.font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

/// Inset grouped card (radius 24, cell colour).
struct NodCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { VStack(spacing: 0) { content }.frame(maxWidth: .infinity, alignment: .leading).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous)) }
}

/// Shared failure layout (07b to 07i): neutral circle with symbol, title, reason, "What to do" card, actions. No red.
struct StatusLayout<Footer: View>: View {
    let symbol: String; let title: String; let reason: String; let next: String
    @ViewBuilder let footer: Footer
    @Environment(\.dynamicTypeSize) private var dts
    var body: some View {
        NodScreen {
            VStack(alignment: .leading, spacing: 16) {
                ZStack { Circle().fill(Color(.tertiarySystemFill)); Image(systemName: symbol).font(.system(size: 28, weight: .semibold)).foregroundStyle(.secondary) }
                    .frame(width: 68, height: 68).accessibilityHidden(true)
                NodTitle(text: title)
                Text(reason).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                NodCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What to do").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Text(next).font(.body).fixedSize(horizontal: false, vertical: true)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityElement(children: .combine)
            }
        } footer: { footer }
    }
}


// MARK: Nod ID mark (design/assets/mark: "the nod", one filled path, 117.73 x 100)
/// The mark as a shape. One colour at a time, never with a lock, shield or checkmark (brand README). The regular cuts are used at every size: the
/// wider small-size cuts the brand file mentions are not in the repository yet, so below about 33 pt the faces may look thin.
struct NodMarkShape: Shape {
    private static let polygons: [[(Double, Double)]] = [
        [(86.48, 23.16), (115.89, 50.65), (85.33, 68.29), (55.92, 40.8)],
        [(107.19, 80.47), (77.46, 97.63), (86.1, 70.39), (115.82, 53.23)],
        [(54.61, 42.58), (83.92, 69.98), (75.04, 98.01), (45.72, 70.61)],
        [(32.55, 1.27), (58.36, 16.17), (56.33, 22.59), (32.55, 36.31), (2.2, 18.79)],
        [(58.36, 16.17), (62.9, 18.79), (56.33, 22.59)],
        [(41.75, 68.59), (33.65, 73.26), (33.65, 38.22), (55.34, 25.69)],
        [(51.32, 38.37), (55.34, 25.69), (64, 20.7), (64, 31.05)],
        [(1.1, 20.7), (31.45, 38.22), (31.45, 73.26), (1.1, 55.74)],
    ]
    func path(in rect: CGRect) -> Path {
        let k = min(rect.width / 117.73, rect.height / 100)
        let dx = rect.minX + (rect.width - 117.73 * k) / 2, dy = rect.minY + (rect.height - 100 * k) / 2
        var p = Path()
        for poly in Self.polygons {
            for (i, pt) in poly.enumerated() {
                let c = CGPoint(x: dx + pt.0 * k, y: dy + pt.1 * k)
                if i == 0 { p.move(to: c) } else { p.addLine(to: c) }
            }
            p.closeSubpath()
        }
        return p
    }
}

/// The mark at a given height, in the current foreground style. Decorative: the text next to it carries the meaning.
struct NodMark: View {
    var height: CGFloat = 14
    var body: some View {
        NodMarkShape().fill(style: FillStyle(eoFill: false)).frame(width: height * 1.1773, height: height).accessibilityHidden(true)
    }
}
