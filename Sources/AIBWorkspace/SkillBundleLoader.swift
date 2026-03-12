import AIBRuntimeCore
import Foundation
import SwiftSkill
import YAML

/// Manages skill bundles in the user-level skill library at `~/.aib/skills/`.
/// Skills are authored and shared here, then imported into workspaces for deployment.
public enum SkillBundleLoader {
    public struct BundleFile: Sendable, Equatable {
        public let relativePath: String
        public let content: Data

        public init(relativePath: String, content: Data) {
            self.relativePath = relativePath
            self.content = content
        }
    }

    /// Directory name for skill bundles.
    public static let skillsDirectoryName = "skills"

    /// Required filename for the skill definition.
    public static let skillFileName = "SKILL.md"

    /// Root directory for user-level skill library: `~/.aib/skills/`.
    public static var skillsRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aib")
            .appendingPathComponent(skillsDirectoryName)
    }

    /// Workspace-local skill storage used for self-contained deployment.
    public static func workspaceSkillsRootURL(workspaceRoot: String) -> URL {
        URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(".aib")
            .appendingPathComponent(skillsDirectoryName)
    }

    /// Cache directory for cloned registries: `~/.aib/cache/registries/`.
    private static var registryCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aib")
            .appendingPathComponent("cache")
            .appendingPathComponent("registries")
    }

    // MARK: - Read

    /// List all skill bundles in the user library.
    public static func listSkills() throws -> [WorkspaceSkillConfig] {
        try listSkills(rootURL: skillsRootURL)
    }

    /// Load a single skill by ID from the user library.
    public static func loadSkill(id: String) throws -> WorkspaceSkillConfig {
        try loadSkill(id: id, rootURL: skillsRootURL)
    }

    /// Load a skill from a SKILL.md file path.
    public static func loadSkill(at path: URL, id: String) throws -> WorkspaceSkillConfig {
        let bundle = try loadBundle(at: path)
        return workspaceConfig(from: bundle, id: id)
    }

    /// List all skill bundles stored at a specific root.
    public static func listSkills(rootURL: URL) throws -> [WorkspaceSkillConfig] {
        let store = SkillStore(rootURL: rootURL)
        return try store.discover().map { workspaceConfig(from: $0, id: $0.name) }
    }

    /// Load a skill definition from a specific root.
    public static func loadSkill(id: String, rootURL: URL) throws -> WorkspaceSkillConfig {
        let bundle = try loadBundle(id: id, rootURL: rootURL)
        return workspaceConfig(from: bundle, id: id)
    }

    /// Load a full skill bundle from the user library.
    public static func loadBundle(id: String) throws -> Skill {
        try loadBundle(id: id, rootURL: skillsRootURL)
    }

    /// Load a full skill bundle from a specific storage root.
    public static func loadBundle(id: String, rootURL: URL) throws -> Skill {
        let store = SkillStore(rootURL: rootURL)
        guard let skill = try store.skill(named: id) else {
            throw ConfigError("Skill not found in library", metadata: ["id": id, "root": rootURL.path])
        }
        return skill
    }

    /// Load a full skill bundle from either a directory or a `SKILL.md` path.
    public static func loadBundle(at path: URL) throws -> Skill {
        let directoryURL = path.lastPathComponent == skillFileName ? path.deletingLastPathComponent() : path
        return try SkillParser().parseDirectory(at: directoryURL)
    }

    /// Enumerate all files that make up a stored skill bundle.
    public static func bundleFiles(
        id: String,
        rootURL: URL,
        fallback: WorkspaceSkillConfig? = nil
    ) throws -> [BundleFile] {
        let bundleURL = skillURL(id: id, rootURL: rootURL)
        if FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false)) {
            return try collectBundleFiles(at: bundleURL)
        }

        guard let fallback else {
            throw ConfigError(
                "Skill bundle not found",
                metadata: ["id": id, "root": rootURL.path(percentEncoded: false)]
            )
        }
        return try generatedBundleFiles(from: fallback)
    }

    // MARK: - Write

    /// Save a skill to the user library as `~/.aib/skills/<id>/SKILL.md`.
    public static func saveSkill(_ skill: WorkspaceSkillConfig) throws {
        try saveSkill(skill, rootURL: skillsRootURL)
    }

    /// Save a skill bundle into a specific storage root.
    public static func saveSkill(_ skill: WorkspaceSkillConfig, rootURL: URL) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let store = SkillStore(rootURL: rootURL)
        try store.save(skillBundle(from: skill))
    }

    /// Save a full skill bundle into a specific storage root.
    public static func saveBundle(_ skill: Skill, rootURL: URL) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let store = SkillStore(rootURL: rootURL)
        try store.save(skill)
    }

    /// Copy an existing skill bundle between storage roots.
    public static func copySkill(id: String, from sourceRootURL: URL, to destinationRootURL: URL) throws {
        let sourceURL = skillURL(id: id, rootURL: sourceRootURL)
        guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            throw ConfigError(
                "Skill not found in library",
                metadata: ["id": id, "root": sourceRootURL.path(percentEncoded: false)]
            )
        }

        try FileManager.default.createDirectory(at: destinationRootURL, withIntermediateDirectories: true)
        let destinationURL = skillURL(id: id, rootURL: destinationRootURL)
        if FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    /// Delete a skill bundle from the user library.
    public static func deleteSkill(id: String) throws {
        try deleteSkill(id: id, rootURL: skillsRootURL)
    }

    /// Delete a skill bundle from a specific storage root.
    public static func deleteSkill(id: String, rootURL: URL) throws {
        let skillDir = skillURL(id: id, rootURL: rootURL)

        guard FileManager.default.fileExists(atPath: skillDir.path(percentEncoded: false)) else {
            throw ConfigError(
                "Skill not found in library",
                metadata: ["id": id, "root": rootURL.path(percentEncoded: false)]
            )
        }

        try FileManager.default.removeItem(at: skillDir)
    }

    /// Check whether a skill exists in the user library.
    public static func skillExists(id: String) -> Bool {
        skillExists(id: id, rootURL: skillsRootURL)
    }

    /// Check whether a skill exists in a specific storage root.
    public static func skillExists(id: String, rootURL: URL) -> Bool {
        let skillFile = skillURL(id: id, rootURL: rootURL).appendingPathComponent(skillFileName)
        return FileManager.default.fileExists(atPath: skillFile.path(percentEncoded: false))
    }

    /// Resolve a skill bundle directory URL from a storage root.
    public static func skillURL(id: String, rootURL: URL) -> URL {
        rootURL.appending(path: id, directoryHint: .isDirectory)
    }

    /// Build a minimal portable skill bundle from the workspace metadata model.
    public static func skillBundle(from skill: WorkspaceSkillConfig) throws -> Skill {
        var bundle = Skill(
            name: skill.id,
            description: skill.description ?? skill.name,
            allowedTools: skill.allowedTools,
            body: skill.instructions ?? ""
        )

        if let tags = skill.tags, !tags.isEmpty {
            bundle.extensions["tags"] = .array(tags.map(SkillValue.string))
        }

        if skill.name != skill.id {
            var codex = CodexConfiguration()
            codex.interface = .init(displayName: skill.name)
            try bundle.setConfiguration(codex)
        }

        return bundle
    }

    // MARK: - Remote Registry (git clone based)

    /// Default GitHub repository URL for curated skills.
    public static let defaultRegistryRepo = "https://github.com/openai/skills.git"
    /// Path within the repository where curated skills are stored.
    public static let defaultRegistryPath = "skills/.curated"

    /// An entry in the remote skill registry.
    public struct RegistryEntry: Sendable {
        public let id: String
        public let name: String
        public let description: String?
        public let tags: [String]
    }

    /// List available skills from a registry by cloning (or pulling) the repo locally.
    public static func listRegistrySkills(
        repo: String = defaultRegistryRepo,
        path: String = defaultRegistryPath
    ) async throws -> [RegistryEntry] {
        let repoDir = try await ensureRegistryClone(repo: repo)
        let skillsDir = repoDir.appendingPathComponent(path)

        guard FileManager.default.fileExists(atPath: skillsDir.path) else {
            throw ConfigError("Skills path not found in registry", metadata: ["path": path])
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: skillsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        return entries.compactMap { dir -> RegistryEntry? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            let skillFile = dir.appendingPathComponent(skillFileName)
            guard FileManager.default.fileExists(atPath: skillFile.path) else { return nil }

            let id = dir.lastPathComponent
            do {
                let config = try loadSkill(at: skillFile, id: id)
                return RegistryEntry(
                    id: id,
                    name: config.name,
                    description: config.description,
                    tags: config.tags ?? []
                )
            } catch {
                return RegistryEntry(id: id, name: id, description: nil, tags: [])
            }
        }
        .sorted { $0.id < $1.id }
    }

    /// Download a skill bundle from the registry into the user library.
    /// Copies the entire skill directory (SKILL.md + scripts, references, etc.).
    public static func downloadRegistrySkill(
        id: String,
        repo: String = defaultRegistryRepo,
        path: String = defaultRegistryPath
    ) async throws {
        let repoDir = try await ensureRegistryClone(repo: repo)
        let sourceDir = repoDir
            .appendingPathComponent(path)
            .appendingPathComponent(id)

        let skillFile = sourceDir.appendingPathComponent(skillFileName)
        guard FileManager.default.fileExists(atPath: skillFile.path) else {
            throw ConfigError("Skill not found in registry", metadata: ["id": id])
        }

        let destDir = skillsRootURL.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: destDir.path) {
            try FileManager.default.removeItem(at: destDir)
        }

        try FileManager.default.createDirectory(
            at: destDir.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceDir, to: destDir)
    }

    // MARK: - Git Clone Management

    /// Ensure the registry repo is cloned locally, pulling if it already exists.
    /// Returns the path to the local clone.
    private static func ensureRegistryClone(repo: String) async throws -> URL {
        let cacheDir = registryCacheURL
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let repoHash = stableHash(repo)
        let repoDir = cacheDir.appendingPathComponent(repoHash)

        if FileManager.default.fileExists(atPath: repoDir.appendingPathComponent(".git").path) {
            // Already cloned — pull latest
            try await runGit(["pull", "--ff-only"], at: repoDir)
        } else {
            // Fresh shallow clone
            if FileManager.default.fileExists(atPath: repoDir.path) {
                try FileManager.default.removeItem(at: repoDir)
            }
            try await runGit(
                ["clone", "--depth", "1", repo, repoDir.path],
                at: cacheDir
            )
        }

        return repoDir
    }

    /// Run a git command asynchronously and throw on failure.
    private static func runGit(_ arguments: [String], at directory: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ConfigError("Failed to run git", metadata: ["args": arguments.joined(separator: " ")]))
                return
            }

            process.waitUntilExit()

            if process.terminationStatus != 0 {
                var errorMsg = "git exited with status \(process.terminationStatus)"
                if let pipe = process.standardError as? Pipe {
                    do {
                        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                        if let stderr = String(data: data, encoding: .utf8),
                           !stderr.isEmpty {
                            errorMsg += ": \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                        }
                    } catch {
                        errorMsg += ": failed to read stderr (\(error.localizedDescription))"
                    }
                }
                continuation.resume(throwing: ConfigError(errorMsg, metadata: ["args": arguments.joined(separator: " ")]))
            } else {
                continuation.resume()
            }
        }
    }

    /// Stable hash for a repo URL to use as cache directory name.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    // MARK: - Frontmatter Parsing

    /// Parse YAML frontmatter (between `---` markers) from SKILL.md content.
    static func parseFrontmatter(_ content: String) -> (frontmatter: String?, body: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else {
            return (nil, content)
        }

        let afterFirstMarker = trimmed.dropFirst(3)
        guard let endRange = afterFirstMarker.range(of: "\n---") else {
            return (nil, content)
        }

        let frontmatter = String(afterFirstMarker[afterFirstMarker.startIndex..<endRange.lowerBound])
        let body = String(afterFirstMarker[endRange.upperBound...])
        return (frontmatter, body)
    }

    /// Render a WorkspaceSkillConfig as SKILL.md content.
    static func renderSkillMD(_ skill: WorkspaceSkillConfig) -> String {
        var lines: [String] = ["---"]

        lines.append("name: \(skill.name)")

        if let desc = skill.description {
            lines.append("description: \(desc)")
        }

        if let tools = skill.allowedTools, !tools.isEmpty {
            lines.append("allowed-tools: \(tools.joined(separator: ", "))")
        }

        if let tags = skill.tags, !tags.isEmpty {
            lines.append("tags: [\(tags.joined(separator: ", "))]")
        }

        lines.append("---")
        lines.append("")

        if let instructions = skill.instructions {
            lines.append(instructions)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func workspaceConfig(from skill: Skill, id: String) -> WorkspaceSkillConfig {
        let displayName = skill.codexDisplayName ?? skill.name
        let tags = skill.extensions["tags"]?.arrayValue?
            .compactMap(\.stringValue)
        let instructions = skill.body.isEmpty ? nil : skill.body
        let allowedTools = skill.allowedTools?.isEmpty == false ? skill.allowedTools : nil

        return WorkspaceSkillConfig(
            id: id,
            name: displayName,
            description: skill.description,
            instructions: instructions,
            allowedTools: allowedTools,
            tags: tags?.isEmpty == false ? tags : nil
        )
    }

    private static func collectBundleFiles(at bundleURL: URL) throws -> [BundleFile] {
        let fm = FileManager.default
        let bundlePath = bundleURL.path(percentEncoded: false)
        guard let enumerator = fm.enumerator(atPath: bundlePath) else { return [] }

        let skippedNames: Set<String> = [".DS_Store"]
        let skippedDirectories: Set<String> = [".git"]
        var files: [BundleFile] = []

        while let relativePath = enumerator.nextObject() as? String {
            let fileName = (relativePath as NSString).lastPathComponent
            if skippedNames.contains(fileName) || skippedDirectories.contains(fileName) {
                continue
            }

            let fileURL = bundleURL.appending(path: relativePath)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path(percentEncoded: false), isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }

            let data = try Data(contentsOf: fileURL)
            files.append(BundleFile(relativePath: relativePath, content: data))
        }

        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private static func generatedBundleFiles(from skill: WorkspaceSkillConfig) throws -> [BundleFile] {
        let bundle = try skillBundle(from: skill)
        var files = [BundleFile(
            relativePath: skillFileName,
            content: Data(try SkillWriter().write(bundle).utf8)
        )]

        for file in bundle.supportingFiles {
            files.append(BundleFile(relativePath: file.relativePath, content: file.content))
        }

        let mappingByKey = Dictionary(uniqueKeysWithValues: ConfigurationFileMapping.defaults.map {
            ($0.key, $0.relativePath)
        })
        for (key, data) in bundle.configurations {
            guard let relativePath = mappingByKey[key] else { continue }
            files.append(BundleFile(relativePath: relativePath, content: data))
        }

        return files.sorted { $0.relativePath < $1.relativePath }
    }
}
