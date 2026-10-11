// Nod ID SDK, test mode: the "Choose a sample passport" screen and the TEST MODE banner. DEBUG builds only.
#if DEBUG
import SwiftUI

struct SamplePickerScreen: View {
    let model: NodIDFlowModel
    var body: some View {
        NodScreen {
            VStack(alignment: .leading, spacing: 16) {
                NodTitle(text: "Choose a sample passport")
                Text("Test mode has no real passport, no NFC and no camera. Pick a sample to see what the member sees. \(model.app) learns only verified or not verified.")
                    .nodBody()
                NodCard {
                    ForEach(Array(TestSample.allCases.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Divider().padding(.leading, 16) }
                        Button { model.pickSample(s) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    Text(s.detail).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
                            }.padding(.horizontal, 16).frame(minHeight: 56).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("\(s.title), \(s.detail)")
                    }
                }
                Text("Nothing is read from a passport and no proof is made.").font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            EmptyView()
        }
    }
}

struct TestBanner: View {
    var body: some View {
        Text("TEST MODE: sample passport, nothing was checked")
            .font(.caption.weight(.bold)).foregroundStyle(.black).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.vertical, 5).padding(.horizontal, 12)
            .background(Color.yellow)
            .accessibilityLabel("Test mode. Sample passport, nothing was checked.")
    }
}

extension NodIDFlowModel {
    /// A sample was chosen: hand the flow a test chip and go straight to the proving screen. No scan, no NFC, no proof.
    func pickSample(_ s: TestSample) {
        guard services is TestServices else { return }
        chip = TestChip(s)
        startProving()
    }
}
#endif
