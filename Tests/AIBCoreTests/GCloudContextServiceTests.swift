import AIBCore
import Foundation
import Testing

private actor MockGCloudCommandRunner {
    private let results: [String: ShellProbe.Result]
    private(set) var commands: [String] = []

    init(results: [String: ShellProbe.Result]) {
        self.results = results
    }

    func run(_ command: String) async throws -> ShellProbe.Result {
        commands.append(command)
        guard let result = results[command] else {
            throw TestFailure("Unexpected command: \(command)")
        }
        return result
    }

    func capturedCommands() -> [String] {
        commands
    }
}

private struct TestFailure: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

@Test(.timeLimit(.minutes(1)))
func gcloudContextFetchesAccountsAndProjects() async throws {
    let runner = MockGCloudCommandRunner(results: [
        "gcloud auth list --format=json 2>/dev/null": .init(
            exitCode: 0,
            stdout: """
            [
              {"account":"inactive@example.com","status":""},
              {"account":"active@example.com","status":"ACTIVE"}
            ]
            """,
            stderr: ""
        ),
        "gcloud config get-value account 2>/dev/null": .init(
            exitCode: 0,
            stdout: "active@example.com",
            stderr: ""
        ),
        "gcloud projects list --format='json(projectId,name)' 2>/dev/null": .init(
            exitCode: 0,
            stdout: """
            [
              {"projectId":"project-beta","name":"Beta"},
              {"projectId":"project-alpha","name":"Alpha"}
            ]
            """,
            stderr: ""
        ),
        "gcloud config get-value project 2>/dev/null": .init(
            exitCode: 0,
            stdout: "project-alpha",
            stderr: ""
        ),
    ])

    let service = GCloudContextService(runCommand: { command in
        try await runner.run(command)
    })

    let context = try await service.fetchContext()

    #expect(context.activeAccount == "active@example.com")
    #expect(context.activeProject == "project-alpha")
    #expect(context.accounts.map(\.account) == ["active@example.com", "inactive@example.com"])
    #expect(context.accounts.first?.isActive == true)
    #expect(context.projects.map(\.projectID) == ["project-alpha", "project-beta"])
}

@Test(.timeLimit(.minutes(1)))
func gcloudProjectSwitchUsesConfigSetCommand() async throws {
    let runner = MockGCloudCommandRunner(results: [
        "gcloud config set project target-project": .init(
            exitCode: 0,
            stdout: "Updated property [core/project].",
            stderr: ""
        ),
    ])

    let service = GCloudContextService(runCommand: { command in
        try await runner.run(command)
    })

    try await service.switchProject(to: "target-project")

    let commands = await runner.capturedCommands()
    #expect(commands == ["gcloud config set project target-project"])
}

@Test(.timeLimit(.minutes(1)))
func gcloudSignInUsesInjectedLoginCommand() async throws {
    let service = GCloudContextService(
        runCommand: { command in
            throw TestFailure("Unexpected command: \(command)")
        },
        runLoginCommand: {
            .init(
                exitCode: 0,
                stdout: "You are now logged in.",
                stderr: ""
            )
        }
    )

    try await service.signIn()
}
