import AppKit
import SwiftUI

struct UtilityMonospacedOutputView: View {
    let lines: [LogLine]
    let emptyMessage: String
    var filterText: String = ""
    var noMatchesMessage: String = "No lines match the current filter."

    var body: some View {
        ZStack(alignment: .topLeading) {
            LogTextView(lines: lines, filterText: filterText)

            if let overlayText {
                Text(overlayText)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor))
                    .allowsHitTesting(false)
            }
        }
    }

    private var overlayText: String? {
        if lines.isEmpty { return emptyMessage }
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let hasMatch = lines.contains { $0.text.localizedStandardContains(query) }
        return hasMatch ? nil : noMatchesMessage
    }
}
