import AIBCore
import SwiftUI
import TipKit

struct ContentView: View {
    @Bindable var model: AgentsInBlackAppModel
    private let runEmulatorTip = RunEmulatorTip()

    var body: some View {
        NavigationSplitView(columnVisibility: $model.splitViewVisibility) {
            WorkspaceSidebarView(model: model)
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            toggleSidebar()
                        } label: {
                            Image(systemName: "sidebar.leading")
                        }
                        .help("Toggle Sidebar")

                        Spacer()

                        Button {
                            Task { await model.toggleEmulator() }
                        } label: {
                            Image(systemName: model.emulatorState.isRunning ? "stop.fill" : "play.fill")
                        }
                        .help(model.emulatorState.isRunning ? "Stop Emulator" : "Run Emulator")
                        .disabled(model.emulatorState.isBusy || model.workspace == nil)
                    }
                }
        } detail: {
            detailContent
                .overlay(alignment: .top) {
                    if model.workspace != nil, !model.emulatorState.isRunning {
                        TipView(runEmulatorTip, arrowEdge: .top)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }
                }
                .navigationTitle(windowHeaderTitle)
                .toolbarTitleDisplayMode(.inline)
        }
        .inspector(isPresented: $model.showInspector) {
            SelectionInspectorView(model: model)
        }
        .toolbar {
            if model.splitViewVisibility == .detailOnly {
                ToolbarItem(placement: .navigation) {
                    Button {
                        Task { await model.toggleEmulator() }
                    } label: {
                        Image(systemName: model.emulatorState.isRunning ? "stop.fill" : "play.fill")
                    }
                    .help(model.emulatorState.isRunning ? "Stop Emulator" : "Run Emulator")
                    .disabled(model.emulatorState.isBusy || model.workspace == nil)
                }
            }

            ToolbarItem(placement: .principal) {
                ToolbarActivityView(model: model)
                    .frame(minWidth: 480)
            }

            if !(model.workspace?.missingDirectories.isEmpty ?? true) {
                ToolbarItem(placement: .principal) {
                    Button {
                        if model.splitViewVisibility != .all {
                            model.toggleSidebarVisibility()
                        }
                    } label: {
                        Label("Missing Directories", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    .help("Some directories are missing — click to show sidebar")
                }
            }

            ToolbarItem(placement: .principal) {
                Button {
                    model.startDeploy()
                } label: {
                    Label("Deploy", systemImage: "icloud.and.arrow.up.fill")
                }
                .help("Deploy to Cloud Run")
                .disabled(model.workspace == nil)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help(model.showInspector ? "Hide Inspector" : "Show Inspector")
            }
        }
        .task {
            await preloadDefaultWorkspaceIfAvailable()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.shutdown()
        }
        .onOpenURL { url in
            model.openIncomingDirectory(url)
        }
        .sheet(isPresented: $model.showDeploySheet, onDismiss: {
            model.cleanupDeployState()
        }) {
            DeploySheet(model: model)
        }
        .sheet(isPresented: $model.showCloneSheet, onDismiss: {
            model.cleanupCloneState()
        }) {
            CloneRepositorySheet(model: model)
        }
        .sheet(isPresented: $model.showCreateServiceSheet) {
            CreateServiceSheet(model: model)
        }
        .sheet(isPresented: $model.showAddSkillSheet) {
            AddSkillSheet(model: model)
        }
        .sheet(isPresented: $model.showSkillRegistrySheet) {
            SkillRegistrySheet(model: model)
        }
        .sheet(isPresented: $model.showCloudSettings, onDismiss: {
            model.onCloudSettingsDismissed()
        }) {
            if let workspace = model.workspace {
                CloudSettingsView(
                    workspaceRootPath: workspace.rootURL.path,
                    onDismiss: { model.showCloudSettings = false }
                )
            }
        }
        .confirmationDialog(
            "Remove Service",
            isPresented: $model.showServiceRemovalDialog,
            presenting: model.serviceRemovalTarget
        ) { target in
            Button("Remove \"\(target.displayName)\"", role: .destructive) {
                Task { await model.confirmRemoveService() }
            }
        } message: { target in
            Text("This will not delete any files.")
        }
        .overlay {
            RuntimeAnnouncementOverlay(center: model.runtimeAnnouncementCenter)
                .zIndex(10_000)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if model.workspace == nil {
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "Open AIB Workspace",
                    systemImage: "folder.badge.gear",
                    description: Text("Choose a workspace root that contains multiple Agent/MCP repositories.")
                )
                HStack(spacing: 12) {
                    Button("New Workspace…") {
                        model.createWorkspacePicker()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Open Workspace…") {
                        model.openWorkspacePicker()
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else {
            CollapsibleSplitView(isExpanded: $model.showUtilityPanel) {
                switch model.detailSurfaceMode {
                case .topology:
                    FlowCanvasView(model: model)
                case .workbench:
                    ServiceWorkbenchView(model: model)
                }
            } content: {
                UtilityPanelView(model: model)
            } header: {
                UtilityPanelHeaderContent(model: model)
            }
        }
    }

    private func preloadDefaultWorkspaceIfAvailable() async {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let workspaceHint = cwd.appendingPathComponent("demo")
        if FileManager.default.fileExists(atPath: workspaceHint.path) {
            await model.loadWorkspace(at: workspaceHint)
            return
        }
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent(".git").path) {
            await model.loadWorkspace(at: cwd)
        }
    }

    private func toggleSidebar() {
        model.toggleSidebarVisibility()
    }

    private var windowHeaderTitle: String {
        model.workspace?.displayName ?? ""
    }
}

#Preview {
    ContentView(model: AgentsInBlackAppModel())
}
