import AppKit
import SwiftUI

struct UtilityMonospacedOutputView: View {
    let output: String
    let emptyMessage: String
    let scrollAnchorID: String
    var filterText: String = ""
    var noMatchesMessage: String = "No lines match the current filter."

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(displayText)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(isPlaceholder ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .id(scrollAnchorID)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: output) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(scrollAnchorID, anchor: .bottom)
                }
            }
        }
    }

    private var displayText: String {
        if output.isEmpty {
            return emptyMessage
        }

        let query = normalizedFilter
        guard !query.isEmpty else { return output }

        let filteredLines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                String(line).localizedStandardContains(query)
            }

        if filteredLines.isEmpty {
            return noMatchesMessage
        }
        return filteredLines.joined(separator: "\n")
    }

    private var normalizedFilter: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isPlaceholder: Bool {
        if output.isEmpty { return true }
        return !normalizedFilter.isEmpty && displayText == noMatchesMessage
    }
}
