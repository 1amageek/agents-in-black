import SwiftUI

struct IssueCountButtonView: View {
    let severity: RuntimeIssueSeverity
    let count: Int
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: severity.symbol)
                    .font(.caption)
                Text("\(count)")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(label.lowercased()) in sidebar")
    }

    private var foregroundColor: Color {
        guard count > 0 else { return .secondary }
        switch severity {
        case .error:
            return .red
        case .warning:
            return .yellow
        }
    }
}
