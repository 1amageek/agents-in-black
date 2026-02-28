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

                        Button {
                            model.deployToCloudRun()
                        } label: {
                            Label("Deploy", systemImage: "icloud.and.arrow.up.fill")
                        }
                        .help("Deploy to Cloud Run")
                        .disabled(model.detailSurfaceMode != .topology || model.workspace == nil)
                    }
                }
        } detail: {
            detailContent
                .navigationTitle(windowHeaderTitle)
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
                WorkspaceHeaderView(model: model)
            }

            ToolbarItem(placement: .principal) {
                IssueCountButtonView(
                    severity: .error,
                    count: model.issueCount(for: .error),
                    label: "Errors",
                    action: { model.showIssueList(filter: .error) }
                )
                IssueCountButtonView(
                    severity: .warning,
                    count: model.issueCount(for: .warning),
                    label: "Warnings",
                    action: { model.showIssueList(filter: .warning) }
                )
            }

            ToolbarItemGroup(placement: .secondaryAction) {
                Button {
                    model.openInEditor()
                } label: {
                    Label("Open Editor", systemImage: "arrow.up.right.square")
                }
                .disabled(model.workspace == nil)
                .help("Open selected repo/file in external editor")
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
            switch model.detailSurfaceMode {
            case .topology:
                FlowCanvasView(model: model)
            case .workbench:
                CollapsibleSplitView(isExpanded: $model.showUtilityPanel) {
                    ServiceWorkbenchView(model: model)
                } content: {
                    UtilityPanelView(model: model)
                } header: {
                    UtilityPanelHeaderContent(model: model)
                }
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
        if let repo = model.selectedRepo() {
            return repo.name
        }
        if let workspace = model.workspace {
            return workspace.displayName
        }
        return ""
    }
}

#Preview {
    ContentView(model: AgentsInBlackAppModel())
}
