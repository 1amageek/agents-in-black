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
    let layout: PiPLayout
    let resolveSnapPosition: ((CGPoint, CGSize) -> CGPoint)?
    let onInteraction: (() -> Void)?

    @ViewBuilder var minimized: Minimized
    @ViewBuilder var expanded: Expanded

    @State private var dragOffset: CGSize = .zero
    @State private var hasNotifiedInteractionInDrag = false

    var currentContentSize: CGSize {
        isExpanded ? layout.expandedSize : layout.minimizedSize
    }

    /// Scale ratio between bubble and panel (e.g. 44/320 ≈ 0.14).
    private var bubbleToPanelScale: CGFloat {
        guard layout.expandedSize.width > 0 else { return 0.1 }
        return layout.minimizedSize.width / layout.expandedSize.width
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
        .onChange(of: isExpanded) { _, _ in
            dragOffset = .zero
            hasNotifiedInteractionInDrag = false
        }
        .simultaneousGesture(TapGesture().onEnded {
            onInteraction?()
        })
    }

    // MARK: - Drag Handler (Environment)

    private func makeDragHandler() -> PiPDragHandler {
        PiPDragHandler(
            onChanged: { translation in
                notifyInteractionIfNeeded()
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
                notifyInteractionIfNeeded()
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
        let corner = PiPGeometry.nearestCorner(
            to: projectedPosition,
            in: canvasSize,
            contentSize: currentContentSize,
            layout: layout
        )
        let resolvedCorner = resolveSnapPosition?(corner, currentContentSize) ?? corner
        position = currentPosition
        dragOffset = .zero
        hasNotifiedInteractionInDrag = false
        withAnimation(transitionAnimation) {
            position = resolvedCorner
        }
    }

    private func notifyInteractionIfNeeded() {
        guard !hasNotifiedInteractionInDrag else { return }
        hasNotifiedInteractionInDrag = true
        onInteraction?()
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
