import AIBCore
import SwiftUI

/// The expanded PiP chat panel with a header, chat view, and window controls.
///
/// The header follows macOS HIG: close/minimize on the left, centered title.
/// The panel uses Liquid Glass for its background material.
struct PiPChatPanel: View {
    @Bindable var session: ChatSession
    let service: AIBServiceModel
    var onMinimize: () -> Void
    var onClose: () -> Void
    var onSelectMessage: ((ChatMessageItem?) -> Void)?

    @Environment(\.pipDragHandler) private var dragHandler

    static let panelSize = CGSize(width: 320, height: 480)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            CompactChatView(session: session, onSelectMessage: onSelectMessage)
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat with \(service.namespacedID)")
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            // Centered title (draggable)
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.mint)
                    .font(.system(size: 10, weight: .medium))
                Text(displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(headerDrag)

            // Window controls on the left (not draggable)
            HStack(spacing: 0) {
                GlassEffectContainer(spacing: 2) {
                    HStack(spacing: 2) {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 20, height: 20)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .help("Close Chat")

                        Button(action: onMinimize) {
                            Image(systemName: "minus")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 20, height: 20)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .help("Minimize")
                    }
                }
                .padding(.leading, 10)
                Spacer()
            }
        }
        .padding(.vertical, 8)
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
