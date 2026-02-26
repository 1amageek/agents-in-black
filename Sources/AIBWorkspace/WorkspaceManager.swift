import AIBRuntimeCore
import Foundation

public enum AIBWorkspaceManager {
    public static let workspaceDirectoryName = ".aib"
    public static let workspaceConfigRelativePath = ".aib/workspace.yaml"

    public static func initWorkspace(options: WorkspaceInitOptions) throws -> WorkspaceInitResult {
        let workspaceRoot = URL(fileURLWithPath: options.workspaceRoot).standardizedFileURL.path
        let workspaceDir = URL(fileURLWithPath: workspaceDirectoryName, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
        let workspaceConfigPath = URL(fileURLWithPath: workspaceConfigRelativePath, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path

        if FileManager.default.fileExists(atPath: workspaceConfigPath), !options.force {
            throw ConfigError("Workspace already initialized", metadata: ["path": workspaceConfigPath])
        }

        try FileManager.default.createDirectory(atPath: workspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: "state", relativeTo: URL(fileURLWithPath: workspaceDir)).path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: "logs", relativeTo: URL(fileURLWithPath: workspaceDir)).path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: "environments", relativeTo: URL(fileURLWithPath: workspaceDir)).path, withIntermediateDirectories: true)

        let workspaceName = URL(fileURLWithPath: workspaceRoot).lastPathComponent
        let repos = options.scanEnabled ? try WorkspaceDiscovery.discoverRepos(workspaceRoot: workspaceRoot, scanPath: options.scanPath) : []
        let workspace = AIBWorkspaceConfig(workspaceName: workspaceName, repos: repos)

        try WorkspaceYAMLCodec.saveWorkspace(workspace, to: workspaceConfigPath)
        try ensureEnvironmentTemplates(workspaceRoot: workspaceRoot)
        try ensureGitignoreEntries(workspaceRoot: workspaceRoot)

        let syncResult = try WorkspaceSyncer.sync(workspaceRoot: workspaceRoot, workspace: workspace)
        return WorkspaceInitResult(workspaceConfig: workspace, generatedServices: syncResult.serviceCount, warnings: syncResult.warnings)
    }

    public static func loadWorkspace(workspaceRoot: String) throws -> AIBWorkspaceConfig {
        let path = URL(fileURLWithPath: workspaceConfigRelativePath, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
        return try WorkspaceYAMLCodec.loadWorkspace(at: path)
    }

    public static func saveWorkspace(_ workspace: AIBWorkspaceConfig, workspaceRoot: String) throws {
        let path = URL(fileURLWithPath: workspaceConfigRelativePath, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
        try WorkspaceYAMLCodec.saveWorkspace(workspace, to: path)
    }

    public static func rescanWorkspace(workspaceRoot: String) throws -> WorkspaceInitResult {
        let existing = try loadWorkspace(workspaceRoot: workspaceRoot)
        let discovered = try WorkspaceDiscovery.discoverRepos(workspaceRoot: workspaceRoot, scanPath: workspaceRoot)
        let merged = merge(existing: existing, discovered: discovered)
        try saveWorkspace(merged, workspaceRoot: workspaceRoot)
        let syncResult = try WorkspaceSyncer.sync(workspaceRoot: workspaceRoot, workspace: merged)
        return WorkspaceInitResult(workspaceConfig: merged, generatedServices: syncResult.serviceCount, warnings: syncResult.warnings)
    }

    public static func syncWorkspace(workspaceRoot: String) throws -> WorkspaceSyncResult {
        let workspace = try loadWorkspace(workspaceRoot: workspaceRoot)
        return try WorkspaceSyncer.sync(workspaceRoot: workspaceRoot, workspace: workspace)
    }

    private static func merge(existing: AIBWorkspaceConfig, discovered: [WorkspaceRepo]) -> AIBWorkspaceConfig {
        let existingByPath = Dictionary(uniqueKeysWithValues: existing.repos.map { ($0.path, $0) })
        let mergedRepos = discovered.map { repo -> WorkspaceRepo in
            guard let prior = existingByPath[repo.path] else { return repo }
            var updated = repo
            updated.enabled = prior.enabled
            updated.servicesNamespace = prior.servicesNamespace
            if let priorSelected = prior.selectedCommand, !priorSelected.isEmpty {
                updated.selectedCommand = priorSelected
            }
            if !prior.commandCandidates.isEmpty {
                updated.commandCandidates = prior.commandCandidates
            }
            return updated
        }
        return AIBWorkspaceConfig(
            version: existing.version,
            workspaceName: existing.workspaceName,
            generatedServicesPath: existing.generatedServicesPath,
            gateway: existing.gateway,
            repos: mergedRepos
        )
    }

    private static func ensureEnvironmentTemplates(workspaceRoot: String) throws {
        let files: [(String, String)] = [
            (".aib/environments/local.yaml", "version: 1\nname: local\n"),
            (".aib/environments/staging.yaml", "version: 1\nname: staging\n"),
            (".aib/environments/prod.yaml", "version: 1\nname: prod\n"),
        ]
        for (relativePath, content) in files {
            let path = URL(fileURLWithPath: relativePath, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
            if !FileManager.default.fileExists(atPath: path) {
                try content.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func ensureGitignoreEntries(workspaceRoot: String) throws {
        let gitignorePath = URL(fileURLWithPath: ".gitignore", relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
        let required = [".aib/state/", ".aib/logs/"]

        let existing: String
        if FileManager.default.fileExists(atPath: gitignorePath) {
            existing = try String(contentsOfFile: gitignorePath, encoding: .utf8)
        } else {
            existing = ""
        }

        var toAppend: [String] = []
        for item in required where !existing.contains(item) {
            toAppend.append(item)
        }
        if toAppend.isEmpty { return }

        let prefix = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let block = prefix + toAppend.joined(separator: "\n") + "\n"

        if FileManager.default.fileExists(atPath: gitignorePath) {
            if let handle = FileHandle(forWritingAtPath: gitignorePath) {
                defer {
                    do {
                        try handle.close()
                    } catch {
                        // Best-effort close after append.
                    }
                }
                try handle.seekToEnd()
                if let data = block.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            }
        } else {
            try block.write(toFile: gitignorePath, atomically: true, encoding: .utf8)
        }
    }
}
