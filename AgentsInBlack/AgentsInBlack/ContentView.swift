import AIBCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AgentsInBlackAppModel

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

            ToolbarItem(placement: .principal) {
                Button {
                    model.startDeploy()
                } label: {
                    Label("Deploy", systemImage: "icloud.and.arrow.up.fill")
                }
                .help("Deploy to Cloud Run")
                .disabled(model.detailSurfaceMode != .topology || model.workspace == nil)
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
                Button("Open Workspace…") {
                    model.openWorkspacePicker()
                }
                .buttonStyle(.borderedProminent)
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
