import Foundation
import Observation

/// A terminal tab backed by a `TerminalSession`.
/// Each tab owns an independent shell process.
/// `contextKey` allows open-or-reuse semantics for sidebar navigation.
@MainActor
@Observable
final class TerminalTabModel: Identifiable {
    let id: String
    let contextKey: String?
    let repoName: String
    let session: TerminalSession

    init(id: String, contextKey: String?, repoName: String, workingDirectory: URL) {
        self.id = id
        self.contextKey = contextKey
        self.repoName = repoName
        self.session = TerminalSession(
            id: id,
            label: repoName,
            workingDirectory: workingDirectory
        )
    }
}
