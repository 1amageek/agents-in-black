import AIBCore
import SwiftUI

/// The expanded PiP chat panel with a header, chat view, and window controls.
///
/// The header is split into a draggable title region and non-draggable
/// window control buttons, following macOS HIG for floating panels.
struct PiPChatPanel: View {
    @Bindable var store: ChatStore
    let service: AIBServiceModel
    var onMinimize: () -> Void
    var onClose: () -> Void

    @Environment(\.pipDragHandler) private var dragHandler

    static let panelSize = CGSize(width: 320, height: 480)

    var body: some View {
        VStack(spacing: 0) {
            header
            CompactChatView(store: store)
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 20, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat with \(service.namespacedID)")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            // Draggable title region
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.mint)
                    .font(.caption)

                Text(displayName)
                    .font(.system(size: 11, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .gesture(headerDrag)

            // Window controls (not draggable)
            HStack(spacing: 4) {
                Button(action: onMinimize) {
                    Image(systemName: "minus")
                        .font(.caption2.weight(.bold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Minimize")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Chat")
            }
            .padding(.trailing, 8)
        }
        .background(.bar)
    }

    // MARK: - Drag

    /// Uses global coordinate space so translation is stable as the view moves.
    private var headerDrag: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                dragHandler?.onChanged(value.translation)
            }
            .onEnded { value in
                dragHandler?.onEnded(value.velocity)
            }
    }

    // MARK: - Helpers

    private var displayName: String {
        let parts = service.namespacedID.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? parts[1] : service.namespacedID
    }
}
