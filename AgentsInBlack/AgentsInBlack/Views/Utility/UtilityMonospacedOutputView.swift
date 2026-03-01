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
                Text(coloredOutput)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(3)
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

    // MARK: - Colored Output

    private var coloredOutput: AttributedString {
        if output.isEmpty {
            var attr = AttributedString(emptyMessage)
            attr.foregroundColor = .secondary
            return attr
        }

        let query = normalizedFilter
        let lines: [Substring]
        if query.isEmpty {
            lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        } else {
            lines = output.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { String($0).localizedStandardContains(query) }
            if lines.isEmpty {
                var attr = AttributedString(noMatchesMessage)
                attr.foregroundColor = .secondary
                return attr
            }
        }

        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            let lineStr = String(line)
            let suffix = index < lines.count - 1 ? "\n" : ""
            var attrLine = AttributedString(lineStr + suffix)
            attrLine.foregroundColor = Self.lineColor(lineStr)
            result.append(attrLine)
        }
        return result
    }

    private var normalizedFilter: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Log Level Color

    private static func lineColor(_ line: String) -> Color {
        let linePrefix = String(line.prefix(60))

        // error / critical
        if linePrefix.contains(" error ") || linePrefix.contains("[error]")
            || linePrefix.contains(" critical ") || linePrefix.contains("[critical]")
        {
            return .red
        }

        // warning
        if linePrefix.contains(" warning ") || linePrefix.contains("[warning]") {
            return .yellow
        }

        // debug / trace
        if linePrefix.contains(" debug ") || linePrefix.contains("[debug]")
            || linePrefix.contains(" trace ") || linePrefix.contains("[trace]")
        {
            return .secondary
        }

        // JSON gateway logs — HTTP 5xx / 4xx
        if line.contains("\"status\":5") {
            return .red
        }
        if line.contains("\"status\":4") {
            return .orange
        }

        return .primary
    }
}
