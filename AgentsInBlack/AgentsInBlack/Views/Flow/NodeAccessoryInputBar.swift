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
    let onSend: (String) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            if isCloudMode {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.cyan)
            }

            TextField("Message \(displayName)...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .focused($isFocused)
                .onSubmit {
                    send()
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
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.thickMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                isCloudMode
                    ? Color.cyan.opacity(0.5)
                    : (colorScheme == .dark ? Color.white.opacity(0.3) : Color.black.opacity(0.2)),
                lineWidth: isCloudMode ? 1.5 : 1
            )
        )
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .frame(width: 260)
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
