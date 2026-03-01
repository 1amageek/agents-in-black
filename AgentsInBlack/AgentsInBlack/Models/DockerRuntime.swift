import AppKit
import Foundation

/// Represents a Docker-compatible runtime application installed on the system.
struct DockerRuntime: Identifiable, Hashable {
    let id: String
    let name: String
    let bundlePath: String

    var appURL: URL { URL(fileURLWithPath: bundlePath) }

    /// App icon pre-sized for toolbar use.
    var icon: NSImage? {
        let image = NSWorkspace.shared.icon(forFile: bundlePath)
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    /// Well-known Docker runtime applications.
    static let knownRuntimes: [DockerRuntime] = [
        DockerRuntime(id: "orbstack", name: "OrbStack", bundlePath: "/Applications/OrbStack.app"),
        DockerRuntime(id: "docker-desktop", name: "Docker Desktop", bundlePath: "/Applications/Docker.app"),
        DockerRuntime(id: "rancher-desktop", name: "Rancher Desktop", bundlePath: "/Applications/Rancher Desktop.app"),
    ]

    /// Detect all installed Docker runtimes.
    static func detectInstalled() -> [DockerRuntime] {
        knownRuntimes.filter { FileManager.default.fileExists(atPath: $0.bundlePath) }
    }
}

// MARK: - UserDefaults Persistence

enum DockerRuntimeSettings {
    private static let key = "preferredDockerRuntimeID"

    static var preferredRuntimeID: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Resolve the preferred runtime from installed runtimes.
    /// Falls back to the first installed runtime if the preferred one is not available.
    static func resolvePreferred(from installed: [DockerRuntime]) -> DockerRuntime? {
        if let preferredID = preferredRuntimeID,
           let match = installed.first(where: { $0.id == preferredID }) {
            return match
        }
        return installed.first
    }
}
