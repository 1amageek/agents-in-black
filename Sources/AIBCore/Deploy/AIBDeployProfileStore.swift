import AIBWorkspace
import Foundation
import YAML

public struct AIBDeployProfile: Sendable, Equatable, Identifiable {
    public var id: String { name }

    public var name: String
    public var providerID: String
    public var gcpProject: String
    public var firebaseProject: String?
    public var region: String
    public var runtimeServiceAccount: String?

    public init(
        name: String,
        providerID: String = "gcp-cloudrun",
        gcpProject: String,
        firebaseProject: String? = nil,
        region: String,
        runtimeServiceAccount: String? = nil
    ) {
        self.name = name
        self.providerID = providerID
        self.gcpProject = gcpProject
        self.firebaseProject = firebaseProject
        self.region = region
        self.runtimeServiceAccount = runtimeServiceAccount
    }

    public var targetOverrides: [String: String] {
        var values: [String: String] = [
            "gcpProject": gcpProject,
            "region": region,
        ]
        if let firebaseProject, !firebaseProject.isEmpty {
            values["firebaseProject"] = firebaseProject
        }
        if let runtimeServiceAccount, !runtimeServiceAccount.isEmpty {
            values["serviceAccount"] = runtimeServiceAccount
        }
        return values
    }
}

public struct AIBDeployProfilesConfig: Sendable, Equatable {
    public var activeProfileName: String?
    public var profiles: [AIBDeployProfile]

    public init(activeProfileName: String? = nil, profiles: [AIBDeployProfile] = []) {
        self.activeProfileName = activeProfileName
        self.profiles = profiles
    }

    public var activeProfile: AIBDeployProfile? {
        guard let activeProfileName else { return profiles.first }
        return profiles.first { $0.name == activeProfileName } ?? profiles.first
    }
}

public protocol DeployProfileStore: Sendable {
    func load(workspaceRoot: String) throws -> AIBDeployProfilesConfig
    func save(workspaceRoot: String, config: AIBDeployProfilesConfig) throws
    func setActiveProfile(workspaceRoot: String, name: String?) throws
}

public struct DefaultDeployProfileStore: DeployProfileStore, Sendable {
    public static let relativePath = ".aib/deploy-profiles.yaml"
    private static let defaultProfileOrder = [
        "salescore-ei-stg": 0,
        "enablement-intelligence": 1,
        "vi-dev-b8a52": 2,
    ]

    public static let defaultConfig = AIBDeployProfilesConfig(
        activeProfileName: "salescore-ei-stg",
        profiles: [
            AIBDeployProfile(
                name: "salescore-ei-stg",
                gcpProject: "salescore-ei-stg",
                firebaseProject: "salescore-ei-stg",
                region: "asia-northeast1"
            ),
            AIBDeployProfile(
                name: "enablement-intelligence",
                gcpProject: "enablement-intelligence",
                firebaseProject: "enablement-intelligence",
                region: "asia-northeast1"
            ),
            AIBDeployProfile(
                name: "vi-dev-b8a52",
                gcpProject: "vi-dev-b8a52",
                firebaseProject: "vi-dev-b8a52",
                region: "asia-northeast1"
            ),
        ]
    )

    public init() {}

    public func load(workspaceRoot: String) throws -> AIBDeployProfilesConfig {
        let fileURL = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(Self.relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let config = Self.defaultConfig
            try save(workspaceRoot: workspaceRoot, config: config)
            return config
        }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        guard let node = try compose(yaml: content), let root = node.mapping else {
            return AIBDeployProfilesConfig()
        }

        let active = root["active"]?.scalar?.string
        let profiles = root["profiles"]?.mapping?.compactMap { key, value -> AIBDeployProfile? in
            guard let name = key.scalar?.string,
                  let mapping = value.mapping
            else {
                return nil
            }
            guard let gcpProject = mapping["gcpProject"]?.scalar?.string,
                  !gcpProject.isEmpty
            else {
                return nil
            }
            return AIBDeployProfile(
                name: name,
                providerID: mapping["provider"]?.scalar?.string ?? "gcp-cloudrun",
                gcpProject: gcpProject,
                firebaseProject: mapping["firebaseProject"]?.scalar?.string,
                region: mapping["region"]?.scalar?.string ?? "us-central1",
                runtimeServiceAccount: mapping["runtimeServiceAccount"]?.scalar?.string
                    ?? mapping["serviceAccount"]?.scalar?.string
            )
        } ?? []

        return AIBDeployProfilesConfig(
            activeProfileName: active,
            profiles: profiles.sorted(by: Self.sortProfiles)
        )
    }

    public func save(workspaceRoot: String, config: AIBDeployProfilesConfig) throws {
        let fileURL = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(Self.relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var profiles: [String: Any] = [:]
        for profile in config.profiles.sorted(by: Self.sortProfiles) {
            var item: [String: Any] = [
                "provider": profile.providerID,
                "gcpProject": profile.gcpProject,
                "region": profile.region,
            ]
            if let firebaseProject = profile.firebaseProject, !firebaseProject.isEmpty {
                item["firebaseProject"] = firebaseProject
            }
            if let runtimeServiceAccount = profile.runtimeServiceAccount, !runtimeServiceAccount.isEmpty {
                item["runtimeServiceAccount"] = runtimeServiceAccount
            }
            profiles[profile.name] = item
        }

        var root: [String: Any] = [
            "version": 1,
            "profiles": profiles,
        ]
        if let active = config.activeProfileName, !active.isEmpty {
            root["active"] = active
        }

        let yamlString = YAMLUtility.emitYAML(root) + "\n"
        try yamlString.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    public func setActiveProfile(workspaceRoot: String, name: String?) throws {
        var config = try load(workspaceRoot: workspaceRoot)
        config.activeProfileName = name
        try save(workspaceRoot: workspaceRoot, config: config)
    }

    private static func sortProfiles(_ lhs: AIBDeployProfile, _ rhs: AIBDeployProfile) -> Bool {
        let lhsOrder = defaultProfileOrder[lhs.name] ?? Int.max
        let rhsOrder = defaultProfileOrder[rhs.name] ?? Int.max
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
