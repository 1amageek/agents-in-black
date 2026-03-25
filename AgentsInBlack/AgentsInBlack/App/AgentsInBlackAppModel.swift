import AppKit
import AIBCore
import AIBRuntimeCore
import AIBWorkspace
import Darwin
import Foundation
import Logging
import Observation
import os
import SwiftUI
import TipKit

private let dropLogger = os.Logger(subsystem: "com.aib.app", category: "RepoDrop")

struct ServiceRemovalTarget {
    let namespacedServiceID: String
    let displayName: String
}

enum CreateServiceError: LocalizedError {
    case noWorkspace
    case directoryExists(String)

    var errorDescription: String? {
        switch self {
        case .noWorkspace:
            "Open a workspace first."
        case .directoryExists(let name):
            "Directory '\(name)' already exists."
        }
    }
}

@MainActor
@Observable
final class AgentsInBlackAppModel {
    var workspace: AIBWorkspaceSnapshot?
    var splitViewVisibility: NavigationSplitViewVisibility = .detailOnly
    var selectedSidebarSection: SidebarSection = .workspace
    var selection: SelectionTarget? = .topology
    var selectedRepoIDForFiles: String?
    var detailSurfaceMode: DetailSurfaceMode = .topology
    var sharedContextSchema: SharedContextSchema = .empty
    var hasUnsavedFlowChanges: Bool = false
    var flowConnectionSourceServiceID: String?
    var flowConnectionTargetServiceID: String?
    var selectedFlowNodeID: String?

    // MARK: - Chat Sessions
    let agentCardCache = A2AAgentCardCache()
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
    var kernelDownloadProgress: Progress?
    var emulatorOutput: String = ""
    var serviceLogOutputByServiceID: [String: String] = [:]
    var serviceSnapshotsByID: [String: AIBServiceRuntimeSnapshot] = [:]
    var activeServiceIDs: Set<String> = []
    var mcpConnectionStatusByConnectionID: [String: MCPConnectionRuntimeStatus] = [:]
    var showInspector: Bool = false
    var selectedChatMessage: ChatMessageItem?
    var lastErrorMessage: String?
    var serviceRemovalTarget: ServiceRemovalTarget?
    var showServiceRemovalDialog = false
    let runtimeAnnouncementCenter = RuntimeAnnouncementCenter()
    var gatewayPort: Int = 8080
    var showUtilityPanel: Bool = false
    var utilityPanelMode: UtilityPanelMode = .aibRuntime
    var utilityPanelFilterText: String = ""
    var utilityServiceLogTarget: UtilityServiceLogTarget = .selection
    var sidebarServiceStatusByServiceID: [String: SidebarServiceStatusInfo] = [:]
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
    private var cloudSettingsOpenedForDeploy: Bool = false
    private var deployEventsTask: Task<Void, Never>?
    private let configStore: DeployTargetConfigStore = DefaultDeployTargetConfigStore()
    private let gcloudContextService = GCloudContextService()

    // MARK: - Deploy Environment Status
    var buildBackendCheckResult: PreflightCheckResult?
    var cloudProviderCheckResult: PreflightCheckResult?
    var detectedProvider: (any DeploymentProvider)?
    var isCheckingEnvironment: Bool = false
    private var environmentCheckTask: Task<Void, Never>?
    var gcloudAccounts: [GCloudAccount] = []
    var gcloudProjects: [GCloudProject] = []
    var activeGCloudAccount: String?
    var activeGCloudProject: String?
    var configuredGCloudProject: String?
    var gcloudContextErrorMessage: String?
    var isRefreshingGCloudContext: Bool = false
    var isSwitchingGCloudAccount: Bool = false
    var isSwitchingGCloudProject: Bool = false
    private var gcloudContextTask: Task<Void, Never>?

    // MARK: - Clone Repository
    var showCloneSheet: Bool = false
    var cloneURL: String = ""
    var cloneInProgress: Bool = false
    var cloneOutput: String = ""
    var cloneError: String?

    // MARK: - Create New Service
    var createServiceKind: AIBServiceKind?

    // MARK: - Skills
    var showAddSkillSheet: Bool = false
    var showSkillRegistrySheet: Bool = false

    // MARK: - Editor
    var installedEditorApps: [ExternalEditorApp] = []
    var preferredEditorApp: ExternalEditorApp?

    let workspaceDiscovery = WorkspaceDiscoveryService()
    let emulatorController = AIBEmulatorController()
    let editorService = ExternalEditorService()
    private var directoryMonitorSource: DispatchSourceFileSystemObject?
    private var directoryMonitorFD: Int32 = -1

    init() {
        refreshPreferredApplications()
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
        gcloudContextTask?.cancel()
        gcloudContextTask = nil
        runtimeAnnouncementCenter.clear()

        stopDirectoryMonitor()
        emulatorController.shutdown()
        deployController.shutdown()
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
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.prompt = "Create"
        panel.title = "New Workspace"
        panel.nameFieldLabel = "Workspace Name:"
        panel.nameFieldStringValue = "MyWorkspace"
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        Task { await createWorkspace(at: url) }
    }

    func createWorkspace(at url: URL) async {
        do {
            let path = url.standardizedFileURL.path
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: path, isDirectory: &isDir) {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            _ = try AIBWorkspaceCore.initWorkspace(
                workspaceRoot: path,
                scanPath: path,
                force: false,
                scanEnabled: true
            )
            try AIBWorkspaceCore.scaffoldDefaultAgent(workspaceRoot: path)
            await loadWorkspace(at: url)
            lastErrorMessage = nil
        } catch {
            setError("Failed to create workspace: \(error.localizedDescription)")
        }
    }

    func openIncomingDirectory(_ url: URL) {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            setError("Only directories can be opened as a workspace.")
            return
        }
        Task { await loadWorkspace(at: standardized) }
    }

    func openIncomingURLs(_ urls: [URL]) {
        let directories = urls.compactMap { url -> URL? in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return url
        }
        guard let first = directories.first else { return }

        if workspace != nil {
            Task { await addDroppedRepositories(directories) }
        } else {
            openIncomingDirectory(first)
        }
    }

    func loadWorkspace(at url: URL) async {
        let logger = os.Logger(subsystem: "com.aib.app", category: "Workspace")
        logger.info("loadWorkspace: starting at \(url.path)")
        do {
            // Remove repos whose directories no longer exist before loading
            let removed = try AIBWorkspaceCore.removeStaleRepos(workspaceRoot: url.path)
            if !removed.isEmpty {
                logger.info("loadWorkspace: removed stale repos: \(removed.joined(separator: ", "))")
            }

            let snapshot = try workspaceDiscovery.loadWorkspace(at: url)
            logger.info("loadWorkspace: loaded \(snapshot.repos.count) repos, \(snapshot.services.count) services")
            workspace = snapshot
            startDirectoryMonitor(for: url)
            gatewayPort = snapshot.gatewayPort
            runtimeIssues = []
            mcpConnectionStatusByConnectionID = [:]
            showIssuesInSidebar = false
            issueListFilter = nil
            if let firstRepo = snapshot.repos.first {
                selectedRepoIDForFiles = firstRepo.id
                ensureTerminalTab(for: firstRepo)
            } else {
                selectedRepoIDForFiles = nil
            }
            selection = .topology
            detailSurfaceMode = .topology
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
            agentCardCache.clearAll()
            rebuildAllSidebarStatuses()
            lastErrorMessage = nil
            refreshEnvironmentStatus()
        } catch {
            logger.error("loadWorkspace: failed: \(error)")
            setError("Failed to load workspace: \(error.localizedDescription)")
        }
    }

    func refreshWorkspace() async {
        guard let workspace else { return }
        await loadWorkspace(at: workspace.rootURL)
    }

    // MARK: - Directory Monitor

    private func startDirectoryMonitor(for rootURL: URL) {
        stopDirectoryMonitor()
        let fd = open(rootURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        directoryMonitorFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleDirectoryChange()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        directoryMonitorSource = source
        source.resume()
    }

    private func stopDirectoryMonitor() {
        directoryMonitorSource?.cancel()
        directoryMonitorSource = nil
        directoryMonitorFD = -1
    }

    private func handleDirectoryChange() async {
        guard let workspace else { return }
        let logger = os.Logger(subsystem: "com.aib.app", category: "DirectoryMonitor")
        do {
            let removed = try AIBWorkspaceCore.removeStaleRepos(workspaceRoot: workspace.rootURL.path)
            if !removed.isEmpty {
                logger.info("Directory monitor: removed stale repos: \(removed.joined(separator: ", "))")
                await loadWorkspace(at: workspace.rootURL)
            }
        } catch {
            logger.error("Directory monitor: failed to sync: \(error)")
        }
    }

    func addDirectoryPicker() {
        guard workspace != nil else {
            setError("Open a workspace first.")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Directory"
        panel.message = "Select a directory to add as a repository reference."
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        Task { await addRepoReference(at: url.standardizedFileURL) }
    }

    func addRepoReference(at url: URL) async {
        dropLogger.info("[REF] addRepoReference called: \(url.path)")
        guard let workspace else {
            dropLogger.error("[REF] No workspace open")
            setError("Open a workspace first.")
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            dropLogger.error("[REF] Not a directory: \(url.path)")
            setError("Selected path is not a directory.")
            return
        }

        dropLogger.info("[REF] Calling AIBWorkspaceCore.addRepo, workspaceRoot=\(workspace.rootURL.path), repoURL=\(url.path)")
        do {
            _ = try AIBWorkspaceCore.addRepo(workspaceRoot: workspace.rootURL.path, repoURL: url)
            dropLogger.info("[REF] Success, reloading workspace")
            await loadWorkspace(at: workspace.rootURL)
            lastErrorMessage = nil
        } catch {
            dropLogger.error("[REF] Failed: \(error.localizedDescription)")
            setError("Failed to add repository: \(error.localizedDescription)")
        }
    }

    func relocateMissingDirectory(name: String) {
        guard workspace != nil else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Select the new location for \"\(name)\"."
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        Task { await performRelocate(repoName: name, newURL: url.standardizedFileURL) }
    }

    private func performRelocate(repoName: String, newURL: URL) async {
        guard let workspace else { return }
        do {
            _ = try AIBWorkspaceCore.relocateRepo(
                workspaceRoot: workspace.rootURL.path,
                repoName: repoName,
                newURL: newURL
            )
            await loadWorkspace(at: workspace.rootURL)
            lastErrorMessage = nil
        } catch {
            setError("Failed to relocate directory: \(error.localizedDescription)")
        }
    }

    func createNewService(template: any ProjectTemplate, serviceName: String, serviceKind: AIBServiceKind) async throws {
        guard let workspace else {
            throw CreateServiceError.noWorkspace
        }

        let serviceDir = workspace.rootURL.appendingPathComponent(serviceName)

        guard !FileManager.default.fileExists(atPath: serviceDir.path) else {
            throw CreateServiceError.directoryExists(serviceName)
        }

        try template.scaffold(at: serviceDir, serviceName: serviceName)
        let result = try AIBWorkspaceCore.addRepo(workspaceRoot: workspace.rootURL.path, repoURL: serviceDir)

        // Auto-configure the service so it appears active (not unconfigured)
        let repoPath = result.workspaceConfig.repos.first { $0.path == serviceName }?.path ?? serviceName
        let configResult = try AIBWorkspaceCore.configureServices(
            workspaceRoot: workspace.rootURL.path,
            path: repoPath,
            runtimes: [template.runtime.rawValue]
        )

        // Override the auto-detected kind if it differs from user intent
        let namespace = configResult.workspaceConfig.repos.first { $0.path == repoPath }?.servicesNamespace ?? serviceName
        let namespacedID = "\(namespace)/main"
        let detectedKind = configResult.workspaceConfig.repos
            .first { $0.path == repoPath }?.services?
            .first.flatMap { $0.kind.flatMap(AIBServiceKind.init(rawValue:)) }
        if detectedKind != serviceKind {
            try AIBWorkspaceCore.updateServiceKind(
                workspaceRoot: workspace.rootURL.path,
                namespacedServiceID: namespacedID,
                kind: serviceKind.rawValue
            )
        }

        await loadWorkspace(at: workspace.rootURL)
        lastErrorMessage = nil
    }

    func addDroppedRepositories(_ urls: [URL]) async {
        dropLogger.info("[DROP] addDroppedRepositories called: \(urls.map(\.path))")
        guard workspace != nil else {
            dropLogger.error("[DROP] No workspace open")
            setError("Open a workspace first.")
            return
        }

        for url in urls {
            await addRepoReference(at: url.standardizedFileURL)
        }
    }

    // MARK: - Clone Repository

    func cloneRepository() {
        guard let workspace else {
            cloneError = "Open a workspace first."
            return
        }

        let trimmed = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cloneError = "Repository URL is empty."
            return
        }

        cloneInProgress = true
        cloneError = nil
        cloneOutput = ""

        let workspaceRoot = workspace.rootURL.path
        dropLogger.info("[CLONE] Starting clone: \(trimmed) into \(workspaceRoot)")

        Task {
            do {
                let escapedRoot = "'" + workspaceRoot.replacingOccurrences(of: "'", with: "'\\''") + "'"
                let escapedURL = "'" + trimmed.replacingOccurrences(of: "'", with: "'\\''") + "'"
                let command = "cd \(escapedRoot) && git clone \(escapedURL)"
                let result = try await ShellProbe.run(command: command, timeout: .seconds(300))

                if result.exitCode == 0 {
                    dropLogger.info("[CLONE] Success, rescanning workspace")
                    _ = try AIBWorkspaceCore.rescanWorkspace(workspaceRoot: workspaceRoot)
                    await loadWorkspace(at: workspace.rootURL)
                    cloneInProgress = false
                    showCloneSheet = false
                } else {
                    dropLogger.error("[CLONE] Failed with exit code \(result.exitCode): \(result.stderr)")
                    cloneError = result.stderr.isEmpty ? "Clone failed (exit code \(result.exitCode))" : result.stderr
                    cloneInProgress = false
                }
            } catch {
                dropLogger.error("[CLONE] Error: \(error.localizedDescription)")
                cloneError = error.localizedDescription
                cloneInProgress = false
            }
        }
    }

    func cleanupCloneState() {
        cloneURL = ""
        cloneInProgress = false
        cloneOutput = ""
        cloneError = nil
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
        case .issue:
            break
        case .skill:
            break
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
            setError("Open a workspace first.")
            return
        }
        let workspaceYAMLPath = workspace.rootURL
            .appendingPathComponent(".aib/workspace.yaml")
            .standardizedFileURL
            .path
        guard FileManager.default.fileExists(atPath: workspaceYAMLPath) else {
            setError("Workspace is not initialized for emulator (.aib/workspace.yaml not found). Open the correct folder or run aib init.")
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
        // Agent services require Claude Code CLI for local execution (subscription auth).
        let hasAgentServices = workspace.services.contains { $0.serviceKind == .agent }
        if hasAgentServices && !isClaudeCodeAvailable {
            setError("Claude Code is not installed. Install it to run agent services locally (no API cost).\nhttps://claude.ai/download")
            appendAIBSystemLogLine("Claude Code CLI not found. Agent services require Claude Code for local execution.")
            registerIssue(
                severity: .error,
                sourceTitle: "AIB Runtime",
                message: "Claude Code CLI not installed. Required for local agent execution.",
                serviceSelectionID: nil,
                repoID: nil
            )
            emulatorState = .error("Claude Code not installed")
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
        mcpConnectionStatusByConnectionID = [:]
        runtimeIssues = []
        rebuildAllSidebarStatuses()
        if effectiveGatewayPort != requestedGatewayPort {
            appendAIBSystemLogLine("Gateway port \(requestedGatewayPort) is busy. Falling back to \(effectiveGatewayPort).")
            utilityPanelMode = .aibRuntime
            showUtilityPanel = true
        }
        do {
            let additionalEnv = (UserDefaults.standard.dictionary(forKey: AppSettingsKey.userEnvironmentVariables) as? [String: String]) ?? [:]
            let result = try await emulatorController.start(
                workspaceURL: workspace.rootURL,
                gatewayPort: effectiveGatewayPort,
                additionalEnvironment: additionalEnv
            )
            emulatorState = .running(pid: result.pid, port: effectiveGatewayPort)
            RunEmulatorTip.hasStartedEmulator = true
            lastErrorMessage = nil
        } catch {
            emulatorState = .error(error.localizedDescription)
            setError("Failed to start emulator on port \(effectiveGatewayPort): \(error.localizedDescription)")
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
            setError("Failed to stop emulator: \(error.localizedDescription)")
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
            editorService.open(url: fileURL, preferredEditor: preferredEditorApp)
            return
        }
        if let service = selectedService(),
           let parentRepo = repo(by: service.repoID) {
            editorService.open(url: parentRepo.rootURL, preferredEditor: preferredEditorApp)
            return
        }
        if let repo = selectedRepo() {
            editorService.open(url: repo.rootURL, preferredEditor: preferredEditorApp)
            return
        }
        if let workspace {
            editorService.open(url: workspace.rootURL, preferredEditor: preferredEditorApp)
        }
    }

    func openExecutionDirectoryEntry(
        _ entry: AIBExecutionDirectoryEntry,
        for service: AIBServiceModel
    ) {
        guard let rootPath = service.executionDirectoryPath else { return }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let targetURL = rootURL.appendingPathComponent(entry.relativePath, isDirectory: entry.kind == .directory)
        editorService.open(url: targetURL, preferredEditor: preferredEditorApp)
    }

    func openExecutionDirectoryRoot(for service: AIBServiceModel) {
        guard let rootPath = service.executionDirectoryPath else { return }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        editorService.open(url: rootURL, preferredEditor: preferredEditorApp)
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
        case .issue:
            return nil
        case .skill:
            return nil
        case nil:
            return nil
        }
    }

    func selectedService() -> AIBServiceModel? {
        guard case .service(let id) = selection else { return nil }
        return service(by: id)
    }

    func selectedSkill() -> AIBSkillDefinition? {
        guard case .skill(let id) = selection else { return nil }
        return workspace?.skills.first(where: { $0.id == id })
    }

    /// Services that have this skill assigned.
    func servicesWithSkill(_ skillID: String) -> [AIBServiceModel] {
        guard let workspace else { return [] }
        return workspace.services.filter {
            $0.assignedSkillIDs.contains(skillID) || $0.nativeSkillIDs.contains(skillID)
        }
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
            if let card = agentCardCache.card(for: service.id) {
                session.updateAgentCard(card)
            }
            return session
        }
        return createSession(for: service, activate: true)
    }

    @discardableResult
    func createSession(for service: AIBServiceModel, activate: Bool) -> ChatSession {
        let card = agentCardCache.card(for: service.id)
        let runner: any AgentRunner = makeLocalRunner(for: service)
        let context = makeRunnerContext(for: service)
        let session = ChatSession(
            serviceID: service.id,
            runner: runner,
            context: context,
            agentCard: card
        )
        let namespacedID = service.namespacedID
        session.logHandler = { [weak self] line in
            guard let self else { return }
            var output = self.serviceLogOutputByServiceID[namespacedID, default: ""]
            output.append(line)
            if output.count > 120_000 {
                output.removeFirst(output.count - 120_000)
            }
            self.serviceLogOutputByServiceID[namespacedID] = output
        }
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
        service.serviceKind == .agent
    }

    /// Whether Claude Code CLI is installed and available for local agent execution.
    var isClaudeCodeAvailable: Bool {
        ClaudeCodeConfiguration().isInstalled
    }

    /// Create the local runner for a service using Claude Code CLI (subscription auth).
    private func makeLocalRunner(for service: AIBServiceModel) -> any AgentRunner {
        return ClaudeCodeAgentRunner(model: service.model)
    }

    /// Build the runner context for a local session.
    private func makeRunnerContext(for service: AIBServiceModel) -> AgentRunnerContext {
        let sanitizedID = service.namespacedID.replacingOccurrences(of: "/", with: "__")
        let mcpConfigPath: String? = workspace.map { ws in
            ws.rootURL
                .appendingPathComponent(".aib/generated/runtime/mcp/\(sanitizedID)/.mcp.json")
                .standardizedFileURL.path
        }
        let skillOverlayPath: String? = workspace.map { ws in
            ws.rootURL
                .appendingPathComponent(".aib/generated/runtime/skills/\(sanitizedID)")
                .standardizedFileURL.path
        }
        return AgentRunnerContext(
            serviceID: service.id,
            mcpConfigPath: mcpConfigPath,
            executionDirectory: service.executionDirectoryPath,
            skillOverlayPath: skillOverlayPath
        )
    }

    private func a2aBaseURL(for service: AIBServiceModel) -> URL {
        let port = gatewayPort
        let urlString = "http://127.0.0.1:\(port)\(service.mountPath)"
        return URL(string: urlString) ?? URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Create a chat session targeting the deployed (remote) endpoint.
    @discardableResult
    func createRemoteSession(for service: AIBServiceModel, deployedURL: URL, activate: Bool) -> ChatSession {
        let rpcPath = service.a2aProfile?.rpcPath ?? "/a2a"
        let card = agentCardCache.card(for: service.id)
        let runner: any AgentRunner = A2AAgentRunner(baseURL: deployedURL, rpcPath: rpcPath)
        let context = AgentRunnerContext(serviceID: service.id)
        let session = ChatSession(
            serviceID: service.id,
            runner: runner,
            context: context,
            agentCard: card,
            title: "Remote"
        )
        var sessions = chatSessionsByService[service.id] ?? []
        sessions.insert(session, at: 0)
        chatSessionsByService[service.id] = sessions
        if activate {
            activeSessionIDByService[service.id] = session.id
        }
        return session
    }

    /// Returns the first deployed endpoint URL for the given service, if available.
    func deployedURL(for service: AIBServiceModel) -> URL? {
        service.endpoints.values.first.flatMap { URL(string: $0) }
    }

    /// Returns the deployed endpoint URL for a specific provider.
    func deployedURL(for service: AIBServiceModel, providerID: String) -> URL? {
        service.endpoints[providerID].flatMap { URL(string: $0) }
    }

    /// Open a chat targeting a deployed (remote) agent.
    /// Called from DeployCompletedView when user clicks "Chat".
    func openRemoteChat(serviceResultID: String, deployedURL: URL) {
        guard let workspace else { return }
        // serviceResultID is the namespaced ServiceID (e.g. "agent/node")
        guard let service = workspace.services.first(where: {
            $0.namespacedID == serviceResultID
        }) else { return }
        let session = createRemoteSession(for: service, deployedURL: deployedURL, activate: true)
        openPiPChat(serviceID: service.id, sessionID: session.id)
    }

    private func fetchAgentCardsForReadyServices(snapshots: [AIBServiceRuntimeSnapshot]) {
        guard let workspace else { return }
        for snapshot in snapshots where snapshot.lifecycleState == .ready {
            guard let service = workspace.services.first(where: { $0.namespacedID == snapshot.serviceID }),
                  service.serviceKind == .agent else { continue }
            let baseURL = a2aBaseURL(for: service)
            let cardPath = service.a2aProfile?.cardPath ?? "/.well-known/agent.json"
            agentCardCache.fetchCard(serviceID: service.id, baseURL: baseURL, cardPath: cardPath)
        }
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

    func sidebarServiceStatus(for service: AIBServiceModel) -> SidebarServiceStatus? {
        sidebarServiceStatusByServiceID[service.id]?.status
    }

    func sidebarServiceStatusReason(for service: AIBServiceModel) -> String? {
        sidebarServiceStatusByServiceID[service.id]?.reason
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
            setError("Only Agent services can create connections.")
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
            setError("Connections can target Agent or MCP services only.")
            return
        }

        self.workspace = workspace
        lastErrorMessage = nil
        Task { await saveFlowConnections() }
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
        lastErrorMessage = nil
        Task { await saveFlowConnections() }
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
            setError("Failed to save Flow connections: \(error.localizedDescription)")
        }
    }

    func switchRepoRuntime(repoID: String, runtime: String) async {
        guard let workspace else { return }
        guard let repo = workspace.repos.first(where: { $0.id == repoID }) else { return }
        do {
            let repoPath = WorkspaceDiscovery.relativePath(
                from: workspace.rootURL,
                to: repo.rootURL
            )
            _ = try AIBWorkspaceCore.updateRepoRuntime(
                workspaceRoot: workspace.rootURL.path,
                repoPath: repoPath,
                runtime: runtime
            )
            _ = try AIBWorkspaceCore.syncWorkspace(workspaceRoot: workspace.rootURL.path)
            await loadWorkspace(at: workspace.rootURL)
            lastErrorMessage = nil
        } catch {
            setError("Failed to switch runtime: \(error.localizedDescription)")
        }
    }

    func configureServices(repoID: String, runtimes: [String]) async {
        guard let workspace else { return }
        guard let repo = workspace.repos.first(where: { $0.id == repoID }) else { return }
        do {
            let repoPath = WorkspaceDiscovery.relativePath(
                from: workspace.rootURL,
                to: repo.rootURL
            )
            _ = try AIBWorkspaceCore.configureServices(
                workspaceRoot: workspace.rootURL.path,
                path: repoPath,
                runtimes: runtimes
            )
            _ = try AIBWorkspaceCore.syncWorkspace(workspaceRoot: workspace.rootURL.path)
            await loadWorkspace(at: workspace.rootURL)
            lastErrorMessage = nil
        } catch {
            setError("Failed to configure services: \(error.localizedDescription)")
        }
    }

    func requestRemoveService(namespacedServiceID: String, displayName: String) {
        serviceRemovalTarget = ServiceRemovalTarget(
            namespacedServiceID: namespacedServiceID,
            displayName: displayName
        )
        showServiceRemovalDialog = true
    }

    func confirmRemoveService() async {
        guard let workspace, let target = serviceRemovalTarget else { return }
        let namespacedServiceID = target.namespacedServiceID
        serviceRemovalTarget = nil
        showServiceRemovalDialog = false
        do {
            _ = try AIBWorkspaceCore.removeService(
                workspaceRoot: workspace.rootURL.path,
                namespacedServiceID: namespacedServiceID
            )
            _ = try AIBWorkspaceCore.syncWorkspace(workspaceRoot: workspace.rootURL.path)
            await loadWorkspace(at: workspace.rootURL)
            lastErrorMessage = nil
        } catch {
            setError("Failed to remove service: \(error.localizedDescription)")
        }
    }

    func removeServiceFromFlow(namespacedServiceID: String) async {
        guard let workspace else { return }
        do {
            _ = try AIBWorkspaceCore.removeService(
                workspaceRoot: workspace.rootURL.path,
                namespacedServiceID: namespacedServiceID
            )
            _ = try AIBWorkspaceCore.syncWorkspace(workspaceRoot: workspace.rootURL.path)
            await loadWorkspace(at: workspace.rootURL)
            lastErrorMessage = nil
        } catch {
            setError("Failed to remove service: \(error.localizedDescription)")
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
            setError("Failed to update MCP profile: \(error.localizedDescription)")
        }
    }

    func updateServiceKind(namespacedServiceID: String, kind: AIBServiceKind) async {
        guard let workspace else { return }
        let kindString: String = switch kind {
        case .agent: "agent"
        case .mcp: "mcp"
        case .unknown: "unknown"
        }
        do {
            try AIBWorkspaceCore.updateServiceKind(
                workspaceRoot: workspace.rootURL.path,
                namespacedServiceID: namespacedServiceID,
                kind: kindString
            )
            _ = try AIBWorkspaceCore.syncWorkspace(workspaceRoot: workspace.rootURL.path)
            await loadWorkspace(at: workspace.rootURL)
            lastErrorMessage = nil
        } catch {
            setError("Failed to update service kind: \(error.localizedDescription)")
        }
    }

    func updateServiceModel(namespacedServiceID: String, model: String?) async {
        guard let workspace else { return }
        do {
            try AIBWorkspaceCore.updateServiceModel(
                workspaceRoot: workspace.rootURL.path,
                namespacedServiceID: namespacedServiceID,
                model: model
            )
            _ = try AIBWorkspaceCore.syncWorkspace(workspaceRoot: workspace.rootURL.path)
            await loadWorkspace(at: workspace.rootURL)
            lastErrorMessage = nil
        } catch {
            setError("Failed to update model: \(error.localizedDescription)")
        }
    }

    // MARK: - Skill Management (Workspace)

    /// Import a skill from the user library into the workspace and sync.
    func importSkill(skillID: String) async {
        guard let workspace else { return }
        do {
            try AIBWorkspaceCore.importSkill(workspaceRoot: workspace.rootURL.path, skillID: skillID)
            _ = try AIBWorkspaceCore.syncWorkspace(workspaceRoot: workspace.rootURL.path)
            await loadWorkspace(at: workspace.rootURL)
            lastErrorMessage = nil
        } catch {
            setError("Failed to import skill: \(error.localizedDescription)")
        }
    }

    func removeSkillFromWorkspace(skillID: String) async {
        guard let workspace else { return }
        do {
            try AIBWorkspaceCore.removeSkill(workspaceRoot: workspace.rootURL.path, skillID: skillID)
            _ = try AIBWorkspaceCore.syncWorkspace(workspaceRoot: workspace.rootURL.path)
            await loadWorkspace(at: workspace.rootURL)
            lastErrorMessage = nil
        } catch {
            setError("Failed to remove skill: \(error.localizedDescription)")
        }
    }

    func assignSkill(skillID: String, namespacedServiceID: String) async {
        guard let workspace else { return }
        do {
            if let skill = workspace.skills.first(where: { $0.id == skillID }),
               !skill.isWorkspaceManaged,
               let bundleRootPath = skill.bundleRootPath {
                try AIBWorkspaceCore.importSkillBundle(
                    workspaceRoot: workspace.rootURL.path,
                    skillID: skillID,
                    sourcePath: bundleRootPath
                )
            }
            try AIBWorkspaceCore.assignSkill(
                workspaceRoot: workspace.rootURL.path,
                skillID: skillID,
                namespacedServiceID: namespacedServiceID
            )
            _ = try AIBWorkspaceCore.syncWorkspace(workspaceRoot: workspace.rootURL.path)
            await loadWorkspace(at: workspace.rootURL)
            lastErrorMessage = nil
        } catch {
            setError("Failed to assign skill: \(error.localizedDescription)")
        }
    }

    func unassignSkill(skillID: String, namespacedServiceID: String) async {
        guard let workspace else { return }
        do {
            try AIBWorkspaceCore.unassignSkill(
                workspaceRoot: workspace.rootURL.path,
                skillID: skillID,
                namespacedServiceID: namespacedServiceID
            )
            _ = try AIBWorkspaceCore.syncWorkspace(workspaceRoot: workspace.rootURL.path)
            await loadWorkspace(at: workspace.rootURL)
            lastErrorMessage = nil
        } catch {
            setError("Failed to unassign skill: \(error.localizedDescription)")
        }
    }

    /// Returns workspace-level skill definitions (for deployment).
    func workspaceSkills() -> [AIBSkillDefinition] {
        workspace?.skills ?? []
    }

    /// Returns skill definitions assigned to a given service.
    func assignedSkills(for service: AIBServiceModel) -> [AIBSkillDefinition] {
        guard let workspace else { return [] }
        let skillIDs = Set(service.assignedSkillIDs).union(service.nativeSkillIDs)
        return skillIDs.compactMap { skillID in
            workspace.skills.first(where: { $0.id == skillID })
        }
        .sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Returns workspace skills NOT yet assigned to a given service.
    func unassignedSkills(for service: AIBServiceModel) -> [AIBSkillDefinition] {
        guard let workspace else { return [] }
        let assignedSet = Set(service.assignedSkillIDs).union(service.nativeSkillIDs)
        return workspace.skills.filter { !assignedSet.contains($0.id) }
    }

    func isExplicitlyAssigned(skillID: String, to service: AIBServiceModel) -> Bool {
        service.assignedSkillIDs.contains(skillID)
    }

    func isNativelyAvailable(skillID: String, for service: AIBServiceModel) -> Bool {
        service.nativeSkillIDs.contains(skillID)
    }

    // MARK: - Skill Library (User-level)

    /// Create a skill in the user library (`~/.aib/skills/`).
    func createLibrarySkill(name: String, description: String?, instructions: String?, tags: [String]) async {
        do {
            try AIBWorkspaceCore.createLibrarySkill(
                name: name,
                description: description,
                instructions: instructions,
                tags: tags
            )
            lastErrorMessage = nil
        } catch {
            setError("Failed to create skill: \(error.localizedDescription)")
        }
    }

    /// Delete a skill from the user library.
    func deleteLibrarySkill(id: String) async {
        do {
            try AIBWorkspaceCore.deleteLibrarySkill(id: id)
            lastErrorMessage = nil
        } catch {
            setError("Failed to delete skill: \(error.localizedDescription)")
        }
    }

    /// List all skills in the user library.
    func librarySkills() -> [AIBSkillDefinition] {
        (try? AIBWorkspaceCore.listLibrarySkills()) ?? []
    }

    // MARK: - Skill Registry (Remote)

    /// List skills available in the remote registry.
    func listRegistrySkills() async throws -> [AIBWorkspaceCore.RegistrySkillEntry] {
        try await AIBWorkspaceCore.listRegistrySkills()
    }

    /// Download a skill from the remote registry into the user library.
    func downloadRegistrySkill(id: String) async {
        do {
            try await AIBWorkspaceCore.downloadRegistrySkill(id: id)
            lastErrorMessage = nil
        } catch {
            setError("Failed to download skill: \(error.localizedDescription)")
        }
    }

    func startDeploy() {
        guard let workspace else { return }
        if hasUnsavedFlowChanges {
            setError("Save topology changes before deploying.")
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
                cloudSettingsOpenedForDeploy = true
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
        let shouldResumeDeploy = cloudSettingsOpenedForDeploy
        cloudSettingsOpenedForDeploy = false

        guard let workspace else { return }

        if shouldResumeDeploy {
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
        }

        refreshEnvironmentStatus()
    }

    /// Open cloud settings from menu bar (independent of deploy flow).
    func openCloudSettings() {
        showCloudSettings = true
    }

    var canSwitchDeployGCloudContext: Bool {
        switch deployPhase {
        case .idle, .reviewing, .failed, .cancelled:
            true
        default:
            false
        }
    }

    var isSwitchingDeployGCloudContext: Bool {
        isSwitchingGCloudAccount || isSwitchingGCloudProject
    }

    var displayDeployGCloudProject: String? {
        configuredGCloudProject ?? activeGCloudProject
    }

    /// Run prerequisite tool-installation checks for the build backend and cloud provider.
    /// and update toolbar indicators. Called on workspace load and cloud settings dismiss.
    func selectEditorApp(_ editor: ExternalEditorApp) {
        preferredEditorApp = editor
        ExternalEditorSettings.preferredEditorID = editor.id
    }

    func launchEditorApp() {
        guard let editor = preferredEditorApp else { return }
        editorService.launch(editor)
    }

    func refreshEnvironmentStatus() {
        refreshPreferredApplications()

        guard let workspace else {
            buildBackendCheckResult = nil
            cloudProviderCheckResult = nil
            detectedProvider = nil
            clearGCloudContext()
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

            let toolbarCheckIDs = provider.prerequisiteCheckIDs.union([.buildBackendAvailable])
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

            let buildBackendResult = results.first(where: { $0.id == .buildBackendAvailable })
            let cloudPrereqID = provider.prerequisiteCheckIDs.first(where: { $0 != .buildBackendAvailable })
            let cloudResult = cloudPrereqID.flatMap { id in results.first(where: { $0.id == id }) }

            self.detectedProvider = provider
            self.buildBackendCheckResult = buildBackendResult
            self.cloudProviderCheckResult = cloudResult
            self.isCheckingEnvironment = false
            if provider.providerID == "gcp-cloudrun" {
                self.refreshGCloudDeployContext(
                    workspaceRoot: workspace.rootURL.path,
                    providerID: provider.providerID
                )
            } else {
                self.clearGCloudContext()
            }
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
                if provider.providerID == "gcp-cloudrun" {
                    refreshGCloudDeployContext(
                        workspaceRoot: workspace.rootURL.path,
                        providerID: provider.providerID
                    )
                }
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

    private func refreshPreferredApplications() {
        installedEditorApps = ExternalEditorApp.detectInstalled()
        preferredEditorApp = ExternalEditorSettings.resolvePreferred(from: installedEditorApps)
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

    func refreshGCloudDeployContext() {
        guard let workspace else {
            clearGCloudContext()
            return
        }

        let providerID: String
        switch deployPhase {
        case .reviewing(let plan), .secretsInput(let plan, _), .applying(let plan):
            providerID = plan.targetConfig.providerID
        case .completed(let result):
            providerID = result.plan.targetConfig.providerID
        default:
            if let detectedProvider {
                providerID = detectedProvider.providerID
            } else {
                do {
                    providerID = try DeploymentProviderRegistry.detect(
                        workspaceRoot: workspace.rootURL.path
                    ).providerID
                } catch {
                    clearGCloudContext()
                    return
                }
            }
        }

        refreshGCloudDeployContext(
            workspaceRoot: workspace.rootURL.path,
            providerID: providerID
        )
    }

    func switchGCloudAccount(to account: String) async {
        guard let workspace else { return }
        guard canSwitchDeployGCloudContext else { return }
        guard activeGCloudAccount != account else { return }

        isSwitchingGCloudAccount = true
        gcloudContextErrorMessage = nil
        defer { isSwitchingGCloudAccount = false }

        do {
            try await gcloudContextService.switchAccount(to: account)
            await applyRefreshedGCloudContext(
                workspaceRoot: workspace.rootURL.path,
                providerID: "gcp-cloudrun"
            )
            restartDeployPipelineForContextChange()
            refreshEnvironmentStatus()
        } catch {
            gcloudContextErrorMessage = "Failed to switch Google account: \(error.localizedDescription)"
        }
    }

    func switchGCloudProject(to projectID: String) async {
        guard let workspace else { return }
        guard canSwitchDeployGCloudContext else { return }
        guard displayDeployGCloudProject != projectID else { return }

        isSwitchingGCloudProject = true
        gcloudContextErrorMessage = nil
        defer { isSwitchingGCloudProject = false }

        do {
            try await gcloudContextService.switchProject(to: projectID)
            try persistConfiguredGCloudProject(
                projectID,
                workspaceRoot: workspace.rootURL.path,
                providerID: "gcp-cloudrun"
            )
            configuredGCloudProject = projectID
            await applyRefreshedGCloudContext(
                workspaceRoot: workspace.rootURL.path,
                providerID: "gcp-cloudrun"
            )
            restartDeployPipelineForContextChange()
            refreshEnvironmentStatus()
        } catch {
            gcloudContextErrorMessage = "Failed to switch Google Cloud project: \(error.localizedDescription)"
        }
    }

    private func refreshGCloudDeployContext(
        workspaceRoot: String,
        providerID: String
    ) {
        guard providerID == "gcp-cloudrun" else {
            clearGCloudContext()
            return
        }

        gcloudContextTask?.cancel()
        gcloudContextErrorMessage = nil
        isRefreshingGCloudContext = true
        gcloudContextTask = Task { [weak self] in
            guard let self else { return }
            await self.applyRefreshedGCloudContext(
                workspaceRoot: workspaceRoot,
                providerID: providerID
            )
        }
    }

    private func applyRefreshedGCloudContext(
        workspaceRoot: String,
        providerID: String
    ) async {
        do {
            let context = try await gcloudContextService.fetchContext()
            guard !Task.isCancelled else { return }
            let configuredProject = loadConfiguredGCloudProject(
                workspaceRoot: workspaceRoot,
                providerID: providerID
            )
            gcloudAccounts = context.accounts
            gcloudProjects = context.projects
            activeGCloudAccount = context.activeAccount
            activeGCloudProject = context.activeProject
            configuredGCloudProject = configuredProject ?? context.activeProject
            gcloudContextErrorMessage = contextWarningMessage(
                for: configuredProject ?? context.activeProject,
                availableProjects: context.projects
            )
        } catch {
            guard !Task.isCancelled else { return }
            gcloudContextErrorMessage = error.localizedDescription
            gcloudAccounts = []
            gcloudProjects = []
            activeGCloudAccount = nil
            activeGCloudProject = nil
            configuredGCloudProject = loadConfiguredGCloudProject(
                workspaceRoot: workspaceRoot,
                providerID: providerID
            )
        }
        isRefreshingGCloudContext = false
    }

    private func clearGCloudContext() {
        gcloudContextTask?.cancel()
        gcloudContextTask = nil
        gcloudAccounts = []
        gcloudProjects = []
        activeGCloudAccount = nil
        activeGCloudProject = nil
        configuredGCloudProject = nil
        gcloudContextErrorMessage = nil
        isRefreshingGCloudContext = false
        isSwitchingGCloudAccount = false
        isSwitchingGCloudProject = false
    }

    private func loadConfiguredGCloudProject(
        workspaceRoot: String,
        providerID: String
    ) -> String? {
        do {
            let config = try configStore.load(
                workspaceRoot: workspaceRoot,
                providerID: providerID
            )
            let project = config.providerConfig["gcpProject"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let project, !project.isEmpty {
                return project
            }
            return nil
        } catch {
            return nil
        }
    }

    private func persistConfiguredGCloudProject(
        _ projectID: String,
        workspaceRoot: String,
        providerID: String
    ) throws {
        var config = try configStore.load(
            workspaceRoot: workspaceRoot,
            providerID: providerID
        )
        config.providerConfig["gcpProject"] = projectID
        try configStore.save(workspaceRoot: workspaceRoot, config: config)
    }

    private func contextWarningMessage(
        for configuredProject: String?,
        availableProjects: [GCloudProject]
    ) -> String? {
        guard let configuredProject, !configuredProject.isEmpty else { return nil }
        guard !availableProjects.isEmpty else { return nil }
        let containsConfigured = availableProjects.contains { $0.projectID == configuredProject }
        guard !containsConfigured else { return nil }
        return "Deploy target project '\(configuredProject)' is not available for the active Google account."
    }

    private func restartDeployPipelineForContextChange() {
        guard showDeploySheet else { return }

        switch deployPhase {
        case .reviewing, .failed, .cancelled:
            deployController.cancel()
            deployController.reset()
            deployPhase = .idle
            beginDeployPipeline()
        default:
            break
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
            appendDeployLogLine(
                level: entry.level,
                message: "\(servicePrefix)\(entry.message)",
                timestamp: entry.timestamp,
                elapsedSeconds: entry.elapsedSeconds
            )
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
        case .secretsInput(_, let requiredSecrets):
            appendDeployLogLine(level: .info, message: "Secrets required: \(requiredSecrets.joined(separator: ", "))")
        case .applying:
            appendDeployLogLine(level: .info, message: "Applying deploy plan...")
        case .completed(let result):
            storeDeployedURLs(from: result)
            appendDeployLogLine(level: .info, message: "Deploy completed: \(result.serviceResults.count) service(s)")
        case .failed(let error):
            appendDeployLogLine(level: .error, message: "Deploy failed (\(error.phase)): \(error.message)")
        case .cancelled:
            appendDeployLogLine(level: .warning, message: "Deploy cancelled")
        }
    }

    private func storeDeployedURLs(from result: AIBDeployResult) {
        guard let workspace else { return }
        let providerID = result.plan.targetConfig.providerID

        // Build a mapping of namespacedServiceID → [providerID: url]
        var endpointsByNamespacedID: [String: [String: String]] = [:]
        for serviceResult in result.serviceResults where serviceResult.success {
            guard let urlString = serviceResult.deployedURL else { continue }
            // serviceResult.id is the namespaced ServiceID (e.g. "agent/node")
            if let service = workspace.services.first(where: {
                $0.namespacedID == serviceResult.id
            }) {
                endpointsByNamespacedID[service.namespacedID] = [providerID: urlString]
            }
        }

        guard !endpointsByNamespacedID.isEmpty else { return }

        Task {
            do {
                try AIBWorkspaceCore.updateServiceEndpoints(
                    workspaceRoot: workspace.rootURL.path,
                    endpointsByNamespacedServiceID: endpointsByNamespacedID
                )
                await loadWorkspace(at: workspace.rootURL)
            } catch {
                setError("Failed to save deployed endpoints: \(error.localizedDescription)")
            }
        }
    }

    private func positionedFlowNodes(_ services: [AIBServiceModel], x: CGFloat) -> [FlowNodeModel] {
        services.enumerated().map { index, service in
            FlowNodeModel(
                id: service.id,
                namespacedID: service.namespacedID,
                displayName: service.packageName,
                serviceKind: service.serviceKind,
                position: CGPoint(x: x, y: CGFloat(60 + index * 80)),
                model: service.model
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
        guard service.serviceKind == .agent else {
            return "Chat is only available for agent services."
        }
        if let error = agentCardCache.errorsByServiceID[service.id] {
            return "Agent Card fetch failed: \(error)"
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
        emulatorOutput.append("\(isoTimestampString()) [aib][app][info] \(message)\n")
        if emulatorOutput.count > 200_000 {
            emulatorOutput.removeFirst(emulatorOutput.count - 200_000)
        }
    }

    private func setError(_ message: String) {
        lastErrorMessage = message
        emulatorOutput.append("\(isoTimestampString()) [aib][app][error] \(message)\n")
        if emulatorOutput.count > 200_000 {
            emulatorOutput.removeFirst(emulatorOutput.count - 200_000)
        }
    }

    private func appendDeployLogLine(
        level: Logging.Logger.Level,
        message: String,
        timestamp: Date = .now,
        elapsedSeconds: TimeInterval? = nil
    ) {
        let elapsedLabel: String
        if let elapsedSeconds {
            elapsedLabel = String(format: " [t+%.1fs]", elapsedSeconds)
        } else {
            elapsedLabel = ""
        }
        emulatorOutput.append("\(isoTimestampString(from: timestamp)) [aib][deploy][\(level)]\(elapsedLabel) \(message)\n")
        if emulatorOutput.count > 200_000 {
            emulatorOutput.removeFirst(emulatorOutput.count - 200_000)
        }
    }

    private func isoTimestampString(from date: Date = .now) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
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

    private struct MCPStatusEntry: Decodable {
        let name: String?
        let status: String
        let config: MCPStatusConfig?
    }

    private struct MCPStatusConfig: Decodable {
        let type: String?
        let url: String?
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

    private func updateMCPConnectionStatus(from entry: AIBEmulatorLogEntry) {
        guard let workspace else { return }
        guard let sourceRawServiceID = extractServiceID(from: entry),
              let sourceServiceID = resolveServiceSelectionID(from: sourceRawServiceID),
              let sourceService = service(by: sourceServiceID),
              sourceService.serviceKind == .agent else {
            return
        }
        guard let statuses = parseMCPStatusEntries(from: entry.message) else { return }

        let existingConnectionIDs = flowConnections()
            .filter { $0.kind == .mcp && $0.sourceServiceID == sourceServiceID }
            .map(\.id)

        var nextStatusMap = mcpConnectionStatusByConnectionID
        for connectionID in existingConnectionIDs {
            nextStatusMap.removeValue(forKey: connectionID)
        }

        for status in statuses {
            guard let targetServiceID = resolveMCPStatusTargetServiceID(
                for: status,
                sourceService: sourceService,
                workspace: workspace
            ) else {
                continue
            }
            let connectionID = "mcp::\(sourceServiceID)->\(targetServiceID)"
            nextStatusMap[connectionID] = normalizeMCPRuntimeStatus(status.status)
        }

        mcpConnectionStatusByConnectionID = nextStatusMap
    }

    private func parseMCPStatusEntries(from message: String) -> [MCPStatusEntry]? {
        guard let statusRange = message.range(of: "MCP status:") else { return nil }
        let payload = message[statusRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return [] }
        guard let data = payload.data(using: .utf8) else { return nil }

        do {
            return try JSONDecoder().decode([MCPStatusEntry].self, from: data)
        } catch {
            return nil
        }
    }

    private func resolveMCPStatusTargetServiceID(
        for status: MCPStatusEntry,
        sourceService: AIBServiceModel,
        workspace: AIBWorkspaceSnapshot
    ) -> String? {
        let targetRefs = Set(sourceService.connections.mcpServers.compactMap(\.serviceRef))
        let candidates = workspace.services.filter { service in
            service.serviceKind == .mcp && targetRefs.contains(service.namespacedID)
        }

        guard !candidates.isEmpty else { return nil }

        if let urlString = status.config?.url,
           let url = URL(string: urlString),
           let port = url.port {
            let matchedByPort = candidates.filter { candidate in
                serviceSnapshotsByID[candidate.namespacedID]?.backendPort == port
            }
            if matchedByPort.count == 1, let matched = matchedByPort.first {
                return matched.id
            }
        }

        if let serverName = status.name {
            let normalizedServerName = normalizeMCPServerToken(serverName)
            if !normalizedServerName.isEmpty {
                let matchedByName = candidates.filter { candidate in
                    normalizeMCPServerToken(candidate.namespacedID) == normalizedServerName ||
                    normalizeMCPServerToken(candidate.localID) == normalizedServerName
                }
                if matchedByName.count == 1, let matched = matchedByName.first {
                    return matched.id
                }
            }
        }

        return candidates.count == 1 ? candidates.first?.id : nil
    }

    private func normalizeMCPServerToken(_ value: String) -> String {
        let canonical = value
            .lowercased()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        let normalized = canonical
            .map { character -> Character in
                if character.isLetter || character.isNumber || character == "-" {
                    return character
                }
                return "-"
            }
        let collapsed = String(normalized).replacingOccurrences(
            of: "-+",
            with: "-",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func normalizeMCPRuntimeStatus(_ status: String) -> MCPConnectionRuntimeStatus {
        switch status.lowercased() {
        case "connected":
            return .connected
        case "failed", "error", "disconnected":
            return .failed
        default:
            return .connecting
        }
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
        rebuildAllSidebarStatuses()
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

        let displayMessage: String
        if entry.metadata.isEmpty {
            displayMessage = entry.message
        } else {
            let metadataStr = entry.metadata.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            displayMessage = "\(entry.message) (\(metadataStr))"
        }
        registerIssue(
            severity: severity,
            sourceTitle: sourceTitle,
            message: displayMessage,
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
            updateMCPConnectionStatus(from: entry)
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
                kernelDownloadProgress = nil
                serviceSnapshotsByID = [:]
                activeServiceIDs = []
                mcpConnectionStatusByConnectionID = [:]
                rebuildAllSidebarStatuses()
            case .starting:
                emulatorState = .starting
                rebuildAllSidebarStatuses()
            case .running(let pid, let port):
                emulatorState = .running(pid: pid, port: port)
                kernelDownloadProgress = nil
                rebuildAllSidebarStatuses()
            case .stopping:
                emulatorState = .stopping
                rebuildAllSidebarStatuses()
            case .failed(let message):
                emulatorState = .error(message)
                kernelDownloadProgress = nil
                serviceSnapshotsByID = [:]
                activeServiceIDs = []
                mcpConnectionStatusByConnectionID = [:]
                setError("Failed to start emulator: \(message)")
                registerIssue(
                    severity: .error,
                    sourceTitle: "AIB Runtime",
                    message: "Failed to start emulator: \(message)",
                    serviceSelectionID: nil,
                    repoID: nil
                )
                utilityPanelMode = .aibRuntime
                showUtilityPanel = true
                rebuildAllSidebarStatuses()
            }
        case .serviceSnapshotsChanged(let snapshots):
            serviceSnapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.serviceID, $0) })
            fetchAgentCardsForReadyServices(snapshots: snapshots)
            rebuildAllSidebarStatuses()
        case .activeServicesChanged(let serviceIDs):
            activeServiceIDs = serviceIDs
        case .kernelDownloadStarted(let progress):
            kernelDownloadProgress = progress
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

    private func rebuildAllSidebarStatuses() {
        rebuildSidebarServiceStatuses()
        reportUnconfiguredRepos()
    }

    private func reportUnconfiguredRepos() {
        guard let workspace else { return }
        let repoIDsWithServices = Set(workspace.services.map(\.repoID))
        let unconfiguredRepos = workspace.repos.filter { !repoIDsWithServices.contains($0.id) }
        for repo in unconfiguredRepos {
            registerIssue(
                severity: .warning,
                sourceTitle: repo.name,
                message: "No services configured. Add services in workspace.yaml.",
                serviceSelectionID: nil,
                repoID: repo.id
            )
        }
    }

    private func rebuildSidebarServiceStatuses() {
        guard let workspace else {
            sidebarServiceStatusByServiceID = [:]
            return
        }
        var statuses: [String: SidebarServiceStatusInfo] = [:]
        for service in workspace.services {
            statuses[service.id] = sidebarStatusForService(service)
        }
        sidebarServiceStatusByServiceID = statuses
    }

    private func sidebarStatusForService(_ service: AIBServiceModel) -> SidebarServiceStatusInfo {
        if let errorIssue = firstIssueForService(serviceID: service.id, severity: .error) {
            return SidebarServiceStatusInfo(status: .error, reason: errorIssue.message)
        }
        if let warningIssue = firstIssueForService(serviceID: service.id, severity: .warning) {
            return SidebarServiceStatusInfo(status: .warning, reason: warningIssue.message)
        }
        if let snapshot = serviceSnapshotsByID[service.namespacedID] {
            let state = snapshot.lifecycleState.rawValue
            if state == "unhealthy" || state == "backoff" {
                return SidebarServiceStatusInfo(status: .error, reason: "Service is unhealthy or in backoff")
            }
            if state == "ready" {
                return SidebarServiceStatusInfo(status: .running)
            }
            if state == "starting" || state == "stopping" || state == "draining" {
                return SidebarServiceStatusInfo(status: .starting)
            }
        }
        return SidebarServiceStatusInfo(status: .configured)
    }

    private func firstIssueForService(serviceID: String, severity: RuntimeIssueSeverity) -> RuntimeIssue? {
        runtimeIssues.first { issue in
            guard issue.severity == severity else { return false }
            return issue.serviceSelectionID == serviceID
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
