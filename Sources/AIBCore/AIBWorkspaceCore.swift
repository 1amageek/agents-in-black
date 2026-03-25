import AIBConfig
import AIBRuntimeCore
import AIBWorkspace
import Foundation

public enum AIBWorkspaceCore {
    public static let workspaceDirectoryName = AIBWorkspaceManager.workspaceDirectoryName
    public static let workspaceConfigRelativePath = AIBWorkspaceManager.workspaceConfigRelativePath

    public static func initWorkspace(options: WorkspaceInitOptions) throws -> WorkspaceInitResult {
        try AIBWorkspaceManager.initWorkspace(options: options)
    }

    public static func initWorkspace(
        workspaceRoot: String,
        scanPath: String? = nil,
        force: Bool = false,
        scanEnabled: Bool = true
    ) throws -> WorkspaceInitResult {
        try AIBWorkspaceManager.initWorkspace(
            options: WorkspaceInitOptions(
                workspaceRoot: workspaceRoot,
                scanPath: scanPath ?? workspaceRoot,
                force: force,
                scanEnabled: scanEnabled
            )
        )
    }

    public static func loadWorkspace(workspaceRoot: String) throws -> AIBWorkspaceConfig {
        try AIBWorkspaceManager.loadWorkspace(workspaceRoot: workspaceRoot)
    }

    public static func addRepo(workspaceRoot: String, repoURL: URL) throws -> WorkspaceInitResult {
        try AIBWorkspaceManager.addRepo(workspaceRoot: workspaceRoot, repoURL: repoURL)
    }

    /// Scaffold a default agent in the workspace using a template from the registry.
    @discardableResult
    public static func scaffoldDefaultAgent(
        workspaceRoot: String,
        serviceName: String = "claude-code-agent",
        runtime: RuntimeKind = .node,
        framework: FrameworkKind = .hono
    ) throws -> WorkspaceInitResult {
        guard let template = ProjectTemplateRegistry.template(for: runtime, framework: framework) else {
            throw ConfigError("No template found", metadata: ["runtime": runtime.rawValue, "framework": framework.rawValue])
        }
        let rootURL = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
        let serviceDir = rootURL.appendingPathComponent(serviceName)

        guard !FileManager.default.fileExists(atPath: serviceDir.path) else {
            throw ConfigError("Directory already exists", metadata: ["path": serviceName])
        }

        try template.scaffold(at: serviceDir, serviceName: serviceName)
        let result = try addRepo(workspaceRoot: workspaceRoot, repoURL: serviceDir)

        // Configure the service so it appears as an active agent, not just "discoverable"
        let repoPath = result.workspaceConfig.repos.first { $0.path == serviceName }?.path ?? serviceName
        return try AIBWorkspaceManager.configureServices(
            workspaceRoot: workspaceRoot,
            path: repoPath,
            runtimes: [runtime]
        )
    }

    @discardableResult
    public static func removeStaleRepos(workspaceRoot: String) throws -> [String] {
        try AIBWorkspaceManager.removeStaleRepos(workspaceRoot: workspaceRoot)
    }

    public static func rescanWorkspace(workspaceRoot: String) throws -> WorkspaceInitResult {
        try AIBWorkspaceManager.rescanWorkspace(workspaceRoot: workspaceRoot)
    }

    public static func syncWorkspace(workspaceRoot: String) throws -> WorkspaceSyncResult {
        try AIBWorkspaceManager.syncWorkspace(workspaceRoot: workspaceRoot)
    }

    public static func updateServiceMCPProfile(
        workspaceRoot: String,
        namespacedServiceID: String,
        path: String
    ) throws {
        try AIBWorkspaceManager.updateServiceMCPProfile(
            workspaceRoot: workspaceRoot,
            namespacedServiceID: namespacedServiceID,
            path: path
        )
    }

    public static func updateServiceKind(
        workspaceRoot: String,
        namespacedServiceID: String,
        kind: String
    ) throws {
        try AIBWorkspaceManager.updateServiceKind(
            workspaceRoot: workspaceRoot,
            namespacedServiceID: namespacedServiceID,
            kind: kind
        )
    }

    public static func updateServiceModel(
        workspaceRoot: String,
        namespacedServiceID: String,
        model: String?
    ) throws {
        try AIBWorkspaceManager.updateServiceModel(
            workspaceRoot: workspaceRoot,
            namespacedServiceID: namespacedServiceID,
            model: model
        )
    }

    public static func updateServiceConnections(
        workspaceRoot: String,
        connectionsByNamespacedServiceID: [String: ServiceConnectionsConfig]
    ) throws {
        try AIBWorkspaceManager.updateServiceConnections(
            workspaceRoot: workspaceRoot,
            connectionsByNamespacedServiceID: connectionsByNamespacedServiceID
        )
    }

    public static func configureServices(
        workspaceRoot: String,
        path: String,
        runtimes: [String]
    ) throws -> WorkspaceInitResult {
        let runtimeKinds = runtimes.compactMap { RuntimeKind(rawValue: $0) }
        guard !runtimeKinds.isEmpty else {
            throw ConfigError("No valid runtimes specified", metadata: ["runtimes": runtimes.joined(separator: ", ")])
        }
        return try AIBWorkspaceManager.configureServices(
            workspaceRoot: workspaceRoot,
            path: path,
            runtimes: runtimeKinds
        )
    }

    public static func removeService(
        workspaceRoot: String,
        namespacedServiceID: String
    ) throws -> WorkspaceInitResult {
        try AIBWorkspaceManager.removeService(
            workspaceRoot: workspaceRoot,
            namespacedServiceID: namespacedServiceID
        )
    }

    public static func updateRepoRuntime(
        workspaceRoot: String,
        repoPath: String,
        runtime: String
    ) throws -> WorkspaceInitResult {
        guard let runtimeKind = RuntimeKind(rawValue: runtime) else {
            throw ConfigError("Unknown runtime: \(runtime)", metadata: ["runtime": runtime])
        }
        return try AIBWorkspaceManager.updateRepoRuntime(
            workspaceRoot: workspaceRoot,
            repoPath: repoPath,
            runtime: runtimeKind
        )
    }

    public static func relocateRepo(
        workspaceRoot: String,
        repoName: String,
        newURL: URL
    ) throws -> WorkspaceInitResult {
        try AIBWorkspaceManager.relocateRepo(
            workspaceRoot: workspaceRoot,
            repoName: repoName,
            newURL: newURL
        )
    }

    public static func updateServiceEndpoints(
        workspaceRoot: String,
        endpointsByNamespacedServiceID: [String: [String: String]]
    ) throws {
        try AIBWorkspaceManager.updateServiceEndpoints(
            workspaceRoot: workspaceRoot,
            endpointsByNamespacedServiceID: endpointsByNamespacedServiceID
        )
    }

    // MARK: - Skill Management

    /// List all skill definitions in the workspace (for deployment).
    public static func listSkills(workspaceRoot: String) throws -> [AIBSkillDefinition] {
        try AIBWorkspaceManager.listSkills(workspaceRoot: workspaceRoot).map(Self.mapSkill)
    }

    /// Add a new skill definition to the workspace.
    /// If `id` is nil, it is auto-generated from `name` via slugification.
    public static func addSkill(
        workspaceRoot: String,
        id: String? = nil,
        name: String,
        description: String? = nil,
        instructions: String? = nil,
        allowedTools: [String] = [],
        tags: [String] = []
    ) throws {
        let resolvedID = id ?? WorkspaceSkillConfig.slugify(name)
        let skill = WorkspaceSkillConfig(
            id: resolvedID,
            name: name,
            description: description,
            instructions: instructions,
            allowedTools: allowedTools.isEmpty ? nil : allowedTools,
            tags: tags.isEmpty ? nil : tags
        )
        try AIBWorkspaceManager.addSkill(workspaceRoot: workspaceRoot, skill: skill)
    }

    /// Remove a skill definition and all its assignments from services.
    public static func removeSkill(workspaceRoot: String, skillID: String) throws {
        try AIBWorkspaceManager.removeSkill(workspaceRoot: workspaceRoot, skillID: skillID)
    }

    /// Assign a skill to an agent service.
    public static func assignSkill(
        workspaceRoot: String,
        skillID: String,
        namespacedServiceID: String
    ) throws {
        try AIBWorkspaceManager.assignSkill(
            workspaceRoot: workspaceRoot,
            skillID: skillID,
            namespacedServiceID: namespacedServiceID
        )
    }

    /// Unassign a skill from an agent service.
    public static func unassignSkill(
        workspaceRoot: String,
        skillID: String,
        namespacedServiceID: String
    ) throws {
        try AIBWorkspaceManager.unassignSkill(
            workspaceRoot: workspaceRoot,
            skillID: skillID,
            namespacedServiceID: namespacedServiceID
        )
    }

    /// Import a skill from the user library into the workspace.
    public static func importSkill(workspaceRoot: String, skillID: String) throws {
        try AIBWorkspaceManager.importSkill(workspaceRoot: workspaceRoot, skillID: skillID)
    }

    /// Import a skill bundle from an execution directory into the workspace.
    public static func importSkillBundle(
        workspaceRoot: String,
        skillID: String,
        sourcePath: String
    ) throws {
        try AIBWorkspaceManager.importSkillBundle(
            workspaceRoot: workspaceRoot,
            skillID: skillID,
            sourcePath: sourcePath
        )
    }

    // MARK: - Skill Library (User-level)

    /// List all skills in the user library (`~/.aib/skills/`).
    public static func listLibrarySkills() throws -> [AIBSkillDefinition] {
        try AIBWorkspaceManager.listLibrarySkills().map(Self.mapSkill)
    }

    /// Create a skill in the user library.
    public static func createLibrarySkill(
        id: String? = nil,
        name: String,
        description: String? = nil,
        instructions: String? = nil,
        allowedTools: [String] = [],
        tags: [String] = []
    ) throws {
        let resolvedID = id ?? WorkspaceSkillConfig.slugify(name)
        let skill = WorkspaceSkillConfig(
            id: resolvedID,
            name: name,
            description: description,
            instructions: instructions,
            allowedTools: allowedTools.isEmpty ? nil : allowedTools,
            tags: tags.isEmpty ? nil : tags
        )
        try AIBWorkspaceManager.createLibrarySkill(skill)
    }

    /// Delete a skill from the user library.
    public static func deleteLibrarySkill(id: String) throws {
        try AIBWorkspaceManager.deleteLibrarySkill(id: id)
    }

    // MARK: - Skill Registry (Remote)

    /// A skill available in a remote registry.
    public struct RegistrySkillEntry: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let description: String?
        public let tags: [String]
    }

    /// List skills available in the default remote registry.
    public static func listRegistrySkills() async throws -> [RegistrySkillEntry] {
        let entries = try await AIBWorkspaceManager.listRegistrySkills()
        return entries.map {
            RegistrySkillEntry(id: $0.id, name: $0.name, description: $0.description, tags: $0.tags)
        }
    }

    /// Download a skill from the remote registry into the user library.
    public static func downloadRegistrySkill(id: String) async throws {
        try await AIBWorkspaceManager.downloadRegistrySkill(id: id)
    }

    private static func mapSkill(_ skill: WorkspaceSkillConfig) -> AIBSkillDefinition {
        AIBSkillDefinition(
            id: skill.id,
            name: skill.name,
            description: skill.description,
            instructions: skill.instructions,
            allowedTools: skill.allowedTools ?? [],
            tags: skill.tags ?? [],
            source: .workspace,
            isWorkspaceManaged: true
        )
    }

    public static func updateServiceConnections(
        workspaceRoot: String,
        connectionsByNamespacedServiceID: [String: AIBServiceConnections]
    ) throws {
        let mapped = Dictionary(uniqueKeysWithValues: connectionsByNamespacedServiceID.map { key, value in
            (
                key,
                ServiceConnectionsConfig(
                    mcpServers: value.mcpServers.map { ServiceConnectionTarget(serviceRef: $0.serviceRef, url: $0.url) },
                    a2aAgents: value.a2aAgents.map { ServiceConnectionTarget(serviceRef: $0.serviceRef, url: $0.url) }
                )
            )
        })
        try updateServiceConnections(
            workspaceRoot: workspaceRoot,
            connectionsByNamespacedServiceID: mapped
        )
    }
}
