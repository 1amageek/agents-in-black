import AppKit
import AIBCore
import AIBRuntimeCore
import Darwin
import Foundation
import Logging
import Observation
import SwiftUI

@MainActor
@Observable
final class AgentsInBlackAppModel {
    var workspace: AIBWorkspaceSnapshot?
    var splitViewVisibility: NavigationSplitViewVisibility = .all
    var selectedSidebarSection: SidebarSection = .workspace
    var selection: SelectionTarget?
    var selectedRepoIDForFiles: String?
    var detailSurfaceMode: DetailSurfaceMode = .workbench
    var hasUnsavedFlowChanges: Bool = false
    var flowConnectionSourceServiceID: String?
    var flowConnectionTargetServiceID: String?
    var selectedFlowNodeID: String?

    // MARK: - Chat Sessions
    let pipManager = PiPManager(layout: PiPLayout(
        expandedSize: PiPChatPanel.panelSize,
        minimizedSize: PiPGeometry.defaultBubbleSize,
        headerHeight: 40,
        edgeInset: 16,
        bottomInset: 76
    ))
    var chatSessionsByService: [String: [ChatSession]] = [:]
    var activeSessionIDByService: [String: UUID] = [:]

    let terminalManager = TerminalManager()

    var emulatorState: EmulatorState = .stopped
    var emulatorOutput: String = ""
    var serviceLogOutputByServiceID: [String: String] = [:]
    var serviceSnapshotsByID: [String: AIBServiceRuntimeSnapshot] = [:]
    var showInspector: Bool = false
    var selectedChatMessage: ChatMessageItem?
    var lastErrorMessage: String?
    let runtimeAnnouncementCenter = RuntimeAnnouncementCenter()
    var gatewayPort: Int = 8080
    var showUtilityPanel: Bool = true
    var utilityPanelMode: UtilityPanelMode = .aibRuntime
    var utilityPanelFilterText: String = ""
    var utilityServiceLogTarget: UtilityServiceLogTarget = .selection
    var sidebarRepoStatusByRepoID: [String: SidebarRepoStatus] = [:]
    var workbenchModeByServiceID: [String: AIBWorkbenchMode] = [:]
    var rawDraftByServiceID: [String: RawRequestDraft] = [:]
    var serviceLogsExpandedByServiceID: [String: Bool] = [:]
    var runtimeIssues: [RuntimeIssue] = []
    var showIssuesInSidebar: Bool = false
    var issueListFilter: RuntimeIssueSeverity?
    private var emulatorEventsTask: Task<Void, Never>?
    private var lastEmulatorLifecycleState: AIBEmulatorLifecycleState?
    private var hasShutdown = false

    // MARK: - Deploy
    let deployController = AIBDeployController()
    var deployPhase: AIBDeployPhase = .idle
    var showDeploySheet: Bool = false
    var showCloudSettings: Bool = false
    private var deployEventsTask: Task<Void, Never>?
    private let configStore: DeployTargetConfigStore = DefaultDeployTargetConfigStore()

    // MARK: - Deploy Environment Status
    var dockerCheckResult: PreflightCheckResult?
    var cloudProviderCheckResult: PreflightCheckResult?
    var detectedProvider: (any DeploymentProvider)?
    var isCheckingEnvironment: Bool = false
    private var environmentCheckTask: Task<Void, Never>?

    // MARK: - Docker Runtime
    var installedDockerRuntimes: [DockerRuntime] = []
    var preferredDockerRuntime: DockerRuntime?

    let workspaceDiscovery = WorkspaceDiscoveryService()
    let emulatorController = AIBEmulatorController()
    let editorService = ExternalEditorService()

    init() {
        emulatorEventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in emulatorController.events() {
                handleEmulatorEvent(event)
            }
        }
    }

    func shutdown() {
        guard !hasShutdown else { return }
        hasShutdown = true

        emulatorEventsTask?.cancel()
        emulatorEventsTask = nil
        deployEventsTask?.cancel()
        deployEventsTask = nil
        environmentCheckTask?.cancel()
        environmentCheckTask = nil
        runtimeAnnouncementCenter.clear()

        let shouldAttemptStop = emulatorState.isRunning || emulatorState.isBusy
        emulatorController.shutdown()
        deployController.shutdown()

        if shouldAttemptStop {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await emulatorController.stop()
                } catch EmulatorControllerError.notRunning {
                    return
                } catch {
                    // Do not surface app-termination errors to the UI.
                    return
                }
            }
        }
    }

    func openWorkspacePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open Workspace"
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        Task { await loadWorkspace(at: url) }
    }

    func createWorkspacePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Create Workspace"
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        Task { await createWorkspace(at: url) }
    }

    func createWorkspace(at url: URL) async {
        do {
            _ = try AIBWorkspaceCore.initWorkspace(
                workspaceRoot: url.standardizedFileURL.path,
                scanPath: url.standardizedFileURL.path,
                force: false,
                scanEnabled: true
            )
            await loadWorkspace(at: url)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Failed to create workspace: \(error.localizedDescription)"
        }
    }

    func openIncomingDirectory(_ url: URL) {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            lastErrorMessage = "Only directories can be opened as a workspace."
            return
        }
        Task { await loadWorkspace(at: standardized) }
    }

    func openIncomingURLs(_ urls: [URL]) {
        guard let directory = urls.first(where: { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }) else { return }
        openIncomingDirectory(directory)
    }

    func loadWorkspace(at url: URL) async {
        do {
            let snapshot = try workspaceDiscovery.loadWorkspace(at: url)
            workspace = snapshot
            runtimeIssues = []
            showIssuesInSidebar = false
            issueListFilter = nil
            if let firstRepo = snapshot.repos.first {
                selectedRepoIDForFiles = firstRepo.id
                selection = .repo(firstRepo.id)
                ensureTerminalTab(for: firstRepo)
            } else {
                selectedRepoIDForFiles = nil
                selection = nil
            }
            if let firstAgent = snapshot.services.first(where: { $0.serviceKind == .agent }) {
                flowConnectionSourceServiceID = firstAgent.id
            } else {
                flowConnectionSourceServiceID = nil
            }
            flowConnectionTargetServiceID = nil
            hasUnsavedFlowChanges = false
            pipManager.closeAll()
            chatSessionsByService.removeAll()
            activeSessionIDByService.removeAll()
            rebuildSidebarRepoStatuses()
            lastErrorMessage = nil
            refreshEnvironmentStatus()
        } catch {
            lastErrorMessage = "Failed to load workspace: \(error.localizedDescription)"
        }
    }

    func refreshWorkspace() async {
        guard let workspace else { return }
        await loadWorkspace(at: workspace.rootURL)
    }

    func addRepositoryPicker() {
        guard let workspace else {
            lastErrorMessage = "Open a workspace first."
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = workspace.rootURL
        panel.prompt = "Add Repository"
        panel.message = "Select a repository directory inside this workspace. The workspace will be rescanned."
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        let selected = url.standardizedFileURL
        let workspaceRoot = workspace.rootURL.standardizedFileURL
        guard selected.path == workspaceRoot.path || selected.path.hasPrefix(workspaceRoot.path + "/") else {
            lastErrorMessage = "Repository must be inside the current workspace directory."
            return
        }

        Task { await addRepository(at: selected) }
    }

    func addRepository(at url: URL) async {
        guard let workspace else {
            lastErrorMessage = "Open a workspace first."
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            lastErrorMessage = "Selected path is not a directory."
            return
        }

        do {
            _ = try AIBWorkspaceCore.rescanWorkspace(workspaceRoot: workspace.rootURL.path)
            await loadWorkspace(at: workspace.rootURL)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Failed to add repository: \(error.localizedDescription)"
        }
    }

    func ensureTerminalTab(for repo: AIBRepoModel) {
        terminalManager.ensureTab(contextKey: repo.id, label: repo.name, workingDirectory: repo.rootURL)
    }

    func select(_ target: SelectionTarget) {
        selection = target
        applySelectionSideEffects(target)
    }

    /// Apply side effects for a selection change without setting `selection`.
    /// Called from both `select(_:)` and `onChange(of: selection)` to ensure
    /// `detailSurfaceMode` stays in sync even when `List(selection:)` binding
    /// updates `selection` directly (bypassing `select(_:)`).
    func applySelectionSideEffects(_ target: SelectionTarget) {
        switch target {
        case .topology:
            selectedSidebarSection = .workspace
            detailSurfaceMode = .topology
        case .repo(let repoID):
            selectedSidebarSection = .workspace
            selectedRepoIDForFiles = repoID
            if let repo = repo(by: repoID) {
                ensureTerminalTab(for: repo)
                if let singleService = singleServiceForRepo(repoID: repoID) {
                    initializeWorkbenchStateIfNeeded(for: singleService)
                    detailSurfaceMode = .workbench
                }
            }
        case .service(let serviceID):
            selectedSidebarSection = .services
            if let service = service(by: serviceID), let repo = repo(by: service.repoID) {
                selectedRepoIDForFiles = repo.id
                ensureTerminalTab(for: repo)
                initializeWorkbenchStateIfNeeded(for: service)
                utilityPanelMode = .serviceRuntime
                showUtilityPanel = true
                detailSurfaceMode = .workbench
            }
        case .file(let path):
            selectedSidebarSection = .files
            if let repo = repoContaining(filePath: path) {
                selectedRepoIDForFiles = repo.id
                ensureTerminalTab(for: repo)
                if let singleService = singleServiceForRepo(repoID: repo.id) {
                    initializeWorkbenchStateIfNeeded(for: singleService)
                    detailSurfaceMode = .workbench
                }
            }
        }
    }

    /// Send a command to a terminal tab's session.
    func sendTerminalCommand(_ command: String, toTabID tabID: String) {
        terminalManager.sendCommand(command, toTabID: tabID)
        utilityPanelMode = .repositoryTerminal
        showUtilityPanel = true
    }

    /// Send a command to any terminal session, creating one if needed for a specific working directory.
    /// Returns the session used, allowing callers to observe its state.
    @discardableResult
    func runCommandInTerminal(_ command: String, workingDirectory: URL, label: String) -> TerminalSession {
        let contextKey = "cmd-\(workingDirectory.lastPathComponent)"
        let tab = terminalManager.openTab(contextKey: contextKey, label: label, workingDirectory: workingDirectory)
        utilityPanelMode = .repositoryTerminal
        showUtilityPanel = true

        tab.session.startIfNeeded()
        tab.session.sendCommand(command)
        return tab.session
    }

    func toggleEmulator() async {
        if emulatorState.isRunning {
            await stopEmulator()
        } else {
            await startEmulator()
        }
    }

    private func startEmulator() async {
        guard let workspace else {
            lastErrorMessage = "Open a workspace first."
            return
        }
        let workspaceYAMLPath = workspace.rootURL
            .appendingPathComponent(".aib/workspace.yaml")
            .standardizedFileURL
            .path
        guard FileManager.default.fileExists(atPath: workspaceYAMLPath) else {
            lastErrorMessage = "Workspace is not initialized for emulator (.aib/workspace.yaml not found). Open the correct folder or run aib init."
            appendAIBSystemLogLine("Missing workspace config: \(workspaceYAMLPath)")
            registerIssue(
                severity: .error,
                sourceTitle: "AIB Runtime",
                message: "Missing workspace config (.aib/workspace.yaml).",
                serviceSelectionID: nil,
                repoID: nil
            )
            emulatorState = .error("missing .aib/workspace.yaml")
            utilityPanelMode = .aibRuntime
            showUtilityPanel = true
            return
        }
        let requestedGatewayPort = gatewayPort
        let effectiveGatewayPort = chooseGatewayPort(preferred: gatewayPort)
        gatewayPort = effectiveGatewayPort
        emulatorState = .starting
        emulatorOutput = ""
        serviceLogOutputByServiceID = [:]
        serviceSnapshotsByID = [:]
        runtimeIssues = []
        rebuildSidebarRepoStatuses()
        if effectiveGatewayPort != requestedGatewayPort {
            appendAIBSystemLogLine("Gateway port \(requestedGatewayPort) is busy. Falling back to \(effectiveGatewayPort).")
            utilityPanelMode = .aibRuntime
            showUtilityPanel = true
        }
        do {
            let result = try await emulatorController.start(
                workspaceURL: workspace.rootURL,
                gatewayPort: effectiveGatewayPort
            )
            emulatorState = .running(pid: result.pid, port: effectiveGatewayPort)
            lastErrorMessage = nil
        } catch {
            emulatorState = .error(error.localizedDescription)
            lastErrorMessage = "Failed to start emulator on port \(effectiveGatewayPort): \(error.localizedDescription)"
            registerIssue(
                severity: .error,
                sourceTitle: "AIB Runtime",
                message: "Failed to start emulator: \(error.localizedDescription)",
                serviceSelectionID: nil,
                repoID: nil
            )
            utilityPanelMode = .aibRuntime
            showUtilityPanel = true
        }
    }

    private func stopEmulator() async {
        emulatorState = .stopping
        do {
            try await emulatorController.stop()
            emulatorState = .stopped
        } catch {
            emulatorState = .error(error.localizedDescription)
            lastErrorMessage = "Failed to stop emulator: \(error.localizedDescription)"
            registerIssue(
                severity: .error,
                sourceTitle: "AIB Runtime",
                message: "Failed to stop emulator: \(error.localizedDescription)",
                serviceSelectionID: nil,
                repoID: nil
            )
        }
    }

    func openInEditor() {
        if let fileURL = selectedFileURL() {
            editorService.open(url: fileURL)
            return
        }
        if let repo = selectedRepo() {
            editorService.open(url: repo.rootURL)
            return
        }
        if let workspace {
            editorService.open(url: workspace.rootURL)
        }
    }

    func issueCount(for severity: RuntimeIssueSeverity) -> Int {
        runtimeIssues.reduce(into: 0) { result, issue in
            guard issue.severity == severity else { return }
            result += issue.count
        }
    }

    func hasIssues(for severity: RuntimeIssueSeverity) -> Bool {
        issueCount(for: severity) > 0
    }

    func filteredRuntimeIssues() -> [RuntimeIssue] {
        let filtered: [RuntimeIssue]
        if let issueListFilter {
            filtered = runtimeIssues.filter { $0.severity == issueListFilter }
        } else {
            filtered = runtimeIssues
        }
        return filtered.sorted { lhs, rhs in
            if lhs.severity != rhs.severity {
                return lhs.severity == .error
            }
            return lhs.lastUpdatedAt > rhs.lastUpdatedAt
        }
    }

    func showIssueList(filter: RuntimeIssueSeverity) {
        issueListFilter = filter
        showIssuesInSidebar = true
    }

    func hideIssueList() {
        showIssuesInSidebar = false
        issueListFilter = nil
    }

    func selectIssue(_ issue: RuntimeIssue) {
        if let serviceSelectionID = issue.serviceSelectionID,
           let service = service(by: serviceSelectionID) {
            select(.service(service.id))
            return
        }
        if let repoID = issue.repoID,
           let repo = repo(by: repoID) {
            select(.repo(repo.id))
            return
        }
        utilityPanelMode = .aibRuntime
        showUtilityPanel = true
    }

    func toggleSidebarVisibility() {
        splitViewVisibility = (splitViewVisibility == .all) ? .detailOnly : .all
    }

    func selectedRepo() -> AIBRepoModel? {
        switch selection {
        case .topology:
            return nil
        case .repo(let repoID):
            return repo(by: repoID)
        case .service(let serviceID):
            if let service = service(by: serviceID) { return repo(by: service.repoID) }
            return nil
        case .file(let path):
            return repoContaining(filePath: path)
        case nil:
            return nil
        }
    }

    func selectedService() -> AIBServiceModel? {
        guard case .service(let id) = selection else { return nil }
        return service(by: id)
    }

    func selectedFlowNode() -> AIBServiceModel? {
        guard let nodeID = selectedFlowNodeID else { return nil }
        return service(by: nodeID)
    }

    // MARK: - PiP Chat

    func openPiPChat(serviceID: String, sessionID: UUID) {
        // Ensure topology mode so the FlowCanvas (and PiP overlay) is visible.
        if detailSurfaceMode != .topology {
            detailSurfaceMode = .topology
        }
        pipManager.open(serviceID: serviceID, sessionID: sessionID)
    }

    // MARK: - Chat Session CRUD

    func activeSession(for service: AIBServiceModel) -> ChatSession {
        if let sessionID = activeSessionIDByService[service.id],
           let session = chatSessionsByService[service.id]?.first(where: { $0.id == sessionID }) {
            session.updateEndpoint(makeChatEndpoint(for: service))
            return session
        }
        return createSession(for: service, activate: true)
    }

    @discardableResult
    func createSession(for service: AIBServiceModel, activate: Bool) -> ChatSession {
        let endpoint = makeChatEndpoint(for: service)
        let session = ChatSession(serviceID: service.id, endpoint: endpoint)
        var sessions = chatSessionsByService[service.id] ?? []
        sessions.insert(session, at: 0)
        chatSessionsByService[service.id] = sessions
        if activate {
            activeSessionIDByService[service.id] = session.id
        }
        return session
    }

    func session(serviceID: String, sessionID: UUID) -> ChatSession? {
        chatSessionsByService[serviceID]?.first(where: { $0.id == sessionID })
    }

    func sessions(for service: AIBServiceModel) -> [ChatSession] {
        chatSessionsByService[service.id] ?? []
    }

    func activateSession(_ sessionID: UUID, for service: AIBServiceModel) {
        guard chatSessionsByService[service.id]?.contains(where: { $0.id == sessionID }) == true else { return }
        activeSessionIDByService[service.id] = sessionID
    }

    func deleteSession(_ sessionID: UUID, for service: AIBServiceModel) {
        chatSessionsByService[service.id]?.removeAll(where: { $0.id == sessionID })
        if activeSessionIDByService[service.id] == sessionID {
            activeSessionIDByService[service.id] = chatSessionsByService[service.id]?.first?.id
        }
        pipManager.close(sessionID: sessionID)
    }

    func canOpenChat(for service: AIBServiceModel) -> Bool {
        service.serviceKind == .agent && service.uiProfile?.chatProfile != nil
    }

    private func makeChatEndpoint(for service: AIBServiceModel) -> ChatEndpoint {
        let port = gatewayPort
        let baseURLString = "http://127.0.0.1:\(port)\(service.mountPath)"
        let profile = service.uiProfile?.chatProfile
        return ChatEndpoint(
            baseURL: URL(string: baseURLString) ?? URL(string: "http://127.0.0.1:\(port)")!,
            method: profile?.method ?? "POST",
            path: profile?.path ?? "/",
            requestContentType: profile?.requestContentType ?? "application/json",
            requestMessageJSONPath: profile?.requestMessageJSONPath ?? "message",
            requestContextJSONPath: profile?.requestContextJSONPath,
            responseMessageJSONPath: profile?.responseMessageJSONPath ?? "message"
        )
    }

    func primaryWorkbenchService() -> AIBServiceModel? {
        if let service = selectedService() {
            return service
        }
        if let repo = selectedRepo() {
            return singleServiceForRepo(repoID: repo.id)
        }
        return nil
    }

    func selectedFileURL() -> URL? {
        guard case .file(let path) = selection else { return nil }
        return URL(fileURLWithPath: path)
    }

    func repo(by id: String) -> AIBRepoModel? {
        workspace?.repos.first(where: { $0.id == id })
    }

    func sidebarStatus(for repo: AIBRepoModel) -> SidebarRepoStatus? {
        sidebarRepoStatusByRepoID[repo.id]
    }

    func service(by id: String) -> AIBServiceModel? {
        workspace?.services.first(where: { $0.id == id })
    }

    func repoContaining(filePath: String) -> AIBRepoModel? {
        guard let workspace else { return nil }
        return workspace.repos.first(where: { filePath.hasPrefix($0.rootURL.path + "/") || filePath == $0.rootURL.path })
    }

    func currentFileTree() -> [AIBFileNode] {
        guard let workspace, let selectedRepoIDForFiles else { return [] }
        return workspace.fileTreesByRepoID[selectedRepoIDForFiles] ?? []
    }

    func flowNodes() -> [FlowNodeModel] {
        guard let workspace else { return [] }
        let services = workspace.services.sorted { $0.namespacedID.localizedStandardCompare($1.namespacedID) == .orderedAscending }
        let agentServices = services.filter { $0.serviceKind == .agent }
        let mcpServices = services.filter { $0.serviceKind == .mcp }
        let otherServices = services.filter { $0.serviceKind == .unknown }

        var nodes: [FlowNodeModel] = []
        nodes.append(contentsOf: positionedFlowNodes(agentServices, x: 80))
        nodes.append(contentsOf: positionedFlowNodes(mcpServices, x: 440))
        nodes.append(contentsOf: positionedFlowNodes(otherServices, x: 260))
        return nodes
    }

    func flowConnections() -> [FlowConnectionModel] {
        guard let workspace else { return [] }
        let serviceByNamespacedID = Dictionary(uniqueKeysWithValues: workspace.services.map { ($0.namespacedID, $0) })
        var connections: [FlowConnectionModel] = []

        for source in workspace.services where source.serviceKind == .agent {
            for target in source.connections.mcpServers {
                guard let serviceRef = target.serviceRef,
                      let resolved = serviceByNamespacedID[serviceRef]
                else { continue }
                let id = "mcp::\(source.id)->\(resolved.id)"
                connections.append(
                    FlowConnectionModel(
                        id: id,
                        sourceServiceID: source.id,
                        targetServiceID: resolved.id,
                        kind: .mcp
                    )
                )
            }
            for target in source.connections.a2aAgents {
                guard let serviceRef = target.serviceRef,
                      let resolved = serviceByNamespacedID[serviceRef]
                else { continue }
                let id = "a2a::\(source.id)->\(resolved.id)"
                connections.append(
                    FlowConnectionModel(
                        id: id,
                        sourceServiceID: source.id,
                        targetServiceID: resolved.id,
                        kind: .a2a
                    )
                )
            }
        }

        return connections
    }

    func flowSourceServices() -> [AIBServiceModel] {
        guard let workspace else { return [] }
        return workspace.services
            .filter { $0.serviceKind == .agent }
            .sorted { $0.namespacedID.localizedStandardCompare($1.namespacedID) == .orderedAscending }
    }

    func flowTargetServices(for sourceID: String?) -> [AIBServiceModel] {
        guard let workspace else { return [] }
        return workspace.services
            .filter { service in
                if let sourceID, service.id == sourceID {
                    return false
                }
                return service.serviceKind == .agent || service.serviceKind == .mcp
            }
            .sorted { $0.namespacedID.localizedStandardCompare($1.namespacedID) == .orderedAscending }
    }

    func addFlowConnection(sourceServiceID: String, targetServiceID: String) {
        guard var workspace else { return }
        guard let sourceIndex = workspace.services.firstIndex(where: { $0.id == sourceServiceID }),
              let target = workspace.services.first(where: { $0.id == targetServiceID })
        else { return }
        guard workspace.services[sourceIndex].serviceKind == .agent else {
            lastErrorMessage = "Only Agent services can create connections."
            return
        }

        let targetRef = target.namespacedID
        if target.serviceKind == .mcp {
            if workspace.services[sourceIndex].connections.mcpServers.contains(where: { $0.serviceRef == targetRef }) {
                return
            }
            workspace.services[sourceIndex].connections.mcpServers.append(.init(serviceRef: targetRef, url: nil))
        } else if target.serviceKind == .agent {
            if workspace.services[sourceIndex].connections.a2aAgents.contains(where: { $0.serviceRef == targetRef }) {
                return
            }
            workspace.services[sourceIndex].connections.a2aAgents.append(.init(serviceRef: targetRef, url: nil))
        } else {
            lastErrorMessage = "Connections can target Agent or MCP services only."
            return
        }

        self.workspace = workspace
        hasUnsavedFlowChanges = true
        lastErrorMessage = nil
    }

    func removeFlowConnection(_ connection: FlowConnectionModel) {
        guard var workspace else { return }
        guard let sourceIndex = workspace.services.firstIndex(where: { $0.id == connection.sourceServiceID }),
              let target = workspace.services.first(where: { $0.id == connection.targetServiceID })
        else { return }

        switch connection.kind {
        case .mcp:
            workspace.services[sourceIndex].connections.mcpServers.removeAll { $0.serviceRef == target.namespacedID }
        case .a2a:
            workspace.services[sourceIndex].connections.a2aAgents.removeAll { $0.serviceRef == target.namespacedID }
        }

        self.workspace = workspace
        hasUnsavedFlowChanges = true
        lastErrorMessage = nil
    }

    func saveFlowConnections() async {
        guard let workspace else { return }
        let mapping = Dictionary(
            uniqueKeysWithValues: workspace.services
                .filter { $0.serviceKind == .agent }
                .map { ($0.namespacedID, $0.connections) }
        )

        do {
            try AIBWorkspaceCore.updateServiceConnections(
                workspaceRoot: workspace.rootURL.path,
                connectionsByNamespacedServiceID: mapping
            )
            _ = try AIBWorkspaceCore.syncWorkspace(workspaceRoot: workspace.rootURL.path)
            await loadWorkspace(at: workspace.rootURL)
            hasUnsavedFlowChanges = false
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Failed to save Flow connections: \(error.localizedDescription)"
        }
    }

    func updateMCPProfile(namespacedServiceID: String, path: String) async {
        guard let workspace else { return }
        do {
            try AIBWorkspaceCore.updateServiceMCPProfile(
                workspaceRoot: workspace.rootURL.path,
                namespacedServiceID: namespacedServiceID,
                path: path
            )
            _ = try AIBWorkspaceCore.syncWorkspace(workspaceRoot: workspace.rootURL.path)
            await loadWorkspace(at: workspace.rootURL)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Failed to update MCP profile: \(error.localizedDescription)"
        }
    }

    func startDeploy() {
        guard let workspace else { return }
        if hasUnsavedFlowChanges {
            lastErrorMessage = "Save topology changes before deploying."
            return
        }

        // Check if cloud settings are configured before starting deploy flow.
        // If not configured, show cloud settings first — deploy resumes after save.
        do {
            let provider = try DeploymentProviderRegistry.detect(workspaceRoot: workspace.rootURL.path)
            if !configStore.isConfigured(
                workspaceRoot: workspace.rootURL.path,
                providerID: provider.providerID,
                provider: provider
            ) {
                showCloudSettings = true
                return
            }
        } catch {
            // Provider detection failed — proceed and let the deploy pipeline surface the error
        }

        beginDeployPipeline()
    }

    /// Resume deploy pipeline after cloud settings are saved.
    func onCloudSettingsDismissed() {
        guard let workspace else { return }

        // Check if settings are now configured (user saved, not cancelled)
        do {
            let provider = try DeploymentProviderRegistry.detect(workspaceRoot: workspace.rootURL.path)
            if configStore.isConfigured(
                workspaceRoot: workspace.rootURL.path,
                providerID: provider.providerID,
                provider: provider
            ) {
                beginDeployPipeline()
            }
        } catch {
            // Settings still not configured — do nothing
        }

        refreshEnvironmentStatus()
    }

    /// Open cloud settings from menu bar (independent of deploy flow).
    func openCloudSettings() {
        showCloudSettings = true
    }

    /// Run prerequisite tool-installation checks (Docker + cloud provider CLI)
    /// and update toolbar indicators. Called on workspace load and cloud settings dismiss.
    func selectDockerRuntime(_ runtime: DockerRuntime) {
        preferredDockerRuntime = runtime
        DockerRuntimeSettings.preferredRuntimeID = runtime.id
    }

    func launchDockerRuntime() {
        guard let runtime = preferredDockerRuntime else { return }
        NSWorkspace.shared.openApplication(
            at: runtime.appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self?.refreshEnvironmentStatus()
            }
        }
    }

    func refreshEnvironmentStatus() {
        // Detect installed Docker runtimes
        installedDockerRuntimes = DockerRuntime.detectInstalled()
        preferredDockerRuntime = DockerRuntimeSettings.resolvePreferred(from: installedDockerRuntimes)

        guard let workspace else {
            dockerCheckResult = nil
            cloudProviderCheckResult = nil
            detectedProvider = nil
            return
        }

        environmentCheckTask?.cancel()
        isCheckingEnvironment = true

        environmentCheckTask = Task { [weak self] in
            guard let self else { return }

            let provider: any DeploymentProvider
            do {
                provider = try DeploymentProviderRegistry.detect(workspaceRoot: workspace.rootURL.path)
            } catch {
                self.isCheckingEnvironment = false
                return
            }

            // Run prerequisite checks + Docker daemon check in parallel.
            // prerequisiteCheckIDs only contains Phase 1 (dockerInstalled, gcloudInstalled),
            // but toolbar needs dockerDaemonRunning too for accurate Docker status.
            let dockerRelated: Set<PreflightCheckID> = [.dockerInstalled, .dockerDaemonRunning]
            let toolbarCheckIDs = provider.prerequisiteCheckIDs.union(dockerRelated)
            let checkers = provider.preflightCheckers().filter { toolbarCheckIDs.contains($0.checkID) }

            let results = await withTaskGroup(
                of: PreflightCheckResult.self,
                returning: [PreflightCheckResult].self
            ) { group in
                for checker in checkers {
                    group.addTask { await checker.run() }
                }
                var collected: [PreflightCheckResult] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }

            guard !Task.isCancelled else { return }

            // Docker status: worst of dockerInstalled and dockerDaemonRunning
            let dockerInstalled = results.first(where: { $0.id == .dockerInstalled })
            let dockerDaemon = results.first(where: { $0.id == .dockerDaemonRunning })
            let dockerStatus: PreflightCheckResult? = {
                guard let installed = dockerInstalled else { return nil }
                if installed.isFailed { return installed }
                if let daemon = dockerDaemon, daemon.isFailed { return daemon }
                return installed
            }()

            let cloudPrereqID = provider.prerequisiteCheckIDs.first(where: { !dockerRelated.contains($0) })
            let cloudResult = cloudPrereqID.flatMap { id in results.first(where: { $0.id == id }) }

            self.detectedProvider = provider
            self.dockerCheckResult = dockerStatus
            self.cloudProviderCheckResult = cloudResult
            self.isCheckingEnvironment = false
        }
    }

    private func beginDeployPipeline() {
        guard let workspace else { return }

        showDeploySheet = true
        deployPhase = .idle
        startDeployEventStream()

        Task {
            do {
                let provider = try DeploymentProviderRegistry.detect(workspaceRoot: workspace.rootURL.path)
                let targetConfig = try AIBDeployService.loadTargetConfig(
                    workspaceRoot: workspace.rootURL.path,
                    providerID: provider.providerID
                )
                deployController.startPlan(
                    workspaceRoot: workspace.rootURL.path,
                    targetConfig: targetConfig,
                    provider: provider
                )
            } catch {
                deployPhase = .failed(AIBDeployError(
                    phase: "config",
                    message: error.localizedDescription
                ))
            }
        }
    }

    /// Trigger sheet dismissal. Actual cleanup happens in `cleanupDeployState()`
    /// via `.sheet(onDismiss:)`, ensuring ALL dismiss paths (button, Esc, click-outside)
    /// go through the same cleanup.
    func dismissDeploySheet() {
        showDeploySheet = false
    }

    /// Cleanup deploy state. Called exclusively from `.sheet(onDismiss:)`.
    func cleanupDeployState() {
        deployController.reset()
        deployPhase = .idle
        deployEventsTask?.cancel()
        deployEventsTask = nil
    }

    private func startDeployEventStream() {
        deployEventsTask?.cancel()
        deployEventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in deployController.events() {
                self.handleDeployEvent(event)
            }
        }
    }

    private func handleDeployEvent(_ event: AIBDeployEvent) {
        switch event {
        case .phaseChanged(let phase):
            self.deployPhase = phase
            appendDeployPhaseLog(phase)
            if case .applying = phase {
                showUtilityPanel = true
                utilityPanelMode = .aibRuntime
            }
        case .log(let entry):
            let servicePrefix = entry.serviceID.map { "[\($0)] " } ?? ""
            appendDeployLogLine(level: entry.level, message: "\(servicePrefix)\(entry.message)")
        }
    }

    private func appendDeployPhaseLog(_ phase: AIBDeployPhase) {
        switch phase {
        case .idle:
            break
        case .preflight:
            appendDeployLogLine(level: .info, message: "Running preflight checks...")
        case .planning:
            appendDeployLogLine(level: .info, message: "Generating deploy plan...")
        case .reviewing:
            appendDeployLogLine(level: .info, message: "Deploy plan ready for review")
        case .applying:
            appendDeployLogLine(level: .info, message: "Applying deploy plan...")
        case .completed(let result):
            appendDeployLogLine(level: .info, message: "Deploy completed: \(result.serviceResults.count) service(s)")
        case .failed(let error):
            appendDeployLogLine(level: .error, message: "Deploy failed (\(error.phase)): \(error.message)")
        case .cancelled:
            appendDeployLogLine(level: .warning, message: "Deploy cancelled")
        }
    }

    private func positionedFlowNodes(_ services: [AIBServiceModel], x: CGFloat) -> [FlowNodeModel] {
        services.enumerated().map { index, service in
            FlowNodeModel(
                id: service.id,
                namespacedID: service.namespacedID,
                serviceKind: service.serviceKind,
                position: CGPoint(x: x, y: CGFloat(60 + index * 80))
            )
        }
    }

    func aibLogOutput() -> String {
        emulatorOutput
    }

    func clearAIBLogs() {
        emulatorOutput = ""
    }

    func toggleUtilityPanelVisibility() {
        showUtilityPanel.toggle()
    }

    func selectedServiceLogOutput() -> String {
        guard let service = primaryWorkbenchService() else { return "" }
        return serviceLogOutputByServiceID[service.namespacedID, default: ""]
    }

    func selectedScopedRuntimeLogOutput() -> String {
        if let service = primaryWorkbenchService() {
            return serviceLogOutputByServiceID[service.namespacedID, default: ""]
        }
        guard let repo = selectedRepo(), let workspace else { return "" }
        let namespacedIDs = Set(workspace.services.filter { $0.repoID == repo.id }.map(\.namespacedID))
        guard !namespacedIDs.isEmpty else { return "" }
        return serviceLogOutputByServiceID
            .filter { namespacedIDs.contains($0.key) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map(\.value)
            .joined(separator: "")
    }

    func utilityServiceRuntimeLogOutput() -> String {
        switch utilityServiceLogTarget {
        case .selection:
            return selectedScopedRuntimeLogOutput()
        case .allServices:
            return serviceLogOutputByServiceID
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map(\.value)
                .joined(separator: "")
        case .service(let namespacedID):
            return serviceLogOutputByServiceID[namespacedID, default: ""]
        }
    }

    func clearSelectedScopedRuntimeLogs() {
        if let service = primaryWorkbenchService() {
            serviceLogOutputByServiceID[service.namespacedID] = ""
            return
        }
        guard let repo = selectedRepo(), let workspace else { return }
        for serviceID in workspace.services.filter({ $0.repoID == repo.id }).map(\.namespacedID) {
            serviceLogOutputByServiceID[serviceID] = ""
        }
    }

    func clearUtilityServiceRuntimeLogs() {
        switch utilityServiceLogTarget {
        case .selection:
            clearSelectedScopedRuntimeLogs()
        case .allServices:
            for key in serviceLogOutputByServiceID.keys {
                serviceLogOutputByServiceID[key] = ""
            }
        case .service(let namespacedID):
            serviceLogOutputByServiceID[namespacedID] = ""
        }
    }

    func utilityServiceLogTargetLabel() -> String {
        switch utilityServiceLogTarget {
        case .selection:
            return "Selection"
        case .allServices:
            return "All Services"
        case .service(let namespacedID):
            if let service = workspace?.services.first(where: { $0.namespacedID == namespacedID }) {
                return service.namespacedID
            }
            return namespacedID
        }
    }

    func utilityServiceLogTargetOptions() -> [(id: UtilityServiceLogTarget, title: String)] {
        var items: [(UtilityServiceLogTarget, String)] = [(.selection, "Selection"), (.allServices, "All Services")]
        let services = (workspace?.services ?? [])
            .sorted { $0.namespacedID.localizedStandardCompare($1.namespacedID) == .orderedAscending }
        items.append(contentsOf: services.map { (.service($0.namespacedID), $0.namespacedID) })
        return items
    }

    func serviceLogOutput(for service: AIBServiceModel) -> String {
        serviceLogOutputByServiceID[service.namespacedID, default: ""]
    }

    func serviceSnapshot(for service: AIBServiceModel) -> AIBServiceRuntimeSnapshot? {
        serviceSnapshotsByID[service.namespacedID]
    }

    func rawDraftSnapshot(for service: AIBServiceModel) -> RawRequestDraft {
        rawDraftByServiceID[service.id] ?? RawRequestDraft()
    }

    func clearLastError() {
        lastErrorMessage = nil
    }

    func effectiveWorkbenchMode(for service: AIBServiceModel) -> AIBWorkbenchMode {
        if let explicit = workbenchModeByServiceID[service.id] {
            return explicit
        }
        if let preferred = service.uiProfile?.primaryMode {
            return preferred
        }
        switch service.serviceKind {
        case .agent:
            return .chat
        case .mcp, .unknown:
            return .raw
        }
    }

    func setWorkbenchMode(_ mode: AIBWorkbenchMode, for service: AIBServiceModel) {
        workbenchModeByServiceID[service.id] = mode
        initializeWorkbenchStateIfNeeded(for: service)
    }

    func rawDraft(for service: AIBServiceModel) -> RawRequestDraft {
        if let existing = rawDraftByServiceID[service.id] {
            return existing
        }
        let initial = RawRequestDraft()
        rawDraftByServiceID[service.id] = initial
        return initial
    }

    func setRawDraft(_ draft: RawRequestDraft, for service: AIBServiceModel) {
        rawDraftByServiceID[service.id] = draft
    }

    func isServiceLogsExpanded(for service: AIBServiceModel) -> Bool {
        serviceLogsExpandedByServiceID[service.id, default: false]
    }

    func setServiceLogsExpanded(_ expanded: Bool, for service: AIBServiceModel) {
        serviceLogsExpandedByServiceID[service.id] = expanded
    }

    func clearWorkbench(for service: AIBServiceModel) {
        switch effectiveWorkbenchMode(for: service) {
        case .chat:
            activeSession(for: service).reset()
        case .raw:
            rawDraftByServiceID[service.id] = RawRequestDraft()
        }
    }

    func requestBaseURLString() -> String? {
        guard let service = primaryWorkbenchService() else { return nil }
        return requestBaseURLString(for: service)
    }

    func requestBaseURLString(for service: AIBServiceModel) -> String? {
        guard let port = effectiveGatewayPort(for: service) else { return nil }
        return "http://127.0.0.1:\(port)\(service.mountPath)"
    }

    func chatUnavailableReason(for service: AIBServiceModel) -> String? {
        guard effectiveWorkbenchMode(for: service) == .chat else { return nil }
        guard let uiProfile = service.uiProfile, let chatProfile = uiProfile.chatProfile else {
            return "This service does not define ui.chat in its service manifest."
        }
        if chatProfile.streaming {
            return "Streaming chat is not supported yet in this build. Use Raw mode."
        }
        if chatProfile.responseMessageJSONPath.isEmpty {
            return "ui.chat.response_message_json_path is required."
        }
        return nil
    }

    func sendRawRequest() async {
        guard let service = primaryWorkbenchService() else { return }
        await sendRawRequest(for: service)
    }

    func sendRawRequest(for service: AIBServiceModel) async {
        initializeWorkbenchStateIfNeeded(for: service)

        guard let port = effectiveGatewayPort(for: service) else {
            var draft = rawDraft(for: service)
            draft.lastTrace = RawRequestTrace(
                method: draft.method.rawValue,
                urlString: "(emulator stopped)",
                requestHeadersText: draft.headersText,
                requestBodyText: draft.bodyText,
                response: ServiceRequestResult(
                    urlString: "(emulator stopped)",
                    statusCode: nil,
                    headersText: "",
                    bodyText: "",
                    latencyMilliseconds: nil,
                    errorMessage: "Start the emulator before sending requests."
                )
            )
            setRawDraft(draft, for: service)
            return
        }

        var draft = rawDraft(for: service)
        let normalizedPath = normalizedPath(draft.path)
        let urlString = "http://127.0.0.1:\(port)\(service.mountPath)\(normalizedPath)"
        guard let url = URL(string: urlString) else {
            draft.lastTrace = RawRequestTrace(
                method: draft.method.rawValue,
                urlString: urlString,
                requestHeadersText: draft.headersText,
                requestBodyText: draft.bodyText,
                response: ServiceRequestResult(urlString: urlString, statusCode: nil, headersText: "", bodyText: "", latencyMilliseconds: nil, errorMessage: "Invalid request URL")
            )
            setRawDraft(draft, for: service)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = draft.method.rawValue

        do {
            let headers = try parsedHeaders(from: draft.headersText)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
        } catch {
            draft.lastTrace = RawRequestTrace(
                method: draft.method.rawValue,
                urlString: urlString,
                requestHeadersText: draft.headersText,
                requestBodyText: draft.bodyText,
                response: ServiceRequestResult(urlString: urlString, statusCode: nil, headersText: "", bodyText: "", latencyMilliseconds: nil, errorMessage: error.localizedDescription)
            )
            setRawDraft(draft, for: service)
            return
        }

        if draft.method.supportsBody {
            let body = draft.bodyText
            if !body.isEmpty {
                request.httpBody = Data(body.utf8)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }
        }

        draft.isSending = true
        setRawDraft(draft, for: service)
        let startedAt = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceRequestError.invalidResponse
            }
            let latency = Int(Date().timeIntervalSince(startedAt) * 1000)
            let headerLines = httpResponse.allHeaderFields
                .map { "\($0.key): \($0.value)" }
                .sorted()
                .joined(separator: "\n")
            let bodyText = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes binary>"
            draft.lastTrace = RawRequestTrace(
                method: draft.method.rawValue,
                urlString: urlString,
                requestHeadersText: draft.headersText,
                requestBodyText: draft.bodyText,
                response: ServiceRequestResult(
                    urlString: urlString,
                    statusCode: httpResponse.statusCode,
                    headersText: headerLines,
                    bodyText: bodyText,
                    latencyMilliseconds: latency
                )
            )
        } catch {
            draft.lastTrace = RawRequestTrace(
                method: draft.method.rawValue,
                urlString: urlString,
                requestHeadersText: draft.headersText,
                requestBodyText: draft.bodyText,
                response: ServiceRequestResult(
                    urlString: urlString,
                    statusCode: nil,
                    headersText: "",
                    bodyText: "",
                    latencyMilliseconds: nil,
                    errorMessage: error.localizedDescription
                )
            )
        }
        draft.isSending = false
        setRawDraft(draft, for: service)
    }

    private func appendAIBSystemLogLine(_ message: String) {
        emulatorOutput.append("[aib][app][info] \(message)\n")
        if emulatorOutput.count > 200_000 {
            emulatorOutput.removeFirst(emulatorOutput.count - 200_000)
        }
    }

    private func appendDeployLogLine(level: Logger.Level, message: String) {
        emulatorOutput.append("[aib][deploy][\(level)] \(message)\n")
        if emulatorOutput.count > 200_000 {
            emulatorOutput.removeFirst(emulatorOutput.count - 200_000)
        }
    }

    private func chooseGatewayPort(preferred: Int) -> Int {
        if isTCPPortAvailable(preferred) {
            return preferred
        }

        let fallbackCandidates = Array(18080...18120)
        for candidate in fallbackCandidates where candidate != preferred {
            if isTCPPortAvailable(candidate) {
                return candidate
            }
        }
        return preferred
    }

    private func isTCPPortAvailable(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var reuse: Int32 = 1
        let setOptResult = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        guard setOptResult == 0 else { return false }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }

    private func initializeWorkbenchStateIfNeeded(for service: AIBServiceModel) {
        if rawDraftByServiceID[service.id] == nil {
            rawDraftByServiceID[service.id] = RawRequestDraft()
        }
        if workbenchModeByServiceID[service.id] == nil, let preferred = service.uiProfile?.primaryMode {
            workbenchModeByServiceID[service.id] = preferred
        }
    }

    private func effectiveGatewayPort(for service: AIBServiceModel) -> Int? {
        if case .running(_, let port) = emulatorState, let port {
            return port
        }
        if let snapshot = serviceSnapshotsByID[service.namespacedID], snapshot.lifecycleState == .ready {
            return gatewayPort
        }
        return nil
    }

    private func singleServiceForRepo(repoID: String) -> AIBServiceModel? {
        guard let workspace else { return nil }
        let repoServices = workspace.services.filter { $0.repoID == repoID }
        guard repoServices.count == 1 else { return nil }
        return repoServices[0]
    }

    private func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }
        if trimmed.hasPrefix("/") {
            return trimmed
        }
        return "/" + trimmed
    }

    private func parsedHeaders(from text: String) throws -> [(String, String)] {
        let lines = text.split(whereSeparator: \.isNewline)
        var headers: [(String, String)] = []
        for rawLine in lines {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let separator = line.firstIndex(of: ":") else {
                throw ServiceRequestError.invalidHeaderLine(line)
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw ServiceRequestError.invalidHeaderLine(line)
            }
            headers.append((String(name), String(value)))
        }
        return headers
    }

    private func extractServiceID(from entry: AIBEmulatorLogEntry) -> String? {
        if let raw = entry.metadata["service_id"] {
            let normalized = trimmedQuotes(raw)
            return normalized.isEmpty ? nil : normalized
        }

        guard entry.message.first == "[" else { return nil }
        guard let firstClose = entry.message.firstIndex(of: "]") else { return nil }
        let secondOpen = entry.message.index(after: firstClose)
        guard secondOpen < entry.message.endIndex, entry.message[secondOpen] == "[" else { return nil }
        let start = entry.message.index(after: entry.message.startIndex)
        let serviceID = String(entry.message[start..<firstClose])
        return serviceID.isEmpty ? nil : serviceID
    }

    private func resolveServiceSelectionID(from rawServiceID: String) -> String? {
        guard let workspace else { return nil }
        if let exact = workspace.services.first(where: { $0.id == rawServiceID }) {
            return exact.id
        }
        if let namespaced = workspace.services.first(where: { $0.namespacedID == rawServiceID }) {
            return namespaced.id
        }
        if let local = workspace.services.first(where: { $0.localID == rawServiceID }) {
            return local.id
        }
        return nil
    }

    private func registerIssue(
        severity: RuntimeIssueSeverity,
        sourceTitle: String,
        message: String,
        serviceSelectionID: String?,
        repoID: String?
    ) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }

        if let existingIndex = runtimeIssues.firstIndex(where: {
            $0.severity == severity &&
            $0.sourceTitle == sourceTitle &&
            $0.message == trimmedMessage &&
            $0.serviceSelectionID == serviceSelectionID &&
            $0.repoID == repoID
        }) {
            runtimeIssues[existingIndex].count += 1
            runtimeIssues[existingIndex].lastUpdatedAt = .now
            return
        }

        runtimeIssues.append(
            RuntimeIssue(
                severity: severity,
                sourceTitle: sourceTitle,
                message: trimmedMessage,
                serviceSelectionID: serviceSelectionID,
                repoID: repoID
            )
        )

        if runtimeIssues.count > 300 {
            runtimeIssues.removeFirst(runtimeIssues.count - 300)
        }
        rebuildSidebarRepoStatuses()
    }

    private func registerIssue(from entry: AIBEmulatorLogEntry) {
        let severity: RuntimeIssueSeverity
        switch entry.level {
        case .error, .critical:
            severity = .error
        case .warning:
            severity = .warning
        default:
            return
        }

        let rawServiceID = extractServiceID(from: entry)
        let serviceSelectionID = rawServiceID.flatMap(resolveServiceSelectionID(from:))
        let matchedService = serviceSelectionID.flatMap(service(by:))
        let repoID = matchedService?.repoID
        let sourceTitle: String
        if let matchedService {
            sourceTitle = matchedService.namespacedID
        } else {
            sourceTitle = entry.loggerLabel
        }

        registerIssue(
            severity: severity,
            sourceTitle: sourceTitle,
            message: entry.message,
            serviceSelectionID: serviceSelectionID,
            repoID: repoID
        )
    }

    private func trimmedQuotes(_ value: String) -> String {
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func handleEmulatorEvent(_ event: AIBEmulatorEvent) {
        switch event {
        case .log(let entry):
            emulatorOutput.append(entry.formattedLine)
            if emulatorOutput.count > 200_000 {
                emulatorOutput.removeFirst(emulatorOutput.count - 200_000)
            }
            registerIssue(from: entry)
            if let serviceID = extractServiceID(from: entry) {
                var output = serviceLogOutputByServiceID[serviceID, default: ""]
                output.append(entry.formattedLine)
                if output.count > 120_000 {
                    output.removeFirst(output.count - 120_000)
                }
                serviceLogOutputByServiceID[serviceID] = output
            }
        case .lifecycleChanged(let lifecycle):
            handleLifecycleTransitionForAnnouncement(next: lifecycle)
            switch lifecycle {
            case .stopped:
                emulatorState = .stopped
                serviceSnapshotsByID = [:]
                rebuildSidebarRepoStatuses()
            case .starting:
                emulatorState = .starting
                rebuildSidebarRepoStatuses()
            case .running(let pid, let port):
                emulatorState = .running(pid: pid, port: port)
                rebuildSidebarRepoStatuses()
            case .stopping:
                emulatorState = .stopping
                rebuildSidebarRepoStatuses()
            case .failed(let message):
                emulatorState = .error(message)
                serviceSnapshotsByID = [:]
                lastErrorMessage = "Failed to start emulator: \(message)"
                registerIssue(
                    severity: .error,
                    sourceTitle: "AIB Runtime",
                    message: "Failed to start emulator: \(message)",
                    serviceSelectionID: nil,
                    repoID: nil
                )
                utilityPanelMode = .aibRuntime
                showUtilityPanel = true
                rebuildSidebarRepoStatuses()
            }
        case .serviceSnapshotsChanged(let snapshots):
            serviceSnapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.serviceID, $0) })
            rebuildSidebarRepoStatuses()
        }
    }

    private func handleLifecycleTransitionForAnnouncement(next lifecycle: AIBEmulatorLifecycleState) {
        let previous = lastEmulatorLifecycleState
        lastEmulatorLifecycleState = lifecycle

        guard let previous else {
            return
        }

        switch (previous, lifecycle) {
        case (.starting, .running(_, let port)):
            runtimeAnnouncementCenter.enqueue(.runtimeStarted(port: port))
        case (.stopping, .stopped), (.running(_, _), .stopped):
            runtimeAnnouncementCenter.enqueue(.runtimeStopped())
        case (_, .failed(let message)):
            runtimeAnnouncementCenter.enqueue(.runtimeStartFailed(message))
        default:
            break
        }
    }

    private func rebuildSidebarRepoStatuses() {
        guard let workspace else {
            sidebarRepoStatusByRepoID = [:]
            return
        }
        var statuses: [String: SidebarRepoStatus] = [:]
        for repo in workspace.repos {
            statuses[repo.id] = sidebarStatusForRepo(repo, workspace: workspace)
        }
        sidebarRepoStatusByRepoID = statuses
    }

    private func sidebarStatusForRepo(_ repo: AIBRepoModel, workspace: AIBWorkspaceSnapshot) -> SidebarRepoStatus {
        let repoServices = workspace.services.filter { $0.repoID == repo.id }
        guard !repoServices.isEmpty else {
            return .warning
        }

        if hasIssue(forRepoID: repo.id, severity: .error) {
            return .error
        }
        if hasIssue(forRepoID: repo.id, severity: .warning) {
            return .warning
        }

        let states = Set(repoServices.compactMap { serviceSnapshotsByID[$0.namespacedID]?.lifecycleState.rawValue })
        if states.contains("unhealthy") || states.contains("backoff") {
            return .error
        }
        if states.contains("ready") {
            return .running
        }
        if states.contains("starting") || states.contains("stopping") || states.contains("draining") {
            return .starting
        }

        return !repoServices.isEmpty ? .configured : .warning
    }

    private func hasIssue(forRepoID repoID: String, severity: RuntimeIssueSeverity) -> Bool {
        runtimeIssues.contains { issue in
            guard issue.severity == severity else { return false }
            if issue.repoID == repoID {
                return true
            }
            if let serviceSelectionID = issue.serviceSelectionID,
               let service = service(by: serviceSelectionID),
               service.repoID == repoID {
                return true
            }
            return false
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case workspace = "Workspace"
    case files = "Files"
    case services = "Services"

    var id: String { rawValue }
}

enum UtilityPanelMode: String, CaseIterable, Identifiable {
    case aibRuntime
    case serviceRuntime
    case repositoryTerminal
    case connections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aibRuntime:
            return "AIB Runtime"
        case .serviceRuntime:
            return "Service Runtime"
        case .repositoryTerminal:
            return "Repository Terminal"
        case .connections:
            return "Connections"
        }
    }
}

enum UtilityServiceLogTarget: Hashable, Identifiable {
    case selection
    case allServices
    case service(String)

    var id: String {
        switch self {
        case .selection:
            return "selection"
        case .allServices:
            return "all-services"
        case .service(let namespacedID):
            return "service:\(namespacedID)"
        }
    }
}

enum HTTPRequestMethod: String, CaseIterable, Identifiable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"

    var id: String { rawValue }

    var supportsBody: Bool {
        switch self {
        case .get, .delete:
            return false
        case .post, .put, .patch:
            return true
        }
    }
}

struct ServiceRequestResult {
    let urlString: String
    let statusCode: Int?
    let headersText: String
    let bodyText: String
    let latencyMilliseconds: Int?
    var errorMessage: String?

    init(
        urlString: String,
        statusCode: Int?,
        headersText: String,
        bodyText: String,
        latencyMilliseconds: Int?,
        errorMessage: String? = nil
    ) {
        self.urlString = urlString
        self.statusCode = statusCode
        self.headersText = headersText
        self.bodyText = bodyText
        self.latencyMilliseconds = latencyMilliseconds
        self.errorMessage = errorMessage
    }
}

struct RawRequestTrace {
    var method: String
    var urlString: String
    var requestHeadersText: String
    var requestBodyText: String
    var response: ServiceRequestResult
}

struct RawRequestDraft {
    var method: HTTPRequestMethod = .get
    var path: String = "/"
    var headersText: String = ""
    var bodyText: String = ""
    var isSending: Bool = false
    var lastTrace: RawRequestTrace?
}

enum ServiceRequestError: LocalizedError {
    case invalidHeaderLine(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidHeaderLine(let line):
            return "Invalid header line: \(line)"
        case .invalidResponse:
            return "Invalid HTTP response"
        }
    }
}
