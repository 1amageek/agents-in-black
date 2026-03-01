import AIBCore
import SwiftUI

// MARK: - Header Content

/// The header content for the utility panel, used inside `CollapsibleSplitView`.
struct UtilityPanelHeaderContent: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        modeSwitcher

        if model.utilityPanelMode == .serviceRuntime {
            serviceTargetMenu
        }

        if model.utilityPanelMode == .connections {
            connectionsHeaderExtras
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(UtilityPanelMode.allCases) { mode in
                Button {
                    model.utilityPanelMode = mode
                    if !model.showUtilityPanel {
                        model.showUtilityPanel = true
                    }
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(.caption)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                        .foregroundStyle(model.utilityPanelMode == mode ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .background(
                            Group {
                                if model.utilityPanelMode == mode {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.accentColor)
                                } else {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.clear)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var serviceTargetMenu: some View {
        Menu {
            ForEach(model.utilityServiceLogTargetOptions(), id: \.id) { option in
                Button {
                    model.utilityServiceLogTarget = option.id
                } label: {
                    if model.utilityServiceLogTarget == option.id {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.utilityServiceLogTargetLabel())
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .frame(maxWidth: 260, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .help("Choose which service runtime logs to display")
    }

    private var connectionsHeaderExtras: some View {
        HStack(spacing: 6) {
            Text("\(model.flowConnections().count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            if model.hasUnsavedFlowChanges {
                Button("Save") {
                    Task { await model.saveFlowConnections() }
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: - Panel Body

/// The body content of the utility panel (logs/terminal + filter footer).
struct UtilityPanelView: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        VStack(spacing: 0) {
            panelContent
            Divider()
            footer
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch model.utilityPanelMode {
        case .aibRuntime:
            EmulatorOutputView(model: model, showsHeader: false, filterText: model.utilityPanelFilterText)
        case .serviceRuntime:
            ServiceRuntimeLogsPaneView(model: model)
        case .repositoryTerminal:
            TerminalTabsView(manager: model.terminalManager, highlightedContextKey: model.selectedRepoIDForFiles)
        case .connections:
            ConnectionsListView(model: model)
        }
    }

    private var footer: some View {
        ZStack {
            Rectangle()
                .fill(.bar)

            HStack(spacing: 8) {
                filterField

                Spacer(minLength: 8)

                if showsClearButton {
                    Button {
                        clearCurrentModeOutput()
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .help(clearButtonHelp)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: 32)
        .clipped()
    }

    private var filterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Filter", text: $model.utilityPanelFilterText)
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .monospaced))

            if !model.utilityPanelFilterText.isEmpty {
                Button {
                    model.utilityPanelFilterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 220, height: 22, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var showsClearButton: Bool {
        switch model.utilityPanelMode {
        case .aibRuntime, .serviceRuntime, .repositoryTerminal:
            return true
        case .connections:
            return false
        }
    }

    private var clearButtonHelp: String {
        switch model.utilityPanelMode {
        case .aibRuntime:
            return "Clear AIB Runtime Logs"
        case .serviceRuntime:
            return "Clear Service Runtime Logs"
        case .repositoryTerminal:
            return "Clear Selected Repository Terminal Output"
        case .connections:
            return ""
        }
    }

    private func clearCurrentModeOutput() {
        switch model.utilityPanelMode {
        case .aibRuntime:
            model.clearAIBLogs()
        case .serviceRuntime:
            model.clearUtilityServiceRuntimeLogs()
        case .repositoryTerminal:
            model.terminalManager.clearSelectedOutput()
        case .connections:
            break
        }
    }
}

private struct ServiceRuntimeLogsPaneView: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        let output = model.utilityServiceRuntimeLogOutput()
        UtilityMonospacedOutputView(
            output: output,
            emptyMessage: emptyMessage,
            scrollAnchorID: "service-runtime-output-bottom",
            filterText: model.utilityPanelFilterText
        )
    }

    private var emptyMessage: String {
        "Select a service and run the emulator to view service runtime logs."
    }
}

private extension UtilityPanelMode {
    var symbolName: String {
        switch self {
        case .aibRuntime:
            return "server.rack"
        case .serviceRuntime:
            return "waveform.path.ecg"
        case .repositoryTerminal:
            return "terminal"
        case .connections:
            return "arrow.triangle.branch"
        }
    }
}
