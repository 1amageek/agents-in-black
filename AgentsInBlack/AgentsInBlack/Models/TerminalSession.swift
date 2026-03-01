import AppKit
import Foundation
import Observation
import SwiftTerm

/// Manages a single terminal session backed by SwiftTerm's LocalProcessTerminalView.
/// The session **owns** the terminal view and its PTY process.
/// The view and process survive SwiftUI view lifecycle changes (panel close/reopen, tab switching).
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id: String
    let label: String
    let workingDirectory: URL

    private(set) var title: String
    private(set) var currentDirectory: String?
    private(set) var isRunning: Bool
    private(set) var lastExitCode: Int32?

    /// The terminal view, created once and owned by this session.
    /// Survives SwiftUI view lifecycle — SwiftTermView merely embeds it.
    let terminalView: LocalProcessTerminalView

    /// Retained delegate bridging PTY callbacks to this session.
    private let processDelegate: SessionProcessDelegate

    init(id: String, label: String, workingDirectory: URL) {
        self.id = id
        self.label = label
        self.workingDirectory = workingDirectory
        self.title = label
        self.isRunning = false

        let savedFontSize = UserDefaults.standard.double(forKey: AppSettingsKey.terminalFontSize)
        let fontSize = savedFontSize > 0 ? savedFontSize : AppSettingsDefault.terminalFontSize

        let view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        view.nativeForegroundColor = .textColor
        view.nativeBackgroundColor = .textBackgroundColor
        self.terminalView = view

        let delegate = SessionProcessDelegate()
        self.processDelegate = delegate
        view.processDelegate = delegate

        // Weak back-reference set after init completes
        delegate.session = self
    }

    /// Start the shell process. Safe to call multiple times — no-ops if already running.
    func startIfNeeded() {
        guard !isRunning else { return }

        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        if let existingPath = ProcessInfo.processInfo.environment["PATH"] {
            let newPath = (extraPaths + [existingPath]).joined(separator: ":")
            env = env.map { $0.hasPrefix("PATH=") ? "PATH=\(newPath)" : $0 }
        }

        let cwd = posixPath(workingDirectory)
        terminalView.startProcess(
            executable: "/bin/zsh",
            args: ["-l"],
            environment: env,
            execName: "-zsh",
            currentDirectory: cwd
        )
        isRunning = true
    }

    /// Send a command string to the running shell.
    func sendCommand(_ command: String) {
        guard isRunning else { return }
        let bytes = Array((command + "\n").utf8)
        terminalView.send(source: terminalView, data: bytes[...])
    }

    /// Restart the shell process.
    func restart() {
        isRunning = false
        lastExitCode = nil
        startIfNeeded()
    }

    // MARK: - Delegate Callbacks

    func updateTitle(_ newTitle: String) {
        title = newTitle
    }

    func updateCurrentDirectory(_ directory: String?) {
        guard let directory else {
            currentDirectory = nil
            return
        }
        // SwiftTerm may report a file URL string (e.g. "file://hostname/path")
        // instead of a POSIX path. Normalize to a plain path.
        if directory.hasPrefix("file://"),
           let url = URL(string: directory),
           url.isFileURL {
            currentDirectory = posixPath(url)
        } else {
            currentDirectory = directory
        }
    }

    func handleProcessTerminated(exitCode: Int32?) {
        isRunning = false
        lastExitCode = exitCode
    }

    // MARK: - Private

    /// Extract a clean POSIX path from a file URL.
    /// Uses NSURL bridge to reliably strip scheme and host from file URLs,
    /// avoiding issues where `URL.path` returns the full URL string on some macOS versions.
    private func posixPath(_ url: URL) -> String {
        if url.isFileURL, let path = (url as NSURL).filePathURL?.path, !path.isEmpty {
            return path
        }
        let standardized = url.standardizedFileURL
        let path = standardized.path(percentEncoded: false)
        if path.hasPrefix("/") && !path.contains("://") {
            return path
        }
        // Last resort: strip scheme and host manually
        return standardized.pathComponents.joined(separator: "/")
    }

    private func shellEscaped(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Process Delegate

/// Bridges LocalProcessTerminalView delegate callbacks (called from PTY thread)
/// to the @MainActor TerminalSession.
private final class SessionProcessDelegate: NSObject, LocalProcessTerminalViewDelegate {
    nonisolated(unsafe) weak var session: TerminalSession?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.session?.updateTitle(title)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor [weak self] in
            self?.session?.updateCurrentDirectory(directory)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.session?.handleProcessTerminated(exitCode: exitCode)
        }
    }
}
