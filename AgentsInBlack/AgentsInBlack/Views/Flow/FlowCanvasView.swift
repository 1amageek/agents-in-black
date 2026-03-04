import AIBCore
import SwiftFlow
import SwiftUI

struct FlowCanvasView: View {
    @Bindable var model: AgentsInBlackAppModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var store = FlowStore<String>()
    @State private var canvasSize: CGSize = .zero
    @State private var hasFittedInitialContent = false

    var body: some View {
        canvas
        .onAppear {
            synchronizeStoreFromModel(resetViewport: true)
        }
        .onChange(of: graphSnapshot) { _, _ in
            synchronizeStoreFromModel(resetViewport: false)
        }
        .onChange(of: colorScheme) { _, _ in
            synchronizeStoreFromModel(resetViewport: false)
        }
        .onChange(of: activitySnapshot) { _, _ in
            updateEdgeAnimations()
        }
    }

    private var graphSnapshot: FlowGraphSnapshot {
        FlowGraphSnapshot(
            nodes: model.flowNodes(),
            connections: model.flowConnections()
        )
    }

    private var activitySnapshot: FlowActivitySnapshot {
        FlowActivitySnapshot(
            activeServiceIDs: model.activeServiceIDs,
            serviceLifecycles: model.serviceSnapshotsByID.reduce(into: [:]) { result, pair in
                result[pair.key] = pair.value.lifecycleStateString
            }
        )
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack {
                FlowCanvas(store: store) { node in
                        FlowServiceNodeContent(node: node)
                    }
                    .nodeAccessory(placement: .bottom) { node in
                        nodeAccessoryContent(for: node, canvasSize: geometry.size)
                    }
                    .environment(\.flowNodeVisualsByID, nodeVisualsByID)
                    .focusEffectDisabled()
                    .onTapGesture(count: 2) {
                        fitToContent()
                    }
                    .onAppear {
                        updateCanvasSize(geometry.size)
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        updateCanvasSize(newSize)
                    }

                canvasHUD

                pipChatOverlay(canvasSize: geometry.size)
            }
        }
        .frame(minHeight: 400)
    }

    // MARK: - Node Accessory

    @ViewBuilder
    private func nodeAccessoryContent(for node: FlowNode<String>, canvasSize: CGSize) -> some View {
        if let service = model.service(by: node.id), model.canOpenChat(for: service) {
            NodeAccessoryInputBar(service: service) { text in
                let chatSession = model.createSession(for: service, activate: true)
                chatSession.composerText = text
                store.clearSelection()
                model.openPiPChat(serviceID: service.id, sessionID: chatSession.id)
                Task { await chatSession.send() }
            }
        }
    }

    // MARK: - HUD Overlay

    private var canvasHUD: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                canvasToolbar
                Spacer()
                MiniMap(store: store, canvasSize: canvasSize, minimapSize: CGSize(width: 180, height: 120))
            }
        }
        .padding(12)
    }

    private var canvasToolbar: some View {
        HStack(spacing: 0) {
            legendSection
            toolbarDivider
            zoomSection
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    private var legendSection: some View {
        HStack(spacing: 6) {
            FlowLegendDot(label: "Agent", color: AIBFlowPalette.agent)
            FlowLegendDot(label: "MCP", color: AIBFlowPalette.mcp)
            FlowLegendDot(label: "A2A", color: AIBFlowPalette.a2a)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 18)
    }

    private var zoomSection: some View {
        HStack(spacing: 2) {
            Button {
                zoom(by: 0.9, animation: .smooth)
            } label: {
                Image(systemName: "minus")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom Out")

            Button {
                fitToContent(animation: .smooth)
            } label: {
                Text("\(Int(exactly: (store.viewport.zoom * 100).rounded()) ?? 100)%")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fit to Content")

            Button {
                zoom(by: 1.1, animation: .smooth)
            } label: {
                Image(systemName: "plus")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom In")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    // MARK: - PiP Chat Overlay

    @ViewBuilder
    private func pipChatOverlay(canvasSize: CGSize) -> some View {
        let pipBindable = Bindable(model.pipManager)
        ForEach(pipBindable.items) { $pip in
            let sessionID = pip.id
            let serviceID = pip.serviceID
            if let service = model.service(by: serviceID),
               let chatSession = model.session(serviceID: serviceID, sessionID: sessionID) {
                PiPContainer(
                    isExpanded: $pip.isExpanded,
                    position: $pip.position,
                    canvasSize: canvasSize,
                    layout: model.pipManager.layout,
                    resolveSnapPosition: { proposed, contentSize in
                        model.pipManager.resolveSnapPosition(
                            for: sessionID,
                            proposed: proposed,
                            contentSize: contentSize
                        )
                    },
                    onInteraction: {
                        model.pipManager.bringToFront(sessionID: sessionID)
                    }
                ) {
                    AgentBubble(service: service)
                        .onTapGesture {
                            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                                model.pipManager.toggleExpanded(sessionID: sessionID)
                            }
                        }
                } expanded: {
                    PiPChatPanel(
                        session: chatSession,
                        service: service,
                        onMinimize: {
                            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                                model.pipManager.toggleExpanded(sessionID: sessionID)
                            }
                        },
                        onClose: {
                            withAnimation(.spring(duration: 0.25)) {
                                model.pipManager.close(sessionID: sessionID)
                            }
                        },
                        onSelectMessage: { message in
                            model.selectedChatMessage = message
                            if message != nil { model.showInspector = true }
                        }
                    )
                }
                .zIndex(Double(pip.zIndex))
            }
        }
    }

    // MARK: - Store Synchronization

    private func synchronizeStoreFromModel(resetViewport: Bool) {
        let nodeModels = model.flowNodes().sorted { $0.namespacedID.localizedStandardCompare($1.namespacedID) == .orderedAscending }
        let edgeModels = model.flowConnections().sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        let serviceKinds = Dictionary(uniqueKeysWithValues: nodeModels.map { ($0.id, $0.serviceKind) })
        let existingPairs = Set(edgeModels.map { "\($0.sourceServiceID)->\($0.targetServiceID)" })

        var configuration = FlowConfiguration(
            defaultEdgePathType: .bezier,
            backgroundStyle: BackgroundStyle(
                pattern: .dot,
                color: (colorScheme == .dark ? Color.white : Color.black).opacity(0.15),
                spacing: 24,
                dotRadius: 1.5
            )
        )
        configuration.minZoom = 0.35
        configuration.maxZoom = 3.0
        configuration.edgeStyle = EdgeStyle(
            strokeColor: .primary.opacity(0.5),
            selectedStrokeColor: AIBFlowPalette.mcp,
            lineWidth: 1.5,
            selectedLineWidth: 2.5,
            animatedDashPattern: [6, 4]
        )
        configuration.connectionValidator = AIBFlowConnectionValidator(nodeKindByID: serviceKinds, existingPairs: existingPairs)

        let viewport = resetViewport ? Viewport() : store.viewport

        let newStore = FlowStore<String>(
            nodes: makeFlowNodes(from: nodeModels),
            edges: makeFlowEdges(from: edgeModels),
            viewport: viewport,
            configuration: configuration
        )

        newStore.onConnect = { proposal in
            model.addFlowConnection(sourceServiceID: proposal.sourceNodeID, targetServiceID: proposal.targetNodeID)
        }

        newStore.onNodesChange = { changes in
            let selectionChanges = changes.compactMap { change -> (String, Bool)? in
                if case let .select(nodeID, isSelected) = change {
                    return (nodeID, isSelected)
                }
                return nil
            }

            // Determine the last selected node (if any)
            let selectedNodeID = selectionChanges.reversed().first(where: { $0.1 })?.0

            // Update flow node selection for inspector
            if let selectedNodeID {
                model.selectedFlowNodeID = selectedNodeID
                if !model.showInspector {
                    model.showInspector = true
                }
            } else if selectionChanges.contains(where: { !$0.1 }) {
                model.selectedFlowNodeID = nil
            }

            // Update source/target picker
            if let selectedNodeID, let service = model.service(by: selectedNodeID) {
                if service.serviceKind == .agent {
                    model.flowConnectionSourceServiceID = selectedNodeID
                } else {
                    model.flowConnectionTargetServiceID = selectedNodeID
                }
            }
        }

        if resetViewport {
            hasFittedInitialContent = false
        }

        if !hasFittedInitialContent,
           canvasSize.width > 0,
           canvasSize.height > 0,
           !newStore.nodes.isEmpty {
            newStore.fitToContent(canvasSize: canvasSize, padding: 96)
            hasFittedInitialContent = true
        }

        store = newStore
        normalizeFlowSelection()
    }

    private func makeFlowNodes(from nodes: [FlowNodeModel]) -> [FlowNode<String>] {
        nodes.map { node in
            FlowNode(
                id: node.id,
                position: node.position,
                size: CGSize(width: 130, height: 44),
                data: node.namespacedID,
                handles: handles(for: node.serviceKind)
            )
        }
    }

    private func makeFlowEdges(from edges: [FlowConnectionModel]) -> [FlowEdge] {
        edges.map { connection in
            FlowEdge(
                id: connection.id,
                sourceNodeID: connection.sourceServiceID,
                sourceHandleID: "source",
                targetNodeID: connection.targetServiceID,
                targetHandleID: "target",
                pathType: .bezier,
                label: connection.kind.rawValue
            )
        }
    }

    private func handles(for kind: AIBServiceKind) -> [HandleDeclaration] {
        switch kind {
        case .agent:
            return [
                HandleDeclaration(id: "target", type: .target, position: .left),
                HandleDeclaration(id: "source", type: .source, position: .right),
            ]
        case .mcp, .unknown:
            return [
                HandleDeclaration(id: "target", type: .target, position: .left),
            ]
        }
    }

    private func normalizeFlowSelection() {
        let sourceOptions = model.flowSourceServices()
        if model.flowConnectionSourceServiceID == nil {
            model.flowConnectionSourceServiceID = sourceOptions.first?.id
        }

        let targetOptions = model.flowTargetServices(for: model.flowConnectionSourceServiceID)
        if let currentTarget = model.flowConnectionTargetServiceID,
           targetOptions.contains(where: { $0.id == currentTarget }) {
            return
        }
        model.flowConnectionTargetServiceID = targetOptions.first?.id
    }

    private func updateCanvasSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let wasZero = canvasSize.width <= 0 || canvasSize.height <= 0
        canvasSize = size

        if wasZero {
            // Initial placement: no animation
            var t = Transaction(animation: nil)
            t.disablesAnimations = true
            withTransaction(t) {
                model.pipManager.updateCanvasSize(size)
            }
        } else {
            // Resize: animate the snap
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                model.pipManager.updateCanvasSize(size)
            }
        }

        if !hasFittedInitialContent, !store.nodes.isEmpty {
            fitToContent()
            hasFittedInitialContent = true
        }
    }

    private func fitToContent(animation: FlowAnimation? = nil) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }

        if store.nodes.isEmpty {
            store.viewport = Viewport()
            return
        }

        if let animation {
            store.fitToContent(canvasSize: canvasSize, padding: 96, animation: animation)
        } else {
            store.fitToContent(canvasSize: canvasSize, padding: 96)
        }
    }

    private func zoom(by factor: CGFloat, animation: FlowAnimation? = nil) {
        let anchor = CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.5)
        if let animation {
            store.zoom(by: factor, anchor: anchor, animation: animation)
        } else {
            store.zoom(by: factor, anchor: anchor)
        }
    }

    private var nodeVisualsByID: [String: FlowNodeVisual] {
        let outgoingCounts = Dictionary(grouping: model.flowConnections(), by: \.sourceServiceID).mapValues(\.count)
        let activity = activitySnapshot
        return Dictionary(
            uniqueKeysWithValues: model.flowNodes().map { node in
                let lifecycle = activity.serviceLifecycles[node.namespacedID]
                let isActive = activity.activeServiceIDs.contains(node.namespacedID)
                let activityState: FlowNodeVisual.ActivityState
                switch lifecycle {
                case "ready" where isActive:
                    activityState = .readyActive
                case "ready":
                    activityState = .readyIdle
                case "starting":
                    activityState = .starting
                case "unhealthy", "backoff":
                    activityState = .unhealthy
                default:
                    activityState = .stopped
                }
                return (
                    node.id,
                    FlowNodeVisual(
                        kind: node.serviceKind,
                        outgoingCount: outgoingCounts[node.id, default: 0],
                        activityState: activityState,
                        displayName: node.displayName
                    )
                )
            }
        )
    }

    // MARK: - Lightweight Edge Animation Update

    /// Compute the set of animated edge IDs from active services and push it
    /// to the store's side-table. No undo, no store rebuild, no edge mutation.
    private func updateEdgeAnimations() {
        let nodeModels = model.flowNodes()
        let namespacedIDByNodeID = Dictionary(uniqueKeysWithValues: nodeModels.map { ($0.id, $0.namespacedID) })
        let activeIDs = model.activeServiceIDs

        var animatedIDs = Set<String>()
        for edge in store.edges {
            let sourceNS = namespacedIDByNodeID[edge.sourceNodeID] ?? ""
            let targetNS = namespacedIDByNodeID[edge.targetNodeID] ?? ""
            if activeIDs.contains(sourceNS) && activeIDs.contains(targetNS) {
                animatedIDs.insert(edge.id)
            }
        }

        store.setAnimatedEdges(animatedIDs)
    }

}

// MARK: - Node Content

private struct FlowServiceNodeContent: View {
    @Environment(\.flowNodeVisualsByID) private var visualsByID
    @Environment(\.colorScheme) private var colorScheme

    let node: FlowNode<String>

    // FlowHandle.diameter is internal (10pt); half is the protrusion inset
    static let handleInset: CGFloat = 5

    var body: some View {
        let visual = visualsByID[node.id] ?? FlowNodeVisual(kind: .unknown, outgoingCount: 0, activityState: .stopped, displayName: nil)
        let tint = AIBFlowPalette.tint(for: visual.kind)
        let parts = displayParts(namespacedID: node.data, displayName: visual.displayName)
        let inset = Self.handleInset

        ZStack {
            nodeCard(tint: tint, kind: visual.kind, parts: parts, activityState: visual.activityState)
                .padding(inset)

            ForEach(node.handles, id: \.id) { handle in
                FlowHandle(handle.id, type: handle.type, position: handle.position)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: handleAlignment(handle.position))
            }
        }
        .frame(width: node.size.width + inset * 2, height: node.size.height + inset * 2)
    }

    private func nodeCard(tint: Color, kind: AIBServiceKind, parts: (primary: String, secondary: String?), activityState: FlowNodeVisual.ActivityState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: AIBFlowPalette.symbol(for: kind))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(parts.primary)
                    .font(.system(size: 11, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let secondary = parts.secondary {
                    Text(secondary)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .frame(width: node.size.width, height: node.size.height)
        .background(cardBackground(activityState: activityState), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(cardBorderColor(tint: tint, activityState: activityState), lineWidth: cardBorderWidth(activityState: activityState))
        }
        .overlay {
            if activityState == .readyActive || activityState == .starting || activityState == .unhealthy {
                NodeActivityOverlay(activityState: activityState, tint: tint)
            }
        }
        .shadow(color: cardShadowColor(tint: tint, activityState: activityState), radius: cardShadowRadius(activityState: activityState), y: cardShadowY)
        .opacity(activityState == .stopped ? 0.5 : 1.0)
    }

    // MARK: - Card Styling

    private func cardBackground(activityState: FlowNodeVisual.ActivityState) -> some ShapeStyle {
        colorScheme == .dark
            ? AnyShapeStyle(Color(white: 0.14))
            : AnyShapeStyle(Color.white)
    }

    private func cardBorderColor(tint: Color, activityState: FlowNodeVisual.ActivityState) -> Color {
        if node.isSelected {
            return tint
        }
        switch activityState {
        case .readyActive:
            return tint.opacity(0.8)
        case .unhealthy:
            return Color.red.opacity(0.7)
        case .starting:
            return tint.opacity(0.5)
        default:
            break
        }
        if node.isHovered {
            return colorScheme == .dark
                ? Color.white.opacity(0.2)
                : Color.black.opacity(0.12)
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.25)
            : Color.black.opacity(0.15)
    }

    private func cardBorderWidth(activityState: FlowNodeVisual.ActivityState) -> CGFloat {
        if node.isSelected { return 1.5 }
        if activityState == .readyActive { return 1.5 }
        return 1
    }

    private func cardShadowColor(tint: Color, activityState: FlowNodeVisual.ActivityState) -> Color {
        if node.isSelected {
            return tint.opacity(0.25)
        }
        switch activityState {
        case .readyActive:
            return tint.opacity(0.3)
        case .unhealthy:
            return Color.red.opacity(0.25)
        default:
            break
        }
        if node.isHovered {
            return .black.opacity(colorScheme == .dark ? 0.4 : 0.12)
        }
        return .black.opacity(colorScheme == .dark ? 0.3 : 0.06)
    }

    private func cardShadowRadius(activityState: FlowNodeVisual.ActivityState) -> CGFloat {
        if node.isSelected { return 12 }
        switch activityState {
        case .readyActive: return 10
        case .unhealthy: return 8
        default: break
        }
        return node.isHovered ? 8 : 4
    }

    private var cardShadowY: CGFloat {
        node.isSelected ? 0 : node.isHovered ? 3 : 2
    }

    // MARK: - Helpers

    /// Resolve the display name for a canvas node.
    /// When a package manifest name is available, show it as primary with namespace as secondary.
    /// Falls back to splitting the namespacedID.
    private func displayParts(namespacedID: String, displayName: String?) -> (primary: String, secondary: String?) {
        let nsParts = namespacedID.split(separator: "/", maxSplits: 1).map(String.init)
        let namespace = nsParts.count == 2 ? nsParts[0] : nil

        if let displayName {
            return (primary: displayName, secondary: namespace)
        }

        if nsParts.count == 2 {
            return (primary: nsParts[1], secondary: nsParts[0])
        }
        return (primary: namespacedID, secondary: nil)
    }

    private func handleAlignment(_ position: HandlePosition) -> Alignment {
        switch position {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}

// MARK: - Node Activity Overlay

private struct NodeActivityOverlay: View {
    let activityState: FlowNodeVisual.ActivityState
    let tint: Color

    @State private var isPulsing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(borderColor, lineWidth: 1.5)
            .opacity(isPulsing ? 1.0 : 0.3)
            .allowsHitTesting(false)
            .onAppear {
                isPulsing = shouldPulse
            }
            .onChange(of: activityState) { _, newState in
                withAnimation(pulseAnimation(for: newState)) {
                    isPulsing = shouldPulse(for: newState)
                }
            }
            .animation(shouldPulse ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: isPulsing)
    }

    private var borderColor: Color {
        switch activityState {
        case .unhealthy:
            return .red
        case .readyActive, .starting:
            return tint
        default:
            return .clear
        }
    }

    private var shouldPulse: Bool {
        shouldPulse(for: activityState)
    }

    private func shouldPulse(for state: FlowNodeVisual.ActivityState) -> Bool {
        switch state {
        case .readyActive, .starting, .unhealthy:
            return true
        default:
            return false
        }
    }

    private func pulseAnimation(for state: FlowNodeVisual.ActivityState) -> Animation? {
        shouldPulse(for: state)
            ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
            : .default
    }
}

// MARK: - Supporting Types

private struct FlowNodeVisual: Equatable {
    let kind: AIBServiceKind
    let outgoingCount: Int
    let activityState: ActivityState
    /// Package manifest name for display (e.g., package.json "name", executableTarget name).
    let displayName: String?

    enum ActivityState: Equatable {
        case stopped
        case starting
        case readyIdle
        case readyActive
        case unhealthy
    }
}

private struct AIBFlowConnectionValidator: ConnectionValidating {
    let nodeKindByID: [String: AIBServiceKind]
    let existingPairs: Set<String>

    func validate(_ proposal: ConnectionProposal) -> Bool {
        guard proposal.sourceNodeID != proposal.targetNodeID else { return false }
        guard nodeKindByID[proposal.sourceNodeID] == .agent else { return false }

        guard let targetKind = nodeKindByID[proposal.targetNodeID],
              targetKind == .agent || targetKind == .mcp else {
            return false
        }

        return !existingPairs.contains("\(proposal.sourceNodeID)->\(proposal.targetNodeID)")
    }
}

private struct FlowGraphSnapshot: Hashable {
    let nodes: [FlowNodeModel]
    let connections: [FlowConnectionModel]
}

private struct FlowActivitySnapshot: Hashable {
    let activeServiceIDs: Set<String>
    let serviceLifecycles: [String: String]
}

// MARK: - Environment

private struct FlowNodeVisualsByIDEnvironmentKey: EnvironmentKey {
    static let defaultValue: [String: FlowNodeVisual] = [:]
}

private extension EnvironmentValues {
    var flowNodeVisualsByID: [String: FlowNodeVisual] {
        get { self[FlowNodeVisualsByIDEnvironmentKey.self] }
        set { self[FlowNodeVisualsByIDEnvironmentKey.self] = newValue }
    }
}

// MARK: - Legend Dot

private struct FlowLegendDot: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
