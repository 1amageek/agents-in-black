import AIBConfig
import Foundation
import YAML

/// Per-service overrides that an explicitly selected deploy overlay can apply.
/// `env` and `deployEnv` merge over `ServiceConfig.env` / `.deployEnv` respectively;
/// `secrets` merge into `ServiceConfig.secrets`. Existing keys are replaced.
public struct AIBEnvironmentServiceOverride: Sendable, Equatable {
    public let env: [String: String]
    public let deployEnv: [String: String]
    public let secrets: [String: SecretRef]

    public init(
        env: [String: String] = [:],
        deployEnv: [String: String] = [:],
        secrets: [String: SecretRef] = [:]
    ) {
        self.env = env
        self.deployEnv = deployEnv
        self.secrets = secrets
    }

    public var isEmpty: Bool {
        env.isEmpty && deployEnv.isEmpty && secrets.isEmpty
    }
}

/// Parsed deploy overlay selected explicitly by name.
///
/// The overlay is applied on top of `.aib/targets/{providerID}.yaml` and the
/// universal `env` / `secrets` declared in `workspace.yaml`. Account, project,
/// region, and service-account selection belong to the target configuration;
/// overlays are optional per-service env / Secret Manager overrides.
public struct AIBEnvironmentConfig: Sendable, Equatable {
    /// Overlay name, taken from the YAML file's basename.
    public let name: String

    /// Top-level overrides keyed by `.aib/targets/{providerID}.yaml` field name
    /// (e.g. `gcpProject`, `region`). They are merged into
    /// `AIBDeployTargetConfig.providerConfig`, replacing any baseline value.
    public let targetOverrides: [String: String]

    /// Per-service overrides keyed by `ServiceID.rawValue` (`<repo>/<service>`).
    public let serviceOverrides: [String: AIBEnvironmentServiceOverride]

    public init(
        name: String,
        targetOverrides: [String: String] = [:],
        serviceOverrides: [String: AIBEnvironmentServiceOverride] = [:]
    ) {
        self.name = name
        self.targetOverrides = targetOverrides
        self.serviceOverrides = serviceOverrides
    }

    /// Override for a specific service, or an empty struct when none is declared.
    public func override(for serviceID: String) -> AIBEnvironmentServiceOverride {
        serviceOverrides[serviceID] ?? AIBEnvironmentServiceOverride()
    }
}

/// Loader for `.aib/environments/<name>.yaml`.
public enum AIBEnvironmentLoader {

    /// Load the overlay for `name`. Returns `nil` when `name` is nil or the file
    /// does not exist — overlay selection is optional.
    /// Throws when the file exists but cannot be parsed or has structural errors.
    public static func load(
        workspaceRoot: String,
        name: String?
    ) throws -> AIBEnvironmentConfig? {
        guard let name, !name.isEmpty else { return nil }
        let path = environmentFilePath(workspaceRoot: workspaceRoot, name: name)
        guard FileManager.default.fileExists(atPath: path) else {
            throw AIBEnvironmentLoaderError(
                message: "Deploy overlay '\(name)' not found at \(path)"
            )
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        guard let node = try compose(yaml: content), let root = node.mapping else {
            return AIBEnvironmentConfig(name: name)
        }

        var targetOverrides: [String: String] = [:]
        if let targetMap = root["target"]?.mapping {
            for (keyNode, valueNode) in targetMap {
                guard let key = keyNode.scalar?.string,
                      let value = valueNode.scalar?.string else { continue }
                targetOverrides[key] = value
            }
        }

        var serviceOverrides: [String: AIBEnvironmentServiceOverride] = [:]
        if let servicesMap = root["services"]?.mapping {
            for (serviceKeyNode, serviceValueNode) in servicesMap {
                guard let serviceID = serviceKeyNode.scalar?.string,
                      let serviceMap = serviceValueNode.mapping else { continue }
                let override = try parseServiceOverride(
                    serviceID: serviceID,
                    mapping: serviceMap
                )
                if !override.isEmpty {
                    serviceOverrides[serviceID] = override
                }
            }
        }

        return AIBEnvironmentConfig(
            name: name,
            targetOverrides: targetOverrides,
            serviceOverrides: serviceOverrides
        )
    }

    public static func environmentFilePath(
        workspaceRoot: String,
        name: String
    ) -> String {
        URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(".aib/environments/\(name).yaml")
            .path
    }

    private static func parseServiceOverride(
        serviceID: String,
        mapping: Node.Mapping
    ) throws -> AIBEnvironmentServiceOverride {
        var env: [String: String] = [:]
        var deployEnv: [String: String] = [:]
        var secrets: [String: SecretRef] = [:]

        if let envMap = mapping["env"]?.mapping {
            env = scalarMap(envMap)
        }
        if let deployEnvMap = (mapping["deployEnv"] ?? mapping["deploy_env"])?.mapping {
            deployEnv = scalarMap(deployEnvMap)
        }
        if let secretsMap = mapping["secrets"]?.mapping {
            for (keyNode, valueNode) in secretsMap {
                guard let envKey = keyNode.scalar?.string else { continue }
                guard let secretMap = valueNode.mapping else {
                    throw AIBEnvironmentLoaderError(
                        message: "services.\(serviceID).secrets.\(envKey) must be a mapping with 'secret' and optional 'version'"
                    )
                }
                guard let secretName = secretMap["secret"]?.scalar?.string,
                      !secretName.isEmpty else {
                    throw AIBEnvironmentLoaderError(
                        message: "services.\(serviceID).secrets.\(envKey).secret is required"
                    )
                }
                let version = secretMap["version"]?.scalar?.string
                secrets[envKey] = SecretRef(secret: secretName, version: version)
            }
        }

        return AIBEnvironmentServiceOverride(
            env: env,
            deployEnv: deployEnv,
            secrets: secrets
        )
    }

    private static func scalarMap(_ mapping: Node.Mapping) -> [String: String] {
        var result: [String: String] = [:]
        for (keyNode, valueNode) in mapping {
            guard let key = keyNode.scalar?.string,
                  let value = valueNode.scalar?.string else { continue }
            result[key] = value
        }
        return result
    }
}

public struct AIBEnvironmentLoaderError: Error, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}
