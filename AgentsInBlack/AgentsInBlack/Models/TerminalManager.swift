import Foundation
import Observation

/// Self-contained terminal tab manager, independent of the app model.
/// Owns terminal tabs, selection state, and provides APIs for tab lifecycle.
/// Each tab runs an independent shell process.
@MainActor
@Observable
final class TerminalManager {
    private(set) var tabs: [TerminalTabModel] = []
    var selectedTabID: String?
    private var nextID: Int = 0

    var selectedTab: TerminalTabModel? {
        if let selectedTabID, let tab = tabs.first(where: { $0.id == selectedTabID }) {
            return tab
        }
        return tabs.first
    }

    // MARK: - Tab Lifecycle

    /// Open or reuse a tab associated with a context key (e.g., repo ID).
    /// If a tab with the same `contextKey` exists, it is selected and returned.
    /// Otherwise a new tab with its own shell process is created.
    @discardableResult
    func openTab(contextKey: String, label: String, workingDirectory: URL) -> TerminalTabModel {
        if let existing = tabs.first(where: { $0.contextKey == contextKey }) {
            selectedTabID = existing.id
            return existing
        }
        return createTab(contextKey: contextKey, label: label, workingDirectory: workingDirectory)
    }

    /// Ensure a tab exists for a context key without changing the current selection.
    /// Creates a new tab if none exists, but never changes `selectedTabID`.
    @discardableResult
    func ensureTab(contextKey: String, label: String, workingDirectory: URL) -> TerminalTabModel {
        if let existing = tabs.first(where: { $0.contextKey == contextKey }) {
            return existing
        }
        let previousSelection = selectedTabID
        let tab = createTab(contextKey: contextKey, label: label, workingDirectory: workingDirectory)
        if previousSelection != nil {
            selectedTabID = previousSelection
        }
        return tab
    }

    /// Create a brand new tab with its own shell process.
    /// Always creates a new tab, never reuses.
    @discardableResult
    func newTab(label: String, workingDirectory: URL) -> TerminalTabModel {
        createTab(contextKey: nil, label: label, workingDirectory: workingDirectory)
    }

    /// Create a new tab based on the selected tab's working directory and context.
    /// Inherits `contextKey` from the source tab so all tabs for the same repo
    /// are highlighted together.
    /// Falls back to the user's home directory if no tab is selected.
    @discardableResult
    func newTabFromSelected() -> TerminalTabModel {
        let dir: URL
        let label: String
        let context: String?
        if let current = selectedTab {
            dir = current.session.currentDirectory
                .map { URL(fileURLWithPath: $0) }
                ?? current.session.workingDirectory
            label = current.repoName
            context = current.contextKey
        } else {
            dir = URL(fileURLWithPath: NSHomeDirectory())
            label = "Terminal"
            context = nil
        }
        return createTab(contextKey: context, label: label, workingDirectory: dir)
    }

    func selectTab(_ tabID: String) {
        selectedTabID = tabID
    }

    func closeTab(_ tabID: String) {
        tabs.removeAll { $0.id == tabID }
        if selectedTabID == tabID {
            selectedTabID = tabs.first?.id
        }
    }

    // MARK: - Commands

    func sendCommand(_ command: String, toTabID tabID: String) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tab.session.sendCommand(command)
    }

    func clearSelectedOutput() {
        guard let tab = selectedTab else { return }
        tab.session.sendCommand("clear")
    }

    // MARK: - Private

    private func createTab(contextKey: String?, label: String, workingDirectory: URL) -> TerminalTabModel {
        nextID += 1
        let tab = TerminalTabModel(
            id: "terminal-\(nextID)",
            contextKey: contextKey,
            repoName: label,
            workingDirectory: workingDirectory
        )
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }
}
