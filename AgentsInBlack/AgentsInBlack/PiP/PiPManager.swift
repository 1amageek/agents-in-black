import CoreGraphics
import Foundation
import Observation

/// Manages PiP (Picture-in-Picture) floating chat panels.
///
/// Each panel is uniquely identified by its session ID, allowing
/// multiple independent panels per service. Owns all PiP layout state:
/// positions, expanded/collapsed. Guarantees that new panels never
/// fully overlap existing ones by deferring positioning until a valid
/// canvas size is available.
@MainActor
@Observable
final class PiPManager {

    /// Layout constants used for all position calculations.
    let layout: PiPLayout

    /// Currently open PiP panels.
    var items: [PiPItemState] = []

    /// Canvas size used for position calculations. Updated by FlowCanvasView.
    var canvasSize: CGSize = .zero
    private var nextZIndex: Int = 0
    private let expandedCornerStackOffset: CGFloat = 28
    private let minimizedCornerStackOffset: CGFloat = 12

    init(layout: PiPLayout) {
        self.layout = layout
    }

    // MARK: - Open / Close

    /// Open or re-activate a PiP panel for the given session.
    ///
    /// If a panel already exists for this session, it is brought to front
    /// and expanded. Otherwise a new panel is appended and positioned
    /// to avoid overlapping existing panels.
    func open(serviceID: String, sessionID: UUID) {
        if let index = items.firstIndex(where: { $0.id == sessionID }) {
            bringToFront(sessionID: sessionID)
            if !items[index].isExpanded {
                let proposedPosition = PiPGeometry.correspondingCorner(
                    from: items[index].position,
                    in: canvasSize,
                    fromSize: layout.minimizedSize,
                    toSize: layout.expandedSize,
                    layout: layout
                )
                items[index].position = resolveSnapPosition(
                    for: sessionID,
                    proposed: proposedPosition,
                    contentSize: layout.expandedSize
                )
            }
            items[index].isExpanded = true
            return
        }
        let position = nextAvailablePosition(for: layout.expandedSize)
        items.append(PiPItemState(
            id: sessionID,
            serviceID: serviceID,
            isExpanded: true,
            position: position,
            zIndex: allocateZIndex()
        ))
    }

    func close(sessionID: UUID) {
        items.removeAll(where: { $0.id == sessionID })
    }

    func closeAll() {
        items.removeAll()
        nextZIndex = 0
    }

    // MARK: - Canvas Size

    /// Called by FlowCanvasView when the canvas geometry changes.
    ///
    /// When the canvas transitions from zero to a valid size (e.g. topology view
    /// first appears), ALL panels are repositioned from scratch because their
    /// initial positions were computed blind. On subsequent resizes, only
    /// pairwise overlaps are resolved.
    func updateCanvasSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let wasZero = canvasSize.width <= 0 || canvasSize.height <= 0
        let sizeChanged = canvasSize != size
        canvasSize = size
        guard sizeChanged else { return }
        if wasZero {
            repositionAll()
        } else {
            snapAllAvoidingOverlap()
        }
    }

    // MARK: - Expand / Collapse

    /// Toggle expanded state and move to the corresponding corner.
    func toggleExpanded(sessionID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == sessionID }) else { return }
        bringToFront(sessionID: sessionID)
        let wasExpanded = items[index].isExpanded
        let fromSize = wasExpanded ? layout.expandedSize : layout.minimizedSize
        let toSize = wasExpanded ? layout.minimizedSize : layout.expandedSize
        let proposedPosition = PiPGeometry.correspondingCorner(
            from: items[index].position,
            in: canvasSize,
            fromSize: fromSize,
            toSize: toSize,
            layout: layout
        )
        items[index].position = resolveSnapPosition(
            for: sessionID,
            proposed: proposedPosition,
            contentSize: toSize
        )
        items[index].isExpanded = !wasExpanded
    }

    /// Mark this PiP as the most recently interacted item so it renders on top.
    func bringToFront(sessionID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == sessionID }) else { return }
        items[index].zIndex = allocateZIndex()
    }

    /// Resolve a drag/toggle snap target by keeping the same corner and
    /// applying a small inward offset when that corner is already occupied.
    func resolveSnapPosition(
        for sessionID: UUID,
        proposed: CGPoint,
        contentSize: CGSize
    ) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return proposed }
        let cornerIndex = PiPGeometry.nearestCornerIndex(
            to: proposed,
            in: canvasSize,
            contentSize: contentSize,
            layout: layout
        )
        let takenPositions = items.compactMap { item -> CGPoint? in
            guard item.id != sessionID else { return nil }
            let itemSize = item.isExpanded ? layout.expandedSize : layout.minimizedSize
            let itemCornerIndex = PiPGeometry.nearestCornerIndex(
                to: item.position,
                in: canvasSize,
                contentSize: itemSize,
                layout: layout
            )
            return itemCornerIndex == cornerIndex ? item.position : nil
        }
        return cornerStackedPositionAvoidingDuplicates(
            cornerIndex: cornerIndex,
            contentSize: contentSize,
            takenPositions: takenPositions
        )
    }

    // MARK: - Positioning

    /// Assign fresh positions to ALL items sequentially, each avoiding preceding ones.
    /// Used when the canvas first becomes available and items placed at zero-canvas
    /// origin need valid positions.
    private func repositionAll() {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        for i in items.indices {
            let contentSize = items[i].isExpanded ? layout.expandedSize : layout.minimizedSize
            let preceding = items[..<i].map(\.position)
            items[i].position = PiPGeometry.initialPosition(
                in: canvasSize,
                contentSize: contentSize,
                avoiding: preceding,
                layout: layout
            )
        }
    }

    /// Snap each item to its nearest corner and keep same-corner items in a
    /// diagonal stack so they remain visible after canvas resize.
    private func snapAllAvoidingOverlap() {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        var assignedPositionsByCorner: [Int: [CGPoint]] = [:]
        let sortedIndices = items.indices.sorted { items[$0].zIndex < items[$1].zIndex }
        for i in sortedIndices {
            let contentSize = items[i].isExpanded ? layout.expandedSize : layout.minimizedSize
            let cornerIndex = PiPGeometry.nearestCornerIndex(
                to: items[i].position,
                in: canvasSize,
                contentSize: contentSize,
                layout: layout
            )
            let takenPositions = assignedPositionsByCorner[cornerIndex, default: []]
            let resolved = cornerStackedPositionAvoidingDuplicates(
                cornerIndex: cornerIndex,
                contentSize: contentSize,
                takenPositions: takenPositions
            )
            items[i].position = resolved
            assignedPositionsByCorner[cornerIndex, default: []].append(resolved)
        }
    }

    // MARK: - Position Helpers

    private func nextAvailablePosition(for contentSize: CGSize) -> CGPoint {
        PiPGeometry.initialPosition(
            in: canvasSize,
            contentSize: contentSize,
            avoiding: items.map(\.position),
            layout: layout
        )
    }

    private func allocateZIndex() -> Int {
        nextZIndex += 1
        return nextZIndex
    }

    private func cornerStackedPosition(
        cornerIndex: Int,
        stackLevel: Int,
        contentSize: CGSize
    ) -> CGPoint {
        let base = PiPGeometry.corner(
            at: cornerIndex,
            in: canvasSize,
            contentSize: contentSize,
            layout: layout
        )
        guard stackLevel > 0 else { return base }
        let perLevelOffset = perLevelStackOffset(for: contentSize)
        let offset = CGFloat(stackLevel) * perLevelOffset
        let dx: CGFloat
        let dy: CGFloat
        switch cornerIndex {
        case 0: // top-right
            dx = -offset
            dy = offset
        case 1: // top-left
            dx = offset
            dy = offset
        case 2: // bottom-right
            dx = -offset
            dy = -offset
        default: // bottom-left
            dx = offset
            dy = -offset
        }
        let candidate = CGPoint(x: base.x + dx, y: base.y + dy)
        return PiPGeometry.clamped(candidate, in: canvasSize, contentSize: contentSize, layout: layout)
    }

    private func perLevelStackOffset(for contentSize: CGSize) -> CGFloat {
        if contentSize.width <= layout.minimizedSize.width + 0.5,
           contentSize.height <= layout.minimizedSize.height + 0.5 {
            return minimizedCornerStackOffset
        }
        return expandedCornerStackOffset
    }

    private func cornerStackedPositionAvoidingDuplicates(
        cornerIndex: Int,
        contentSize: CGSize,
        takenPositions: [CGPoint]
    ) -> CGPoint {
        let maxAttempts = max(takenPositions.count + 6, 10)
        for level in 0..<maxAttempts {
            let candidate = cornerStackedPosition(
                cornerIndex: cornerIndex,
                stackLevel: level,
                contentSize: contentSize
            )
            let isDuplicate = takenPositions.contains { taken in
                hypot(taken.x - candidate.x, taken.y - candidate.y) < 1
            }
            if !isDuplicate {
                return candidate
            }
        }
        return cornerStackedPosition(
            cornerIndex: cornerIndex,
            stackLevel: maxAttempts,
            contentSize: contentSize
        )
    }
}
