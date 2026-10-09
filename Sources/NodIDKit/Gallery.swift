// A gallery of every SDK screen on mock data, for looking at the screens on a device (accent, text size, light or dark) and for VoiceOver passes.
// Only reachable through `@_spi(Testing)`: integrators do not see it. It never talks to a server and never reads a passport.
import SwiftUI

@_spi(Testing) public struct NodIDScreenGallery: View {
    public init() {}
    private struct Entry: Identifiable {
        let id: String
        let setup: (NodIDFlowModel, GalleryFlags) -> Void
    }
    fileprivate struct GalleryFlags { var accent: String; var wallet: Bool; var onePerPerson: Bool; var alternatives: Bool }
    private static let alts = [SessionPolicy.Alternative(title: "Visit a store", detail: "Show your ID to staff and they will unlock your account.")]
    private static func show(_ s: FlowScreen, nfc: NFCUIState = .idle, long: Bool = false, step: ProofStep? = nil, order: [PlacementSpot]? = nil,
                             attempts: Int = 0, last: ChipFailure? = nil, download: Int? = nil) -> (NodIDFlowModel, GalleryFlags) -> Void {
        { m, f in m.previewShow(s, nfc: nfc, long: long, step: step, order: order, accent: f.accent, onePerPerson: f.onePerPerson, offerDigitalId: f.wallet,
                                alternatives: f.alternatives ? alts : [], attempts: attempts, lastFailure: last, download: download) }
    }
    private static let entries: [Entry] = [
        Entry(id: "01 Intro", setup: show(.intro)),
        Entry(id: "02 What you need", setup: show(.need)),
        Entry(id: "03 Camera permission", setup: show(.prime)),
        Entry(id: "04 Scan (opens the camera)", setup: show(.scan)),
        Entry(id: "04c Type the details", setup: show(.manual)),
        Entry(id: "05a US: back cover, reading 40%", setup: show(.placement, nfc: .reading(40), order: [.backCover, .photoPage, .frontCover])),
        Entry(id: "05a Photo page, searching", setup: show(.placement, nfc: .searching, order: [.photoPage, .backCover, .frontCover])),
        Entry(id: "05a Front cover, move closer", setup: show(.placement, nfc: .closer, order: [.frontCover, .backCover, .photoPage])),
        Entry(id: "05a Hold still", setup: show(.placement, nfc: .hold(80), order: [.photoPage, .backCover, .frontCover])),
        Entry(id: "05a Done", setup: show(.placement, nfc: .done, order: [.photoPage, .backCover, .frontCover])),
        Entry(id: "06 Making your proof", setup: show(.proving, step: .checkingRules)),
        Entry(id: "06b Still working", setup: show(.proving, long: true, step: .makingProof)),
        Entry(id: "06 First-run download 37%", setup: show(.proving, step: .passportRead, download: 37)),
        Entry(id: "07a Verified", setup: show(.success)),
        Entry(id: "09 Receipt", setup: show(.receipt)),
        Entry(id: "07b Chip unreadable, first time", setup: show(.failure(.chipUnreadable), attempts: 1, last: .tagLost)),
        Entry(id: "07b Chip unreadable, second time", setup: show(.failure(.chipUnreadable), attempts: 2, last: .chipNotFound)),
        Entry(id: "07b iPhone without NFC", setup: show(.failure(.chipUnreadable), attempts: 1, last: .unsupported)),
        Entry(id: "07i Details don't open the chip", setup: show(.failure(.keyMismatch))),
        Entry(id: "07h Camera off", setup: show(.failure(.camDenied))),
        Entry(id: "07c Expired", setup: show(.failure(.expired))),
        Entry(id: "07d Under age", setup: show(.failure(.underage))),
        Entry(id: "07e Already used", setup: show(.failure(.used))),
        Entry(id: "07f Country", setup: show(.failure(.country))),
        Entry(id: "07 Technical error", setup: show(.failure(.technical))),
        Entry(id: "07g Cancelled", setup: show(.cancelled)),
        Entry(id: "08a Digital ID", setup: show(.digitalId)),
        Entry(id: "08b No passport options", setup: show(.noPassport)),
    ]

    private static let accents: [(String, String)] = [("Plum #7B2D5B", "#7B2D5B"), ("Ink #1F3C7A", "#1F3C7A"), ("Yellow #FFD700 (too light)", "#FFD700"),
        ("Teal #00897B", "#00897B"), ("Near-black #202020", "#202020"), ("Hot pink #FF1493", "#FF1493"), ("Navy #0A1F44 (too dark for dark mode)", "#0A1F44")]
    @State private var accent = "#7B2D5B"
    @State private var appearance = 0      // 0 system, 1 light, 2 dark
    @State private var textSize = 0        // 0 default, 1 xxxLarge, 2 AX3, 3 AX5
    @State private var wallet = false
    @State private var onePerPerson = true
    @State private var alternatives = true
    @State private var shown: String?

    private var scheme: ColorScheme? { [nil, .light, .dark][appearance] }
    private var size: DynamicTypeSize? { [nil, .xxxLarge, .accessibility3, .accessibility5][textSize] }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Look") {
                    Picker("Accent", selection: $accent) { ForEach(Self.accents, id: \.1) { Text($0.0).tag($0.1) } }
                    Picker("Appearance", selection: $appearance) { Text("System").tag(0); Text("Light").tag(1); Text("Dark").tag(2) }.pickerStyle(.segmented)
                    Picker("Text size", selection: $textSize) { Text("Default").tag(0); Text("XXXL").tag(1); Text("AX3").tag(2); Text("AX5").tag(3) }.pickerStyle(.segmented)
                }
                Section("What the app has switched on") {
                    Toggle("One account per person", isOn: $onePerPerson)
                    Toggle("Digital ID offered", isOn: $wallet)
                    Toggle("Other ways to prove", isOn: $alternatives)
                }
                Section("Screens (each opens like the real sheet)") {
                    ForEach(Self.entries) { e in Button(e.id) { shown = e.id } }
                }
            }
            .navigationTitle("Screen gallery")
            .sheet(item: Binding(get: { shown.map { Pick(id: $0) } }, set: { shown = $0?.id })) { p in
                if let e = Self.entries.first(where: { $0.id == p.id }) {
                    GalleryScreen(setup: e.setup, flags: GalleryFlags(accent: accent, wallet: wallet, onePerPerson: onePerPerson, alternatives: alternatives))
                        .preferredColorScheme(scheme)
                        .modifier(SizeOverride(size: size))
                        .presentationDetents([.large])
                }
            }
        }
        .preferredColorScheme(scheme)
    }
    private struct Pick: Identifiable { let id: String }
    private struct SizeOverride: ViewModifier {
        let size: DynamicTypeSize?
        func body(content: Content) -> some View { if let size { content.dynamicTypeSize(size) } else { content } }
    }
}

private struct GalleryScreen: View {
    @State private var model: NodIDFlowModel
    init(setup: (NodIDFlowModel, NodIDScreenGallery.GalleryFlags) -> Void, flags: NodIDScreenGallery.GalleryFlags) {
        let m = NodIDFlowModel(sessionId: "gallery", services: MockServices()) { _ in }
        setup(m, flags)
        _model = State(initialValue: m)
    }
    var body: some View { NodIDVerifyView(model: model) }
}
