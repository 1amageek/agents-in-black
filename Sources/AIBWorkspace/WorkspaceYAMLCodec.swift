import AIBRuntimeCore
import Foundation
import Yams

public enum WorkspaceYAMLCodec {
    public static func loadWorkspace(at path: String) throws -> AIBWorkspaceConfig {
        do {
            let yaml = try String(contentsOfFile: path, encoding: .utf8)
            return try YAMLDecoder().decode(WorkspaceFileDTO.self, from: yaml).toModel()
        } catch {
            throw ConfigError("Failed to load workspace config", metadata: ["path": path, "underlying_error": "\(error)"])
        }
    }

    public static func saveWorkspace(_ config: AIBWorkspaceConfig, to path: String) throws {
        do {
            let dto = WorkspaceFileDTO(config)
            let yaml = try YAMLEncoder().encode(dto)
            try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw ConfigError("Failed to save workspace config", metadata: ["path": path, "underlying_error": "\(error)"])
        }
    }
}

private struct WorkspaceFileDTO: Codable {
    var version: Int
    var workspaceName: String
    var generatedServicesPath: String
    var gateway: Gateway
    var repos: [Repo]

    enum CodingKeys: String, CodingKey {
        case version
        case workspaceName = "workspace_name"
        case generatedServicesPath = "generated_services_path"
        case gateway
        case repos
    }

    struct Gateway: Codable {
        var port: Int
    }

    struct Repo: Codable {
        var name: String
        var path: String
        var manifestPath: String?
        var runtime: String
        var framework: String
        var packageManager: String
        var status: String
        var detectionConfidence: String
        var commandCandidates: [CommandCandidateDTO]
        var selectedCommand: [String]?
        var servicesNamespace: String?
        var enabled: Bool

        enum CodingKeys: String, CodingKey {
            case name
            case path
            case manifestPath = "manifest_path"
            case runtime
            case framework
            case packageManager = "package_manager"
            case status
            case detectionConfidence = "detection_confidence"
            case commandCandidates = "command_candidates"
            case selectedCommand = "selected_command"
            case servicesNamespace = "services_namespace"
            case enabled
        }
    }

    struct CommandCandidateDTO: Codable {
        var argv: [String]
        var reason: String
    }

    init(_ config: AIBWorkspaceConfig) {
        self.version = config.version
        self.workspaceName = config.workspaceName
        self.generatedServicesPath = config.generatedServicesPath
        self.gateway = .init(port: config.gateway.port)
        self.repos = config.repos.map {
            .init(
                name: $0.name,
                path: $0.path,
                manifestPath: $0.manifestPath,
                runtime: $0.runtime.rawValue,
                framework: $0.framework.rawValue,
                packageManager: $0.packageManager.rawValue,
                status: $0.status.rawValue,
                detectionConfidence: $0.detectionConfidence.rawValue,
                commandCandidates: $0.commandCandidates.map { .init(argv: $0.argv, reason: $0.reason) },
                selectedCommand: $0.selectedCommand,
                servicesNamespace: $0.servicesNamespace,
                enabled: $0.enabled
            )
        }
    }

    func toModel() throws -> AIBWorkspaceConfig {
        let repos = try repos.map { repo in
            guard let runtime = RuntimeKind(rawValue: repo.runtime) else {
                throw ConfigError("Invalid runtime", metadata: ["repo": repo.name, "runtime": repo.runtime])
            }
            guard let framework = FrameworkKind(rawValue: repo.framework) else {
                throw ConfigError("Invalid framework", metadata: ["repo": repo.name, "framework": repo.framework])
            }
            guard let packageManager = PackageManagerKind(rawValue: repo.packageManager) else {
                throw ConfigError("Invalid package_manager", metadata: ["repo": repo.name, "package_manager": repo.packageManager])
            }
            guard let status = RepoStatus(rawValue: repo.status) else {
                throw ConfigError("Invalid status", metadata: ["repo": repo.name, "status": repo.status])
            }
            guard let confidence = DetectionConfidence(rawValue: repo.detectionConfidence) else {
                throw ConfigError("Invalid detection_confidence", metadata: ["repo": repo.name, "detection_confidence": repo.detectionConfidence])
            }
            return WorkspaceRepo(
                name: repo.name,
                path: repo.path,
                manifestPath: repo.manifestPath,
                runtime: runtime,
                framework: framework,
                packageManager: packageManager,
                status: status,
                detectionConfidence: confidence,
                commandCandidates: repo.commandCandidates.map { .init(argv: $0.argv, reason: $0.reason) },
                selectedCommand: repo.selectedCommand,
                servicesNamespace: repo.servicesNamespace,
                enabled: repo.enabled
            )
        }
        return AIBWorkspaceConfig(
            version: version,
            workspaceName: workspaceName,
            generatedServicesPath: generatedServicesPath,
            gateway: .init(port: gateway.port),
            repos: repos
        )
    }
}
