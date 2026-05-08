import AIBCore
import AppKit
import SwiftUI

struct CloudRunLogsSheet: View {
    @Bindable var model: AgentsInBlackAppModel
    let serviceName: String
    let region: String
    let onClose: () -> Void

    @State private var controller: AIBCloudLogsController
    @State private var resolvedContext: LogsContext?
    @State private var initialErrorMessage: String?

    private struct LogsContext {
        let provider: any DeploymentProvider
        let targetConfig: AIBDeployTargetConfig
    }

    init(
        model: AgentsInBlackAppModel,
        serviceName: String,
        region: String,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.serviceName = serviceName
        self.region = region
        self.onClose = onClose
        self._controller = State(initialValue: AIBCloudLogsController(
            serviceName: serviceName,
            region: region
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modeBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 480)
        .task {
            await resolveContextIfNeeded()
        }
        .onDisappear {
            controller.stopTail()
        }
    }

    private func copyAllLogsToPasteboard() {
        // Snapshot ordering reverses chronologically (newest first); flip back so
        // pasted text reads top-to-bottom in time order.
        let text = controller.entries
            .reversed()
            .map(formatEntryLine)
            .joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Cloud Run Logs", systemImage: "doc.text.magnifyingglass")
                    .font(.title3.weight(.semibold))
                Text("\(serviceName) — \(region)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Spacer()
            if let last = controller.lastRefreshedAt {
                Text("Updated \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                copyAllLogsToPasteboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(controller.entries.isEmpty)
            .help("Copy all visible log entries to the clipboard")
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var modeBar: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: Binding(
                get: { controller.mode },
                set: { newValue in
                    guard let context = resolvedContext else { return }
                    controller.setMode(newValue, provider: context.provider, targetConfig: context.targetConfig)
                }
            )) {
                Text("Latest").tag(AIBCloudLogsController.Mode.latest)
                Text("Tail").tag(AIBCloudLogsController.Mode.tail)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .disabled(resolvedContext == nil)

            Spacer()

            switch controller.mode {
            case .latest:
                Button {
                    guard let context = resolvedContext else { return }
                    controller.fetchLatest(provider: context.provider, targetConfig: context.targetConfig)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(resolvedContext == nil || controller.state.isLoading)
            case .tail:
                if controller.state.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Tailing…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button {
                    controller.stopTail()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(resolvedContext == nil)
                Button {
                    guard let context = resolvedContext else { return }
                    controller.startTail(provider: context.provider, targetConfig: context.targetConfig)
                } label: {
                    Label("Restart", systemImage: "play.fill")
                }
                .disabled(resolvedContext == nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let initialErrorMessage {
            VStack(spacing: 8) {
                Label("Cannot resolve provider", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(initialErrorMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch controller.state {
            case .idle:
                placeholder("Select Refresh to load logs.", systemImage: "doc.text")
            case .loading where controller.entries.isEmpty:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading logs…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 8) {
                    Label("Failed to load logs", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("Retry") {
                        guard let context = resolvedContext else { return }
                        switch controller.mode {
                        case .latest: controller.fetchLatest(provider: context.provider, targetConfig: context.targetConfig)
                        case .tail: controller.startTail(provider: context.provider, targetConfig: context.targetConfig)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading, .loaded:
                logList
            }
        }
    }

    private func placeholder(_ text: String, systemImage: String) -> some View {
        ContentUnavailableView(text, systemImage: systemImage)
    }

    @ViewBuilder
    private var logList: some View {
        if controller.entries.isEmpty {
            ContentUnavailableView(
                "No log entries",
                systemImage: "doc.text",
                description: Text(controller.mode == .tail
                                  ? "Waiting for new entries…"
                                  : "No recent logs in the queried window.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.entries) { entry in
                        Divider().opacity(entry == controller.entries.first ? 0 : 1)
                        logRow(entry)
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func logRow(_ entry: CloudLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                severityPill(for: entry.severity)
                if let revision = entry.revisionName {
                    Text(revision)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(revision)
                }
                Spacer()
            }
            Text(entry.message)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                copyEntryToPasteboard(entry)
            } label: {
                Label("Copy Line", systemImage: "doc.on.doc")
            }
            Button {
                copyMessageToPasteboard(entry)
            } label: {
                Label("Copy Message Only", systemImage: "text.bubble")
            }
            Divider()
            Button {
                copyAllLogsToPasteboard()
            } label: {
                Label("Copy All Logs", systemImage: "doc.on.doc.fill")
            }
        }
    }

    private func formatEntryLine(_ entry: CloudLogEntry) -> String {
        let timestamp = entry.timestamp.formatted(.iso8601)
        let revision = entry.revisionName.map { " [\($0)]" } ?? ""
        return "[\(timestamp)] \(entry.severity.uppercased())\(revision) \(entry.message)"
    }

    private func copyEntryToPasteboard(_ entry: CloudLogEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(formatEntryLine(entry), forType: .string)
    }

    private func copyMessageToPasteboard(_ entry: CloudLogEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.message, forType: .string)
    }

    @ViewBuilder
    private func severityPill(for severity: String) -> some View {
        let normalized = severity.uppercased()
        let color: Color = {
            switch normalized {
            case "EMERGENCY", "ALERT", "CRITICAL", "ERROR": return .red
            case "WARNING": return .orange
            case "NOTICE", "INFO": return .blue
            case "DEBUG": return .gray
            default: return .secondary
            }
        }()
        Text(normalized)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func resolveContextIfNeeded() async {
        guard resolvedContext == nil, initialErrorMessage == nil else { return }
        guard let resolved = await model.currentDeploymentsContext() else {
            initialErrorMessage = "Workspace has no deploy provider configured. Open Target Settings first."
            return
        }
        resolvedContext = LogsContext(
            provider: resolved.provider,
            targetConfig: resolved.targetConfig
        )
        controller.fetchLatest(
            provider: resolved.provider,
            targetConfig: resolved.targetConfig
        )
    }
}
