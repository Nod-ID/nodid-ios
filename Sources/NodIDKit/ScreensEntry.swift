// Nod ID SDK screens 01 to 04d: intro, what you need, camera priming, scan, manual entry.
import SwiftUI
import AVFoundation

struct LoadingScreen: View {
    var body: some View {
        VStack(spacing: 12) { ProgressView(); Text("Getting ready").font(.subheadline).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityElement(children: .combine)
    }
}

// MARK: 01
struct IntroScreen: View {
    let model: NodIDFlowModel
    @Environment(\.dynamicTypeSize) private var dts
    var body: some View {
        let p = model.policy
        let app = model.app
        NodScreen {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text(String(app.prefix(1)).uppercased()).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(Color(hex: p?.accentHex ?? ""), in: RoundedRectangle(cornerRadius: 9, style: .continuous)).accessibilityHidden(true)
                    Text("Request from \(app)").font(.subheadline).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
                NodTitle(text: model.showAge ? "Confirm you're over \(model.minAge)" : "Confirm with your passport")
                Text(model.showAge ? "Your passport stays on your phone. \(app) only learns that you're over \(model.minAge)."
                                   : "Your passport stays on your phone. \(app) only learns that the checks passed.")
                    .font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                section("\(app) will learn", rows: learnRows(p), symbol: "checkmark.circle.fill", tinted: true)
                section("\(app) won't learn", rows: ["Your name", "Your date of birth or exact age", "Your photo or passport image", "Your passport number or nationality"], symbol: "minus.circle.fill", tinted: false)
                Text("Takes about a minute. Next, you'll check that your passport has a chip.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    NodMark(height: 15)
                    Text("Verification by Nod ID")
                }.font(.footnote.weight(.medium)).foregroundStyle(.secondary).accessibilityElement(children: .combine)
            }
        } footer: {
            NodPrimaryButton(title: "Continue") { model.go(.need) }
            if p?.offerDigitalId == true { NodSecondaryButton(title: "Use a Digital ID Instead") { model.go(.digitalId) } }
            NodTertiaryButton(title: "I Don't Have a Passport") { model.go(.noPassport) }
        }
    }
    private func learnRows(_ p: SessionPolicy?) -> [String] {
        var r: [String] = []
        if p?.checkAge ?? true, model.minAge > 0 { r.append("You're over \(model.minAge)") }
        if p?.checkExpiry ?? false { r.append("Your passport is still valid") }
        if p?.checkCountry ?? false { r.append("Your passport is from a country \(model.app) accepts") }
        if p?.onePerPerson ?? false { r.append("This is your only \(model.app) account") }
        if r.isEmpty { r.append("That your passport passed the checks") }
        return r
    }
    @ViewBuilder private func section(_ title: String, rows: [String], symbol: String, tinted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
            NodCard {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    if i > 0 { Divider().padding(.leading, 52) }
                    HStack(spacing: 12) {
                        Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(tinted ? AnyShapeStyle(IntroAccent()) : AnyShapeStyle(Color.secondary)).accessibilityHidden(true)
                        Text(r).font(.body).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 44).accessibilityElement(children: .combine)
                }
            }
        }
    }
}
/// Accent as a ShapeStyle that reads the palette from the environment.
struct IntroAccent: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color { environment.nod.acc }
}

// MARK: passport cover art (also used by 05a)
struct ChipSymbol: View {
    var size: CGFloat = 40; var ring: Color? = nil
    var body: some View {
        ZStack {
            if let ring { Circle().strokeBorder(ring, lineWidth: 2.5).frame(width: size * 1.7, height: size * 1.7) }
            Circle().strokeBorder(Color(red: 0xD8 / 255, green: 0xC5 / 255, blue: 0x90 / 255), lineWidth: 2).frame(width: size, height: size)
            RoundedRectangle(cornerRadius: size * 0.1).stroke(Color(red: 0xD8 / 255, green: 0xC5 / 255, blue: 0x90 / 255), lineWidth: 1.6).frame(width: size * 0.5, height: size * 0.4)
        }
    }
}
struct PassportCover: View {
    @Environment(\.colorScheme) private var scheme
    var width: CGFloat = 176; var height: CGFloat = 248; var ring: Color? = nil
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(scheme == .dark ? Color(red: 0x3A / 255, green: 0x42 / 255, blue: 0x54 / 255) : Color(red: 0x2B / 255, green: 0x31 / 255, blue: 0x40 / 255))
            VStack(spacing: height * 0.06) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.35)).frame(width: width * 0.45, height: 4)
                Circle().stroke(Color.white.opacity(0.3), lineWidth: 2).frame(width: width * 0.3, height: width * 0.3)
                Spacer().frame(height: height * 0.04)
                ChipSymbol(size: width * 0.17, ring: ring)
            }
        }.frame(width: width, height: height)
    }
}

// MARK: 02
struct NeedScreen: View {
    let model: NodIDFlowModel
    @Environment(\.dynamicTypeSize) private var dts
    @Environment(\.nod) private var nod
    var body: some View {
        NodScreen {
            VStack(alignment: .leading, spacing: 16) {
                NodTitle(text: "Check your passport has a chip")
                Text("Look for this symbol on the front cover. It means your passport has a chip your iPhone can read.").nodBody()
                if !dts.isAccessibilitySize {
                    VStack(spacing: 10) {
                        PassportCover(ring: nod.acc)
                        Text("Chip symbol").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).frame(height: 330)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .accessibilityElement(children: .ignore).accessibilityLabel("Illustration: a passport front cover with the chip symbol ringed.")
                }
                Text("Most passports issued in the last 15 years have it. ID cards and driving licences can't be read here.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            NodPrimaryButton(title: "Continue") { model.go(.prime) }
            NodSecondaryButton(title: "My Passport Doesn't Have This") { model.go(.noPassport) }
        }
    }
}

// MARK: 03
struct PrimeScreen: View {
    let model: NodIDFlowModel
    var body: some View {
        NodScreen {
            VStack(alignment: .leading, spacing: 16) {
                NodTitle(text: "Next, your iPhone reads your passport")
                NodCard {
                    row("camera.fill", "1. Scan your photo page", "Your camera reads the two lines of text at the bottom.")
                    Divider().padding(.leading, 68)
                    row("iphone.radiowaves.left.and.right", "2. Hold your iPhone near your passport", "Your iPhone uses those lines to open the chip and read it.")
                }
                Text("The photo and your passport details stay on your iPhone. They're deleted when you finish.").nodBody()
                Text("Next, iOS will ask to use your camera.").font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            NodPrimaryButton(title: "Continue") { model.continueFromPrime() }   // exactly one button
        }
    }
    private func row(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(IntroAccent())
                .frame(width: 40, height: 40).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(body).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(16).accessibilityElement(children: .combine)
    }
}

// MARK: 04
struct ScanScreen: View {
    let model: NodIDFlowModel
    @State private var torch = false
    @Environment(\.dynamicTypeSize) private var dts
    private let yellow = Color(red: 1, green: 214 / 255, blue: 10 / 255).opacity(0.95)
    private let green = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    var body: some View {
        let ok = model.scanCaptured
        GeometryReader { geo in
            let w = min(geo.size.width - 60, 333), h: CGFloat = 232
            let top: CGFloat = dts.isAccessibilitySize ? 150 : 248
            ZStack(alignment: .top) {
                Color.black
                CameraPreview(session: model.scanner.session).accessibilityHidden(true)
                // Dim everything outside the frame (58% black), with the frame cut out.
                Path { p in p.addRect(CGRect(origin: .zero, size: geo.size)); p.addRoundedRect(in: CGRect(x: (geo.size.width - w) / 2, y: top, width: w, height: h), cornerSize: CGSize(width: 18, height: 18)) }
                    .fill(Color.black.opacity(0.58), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 18).stroke(ok ? green : .white, lineWidth: 3).frame(width: w, height: h).offset(y: top)
                    .accessibilityElement().accessibilityLabel("Camera view of the passport photo page. The two lines of text at the bottom are \(ok ? "captured." : "inside the frame.")")
                // Guide lines inside the frame.
                VStack(spacing: 10) {
                    ForEach(0..<2, id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(ok ? green : yellow).frame(height: 4).opacity(0.9) }
                    if ok { Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(green) }
                }.padding(.horizontal, 28).frame(width: w, height: h, alignment: .bottom).padding(.bottom, 24).offset(y: top).accessibilityHidden(true)
                VStack(spacing: 12) {
                    Text("Scan your photo page").font(.title2.bold()).foregroundStyle(.white).accessibilityAddTraits(.isHeader)
                    Text("Fit the two lines at the bottom of the page inside the frame. Your iPhone needs them to unlock the chip.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 28).padding(.top, 64).frame(maxWidth: .infinity).frame(height: top, alignment: .top)
                VStack(spacing: 8) {
                    Spacer().frame(height: top + h + 16)
                    HStack(spacing: 6) {
                        if ok { Image(systemName: "checkmark") }
                        Text(model.cameraUnavailable ? "Camera not available. Type the lines instead." : ok ? "Got it. Next, hold your iPhone near your passport." : "Hold steady").font(.subheadline.weight(.medium))
                    }.foregroundStyle(ok ? green : .white).padding(.horizontal, 14).padding(.vertical, 8).background(.black.opacity(0.55), in: Capsule())
                        .accessibilityElement(children: .combine)
                    Spacer()
                    HStack(spacing: 12) {
                        Button { torch.toggle(); model.setTorch(torch) } label: {
                            Image(systemName: torch ? "flashlight.on.fill" : "flashlight.off.fill").font(.system(size: 20)).frame(width: 52, height: 52).nodGlassCircle()
                        }.accessibilityLabel(torch ? "Turn off flashlight" : "Turn on flashlight")
                        Button { model.go(.manual) } label: {
                            Text("Type the Lines Instead").font(.headline).padding(.horizontal, 22).frame(minHeight: 52).nodGlassCapsule()
                        }
                    }.buttonStyle(.plain).foregroundStyle(.white).padding(.bottom, 30)
                }.frame(maxWidth: .infinity)
            }
        }.ignoresSafeArea().environment(\.colorScheme, .dark)
    }
}

// MARK: 04c / 04d
struct ManualScreen: View {
    @Bindable var model: NodIDFlowModel
    @Environment(\.dynamicTypeSize) private var dts
    @Environment(\.nod) private var nod
    @FocusState private var focused: Bool
    var body: some View {
        let numErr = model.docNumberError, bErr = model.birthError, eErr = model.expiryError
        NodScreen {
            VStack(alignment: .leading, spacing: 16) {
                NodTitle(text: "Type the details instead")
                Text("Your iPhone needs three details from the two lines at the bottom of your photo page. They stay on your phone.").nodBody()
                if !dts.isAccessibilitySize { mrzMap }
                NodCard {
                    HStack {
                        Label { Text("Passport number") } icon: { if numErr != nil { Image(systemName: "exclamationmark") } }
                            .foregroundStyle(numErr == nil ? Color.primary : nod.errorTint).font(.body)
                        Spacer(minLength: 8)
                        TextField("", text: $model.docNumber)
                            .font(.system(.body, design: .monospaced)).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled().textContentType(nil)
                            .keyboardType(.asciiCapable).privacySensitive().focused($focused).submitLabel(.done)
                            .onChange(of: model.docNumber) { _, v in
                                let c = String(v.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(9))
                                if c != v { model.docNumber = c }
                                model.docNumberTouched = true
                            }
                            .accessibilityLabel("Passport number")
                    }.padding(.horizontal, 16).frame(minHeight: 52)
                    Divider().padding(.leading, 16)
                    DatePicker(selection: $model.birthDate, in: ...Date(), displayedComponents: .date) {
                        Text("Date of birth").foregroundStyle(bErr == nil ? Color.primary : nod.errorTint)
                    }.padding(.horizontal, 16).frame(minHeight: 52).privacySensitive()
                    Divider().padding(.leading, 16)
                    DatePicker(selection: $model.expiryDate, displayedComponents: .date) {
                        Text("Expiry date").foregroundStyle(eErr == nil ? Color.primary : nod.errorTint)
                    }.padding(.horizontal, 16).frame(minHeight: 52).privacySensitive()
                    Divider().padding(.leading, 16)
                    HStack {
                        Text("Issued by")
                        Spacer(minLength: 8)
                        Picker("Issued by", selection: $model.issuingChoice) {
                            Text("Choose").tag(String?.none)
                            ForEach(IssuingCountry.all, id: \.code) { c in Text(c.name).tag(String?.some(c.code)) }
                        }.pickerStyle(.menu).labelsHidden().tint(nod.acc)
                    }.padding(.horizontal, 16).frame(minHeight: 52)
                    .accessibilityElement(children: .combine)
                }
                if let m = numErr ?? bErr ?? eErr {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark").accessibilityHidden(true)
                        Text(m).fixedSize(horizontal: false, vertical: true)
                    }.font(.subheadline).foregroundStyle(nod.errorTint).padding(.horizontal, 4)
                        .accessibilityElement(children: .combine).accessibilityLabel("Error. \(m)")
                }
                Text("Next, hold your iPhone near your passport. If a detail is wrong, the chip won't open and you can check them again.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            NodPrimaryButton(title: "Continue", enabled: model.manualValid) { focused = false; model.continueFromManual() }
            NodSecondaryButton(title: "Scan the Page Instead") { model.go(.scan) }
        }
        .scrollDismissesKeyboard(.interactively)
    }
    /// Map of the second line: underlines where each detail sits. Uses a placeholder shape, never real values.
    private var mrzMap: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill))
                    mark("1", x: w * 0.05, width: w * 0.24, y: 24)
                    mark("2", x: w * 0.40, width: w * 0.17, y: 24)
                    mark("3", x: w * 0.63, width: w * 0.17, y: 24)
                    Text("Passport number   Birth   Expiry").font(.caption2).foregroundStyle(.secondary).padding(.leading, w * 0.05).padding(.top, 36)
                }
            }.frame(height: 62)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Map of the second line: 1 Passport number, 2 Birth, 3 Expiry.")
    }
    private func mark(_ n: String, x: CGFloat, width: CGFloat, y: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(n).font(.system(size: 11, weight: .bold)).foregroundStyle(nod.acc)
            Rectangle().fill(nod.acc).frame(width: width, height: 2.5)
        }.offset(x: x, y: y - 20)
    }
}

/// Countries offered on the type-it-in screen: the three letters match line 1 of the passport. Choosing one lets the
/// placement guide show the best spot first; leaving it unset only changes the order of the spots.
struct IssuingCountry {
    let code: String, region: String
    var name: String { Locale.current.localizedString(forRegionCode: region) ?? code }
    static let all: [IssuingCountry] = {
        let t: [(String, String)] = [
            ("USA","US"),("GBR","GB"),("CAN","CA"),("AUS","AU"),("NZL","NZ"),("IRL","IE"),("FRA","FR"),("DEU","DE"),("ESP","ES"),("ITA","IT"),
            ("NLD","NL"),("BEL","BE"),("LUX","LU"),("AUT","AT"),("CHE","CH"),("DNK","DK"),("SWE","SE"),("NOR","NO"),("FIN","FI"),("ISL","IS"),
            ("PRT","PT"),("POL","PL"),("CZE","CZ"),("SVK","SK"),("HUN","HU"),("ROU","RO"),("BGR","BG"),("HRV","HR"),("SVN","SI"),("GRC","GR"),
            ("EST","EE"),("LVA","LV"),("LTU","LT"),("MLT","MT"),("CYP","CY"),("SGP","SG"),("JPN","JP"),("KOR","KR"),("IND","IN"),("ISR","IL"),
            ("BRA","BR"),("MEX","MX"),("ARG","AR"),("ZAF","ZA")]
        return t.map { IssuingCountry(code: $0.0, region: $0.1) }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }()
}
