import SwiftUI

struct TerminalTabDetailView: View {
    @Bindable var model: AgentsInBlackAppModel
    @Bindable var tab: TerminalTabModel
    var showsHeader: Bool = true
    var filterText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                terminalHeader
                Divider()
            }
            UtilityMonospacedOutputView(
                output: tab.output,
                emptyMessage: "Terminal output will appear here.",
                scrollAnchorID: "output-bottom",
                filterText: filterText
            )
            Divider()
            HStack(spacing: 8) {
                TextField("Run command in \(tab.repoName)", text: $tab.commandInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .controlSize(.small)
                    .onSubmit {
                        Task { await model.runTerminalCommand(for: tab.id) }
                    }
                Button {
                    Task { await model.runTerminalCommand(for: tab.id) }
                } label: {
                    Label("Run", systemImage: "return")
                }
                .controlSize(.small)
                .disabled(tab.commandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tab.isRunningCommand)
            }
            .padding(12)
            .background(.bar)
        }
    }

    private var terminalHeader: some View {
        HStack(spacing: 12) {
            Text(tab.repoName)
                .font(.headline)
            Text(abbreviatedPath(tab.cwdURL.path))
                .help(tab.cwdURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let code = tab.lastExitCode {
                Text("exit \(code)")
                    .font(.caption)
                    .foregroundStyle(code == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
            }
            if tab.isRunningCommand {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        let normalized: String
        if path == home {
            normalized = "~"
        } else if path.hasPrefix(home + "/") {
            normalized = "~" + path.dropFirst(home.count)
        } else {
            normalized = path
        }

        let limit = 64
        guard normalized.count > limit else { return normalized }

        let head = normalized.prefix(26)
        let tail = normalized.suffix(30)
        return "\(head)…\(tail)"
    }
}
