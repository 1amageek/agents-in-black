import AIBCore
import SwiftUI

/// A minimized PiP bubble representing an agent service.
struct AgentBubble: View {
    let service: AIBServiceModel

    private let diameter: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: diameter, height: diameter)
            Circle()
                .strokeBorder(Color.mint.opacity(0.6), lineWidth: 1.5)
                .frame(width: diameter, height: diameter)

            Text(initial)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.mint)
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .accessibilityLabel("Chat with \(service.namespacedID)")
    }

    private var initial: String {
        let parts = service.namespacedID.split(separator: "/", maxSplits: 1).map(String.init)
        return String((parts.last ?? service.namespacedID).prefix(1)).uppercased()
    }
}
