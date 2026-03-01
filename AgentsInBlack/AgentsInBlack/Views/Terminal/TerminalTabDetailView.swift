import SwiftUI

struct TerminalTabDetailView: View {
    @Bindable var tab: TerminalTabModel
    var showsHeader: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                terminalHeader
                Divider()
            }
            SwiftTermView(session: tab.session)
        }
    }

    private var terminalHeader: some View {
        HStack(spacing: 12) {
            Text(tab.repoName)
                .font(.headline)

            Text(tab.session.currentDirectory ?? abbreviatedPath(tab.session.workingDirectory.standardizedFileURL.path(percentEncoded: false)))
                .help(tab.session.workingDirectory.standardizedFileURL.path(percentEncoded: false))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if let code = tab.session.lastExitCode {
                Text("exit \(code)")
                    .font(.caption)
                    .foregroundStyle(code == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
            }

            if !tab.session.isRunning, tab.session.lastExitCode != nil {
                Button {
                    tab.session.restart()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Restart shell")
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
