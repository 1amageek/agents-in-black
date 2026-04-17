import AppKit
import SwiftUI

struct UtilityMonospacedOutputView: View {
    let lines: [LogLine]
    let emptyMessage: String
    var filterText: String = ""
    var noMatchesMessage: String = "No lines match the current filter."

    var body: some View {
        ScrollViewReader { proxy in
            let visible = filteredLines
            ScrollView {
                content(visible: visible)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: visible.last?.id) { _, newID in
                guard let newID else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newID, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func content(visible: [LogLine]) -> some View {
        if lines.isEmpty {
            placeholder(emptyMessage)
        } else if visible.isEmpty {
            placeholder(noMatchesMessage)
        } else {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(visible) { line in
                    Text(line.text)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Self.lineColor(line.text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(line.id)
                }
            }
            .textSelection(.enabled)
            .padding(12)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }

    private var filteredLines: [LogLine] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return lines }
        return lines.filter { $0.text.localizedStandardContains(query) }
    }

    // MARK: - Log Level Color

    private static func lineColor(_ line: String) -> Color {
        let linePrefix = String(line.prefix(60))

        if linePrefix.contains(" error ") || linePrefix.contains("[error]")
            || linePrefix.contains(" critical ") || linePrefix.contains("[critical]")
        {
            return .red
        }

        if linePrefix.contains(" warning ") || linePrefix.contains("[warning]") {
            return .yellow
        }

        if linePrefix.contains(" debug ") || linePrefix.contains("[debug]")
            || linePrefix.contains(" trace ") || linePrefix.contains("[trace]")
        {
            return .secondary
        }

        if line.contains("\"status\":5") {
            return .red
        }
        if line.contains("\"status\":4") {
            return .orange
        }

        return .primary
    }
}
