import CoreGraphics
import Foundation

/// Layout state for a single PiP (Picture-in-Picture) floating panel.
///
/// Each panel is uniquely identified by its session ID.
/// The `serviceID` is retained for service lookup in views.
struct PiPItemState: Identifiable {
    let id: UUID
    let serviceID: String
    var isExpanded: Bool = true
    var position: CGPoint = .zero
    var zIndex: Int = 0
}
