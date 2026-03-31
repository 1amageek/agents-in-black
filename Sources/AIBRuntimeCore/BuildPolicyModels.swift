import Foundation

public enum AIBBuildMode: String, Sendable, Equatable, Codable {
    case strict
    case convenience
}

public enum AIBSourceCredentialType: String, Sendable, Equatable, Codable {
    case ssh
    case githubToken
}

public struct AIBConvenienceOptions: Sendable, Equatable, Codable {
    public var useHostCorepackCache: Bool
    public var useHostPNPMStore: Bool
    public var useRepoLocalPNPMStore: Bool

    public init(
        useHostCorepackCache: Bool = true,
        useHostPNPMStore: Bool = true,
        useRepoLocalPNPMStore: Bool = true
    ) {
        self.useHostCorepackCache = useHostCorepackCache
        self.useHostPNPMStore = useHostPNPMStore
        self.useRepoLocalPNPMStore = useRepoLocalPNPMStore
    }
}

public struct AIBSourceCredential: Sendable, Equatable, Codable {
    public var type: AIBSourceCredentialType
    public var host: String
    public var localPrivateKeyPath: String?
    public var localKnownHostsPath: String?
    public var localPrivateKeyPassphraseEnv: String?
    public var localAccessTokenEnv: String?
    public var cloudPrivateKeySecret: String?
    public var cloudKnownHostsSecret: String?

    public init(
        type: AIBSourceCredentialType = .ssh,
        host: String,
        localPrivateKeyPath: String? = nil,
        localKnownHostsPath: String? = nil,
        localPrivateKeyPassphraseEnv: String? = nil,
        localAccessTokenEnv: String? = nil,
        cloudPrivateKeySecret: String? = nil,
        cloudKnownHostsSecret: String? = nil
    ) {
        self.type = type
        self.host = host
        self.localPrivateKeyPath = localPrivateKeyPath
        self.localKnownHostsPath = localKnownHostsPath
        self.localPrivateKeyPassphraseEnv = localPrivateKeyPassphraseEnv
        self.localAccessTokenEnv = localAccessTokenEnv
        self.cloudPrivateKeySecret = cloudPrivateKeySecret
        self.cloudKnownHostsSecret = cloudKnownHostsSecret
    }

    public func isValidForLocalBuild() -> Bool {
        let normalizedHost = !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch type {
        case .ssh:
            return normalizedHost
                && !(localPrivateKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        case .githubToken:
            return normalizedHost
                && !(localAccessTokenEnv?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    public func isValidForCloudBuild() -> Bool {
        type == .ssh
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(cloudPrivateKeySecret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

public enum AIBSourceDependencyAuth: String, Sendable, Equatable, Codable {
    case ssh
}

public struct AIBSourceDependencyFinding: Sendable, Equatable, Codable {
    public var sourceFile: String
    public var requirement: String
    public var host: String
    public var auth: AIBSourceDependencyAuth

    public init(
        sourceFile: String,
        requirement: String,
        host: String,
        auth: AIBSourceDependencyAuth
    ) {
        self.sourceFile = sourceFile
        self.requirement = requirement
        self.host = host
        self.auth = auth
    }
}

public enum AIBSourceDependencyAnalyzer {
    public static func nodeGitDependencies(repoRoot: String) throws -> [AIBSourceDependencyFinding] {
        let repoURL = URL(fileURLWithPath: repoRoot)
        var findings: [AIBSourceDependencyFinding] = []

        let packageJSONURL = repoURL.appendingPathComponent("package.json")
        if FileManager.default.fileExists(atPath: packageJSONURL.path) {
            findings.append(contentsOf: try packageJSONFindings(fileURL: packageJSONURL))
        }

        let lineScannedFiles = [
            "pnpm-lock.yaml",
            "package-lock.json",
            "yarn.lock",
        ]

        for relativePath in lineScannedFiles {
            let fileURL = repoURL.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            findings.append(contentsOf: lineFindings(content: content, sourceFile: relativePath))
        }

        return deduplicated(findings)
    }

    public static func matchingLocalCredential(
        for finding: AIBSourceDependencyFinding,
        in credentials: [AIBSourceCredential]
    ) -> AIBSourceCredential? {
        credentials.first { credential in
            credential.type == .ssh
                && credential.host.caseInsensitiveCompare(finding.host) == .orderedSame
                && credential.isValidForLocalBuild()
        }
    }

    public static func matchingCloudCredential(
        for finding: AIBSourceDependencyFinding,
        in credentials: [AIBSourceCredential]
    ) -> AIBSourceCredential? {
        credentials.first { credential in
            credential.type == .ssh
                && credential.host.caseInsensitiveCompare(finding.host) == .orderedSame
                && credential.isValidForCloudBuild()
        }
    }

    public static func defaultKnownHosts(for host: String) -> String? {
        guard host.caseInsensitiveCompare("github.com") == .orderedSame else { return nil }
        return """
        github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMq2bU6M1mXc5teLoI0lp4rWuIwoMvV7bgidh+NROm4
        github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSOhIrVesVgdb59uD3gTWMukYdR4P9J66yUfX2KF1be9JY3zhLE36QTtf8l0oob8cMY3AWEzhFaww7mN58v8=
        github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2Azg+0d1dQc5sKXc5teLoI0lp4rWuIwoMvV7bgidh+NROm4w5h2e6StVWLr0lCBfbNILIRjG5coxP0JkgL+xr5Tc5rI4YacRpyvK/MrHS1LLc6IprNk508twVgW0rOvrlesBxgVjbBc088DfjIjjQVIGQXvIho2J1IpF4l6RLYHR/cmvs9s+xkVxEer8Aos75G9H1lOLRqeDyDRr1IkeIcc98BVxIQCIctodj8GZFODdgNpTiFqouBZfyqCkCmZJLdnOjFkMrDXLI4sdAlnXrhIRbkIuAeGHWxirMRHkRkNvztNFVQVw1Gc7YCOUMIqFZ3VAb9YSEuxsjjXNMTvEfgQ==
        """
    }

    private static func packageJSONFindings(fileURL: URL) throws -> [AIBSourceDependencyFinding] {
        let data = try Data(contentsOf: fileURL)
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        guard let root = jsonObject as? [String: Any] else { return [] }

        let sections = [
            "dependencies",
            "devDependencies",
            "optionalDependencies",
            "peerDependencies",
            "resolutions",
            "overrides",
        ]
        var findings: [AIBSourceDependencyFinding] = []
        for section in sections {
            guard let mapping = root[section] as? [String: Any] else { continue }
            for value in mapping.values {
                guard let requirement = value as? String else { continue }
                if let finding = finding(for: requirement, sourceFile: "package.json") {
                    findings.append(finding)
                }
            }
        }
        return findings
    }

    private static func lineFindings(content: String, sourceFile: String) -> [AIBSourceDependencyFinding] {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { finding(for: String($0), sourceFile: sourceFile) }
    }

    private static func finding(for rawRequirement: String, sourceFile: String) -> AIBSourceDependencyFinding? {
        let requirement = rawRequirement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requirement.isEmpty else { return nil }

        let patterns: [(String, String)] = [
            ("git+ssh://git@github.com/", "github.com"),
            ("ssh://git@github.com/", "github.com"),
            ("git@github.com:", "github.com"),
            ("github:", "github.com"),
        ]

        for (needle, host) in patterns where requirement.contains(needle) || requirement.hasPrefix(needle) {
            return AIBSourceDependencyFinding(
                sourceFile: sourceFile,
                requirement: requirement,
                host: host,
                auth: .ssh
            )
        }
        return nil
    }

    private static func deduplicated(_ findings: [AIBSourceDependencyFinding]) -> [AIBSourceDependencyFinding] {
        var seen: Set<String> = []
        var ordered: [AIBSourceDependencyFinding] = []
        for finding in findings {
            let key = "\(finding.sourceFile)|\(finding.host)|\(finding.requirement)"
            if seen.insert(key).inserted {
                ordered.append(finding)
            }
        }
        return ordered
    }
}
