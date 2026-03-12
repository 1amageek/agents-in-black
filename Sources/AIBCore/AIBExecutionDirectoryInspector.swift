import Foundation

public struct AIBExecutionDirectoryEntry: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case file
        case directory
    }

    public var relativePath: String
    public var kind: Kind

    public init(relativePath: String, kind: Kind) {
        self.relativePath = relativePath
        self.kind = kind
    }
}

public struct AIBExecutionDirectoryFile: Hashable, Sendable {
    public var relativePath: String
    public var content: Data

    public init(relativePath: String, content: Data) {
        self.relativePath = relativePath
        self.content = content
    }
}

public enum AIBExecutionDirectoryInspector {
    public static let supportedDirectoryNames: [String] = [
        ".claude",
        ".codex",
        ".agents",
    ]

    public static let supportedFileNames: [String] = [
        "AGENTS.md",
        "AGENT.md",
        "CLAUDE.md",
        "CODEX.md",
    ]

    public static func discoverEntries(at rootURL: URL) throws -> [AIBExecutionDirectoryEntry] {
        var entries: [AIBExecutionDirectoryEntry] = []
        let fm = FileManager.default

        for name in supportedDirectoryNames {
            let directoryURL = rootURL.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directoryURL.path(percentEncoded: false), isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            entries.append(AIBExecutionDirectoryEntry(relativePath: name, kind: .directory))
            try appendDirectoryEntries(
                at: directoryURL,
                relativeBase: name,
                into: &entries
            )
        }

        for name in supportedFileNames {
            let fileURL = rootURL.appendingPathComponent(name, isDirectory: false)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path(percentEncoded: false), isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            entries.append(AIBExecutionDirectoryEntry(relativePath: name, kind: .file))
        }

        return entries.sorted { lhs, rhs in
            lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    public static func collectFiles(at rootURL: URL) throws -> [AIBExecutionDirectoryFile] {
        let entries = try discoverEntries(at: rootURL)
        return try entries.compactMap { entry in
            guard entry.kind == .file else { return nil }
            let fileURL = rootURL.appendingPathComponent(entry.relativePath, isDirectory: false)
            let content = try Data(contentsOf: fileURL)
            return AIBExecutionDirectoryFile(relativePath: entry.relativePath, content: content)
        }
    }

    public static func topLevelMarkers(for entries: [AIBExecutionDirectoryEntry]) -> [String] {
        let markers = Set(entries.compactMap { entry in
            entry.relativePath.split(separator: "/", maxSplits: 1).first.map(String.init)
        })
        return markers.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private static func appendDirectoryEntries(
        at directoryURL: URL,
        relativeBase: String,
        into entries: inout [AIBExecutionDirectoryEntry]
    ) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return
        }

        while let item = enumerator.nextObject() as? URL {
            let relativeComponents = item.standardizedFileURL.pathComponents.dropFirst(
                directoryURL.standardizedFileURL.pathComponents.count
            )
            guard !relativeComponents.isEmpty else { continue }
            let relativeComponent = relativeComponents.joined(separator: "/")
            let relativePath = relativeBase + "/" + relativeComponent
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                entries.append(AIBExecutionDirectoryEntry(relativePath: relativePath, kind: .directory))
            } else if values.isRegularFile == true {
                entries.append(AIBExecutionDirectoryEntry(relativePath: relativePath, kind: .file))
            }
        }
    }
}
