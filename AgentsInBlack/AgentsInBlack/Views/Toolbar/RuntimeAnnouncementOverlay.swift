import SwiftUI

struct RuntimeAnnouncementOverlay: View {
    @Bindable var center: RuntimeAnnouncementCenter

    var body: some View {
        ZStack {
            if let announcement = center.current {
                announcementCard(for: announcement)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.92).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.38, bounce: 0.18), value: center.current?.id)
    }

    private func announcementCard(for announcement: RuntimeAnnouncement) -> some View {
        VStack(spacing: 12) {
            Image(systemName: announcement.symbolName)
                .font(.system(size: 72, weight: .medium))
                .foregroundStyle(symbolColor(for: announcement.style))
                .symbolRenderingMode(.hierarchical)

            Text(announcement.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            if let message = announcement.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(width: 220)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        .allowsHitTesting(announcement.autoDismissDelay == nil)
        .overlay(alignment: .topTrailing) {
            if announcement.autoDismissDelay == nil {
                Button {
                    center.dismissCurrent()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .allowsHitTesting(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: announcement))
    }

    private func symbolColor(for style: RuntimeAnnouncement.Style) -> Color {
        switch style {
        case .success: return .white
        case .info: return .white
        case .warning: return .yellow
        case .error: return .red
        }
    }

    private func accessibilityLabel(for announcement: RuntimeAnnouncement) -> String {
        if let message = announcement.message {
            return "\(announcement.title). \(message)"
        }
        return announcement.title
    }
}
