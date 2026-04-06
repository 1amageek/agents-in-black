import AIBCore
import SwiftUI

/// A compact input bar shown as a node accessory on the Flow Canvas.
///
/// When the user submits a message, the `onSend` closure is called with the
/// trimmed text. The parent is responsible for routing the message to the
/// appropriate ``ChatSession`` and opening the PiP chat panel.
struct NodeAccessoryInputBar: View {
    let service: AIBServiceModel
    var isCloudMode: Bool = false
    @Binding var droppedText: String?
    let onSend: (String) -> Void

    @State private var text: String = ""
    @State private var textHeight: CGFloat = 30
    @State private var isFocused: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    private let minHeight: CGFloat = 30
    private let maxHeight: CGFloat = 320

    private var clampedHeight: CGFloat {
        min(max(textHeight, minHeight), maxHeight)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isCloudMode {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.cyan)
                    .padding(.bottom, 8)
            }

            GrowingTextView(
                text: $text,
                contentHeight: $textHeight,
                isFocused: $isFocused,
                onReturn: { send() }
            )
            .frame(height: clampedHeight)
            .overlay(alignment: .leading) {
                if text.isEmpty && !isFocused {
                    Text("Message \(displayName)...")
                        .foregroundStyle(.placeholder)
                        .allowsHitTesting(false)
                        .padding(.leading, 4)
                }
            }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(.bottom, 4)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16).strokeBorder(
                isCloudMode
                    ? Color.cyan.opacity(0.5)
                    : (colorScheme == .dark ? Color.white.opacity(0.3) : Color.black.opacity(0.2)),
                lineWidth: isCloudMode ? 1.5 : 1
            )
        )
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .frame(width: 260)
        .onChange(of: droppedText) { _, newValue in
            guard let newValue else { return }
            text = newValue
            droppedText = nil
        }
    }

    // MARK: - Helpers

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let message = trimmed
        text = ""
        onSend(message)
    }

    private var displayName: String {
        let parts = service.namespacedID.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? parts[1] : service.namespacedID
    }
}
