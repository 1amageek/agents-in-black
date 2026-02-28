import Foundation
import Observation

@MainActor
@Observable
final class TerminalTabModel: Identifiable {
    let id: String
    let repoID: String
    let repoName: String
    let cwdURL: URL

    var title: String
    var commandInput: String
    var output: String
    var isRunningCommand: Bool
    var lastExitCode: Int32?

    init(repoID: String, repoName: String, cwdURL: URL) {
        self.id = repoID
        self.repoID = repoID
        self.repoName = repoName
        self.cwdURL = cwdURL
        self.title = repoName
        self.commandInput = ""
        self.output = ""
        self.isRunningCommand = false
        self.lastExitCode = nil
    }

    func appendOutput(_ text: String) {
        output.append(text)
        if !output.hasSuffix("\n") {
            output.append("\n")
        }
    }
}
