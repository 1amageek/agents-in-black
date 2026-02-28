import SwiftUI

struct EmulatorOutputView: View {
    @Bindable var model: AgentsInBlackAppModel
    var showsHeader: Bool = true
    var filterText: String = ""

    var body: some View {
        let output = model.aibLogOutput()

        VStack(spacing: 0) {
            if showsHeader {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AIB Logs")
                            .font(.headline)
                        Text(model.emulatorState.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Button("Clear") {
                        model.clearAIBLogs()
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

                Divider()
            }
            UtilityMonospacedOutputView(
                output: output,
                emptyMessage: emptyMessage,
                scrollAnchorID: "emulator-output-bottom",
                filterText: filterText
            )
        }
    }

    private var emptyMessage: String {
        "Run the emulator to stream AIB logs here."
    }
}
