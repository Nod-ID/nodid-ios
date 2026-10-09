// Nod ID SDK: SwiftUI previews on MockServices. Not rendered or viewed by the author; compile-checked only.
#if DEBUG
import SwiftUI

@MainActor private func previewView(_ s: FlowScreen, nfc: NFCUIState = .idle, long: Bool = false, step: ProofStep? = nil, offset: Int = 0, order: [PlacementSpot]? = nil) -> some View {
    let m = NodIDFlowModel(sessionId: "preview", services: MockServices()) { _ in }
    m.previewShow(s, nfc: nfc, long: long, step: step, spotOffset: offset, order: order)
    return NodIDVerifyViewPreviewHost(model: m)
}
private struct NodIDVerifyViewPreviewHost: View {
    let model: NodIDFlowModel
    var body: some View { NodIDVerifyView(model: model) }
}

#Preview("01 Intro") { previewView(.intro) }
#Preview("01 Intro dark") { previewView(.intro).preferredColorScheme(.dark) }
#Preview("05a US back cover") { previewView(.placement, nfc: .reading(40), order: [.backCover, .photoPage, .frontCover]) }
#Preview("05a photo page") { previewView(.placement, nfc: .searching, order: [.photoPage, .backCover, .frontCover]) }
#Preview("05a front cover, closer") { previewView(.placement, nfc: .closer, order: [.frontCover, .backCover, .photoPage]) }
#Preview("06 Proving") { previewView(.proving, step: .checkingRules) }
#Preview("06b Still working") { previewView(.proving, long: true, step: .makingProof) }
#Preview("07a Verified") { previewView(.success) }
#Preview("07c Expired") { previewView(.failure(.expired)) }
#Preview("07b Chip unreadable") { previewView(.failure(.chipUnreadable)) }
#Preview("09 Receipt") { previewView(.receipt) }
#Preview("Intro AX5") { previewView(.intro).dynamicTypeSize(.accessibility5) }
#endif
