import AIBCore
import SwiftFlow
import SwiftSkill
import SwiftUI
import UniformTypeIdentifiers

struct FlowCanvasView: View {
    @Bindable var model: AgentsInBlackAppModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var store = FlowStore<String>()
    @State private var canvasSize: CGSize = .zero
    @State private var hasFittedInitialContent = false
    @State private var useCloudEndpoint: Bool = false
    @State private var droppedTextByNodeID: [String: String] = [:]

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
            mcpConnectionStatusByConnectionID: model.mcpConnectionStatusByConnectionID,
            serviceLifecycles: model.serviceSnapshotsByID.reduce(into: [:]) { result, pair in
                result[pair.key] = pair.value.lifecycleStateString
            }
        )
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack {
                FlowCanvas(store: store) { node, _ in
                        FlowServiceNodeContent(node: node)
                    }
                    .nodeAccessory(placement: .bottom) { node in
                        nodeAccessoryContent(for: node, canvasSize: geometry.size)
                    }
                    .dropDestination(for: [.agentSkill, .fileURL]) { phase in
                        handleCanvasDrop(phase)
                    }
                    .environment(\.flowNodeVisualsByID, nodeVisualsByID)
                    .focusEffectDisabled()
                    .onDeleteCommand {
                        guard let selectedID = model.selectedFlowNodeID,
                              let service = model.service(by: selectedID) else { return }
                        model.requestRemoveService(
                            namespacedServiceID: service.namespacedID,
                            displayName: service.packageName ?? service.localID
                        )
                    }
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

                contextSchemaHUD

                pipChatOverlay(canvasSize: geometry.size)
            }
        }
        .frame(minHeight: 400)
    }

    // MARK: - Canvas Drop Handling

    private func handleCanvasDrop(_ phase: DropPhase) -> Bool {
        switch phase {
        case .updated(let providers, _, let target):
            guard case .node(let nodeID) = target,
                  let service = model.service(by: nodeID),
                  service.serviceKind == .agent else { return false }
            let hasSkill = providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.agentSkill.identifier) }
            let hasFile = providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            return hasSkill || hasFile

        case .performed(let providers, _, let target):
            guard case .node(let nodeID) = target,
                  let service = model.service(by: nodeID),
                  service.serviceKind == .agent else { return false }

            // Skill drop
            let skillTypeID = UTType.agentSkill.identifier
            for provider in providers where provider.hasItemConformingToTypeIdentifier(skillTypeID) {
                provider.loadDataRepresentation(forTypeIdentifier: skillTypeID) { data, error in
                    guard let data else { return }
                    guard let skill = try? JSONDecoder().decode(Skill.self, from: data) else { return }
                    Task { @MainActor in
                        await model.assignSkill(
                            skillID: skill.name,
                            namespacedServiceID: service.namespacedID
                        )
                    }
                }
            }

            // File drop — insert content into the node's InputBar
            let fileTypeID = UTType.fileURL.identifier
            for provider in providers where provider.hasItemConformingToTypeIdentifier(fileTypeID) {
                provider.loadItem(forTypeIdentifier: fileTypeID) { item, error in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    guard url.pathExtension.lowercased() == "txt" else { return }
                    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
                    let fileName = url.lastPathComponent
                    let insertText = "File: \(fileName)\n\n\(content)"
                    Task { @MainActor in
                        store.selectNode(nodeID, exclusive: true)
                        droppedTextByNodeID[nodeID] = insertText
                    }
                }
            }
            return true

        case .exited:
            return false
        }
    }

    // MARK: - Message Sending

    private func sendMessage(_ text: String, to service: AIBServiceModel) {
        let hasCloud = model.deployedURL(for: service) != nil
        let isCloud = useCloudEndpoint && hasCloud
        let isEmulatorRunning = model.emulatorState.isRunning

        if !isEmulatorRunning && !hasCloud {
            let chatSession = model.createSession(for: service, activate: true)
            chatSession.composerText = ""
            store.clearSelection()
            model.openPiPChat(serviceID: service.id, sessionID: chatSession.id)
            chatSession.appendGuide(
                userText: text,
                message: "No endpoint available. Start the emulator or deploy to Cloud Run first."
            )
            return
        }

        let chatSession: ChatSession
        if isCloud, let deployedURL = model.deployedURL(for: service) {
            chatSession = model.createRemoteSession(for: service, deployedURL: deployedURL, activate: true)
        } else {
            chatSession = model.createSession(for: service, activate: true)
        }
        chatSession.composerText = text
        store.clearSelection()
        model.openPiPChat(serviceID: service.id, sessionID: chatSession.id)
        Task { await chatSession.send() }
    }

    // MARK: - Node Accessory

    @ViewBuilder
    private func nodeAccessoryContent(for node: FlowNode<String>, canvasSize: CGSize) -> some View {
        if let service = model.service(by: node.id), model.canOpenChat(for: service) {
            let hasCloud = model.deployedURL(for: service) != nil
            let isCloud = useCloudEndpoint && hasCloud
            NodeAccessoryInputBar(
                service: service,
                isCloudMode: isCloud,
                droppedText: Binding(
                    get: { droppedTextByNodeID[node.id] },
                    set: { droppedTextByNodeID[node.id] = $0 }
                )
            ) { text in
                sendMessage(text, to: service)
            }
        }
    }

    // MARK: - Context Schema Overlay

    private var contextSchemaHUD: some View {
        VStack {
            HStack {
                Spacer()
                ContextSchemaOverlay(contextSchema: $model.sharedContextSchema)
            }
            Spacer()
        }
        .padding(12)
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
            if hasAnyDeployedEndpoint {
                toolbarDivider
                endpointToggleSection
            }
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

    private var hasAnyDeployedEndpoint: Bool {
        guard let workspace = model.workspace else { return false }
        return workspace.services.contains { !$0.endpoints.isEmpty }
    }

    private var endpointToggleSection: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                useCloudEndpoint.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: useCloudEndpoint ? "cloud.fill" : "desktopcomputer")
                    .font(.caption2.weight(.semibold))
                Text(useCloudEndpoint ? "Cloud" : "Local")
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(useCloudEndpoint ? .cyan : .secondary)
            .frame(minHeight: 28)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(useCloudEndpoint ? "Using cloud endpoints" : "Using local emulator")
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
                color: AIBFlowPalette.canvasGridColor(for: colorScheme),
                spacing: 24,
                dotRadius: 1.5
            )
        )
        configuration.minZoom = 0.35
        configuration.maxZoom = 3.0
        configuration.edgeStyle = EdgeStyle(
            strokeColor: AIBFlowPalette.edgeStrokeColor(for: colorScheme),
            selectedStrokeColor: AIBFlowPalette.edgeSelectedStrokeColor(for: colorScheme),
            lineWidth: 2.0,
            selectedLineWidth: 3.0,
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

        newStore.onEdgesChange = { changes in
            let connectionsByID = Dictionary(uniqueKeysWithValues: edgeModels.map { ($0.id, $0) })
            for change in changes {
                if case .remove(let edgeID) = change,
                   let connection = connectionsByID[edgeID] {
                    model.removeFlowConnection(connection)
                }
            }
        }

        newStore.onNodesChange = { changes in
            // Handle node removals — show confirmation, then re-sync to restore until approved
            for change in changes {
                if case .remove(let nodeID) = change,
                   let service = model.service(by: nodeID) {
                    model.requestRemoveService(
                        namespacedServiceID: service.namespacedID,
                        displayName: service.packageName ?? service.localID
                    )
                    synchronizeStoreFromModel(resetViewport: false)
                    return
                }
            }

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
            return FlowNode(
                id: node.id,
                position: node.position,
                size: CGSize(width: 170, height: 58),
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
        let connectionModels = model.flowConnections()
        let namespacedIDByNodeID = Dictionary(uniqueKeysWithValues: model.flowNodes().map { ($0.id, $0.namespacedID) })
        var connectedMCPNodeIDs = Set<String>()
        var connectingMCPNodeIDs = Set<String>()
        var failedMCPNodeIDs = Set<String>()
        var activeSourceMCPNodeIDs = Set<String>()

        for connection in connectionModels where connection.kind == .mcp {
            guard let status = activity.mcpConnectionStatusByConnectionID[connection.id] else { continue }
            switch status {
            case .connected:
                connectedMCPNodeIDs.insert(connection.targetServiceID)
            case .connecting:
                connectingMCPNodeIDs.insert(connection.targetServiceID)
            case .failed:
                failedMCPNodeIDs.insert(connection.targetServiceID)
            }
        }
        for connection in connectionModels where connection.kind == .mcp {
            let sourceNamespacedID = namespacedIDByNodeID[connection.sourceServiceID] ?? ""
            if activity.activeServiceIDs.contains(sourceNamespacedID) {
                activeSourceMCPNodeIDs.insert(connection.targetServiceID)
            }
        }

        return Dictionary(
            uniqueKeysWithValues: model.flowNodes().map { node in
                let lifecycle = activity.serviceLifecycles[node.namespacedID]
                let isActive = activity.activeServiceIDs.contains(node.namespacedID)
                let activityState: FlowNodeVisual.ActivityState
                if node.serviceKind == .mcp {
                    if failedMCPNodeIDs.contains(node.id) {
                        activityState = .unhealthy
                    } else if connectedMCPNodeIDs.contains(node.id) || isActive {
                        activityState = .readyActive
                    } else if connectingMCPNodeIDs.contains(node.id) || activeSourceMCPNodeIDs.contains(node.id) {
                        activityState = .starting
                    } else {
                        switch lifecycle {
                        case "ready":
                            activityState = .readyIdle
                        case "starting":
                            activityState = .starting
                        case "unhealthy", "backoff":
                            activityState = .unhealthy
                        default:
                            activityState = .stopped
                        }
                    }
                } else {
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
                }
                let runnerLabel: String? = node.serviceKind == .agent
                    && model.emulatorState.isRunning
                    && ClaudeCodeConfiguration().isInstalled
                    ? "Claude Code" : nil
                return (
                    node.id,
                    FlowNodeVisual(
                        kind: node.serviceKind,
                        outgoingCount: outgoingCounts[node.id, default: 0],
                        activityState: activityState,
                        displayName: node.displayName,
                        model: node.model,
                        localRunner: runnerLabel
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
        let connectionByID = Dictionary(uniqueKeysWithValues: model.flowConnections().map { ($0.id, $0) })
        let activeIDs = model.activeServiceIDs
        let lifecycleByServiceID = model.serviceSnapshotsByID.reduce(into: [String: String]()) { result, pair in
            result[pair.key] = pair.value.lifecycleStateString
        }
        let mcpStatuses = model.mcpConnectionStatusByConnectionID

        var animatedIDs = Set<String>()
        for edge in store.edges {
            if let connection = connectionByID[edge.id], connection.kind == .mcp {
                if let status = mcpStatuses[connection.id], status == .connecting || status == .connected {
                    animatedIDs.insert(edge.id)
                } else {
                    let sourceNS = namespacedIDByNodeID[edge.sourceNodeID] ?? ""
                    let targetNS = namespacedIDByNodeID[edge.targetNodeID] ?? ""
                    let targetLifecycle = lifecycleByServiceID[targetNS]
                    if activeIDs.contains(sourceNS), targetLifecycle == "ready" || targetLifecycle == "starting" {
                        animatedIDs.insert(edge.id)
                    }
                }
                continue
            }

            let sourceNS = namespacedIDByNodeID[edge.sourceNodeID] ?? ""
            let targetNS = namespacedIDByNodeID[edge.targetNodeID] ?? ""
            let targetLifecycle = lifecycleByServiceID[targetNS]
            if activeIDs.contains(sourceNS), targetLifecycle == "ready" || targetLifecycle == "starting" {
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
        let visual = visualsByID[node.id] ?? FlowNodeVisual(
            kind: .unknown,
            outgoingCount: 0,
            activityState: .stopped,
            displayName: nil,
            model: nil,
            localRunner: nil
        )
        let tint = AIBFlowPalette.tint(for: visual.kind)
        let parts = displayParts(namespacedID: node.data, displayName: visual.displayName)
        let inset = Self.handleInset

        ZStack {
            nodeCard(
                tint: tint,
                kind: visual.kind,
                parts: parts,
                activityState: visual.activityState,
                model: visual.model,
                localRunner: visual.localRunner
            )
                .padding(inset)

            ForEach(node.handles, id: \.id) { handle in
                FlowHandle(handle.id, type: handle.type, position: handle.position)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: handleAlignment(handle.position))
            }
        }
        .frame(width: node.size.width + inset * 2, height: node.size.height + inset * 2)
    }

    private func nodeCard(
        tint: Color,
        kind: AIBServiceKind,
        parts: (primary: String, secondary: String?),
        activityState: FlowNodeVisual.ActivityState,
        model: String? = nil,
        localRunner: String? = nil
    ) -> some View {
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

                if let model {
                    HStack(spacing: 3) {
                        Text(model)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let localRunner {
                            Text(localRunner)
                                .font(.system(size: 7, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.green.opacity(0.8), in: Capsule())
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .frame(width: node.size.width, height: node.size.height)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(AIBFlowPalette.nodeBaseFill(for: colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.opacity(cardTintOverlayOpacity(activityState: activityState)))
                }
        }
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

    private func cardTintOverlayOpacity(activityState: FlowNodeVisual.ActivityState) -> Double {
        switch activityState {
        case .readyActive:
            return colorScheme == .dark ? 0.20 : 0.10
        case .starting:
            return colorScheme == .dark ? 0.16 : 0.08
        case .readyIdle:
            return colorScheme == .dark ? 0.12 : 0.06
        case .unhealthy:
            return colorScheme == .dark ? 0.14 : 0.07
        case .stopped:
            return colorScheme == .dark ? 0.08 : 0.04
        }
    }

    private func cardBorderColor(tint: Color, activityState: FlowNodeVisual.ActivityState) -> Color {
        if node.isDropTarget {
            return .purple
        }
        if node.isSelected {
            return tint
        }
        switch activityState {
        case .readyActive:
            return tint.opacity(0.8)
        case .unhealthy:
            return Color.red.opacity(0.7)
        case .starting:
            return tint.opacity(0.7)
        default:
            break
        }
        return AIBFlowPalette.nodeNeutralBorder(for: colorScheme, isHovered: node.isHovered)
    }

    private func cardBorderWidth(activityState: FlowNodeVisual.ActivityState) -> CGFloat {
        if node.isDropTarget { return 2 }
        if node.isSelected { return 2 }
        if activityState == .readyActive { return 1.8 }
        if activityState == .starting { return 1.5 }
        return 1.2
    }

    private func cardShadowColor(tint: Color, activityState: FlowNodeVisual.ActivityState) -> Color {
        if node.isDropTarget {
            return .purple.opacity(0.4)
        }
        if node.isSelected {
            return tint.opacity(0.35)
        }
        switch activityState {
        case .readyActive:
            return tint.opacity(0.4)
        case .unhealthy:
            return Color.red.opacity(0.32)
        default:
            break
        }
        if node.isHovered {
            return .black.opacity(colorScheme == .dark ? 0.4 : 0.12)
        }
        return .black.opacity(colorScheme == .dark ? 0.3 : 0.06)
    }

    private func cardShadowRadius(activityState: FlowNodeVisual.ActivityState) -> CGFloat {
        if node.isDropTarget { return 12 }
        if node.isSelected { return 12 }
        switch activityState {
        case .readyActive: return 10
        case .unhealthy: return 8
        default: break
        }
        return node.isHovered ? 8 : 4
    }

    private var cardShadowY: CGFloat {
        if node.isDropTarget { return 0 }
        return node.isSelected ? 0 : node.isHovered ? 3 : 2
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
    /// LLM model identifier for agent services.
    let model: String?
    /// Local runner type used for this agent (e.g., "Claude Code").
    /// nil for non-agent services or when using A2A container runner.
    let localRunner: String?

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
    let mcpConnectionStatusByConnectionID: [String: MCPConnectionRuntimeStatus]
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
