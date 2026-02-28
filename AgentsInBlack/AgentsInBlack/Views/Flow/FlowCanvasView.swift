import AIBCore
import SwiftFlow
import SwiftUI

struct FlowCanvasView: View {
    @Bindable var model: AgentsInBlackAppModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var store = FlowStore<String>()
    @State private var canvasSize: CGSize = .zero
    @State private var hasFittedInitialContent = false
    @State private var showConnectionsList = false

    var body: some View {
        CollapsibleSplitView(isExpanded: $showConnectionsList) {
            canvas
        } content: {
            connectionsContent
        } header: {
            connectionsHeader
        }
        .onAppear {
            synchronizeStoreFromModel(resetViewport: true)
        }
        .onChange(of: graphSnapshot) { _, _ in
            synchronizeStoreFromModel(resetViewport: false)
        }
        .onChange(of: colorScheme) { _, _ in
            synchronizeStoreFromModel(resetViewport: false)
        }
    }

    private var graphSnapshot: FlowGraphSnapshot {
        FlowGraphSnapshot(nodes: model.flowNodes(), connections: model.flowConnections())
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack {
                FlowCanvas(store: store) { node in
                        FlowServiceNodeContent(node: node)
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
                Text("\(Int((store.viewport.zoom * 100).rounded()))%")
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
        ForEach($model.openPiPChats) { $pip in
            if let service = model.service(by: pip.id) {
                PiPContainer(
                    isExpanded: $pip.isExpanded,
                    position: $pip.position,
                    canvasSize: canvasSize,
                    minimizedSize: PiPGeometry.defaultBubbleSize,
                    expandedSize: PiPChatPanel.panelSize
                ) {
                    AgentBubble(service: service)
                        .onTapGesture {
                            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                                pip.position = PiPGeometry.correspondingCorner(
                                    from: pip.position, in: canvasSize,
                                    fromSize: PiPGeometry.defaultBubbleSize,
                                    toSize: PiPChatPanel.panelSize
                                )
                                pip.isExpanded = true
                            }
                        }
                } expanded: {
                    PiPChatPanel(
                        store: model.chatStore(for: service),
                        service: service,
                        onMinimize: {
                            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                                pip.position = PiPGeometry.correspondingCorner(
                                    from: pip.position, in: canvasSize,
                                    fromSize: PiPChatPanel.panelSize,
                                    toSize: PiPGeometry.defaultBubbleSize
                                )
                                pip.isExpanded = false
                            }
                        },
                        onClose: {
                            withAnimation(.spring(duration: 0.25)) {
                                model.closePiPChat(serviceID: pip.id)
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Connections List

    @ViewBuilder
    private var connectionsHeader: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("Connections")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        Text("\(model.flowConnections().count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)

        if model.hasUnsavedFlowChanges {
            Spacer(minLength: 8)
            Button("Save") {
                Task { await model.saveFlowConnections() }
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
        }
    }

    private var connectionsContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.flowConnections()) { connection in
                    connectionRow(connection)
                    if connection.id != model.flowConnections().last?.id {
                        Divider().padding(.leading, 40)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func connectionRow(_ connection: FlowConnectionModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: connection.kind == .mcp ? "wrench.and.screwdriver" : "arrow.left.arrow.right")
                .font(.caption)
                .foregroundStyle(connectionColor(for: connection.kind))
                .frame(width: 20, alignment: .center)

            Text(connection.kind.rawValue)
                .font(.caption2.weight(.bold))
                .foregroundStyle(connectionColor(for: connection.kind))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(connectionColor(for: connection.kind).opacity(0.12), in: Capsule())

            Text(connectionSummary(connection))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Button {
                model.removeFlowConnection(connection)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove connection")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func connectionSummary(_ connection: FlowConnectionModel) -> String {
        let source = model.service(by: connection.sourceServiceID)?.namespacedID ?? connection.sourceServiceID
        let target = model.service(by: connection.targetServiceID)?.namespacedID ?? connection.targetServiceID
        return "\(source)  \u{2192}  \(target)"
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
            selectedLineWidth: 2.5
        )
        configuration.connectionValidator = AIBFlowConnectionValidator(nodeKindByID: serviceKinds, existingPairs: existingPairs)

        let viewport = resetViewport ? Viewport() : store.viewport

        var newStore = FlowStore<String>(
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
        canvasSize = size
        model.flowCanvasSize = size

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
        return Dictionary(
            uniqueKeysWithValues: model.flowNodes().map { node in
                (
                    node.id,
                    FlowNodeVisual(
                        kind: node.serviceKind,
                        outgoingCount: outgoingCounts[node.id, default: 0]
                    )
                )
            }
        )
    }

    private func connectionColor(for kind: FlowConnectionKind) -> Color {
        switch kind {
        case .mcp: AIBFlowPalette.mcp
        case .a2a: AIBFlowPalette.a2a
        }
    }
}

// MARK: - Color Palette

private enum AIBFlowPalette {
    static let agent = Color.mint
    static let mcp = Color.cyan
    static let a2a = Color.orange
    static let unknown = Color.secondary

    static func tint(for kind: AIBServiceKind) -> Color {
        switch kind {
        case .agent: agent
        case .mcp: mcp
        case .unknown: unknown
        }
    }

    static func symbol(for kind: AIBServiceKind) -> String {
        switch kind {
        case .agent: "sparkles"
        case .mcp: "wrench.and.screwdriver.fill"
        case .unknown: "square.stack.3d.up.fill"
        }
    }

    static func label(for kind: AIBServiceKind) -> String {
        switch kind {
        case .agent: "Agent"
        case .mcp: "MCP"
        case .unknown: "Other"
        }
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
        let visual = visualsByID[node.id] ?? FlowNodeVisual(kind: .unknown, outgoingCount: 0)
        let tint = AIBFlowPalette.tint(for: visual.kind)
        let parts = splitNamespacedID(node.data)
        let inset = Self.handleInset

        ZStack {
            nodeCard(tint: tint, kind: visual.kind, parts: parts, outgoingCount: visual.outgoingCount)
                .padding(inset)

            ForEach(node.handles, id: \.id) { handle in
                FlowHandle(handle.id, type: handle.type, position: handle.position)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: handleAlignment(handle.position))
            }
        }
        .frame(width: node.size.width + inset * 2, height: node.size.height + inset * 2)
    }

    private func nodeCard(tint: Color, kind: AIBServiceKind, parts: (primary: String, secondary: String?), outgoingCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: AIBFlowPalette.symbol(for: kind))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20)

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
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(width: node.size.width, height: node.size.height)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(cardBorderColor(tint: tint), lineWidth: cardBorderWidth)
        }
        .shadow(color: cardShadowColor(tint: tint), radius: cardShadowRadius, y: cardShadowY)
    }

    // MARK: - Card Styling

    private var cardBackground: some ShapeStyle {
        colorScheme == .dark
            ? AnyShapeStyle(Color(white: 0.14))
            : AnyShapeStyle(Color.white)
    }

    private func cardBorderColor(tint: Color) -> Color {
        if node.isSelected {
            return tint
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

    private var cardBorderWidth: CGFloat {
        node.isSelected ? 1.5 : 1
    }

    private func cardShadowColor(tint: Color) -> Color {
        if node.isSelected {
            return tint.opacity(0.25)
        }
        if node.isHovered {
            return .black.opacity(colorScheme == .dark ? 0.4 : 0.12)
        }
        return .black.opacity(colorScheme == .dark ? 0.3 : 0.06)
    }

    private var cardShadowRadius: CGFloat {
        node.isSelected ? 12 : node.isHovered ? 8 : 4
    }

    private var cardShadowY: CGFloat {
        node.isSelected ? 0 : node.isHovered ? 3 : 2
    }

    // MARK: - Helpers

    private func splitNamespacedID(_ value: String) -> (primary: String, secondary: String?) {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            return (primary: parts[1], secondary: parts[0])
        }
        return (primary: value, secondary: nil)
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

// MARK: - Supporting Types

private struct FlowNodeVisual {
    let kind: AIBServiceKind
    let outgoingCount: Int
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
