import CoreGraphics

/// Layout constants for PiP (Picture-in-Picture) floating panels.
///
/// Owned by ``PiPManager`` and consumed by ``PiPGeometry`` for all
/// position calculations. Centralises expanded/minimized sizes and
/// edge insets so they are defined once rather than passed as parameters.
struct PiPLayout {
    let expandedSize: CGSize
    let minimizedSize: CGSize
    let headerHeight: CGFloat
    let edgeInset: CGFloat
    let bottomInset: CGFloat
}
