import SwiftUI

/// A generic floating panel that supports minimized and expanded states.
///
/// Both states snap to the nearest content-aware corner on drag end with
/// momentum. When transitioning between states, both views coexist in a
/// ZStack and their opacity/scale are driven directly by `isExpanded`,
/// ensuring position, scale and opacity animate in a single transaction.
///
/// All drag gestures use the global coordinate space to avoid feedback loops
/// caused by the view moving under the gesture during drag.
struct PiPContainer<Minimized: View, Expanded: View>: View {
    @Binding var isExpanded: Bool
    @Binding var position: CGPoint
    let canvasSize: CGSize
    let minimizedSize: CGSize
    let expandedSize: CGSize

    @ViewBuilder var minimized: Minimized
    @ViewBuilder var expanded: Expanded

    @State private var dragOffset: CGSize = .zero

    var currentContentSize: CGSize {
        isExpanded ? expandedSize : minimizedSize
    }

    /// Scale ratio between bubble and panel (e.g. 44/320 ≈ 0.14).
    private var bubbleToPanelScale: CGFloat {
        guard expandedSize.width > 0 else { return 0.1 }
        return minimizedSize.width / expandedSize.width
    }

    private var transitionAnimation: Animation { .spring(duration: 0.35, bounce: 0.15) }

    var body: some View {
        ZStack {
            expanded
                .environment(\.pipDragHandler, makeDragHandler())
                .opacity(isExpanded ? 1 : 0)
                .scaleEffect(isExpanded ? 1 : bubbleToPanelScale)
                .allowsHitTesting(isExpanded)

            minimized
                .gesture(bubbleDrag)
                .opacity(isExpanded ? 0 : 1)
                .scaleEffect(isExpanded ? (1 / bubbleToPanelScale) : 1)
                .allowsHitTesting(!isExpanded)
        }
        .position(
            x: position.x + dragOffset.width,
            y: position.y + dragOffset.height
        )
        .onChange(of: canvasSize) { _, newSize in
            let corner = PiPGeometry.nearestCorner(to: position, in: newSize, contentSize: currentContentSize)
            withAnimation(transitionAnimation) {
                position = corner
            }
        }
        .onChange(of: isExpanded) { _, _ in
            dragOffset = .zero
        }
    }

    // MARK: - Drag Handler (Environment)

    private func makeDragHandler() -> PiPDragHandler {
        PiPDragHandler(
            onChanged: { translation in
                dragOffset = translation
            },
            onEnded: { velocity in
                applyDragEnd(velocity: velocity)
            }
        )
    }

    // MARK: - Bubble Drag (Minimized)

    private var bubbleDrag: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                applyDragEnd(velocity: value.velocity)
            }
    }

    // MARK: - Shared

    private func applyDragEnd(velocity: CGSize) {
        let currentPosition = CGPoint(
            x: position.x + dragOffset.width,
            y: position.y + dragOffset.height
        )
        let projectedPosition = CGPoint(
            x: currentPosition.x + PiPGeometry.project(initialVelocity: velocity.width),
            y: currentPosition.y + PiPGeometry.project(initialVelocity: velocity.height)
        )
        let corner = PiPGeometry.nearestCorner(to: projectedPosition, in: canvasSize, contentSize: currentContentSize)
        position = currentPosition
        dragOffset = .zero
        withAnimation(transitionAnimation) {
            position = corner
        }
    }
}

// MARK: - PiP Drag Handler (Environment)

/// Drag callbacks injected by ``PiPContainer`` into the expanded content.
/// The content applies these to its draggable title bar region.
struct PiPDragHandler {
    /// Called on each drag movement with the current translation.
    let onChanged: (CGSize) -> Void
    /// Called on drag end with the gesture velocity (points per second).
    let onEnded: (CGSize) -> Void
}

private struct PiPDragHandlerKey: EnvironmentKey {
    static let defaultValue: PiPDragHandler? = nil
}

extension EnvironmentValues {
    var pipDragHandler: PiPDragHandler? {
        get { self[PiPDragHandlerKey.self] }
        set { self[PiPDragHandlerKey.self] = newValue }
    }
}

// MARK: - PiP Geometry

enum PiPGeometry {
    static let edgeInset: CGFloat = 16
    static let bottomInset: CGFloat = 76
    static let defaultBubbleSize = CGSize(width: 44, height: 44)

    /// Deceleration rate matching UIScrollView.DecelerationRate.normal (0.998).
    private static let decelerationRate: CGFloat = 0.998

    /// Distance travelled after decelerating to zero velocity at a constant rate.
    static func project(initialVelocity: CGFloat) -> CGFloat {
        (initialVelocity / 1000.0) * decelerationRate / (1.0 - decelerationRate)
    }

    /// Clamp a center point so the content stays within the canvas bounds.
    /// When the canvas is smaller than the content, centers on that axis.
    static func clamped(_ point: CGPoint, in canvasSize: CGSize, contentSize: CGSize) -> CGPoint {
        let halfW = contentSize.width / 2
        let halfH = contentSize.height / 2
        let minX = halfW + edgeInset
        let maxX = canvasSize.width - halfW - edgeInset
        let minY = halfH + edgeInset
        let maxY = canvasSize.height - halfH - bottomInset
        return CGPoint(
            x: minX <= maxX ? max(minX, min(maxX, point.x)) : canvasSize.width / 2,
            y: minY <= maxY ? max(minY, min(maxY, point.y)) : canvasSize.height / 2
        )
    }

    /// Find the nearest snap corner for the given content size.
    static func nearestCorner(to point: CGPoint, in canvasSize: CGSize, contentSize: CGSize) -> CGPoint {
        let corners = allCorners(in: canvasSize, contentSize: contentSize)
        return corners.min(by: { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }) ?? point
    }

    /// Map a position from one content size to the corresponding corner of another.
    ///
    /// Finds which corner index the position is nearest to in the `fromSize` layout,
    /// then returns the same-index corner in the `toSize` layout.
    /// This preserves spatial intent (e.g. top-right stays top-right).
    static func correspondingCorner(
        from position: CGPoint,
        in canvasSize: CGSize,
        fromSize: CGSize,
        toSize: CGSize
    ) -> CGPoint {
        let fromCorners = allCorners(in: canvasSize, contentSize: fromSize)
        let toCorners = allCorners(in: canvasSize, contentSize: toSize)

        var bestIndex = 0
        var bestDist = CGFloat.infinity
        for (i, corner) in fromCorners.enumerated() {
            let d = hypot(corner.x - position.x, corner.y - position.y)
            if d < bestDist {
                bestDist = d
                bestIndex = i
            }
        }
        return toCorners[bestIndex]
    }

    /// Compute an initial position for a minimized PiP bubble, avoiding existing positions.
    static func initialPosition(
        in size: CGSize,
        avoiding existingPositions: [CGPoint]
    ) -> CGPoint {
        let corners = allCorners(in: size, contentSize: defaultBubbleSize)
        return corners.first(where: { corner in
            !existingPositions.contains(where: { hypot($0.x - corner.x, $0.y - corner.y) < 30 })
        }) ?? CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Compute an initial position for an expanded PiP panel, avoiding existing positions.
    static func initialExpandedPosition(
        in canvasSize: CGSize,
        panelSize: CGSize,
        avoiding existingPositions: [CGPoint]
    ) -> CGPoint {
        let corners = allCorners(in: canvasSize, contentSize: panelSize)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let candidates = corners + [center]

        let minDistance: CGFloat = 60
        return candidates.first(where: { pos in
            !existingPositions.contains(where: { hypot($0.x - pos.x, $0.y - pos.y) < minDistance })
        }) ?? center
    }

    /// Four corner positions where content of the given size fits within bounds.
    /// When the canvas is smaller than the content on an axis, centers on that axis.
    private static func allCorners(in canvasSize: CGSize, contentSize: CGSize) -> [CGPoint] {
        let halfW = contentSize.width / 2
        let halfH = contentSize.height / 2
        let minX = halfW + edgeInset
        let maxX = canvasSize.width - halfW - edgeInset
        let minY = halfH + edgeInset
        let maxY = canvasSize.height - halfH - bottomInset

        let cx = canvasSize.width / 2
        let cy = canvasSize.height / 2
        let x0 = minX <= maxX ? minX : cx
        let x1 = minX <= maxX ? maxX : cx
        let y0 = minY <= maxY ? minY : cy
        let y1 = minY <= maxY ? maxY : cy
        return [
            CGPoint(x: x1, y: y0),  // top-right
            CGPoint(x: x0, y: y0),  // top-left
            CGPoint(x: x1, y: y1),  // bottom-right
            CGPoint(x: x0, y: y1),  // bottom-left
        ]
    }
}
