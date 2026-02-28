import CoreGraphics
import Foundation

/// Layout state for a single PiP (Picture-in-Picture) floating panel.
struct PiPItemState: Identifiable {
    let id: String
    var isExpanded: Bool = true
    var position: CGPoint = .zero
}
