import SwiftUI

struct ChatMarkdownText: View {
    let text: String
    var role: ChatMessageRole

    private var parsedMarkdown: AttributedString? {
        do {
            return try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            return nil
        }
    }

    var body: some View {
        Group {
            if let parsedMarkdown {
                Text(parsedMarkdown)
            } else {
                Text(text)
            }
        }
        .font(.body)
        .foregroundStyle(textColor)
        .textSelection(.enabled)
        .tint(.accentColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var textColor: some ShapeStyle {
        switch role {
        case .error:
            AnyShapeStyle(Color.red)
        case .user:
            AnyShapeStyle(Color.white)
        case .assistant, .system, .info:
            AnyShapeStyle(.primary)
        }
    }
}
