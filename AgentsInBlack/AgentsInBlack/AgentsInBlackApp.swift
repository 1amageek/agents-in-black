import AppKit
import SwiftUI

@main
struct AgentsInBlackApp: App {
    @NSApplicationDelegateAdaptor(AgentsInBlackAppDelegate.self) private var appDelegate
    @State private var model = AgentsInBlackAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    appDelegate.setOpenHandler { [weak model] urls in
                        guard let model else { return }
                        model.openIncomingURLs(urls)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workspace…") {
                    model.createWorkspacePicker()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Open Workspace…") {
                    model.openWorkspacePicker()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }

            CommandGroup(after: .sidebar) {
                Button(model.showInspector ? "Hide Inspector" : "Show Inspector") {
                    model.showInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

final class AgentsInBlackAppDelegate: NSObject, NSApplicationDelegate {
    private var pendingOpenURLs: [URL] = []
    private var openHandler: (([URL]) -> Void)?
    private var windowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        for window in NSApp.windows {
            configureWindowAppearance(window)
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.configureWindowAppearance(window)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
    }

    func setOpenHandler(_ handler: @escaping ([URL]) -> Void) {
        openHandler = handler
        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs.removeAll()
            handler(urls)
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        deliverOpenURLs(urls)
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        deliverOpenURLs([URL(fileURLWithPath: filename)])
        return true
    }

    private func deliverOpenURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let openHandler {
            openHandler(urls)
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
    }

    private func configureWindowAppearance(_ window: NSWindow) {
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
    }
}
