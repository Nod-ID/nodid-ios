// Nod ID SDK: root view of the member flow. The host presents it as a large-detent page sheet:
//   .sheet(isPresented: $show) { NodIDVerifyView(sessionId: id, services: services) { outcome in ... }.presentationDetents([.large]) }
// The host only ever receives `NodIDOutcome`; reasons stay on the phone.
import SwiftUI

public struct NodIDVerifyView: View {
    @State private var model: NodIDFlowModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let services: NodIDServices

    /// The usual way in: live Nod ID servers, resources in the host app's bundle.
    public init(sessionId: String, onFinish: @escaping (NodIDOutcome) -> Void) {
        self.init(sessionId: sessionId, services: RealServices(), onFinish: onFinish)
    }

    public init(sessionId: String, services: NodIDServices, onFinish: @escaping (NodIDOutcome) -> Void) {
        self.services = services
        _model = State(initialValue: NodIDFlowModel(sessionId: sessionId, services: services, onFinish: onFinish))
    }

    private var navTitle: String? {
        switch model.screen {
        case .manual: return "Passport details"
        case .receipt: return "Receipt"
        case .digitalId: return "Digital ID"
        case .noPassport: return "Other options"
        default: return nil
        }
    }

    init(model: NodIDFlowModel) { self.services = model.services; _model = State(initialValue: model) }

    public var body: some View {
        let nod = NodPalette.make(hex: model.policy?.accentHex ?? "", dark: scheme == .dark)
        let camera = model.screen == .scan
        ZStack(alignment: .top) {
            (camera ? Color.black : Color(.systemGroupedBackground)).ignoresSafeArea()
            screenView.transition(.opacity)
            if model.screen != .loading {
                ZStack {
                    if let t = navTitle { Text(t).font(.headline).frame(maxWidth: .infinity).padding(.top, 8).frame(height: 52).accessibilityAddTraits(.isHeader) }
                    NodToolbar(showBack: model.backTarget != nil, showClose: model.showClose, onDark: camera, back: { model.back() }, close: { model.close() })
                }
            }
        }
        .environment(\.nod, nod)
        .tint(nod.acc)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.screen)
        .interactiveDismissDisabled(model.lockDismiss)
        .onAppear { SnapshotCover.shared.install(); model.start() }
        .onDisappear { SnapshotCover.shared.remove(); model.viewDisappeared() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.recheckCamera() }
    }

    @ViewBuilder private var screenView: some View {
        switch model.screen {
        case .loading: LoadingScreen()
        case .intro: IntroScreen(model: model)
        case .need: NeedScreen(model: model)
        case .prime: PrimeScreen(model: model)
        case .scan: ScanScreen(model: model)
        case .manual: ManualScreen(model: model)
        case .placement: PlacementScreen(model: model)
        case .proving: ProvingScreen(model: model)
        case .success: SuccessScreen(model: model)
        case .receipt: ReceiptScreen(model: model)
        case .failure(let f): FailureScreen(model: model, kind: f)
        case .cancelled: CancelledScreen(model: model)
        case .digitalId: DigitalIDScreen(model: model)
        case .noPassport: NoPassportScreen(model: model)
        }
    }
}
