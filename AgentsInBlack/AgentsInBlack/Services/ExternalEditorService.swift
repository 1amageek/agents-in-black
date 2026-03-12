import AppKit
import Foundation

struct ExternalEditorApp: Identifiable, Hashable {
    let id: String
    let name: String
    let bundlePath: String

    var appURL: URL { URL(fileURLWithPath: bundlePath) }

    var icon: NSImage? {
        if let bundle = Bundle(url: appURL),
           let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let nsImage = loadBundleIcon(named: iconName, from: bundle)
            nsImage?.size = NSSize(width: 18, height: 18)
            if let nsImage {
                return nsImage
            }
        }

        let fallback = NSWorkspace.shared.icon(forFile: bundlePath)
        fallback.size = NSSize(width: 18, height: 18)
        return fallback
    }

    static let knownEditors: [ExternalEditorApp] = [
        ExternalEditorApp(id: "xcode", name: "Xcode", bundlePath: "/Applications/Xcode.app"),
        ExternalEditorApp(id: "cursor", name: "Cursor", bundlePath: "/Applications/Cursor.app"),
        ExternalEditorApp(id: "vscode", name: "Visual Studio Code", bundlePath: "/Applications/Visual Studio Code.app"),
        ExternalEditorApp(id: "windsurf", name: "Windsurf", bundlePath: "/Applications/Windsurf.app"),
        ExternalEditorApp(id: "zed", name: "Zed", bundlePath: "/Applications/Zed.app"),
        ExternalEditorApp(id: "nova", name: "Nova", bundlePath: "/Applications/Nova.app"),
        ExternalEditorApp(id: "coteditor", name: "CotEditor", bundlePath: "/Applications/CotEditor.app"),
    ]

    static func detectInstalled() -> [ExternalEditorApp] {
        knownEditors.filter { FileManager.default.fileExists(atPath: $0.bundlePath) }
    }

    private func loadBundleIcon(named iconName: String, from bundle: Bundle) -> NSImage? {
        let resourceName = URL(fileURLWithPath: iconName).deletingPathExtension().lastPathComponent
        let resourceExtension = URL(fileURLWithPath: iconName).pathExtension.isEmpty
            ? "icns"
            : URL(fileURLWithPath: iconName).pathExtension
        guard let iconPath = bundle.path(forResource: resourceName, ofType: resourceExtension) else {
            return nil
        }
        return NSImage(contentsOfFile: iconPath)
    }
}

enum ExternalEditorSettings {
    private static let key = "preferredExternalEditorID"

    static var preferredEditorID: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func resolvePreferred(from installed: [ExternalEditorApp]) -> ExternalEditorApp? {
        if let preferredEditorID,
           let match = installed.first(where: { $0.id == preferredEditorID }) {
            return match
        }
        return installed.first
    }
}

@MainActor
final class ExternalEditorService {
    func open(url: URL, preferredEditor: ExternalEditorApp? = nil) {
        guard let preferredEditor else {
            NSWorkspace.shared.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: preferredEditor.appURL,
            configuration: configuration
        ) { _, error in
            if error != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func launch(_ editor: ExternalEditorApp) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: editor.appURL, configuration: configuration) { _, _ in
        }
    }

}
