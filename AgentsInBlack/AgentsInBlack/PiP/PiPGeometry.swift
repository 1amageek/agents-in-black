import CoreGraphics

/// Pure geometry helpers for PiP panel positioning.
///
/// All methods are static and side-effect free. They compute snap
/// corners, overlap detection, cascade offsets, and deceleration
/// projections used by ``PiPManager`` and ``PiPContainer``.
enum PiPGeometry {
    static let defaultBubbleSize = CGSize(width: 44, height: 44)

    /// Deceleration rate matching UIScrollView.DecelerationRate.normal (0.998).
    private static let decelerationRate: CGFloat = 0.998

    /// Distance travelled after decelerating to zero velocity at a constant rate.
    static func project(initialVelocity: CGFloat) -> CGFloat {
        (initialVelocity / 1000.0) * decelerationRate / (1.0 - decelerationRate)
    }

    /// Clamp a center point so the content stays within the canvas bounds.
    /// When the canvas is smaller than the content, centers on that axis.
    static func clamped(
        _ point: CGPoint,
        in canvasSize: CGSize,
        contentSize: CGSize,
        edgeInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGPoint {
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

    /// Convenience overload that reads insets from a ``PiPLayout``.
    static func clamped(_ point: CGPoint, in canvasSize: CGSize, contentSize: CGSize, layout: PiPLayout) -> CGPoint {
        clamped(point, in: canvasSize, contentSize: contentSize, edgeInset: layout.edgeInset, bottomInset: layout.bottomInset)
    }

    /// Find the nearest snap corner for the given content size.
    static func nearestCorner(
        to point: CGPoint,
        in canvasSize: CGSize,
        contentSize: CGSize,
        edgeInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGPoint {
        let corners = allCorners(in: canvasSize, contentSize: contentSize, edgeInset: edgeInset, bottomInset: bottomInset)
        return corners.min(by: {
            hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y)
        }) ?? point
    }

    /// Convenience overload that reads insets from a ``PiPLayout``.
    static func nearestCorner(to point: CGPoint, in canvasSize: CGSize, contentSize: CGSize, layout: PiPLayout) -> CGPoint {
        nearestCorner(to: point, in: canvasSize, contentSize: contentSize, edgeInset: layout.edgeInset, bottomInset: layout.bottomInset)
    }

    /// Index of the nearest corner.
    ///
    /// Indices are: 0 = top-right, 1 = top-left, 2 = bottom-right, 3 = bottom-left.
    static func nearestCornerIndex(
        to point: CGPoint,
        in canvasSize: CGSize,
        contentSize: CGSize,
        edgeInset: CGFloat,
        bottomInset: CGFloat
    ) -> Int {
        let corners = allCorners(in: canvasSize, contentSize: contentSize, edgeInset: edgeInset, bottomInset: bottomInset)
        var bestIndex = 0
        var bestDistance = CGFloat.infinity
        for (index, corner) in corners.enumerated() {
            let distance = hypot(corner.x - point.x, corner.y - point.y)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Convenience overload that reads insets from a ``PiPLayout``.
    static func nearestCornerIndex(
        to point: CGPoint,
        in canvasSize: CGSize,
        contentSize: CGSize,
        layout: PiPLayout
    ) -> Int {
        nearestCornerIndex(
            to: point,
            in: canvasSize,
            contentSize: contentSize,
            edgeInset: layout.edgeInset,
            bottomInset: layout.bottomInset
        )
    }

    /// Corner center point for a corner index.
    ///
    /// Indices are: 0 = top-right, 1 = top-left, 2 = bottom-right, 3 = bottom-left.
    static func corner(
        at index: Int,
        in canvasSize: CGSize,
        contentSize: CGSize,
        edgeInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGPoint {
        let corners = allCorners(in: canvasSize, contentSize: contentSize, edgeInset: edgeInset, bottomInset: bottomInset)
        let safeIndex = min(max(index, 0), corners.count - 1)
        return corners[safeIndex]
    }

    /// Convenience overload that reads insets from a ``PiPLayout``.
    static func corner(at index: Int, in canvasSize: CGSize, contentSize: CGSize, layout: PiPLayout) -> CGPoint {
        corner(at: index, in: canvasSize, contentSize: contentSize, edgeInset: layout.edgeInset, bottomInset: layout.bottomInset)
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
        toSize: CGSize,
        edgeInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGPoint {
        let fromCorners = allCorners(in: canvasSize, contentSize: fromSize, edgeInset: edgeInset, bottomInset: bottomInset)
        let toCorners = allCorners(in: canvasSize, contentSize: toSize, edgeInset: edgeInset, bottomInset: bottomInset)

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

    /// Convenience overload that reads insets from a ``PiPLayout``.
    static func correspondingCorner(
        from position: CGPoint,
        in canvasSize: CGSize,
        fromSize: CGSize,
        toSize: CGSize,
        layout: PiPLayout
    ) -> CGPoint {
        correspondingCorner(from: position, in: canvasSize, fromSize: fromSize, toSize: toSize, edgeInset: layout.edgeInset, bottomInset: layout.bottomInset)
    }

    /// Whether two panel bounding boxes overlap, given their center points.
    static func panelsOverlap(
        _ a: CGPoint, _ b: CGPoint, panelSize: CGSize
    ) -> Bool {
        abs(a.x - b.x) < panelSize.width && abs(a.y - b.y) < panelSize.height
    }

    /// Snap a point to the nearest corner that does NOT overlap any existing
    /// position. Falls back to cascade when all corners are taken.
    static func nearestAvailableCorner(
        to point: CGPoint,
        in canvasSize: CGSize,
        contentSize: CGSize,
        avoiding existingPositions: [CGPoint],
        layout: PiPLayout
    ) -> CGPoint {
        let corners = allCorners(in: canvasSize, contentSize: contentSize, edgeInset: layout.edgeInset, bottomInset: layout.bottomInset)
        // Sort corners by distance to current position (prefer staying close).
        let sorted = corners.sorted {
            hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y)
        }
        // Pick the nearest corner that doesn't overlap any assigned position.
        if let free = sorted.first(where: { corner in
            !existingPositions.contains(where: { panelsOverlap($0, corner, panelSize: contentSize) })
        }) {
            return free
        }
        // All corners overlap — cascade from the nearest corner.
        let base = sorted.first ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        return cascaded(
            from: base,
            in: canvasSize,
            contentSize: contentSize,
            existingPositions: existingPositions,
            layout: layout
        )
    }

    /// Compute an initial position for a PiP panel, avoiding existing positions.
    ///
    /// Uses bounding-box overlap detection so that panels whose rectangles
    /// intersect are never considered "free".
    static func initialPosition(
        in canvasSize: CGSize,
        contentSize: CGSize,
        avoiding existingPositions: [CGPoint],
        layout: PiPLayout
    ) -> CGPoint {
        let corners = allCorners(in: canvasSize, contentSize: contentSize, edgeInset: layout.edgeInset, bottomInset: layout.bottomInset)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let candidates = corners + [center]

        if let free = candidates.first(where: { pos in
            !existingPositions.contains(where: { panelsOverlap($0, pos, panelSize: contentSize) })
        }) {
            return free
        }
        // Cascade from top-right corner
        let base = corners.first ?? center
        return cascaded(
            from: base,
            in: canvasSize,
            contentSize: contentSize,
            existingPositions: existingPositions,
            layout: layout
        )
    }

    // MARK: - Private

    /// Cascade step offsets by the full panel width + gap so panels sit
    /// side-by-side without overlap. Falls back to smaller vertical offset
    /// when horizontal space is exhausted.
    private static let cascadeGap: CGFloat = 16
    private static let maxCascadeAttempts = 10

    private static func cascaded(
        from base: CGPoint,
        in canvasSize: CGSize,
        contentSize: CGSize,
        existingPositions: [CGPoint],
        layout: PiPLayout
    ) -> CGPoint {
        let hStep = contentSize.width + cascadeGap
        let vStep = contentSize.height + cascadeGap

        // Try horizontal placement first (left of base, then right).
        // Then try vertical (below base, then above).
        let offsets: [(CGFloat, CGFloat)] = [
            (-hStep, 0), (hStep, 0),
            (0, vStep), (0, -vStep),
            (-hStep, vStep), (hStep, vStep),
            (-hStep, -vStep), (hStep, -vStep),
        ]

        for (dx, dy) in offsets {
            let candidate = CGPoint(x: base.x + dx, y: base.y + dy)
            let clampedPoint = clamped(
                candidate, in: canvasSize, contentSize: contentSize,
                edgeInset: layout.edgeInset, bottomInset: layout.bottomInset
            )
            if !existingPositions.contains(where: { panelsOverlap($0, clampedPoint, panelSize: contentSize) }) {
                return clampedPoint
            }
        }

        // Fallback: macOS-style diagonal cascade with header-height offset
        for i in 1...maxCascadeAttempts {
            let offset = CGFloat(i)
            let candidate = CGPoint(
                x: base.x - offset * layout.headerHeight,
                y: base.y + offset * layout.headerHeight
            )
            let clampedPoint = clamped(
                candidate, in: canvasSize, contentSize: contentSize,
                edgeInset: layout.edgeInset, bottomInset: layout.bottomInset
            )
            if !existingPositions.contains(where: { panelsOverlap($0, clampedPoint, panelSize: contentSize) }) {
                return clampedPoint
            }
        }

        // Last resort: offset from base
        let fallback = CGPoint(
            x: base.x - CGFloat(maxCascadeAttempts + 1) * layout.headerHeight,
            y: base.y + CGFloat(maxCascadeAttempts + 1) * layout.headerHeight
        )
        return clamped(fallback, in: canvasSize, contentSize: contentSize, edgeInset: layout.edgeInset, bottomInset: layout.bottomInset)
    }

    /// Four corner positions where content of the given size fits within bounds.
    /// When the canvas is smaller than the content on an axis, centers on that axis.
    private static func allCorners(
        in canvasSize: CGSize,
        contentSize: CGSize,
        edgeInset: CGFloat,
        bottomInset: CGFloat
    ) -> [CGPoint] {
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
