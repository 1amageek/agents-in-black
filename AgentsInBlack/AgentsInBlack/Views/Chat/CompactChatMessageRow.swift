import SwiftUI

/// A Messages-style chat bubble aligned by role.
struct CompactChatMessageRow: View {
    let message: ChatMessageItem
    var isSelected: Bool = false

    private var isUser: Bool { message.role == .user }
    private var isError: Bool { message.role == .error }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                // Bubble
                VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                    ChatMarkdownText(text: message.text, role: message.role)

                    metadata
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleBackground, in: BubbleShape(isUser: isUser))
                .overlay {
                    if isSelected {
                        BubbleShape(isUser: isUser)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    }
                }

                // Timestamp outside the bubble
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            if !isUser { Spacer(minLength: 48) }
        }
    }

    // MARK: - Metadata

    @ViewBuilder
    private var metadata: some View {
        let hasInfo = message.statusCode != nil || message.latencyMs != nil
        if hasInfo {
            HStack(spacing: 4) {
                if let code = message.statusCode {
                    Text("\(code)")
                        .font(.system(size: 10).monospacedDigit())
                }
                if let ms = message.latencyMs {
                    Text("\(ms)ms")
                        .font(.system(size: 10).monospacedDigit())
                }
            }
            .foregroundStyle(metadataColor)
        }
    }

    // MARK: - Styling
    private var metadataColor: some ShapeStyle {
        if isUser { return AnyShapeStyle(Color.white.opacity(0.6)) }
        return AnyShapeStyle(.tertiary)
    }

    private var bubbleBackground: some ShapeStyle {
        switch message.role {
        case .user:
            AnyShapeStyle(Color.accentColor)
        case .assistant:
            AnyShapeStyle(Color(.controlBackgroundColor))
        case .error:
            AnyShapeStyle(Color.red.opacity(0.1))
        case .system, .info:
            AnyShapeStyle(.ultraThinMaterial)
        }
    }
}

// MARK: - Bubble Shape

/// A rounded rectangle with one corner flattened to indicate the message direction.
private struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 14
        let tail: CGFloat = 4
        return Path(
            roundedRect: rect,
            cornerRadii: RectangleCornerRadii(
                topLeading: r,
                bottomLeading: isUser ? r : tail,
                bottomTrailing: isUser ? tail : r,
                topTrailing: r
            )
        )
    }
}
