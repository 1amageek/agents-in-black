import Foundation

public struct GCloudAccount: Sendable, Hashable, Identifiable {
    public let account: String
    public let isActive: Bool

    public var id: String { account }

    public init(account: String, isActive: Bool) {
        self.account = account
        self.isActive = isActive
    }
}

public struct GCloudProject: Sendable, Hashable, Identifiable {
    public let projectID: String
    public let name: String?

    public var id: String { projectID }

    public init(projectID: String, name: String?) {
        self.projectID = projectID
        self.name = name
    }
}

public struct GCloudRegion: Sendable, Hashable, Identifiable {
    public let locationId: String
    public let displayName: String?

    public var id: String { locationId }

    public init(locationId: String, displayName: String?) {
        self.locationId = locationId
        self.displayName = displayName
    }
}

public struct GCloudContextSnapshot: Sendable, Equatable {
    public let activeAccount: String?
    public let accounts: [GCloudAccount]
    public let activeProject: String?
    public let projects: [GCloudProject]

    public init(
        activeAccount: String?,
        accounts: [GCloudAccount],
        activeProject: String?,
        projects: [GCloudProject]
    ) {
        self.activeAccount = activeAccount
        self.accounts = accounts
        self.activeProject = activeProject
        self.projects = projects
    }
}

public struct GCloudContextService: Sendable {
    public typealias CommandRunner = @Sendable (String) async throws -> ShellProbe.Result
    public typealias LoginCommandRunner = @Sendable () async throws -> ShellProbe.Result

    private let runCommand: CommandRunner
    private let runLoginCommand: LoginCommandRunner

    public init(
        runCommand: @escaping CommandRunner = { command in
            try await ShellProbe.run(command: command)
        },
        runLoginCommand: @escaping LoginCommandRunner = {
            try await ShellProbe.run(
                command: "gcloud auth login --brief",
                timeout: .seconds(300)
            )
        }
    ) {
        self.runCommand = runCommand
        self.runLoginCommand = runLoginCommand
    }

    public func fetchContext() async throws -> GCloudContextSnapshot {
        async let accounts = fetchAccounts()
        async let activeAccount = fetchConfigValue(for: "account")
        async let projects = fetchProjects()
        async let activeProject = fetchConfigValue(for: "project")

        let resolvedAccounts = try await accounts
        let resolvedActiveAccount = try await activeAccount
        let resolvedProjects = try await projects
        let resolvedActiveProject = try await activeProject

        return GCloudContextSnapshot(
            activeAccount: resolvedActiveAccount,
            accounts: resolvedAccounts.map { account in
                GCloudAccount(
                    account: account.account,
                    isActive: account.account == resolvedActiveAccount || account.status == "ACTIVE"
                )
            },
            activeProject: resolvedActiveProject,
            projects: resolvedProjects
        )
    }

    public func switchAccount(to account: String) async throws {
        try await runConfigSetCommand(key: "account", value: account)
    }

    public func switchProject(to projectID: String) async throws {
        try await runConfigSetCommand(key: "project", value: projectID)
    }

    public func signIn() async throws {
        let result = try await runLoginCommand()
        guard result.exitCode == 0 else {
            throw commandFailure(
                phase: "gcloud-auth",
                result: result,
                fallback: "Failed to sign in to Google Cloud."
            )
        }
    }

    func fetchAccounts() async throws -> [AccountDTO] {
        let result = try await runCommand("gcloud auth list --format=json 2>/dev/null")
        guard result.exitCode == 0 else {
            throw commandFailure(phase: "gcloud-auth", result: result, fallback: "Failed to list Google accounts.")
        }

        let data = Data(result.stdout.utf8)
        return try Self.parseAccounts(from: data)
    }

    func fetchProjects() async throws -> [GCloudProject] {
        let result = try await runCommand("gcloud projects list --format='json(projectId,name)' 2>/dev/null")
        guard result.exitCode == 0 else {
            throw commandFailure(phase: "gcloud-projects", result: result, fallback: "Failed to list Google Cloud projects.")
        }

        let data = Data(result.stdout.utf8)
        return try Self.parseProjects(from: data)
    }

    public func fetchRegions(projectID: String) async throws -> [GCloudRegion] {
        let projectArg = Self.shellQuote(projectID)
        let command = "gcloud run regions list --project=\(projectArg) --format='json(locationId,displayName)' --quiet 2>/dev/null"
        let result = try await runCommand(command)
        guard result.exitCode == 0 else {
            throw commandFailure(
                phase: "gcloud-regions",
                result: result,
                fallback: "Failed to list Cloud Run regions."
            )
        }

        let data = Data(result.stdout.utf8)
        return try Self.parseRegions(from: data)
    }

    func fetchConfigValue(for key: String) async throws -> String? {
        let result = try await runCommand("gcloud config get-value \(key) 2>/dev/null")
        guard result.exitCode == 0 else {
            throw commandFailure(
                phase: "gcloud-config",
                result: result,
                fallback: "Failed to read gcloud config value '\(key)'."
            )
        }
        return Self.normalizeConfigValue(result.stdout)
    }

    func runConfigSetCommand(key: String, value: String) async throws {
        let command = "gcloud config set \(key) \(Self.shellQuote(value))"
        let result = try await runCommand(command)
        guard result.exitCode == 0 else {
            throw commandFailure(
                phase: "gcloud-config",
                result: result,
                fallback: "Failed to update gcloud \(key)."
            )
        }
    }

    static func parseAccounts(from data: Data) throws -> [AccountDTO] {
        let decoder = JSONDecoder()
        return try decoder.decode([AccountDTO].self, from: data)
            .filter { !$0.account.isEmpty }
            .sorted { lhs, rhs in
                if lhs.status == "ACTIVE", rhs.status != "ACTIVE" {
                    return true
                }
                if lhs.status != "ACTIVE", rhs.status == "ACTIVE" {
                    return false
                }
                return lhs.account.localizedStandardCompare(rhs.account) == .orderedAscending
            }
    }

    static func parseProjects(from data: Data) throws -> [GCloudProject] {
        let decoder = JSONDecoder()
        return try decoder.decode([ProjectDTO].self, from: data)
            .compactMap { project in
                guard !project.projectID.isEmpty else { return nil }
                return GCloudProject(projectID: project.projectID, name: project.name)
            }
            .sorted { lhs, rhs in
                let lhsName = lhs.name ?? lhs.projectID
                let rhsName = rhs.name ?? rhs.projectID
                return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
            }
    }

    static func parseRegions(from data: Data) throws -> [GCloudRegion] {
        let decoder = JSONDecoder()
        return try decoder.decode([RegionDTO].self, from: data)
            .compactMap { region in
                guard !region.locationId.isEmpty else { return nil }
                return GCloudRegion(locationId: region.locationId, displayName: region.displayName)
            }
            .sorted { lhs, rhs in
                lhs.locationId.localizedStandardCompare(rhs.locationId) == .orderedAscending
            }
    }

    static func normalizeConfigValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "(unset)" else { return nil }
        return trimmed
    }

    private func commandFailure(
        phase: String,
        result: ShellProbe.Result,
        fallback: String
    ) -> AIBDeployError {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = !stderr.isEmpty ? stderr : stdout
        return AIBDeployError(
            phase: phase,
            message: detail.isEmpty ? fallback : detail
        )
    }

    private static func shellQuote(_ value: String) -> String {
        guard value.contains(where: { " \t\n\"'\\$`!#&|;(){}[]<>?*~".contains($0) }) || value.isEmpty else {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension GCloudContextService {
    struct AccountDTO: Decodable, Sendable {
        let account: String
        let status: String?
    }

    struct ProjectDTO: Decodable, Sendable {
        let projectID: String
        let name: String?

        enum CodingKeys: String, CodingKey {
            case projectID = "projectId"
            case name
        }
    }

    struct RegionDTO: Decodable, Sendable {
        let locationId: String
        let displayName: String?
    }
}
