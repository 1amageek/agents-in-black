import SwiftUI

struct AppSettingsView: View {
    @AppStorage(AppSettingsKey.terminalFontSize) private var terminalFontSize = AppSettingsDefault.terminalFontSize

    var body: some View {
        Form {
            Section("Terminal") {
                HStack {
                    Text("Font Size")
                    Spacer()
                    Text("\(Int(terminalFontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(value: $terminalFontSize, in: 8...24, step: 1) {
                    Text("Font Size")
                } minimumValueLabel: {
                    Text("A")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("A")
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text("The quick brown fox jumps over the lazy dog")
                    .font(.system(size: CGFloat(terminalFontSize), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
    }
}

#Preview {
    AppSettingsView()
}
