// The host's accent colour, made readable. The accent is the customer's choice, so it can be too light for white text in light mode or too dark
// on the dark background. Everything here is plain arithmetic (no UI types) so it can be tested on the Mac: Tests/AccentContrastCheck.swift.
import Foundation

struct RGB: Equatable {
    var r: Double, g: Double, b: Double   // 0...1
    /// "#RRGGBB" or "RRGGBB"; nil when it is not a hex colour.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
    }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    func mixed(with o: RGB, _ t: Double) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
    /// WCAG relative luminance.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

enum AccentContrast {
    static let white = RGB(r: 1, g: 1, b: 1)
    /// The dark-mode screen and text-on-accent colour of the SDK (#121214).
    static let nearBlack = RGB(r: 0x12 / 255, g: 0x12 / 255, b: 0x14 / 255)
    static let ink = RGB(hex: "#1F3C7A")!
    /// WCAG 2 AA for normal text.
    static let target = 4.5

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (a.luminance, b.luminance)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// The accent to draw with. Light mode: white text sits on it and it is used as text on white, so it must reach 4.5:1 against white; if not,
    /// it is mixed toward black just enough. Dark mode: it is used as text on the near-black screen and carries near-black text, so it must reach
    /// 4.5:1 against near-black; the generated variant mixes toward white (35% at least, as designed) until it does.
    static func accent(hex: String, dark: Bool) -> RGB {
        let base = RGB(hex: hex) ?? ink
        if dark {
            var a = base.mixed(with: white, 0.35)
            var t = 0.35
            while ratio(a, nearBlack) < target && t < 1 { t += 0.05; a = base.mixed(with: white, t) }
            return a
        }
        var a = base
        var t = 0.0
        while ratio(a, white) < target && t < 1 { t += 0.05; a = base.mixed(with: RGB(r: 0, g: 0, b: 0), t) }
        return a
    }
    /// Text on the accent: white in light mode, near-black in dark mode.
    static func onAccent(dark: Bool) -> RGB { dark ? nearBlack : white }
}
