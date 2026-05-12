import Testing
@testable import AIBCore

@Suite("Deploy error details")
struct DeployErrorDetailTests {

    @Test("Failed command message includes recent stdout and stderr")
    func failedCommandMessageIncludesRecentOutput() {
        let command = DeployCommand(
            label: "Building and pushing image",
            arguments: ["bash", "-lc", "exit 1"],
            stepID: AIBDeployStep.dockerBuild.rawValue
        )
        let result = ProcessRunResult(
            exitCode: 1,
            stdout: "build step 1\nfailed to solve: process exited with code 1\n",
            stderr: "denied: Permission denied while pushing image\n"
        )

        let message = DefaultDeployExecutor.commandFailureMessage(command: command, result: result)

        #expect(message.contains("Building and pushing image failed (exit 1)"))
        #expect(message.contains("Recent command output:"))
        #expect(message.contains("stderr:"))
        #expect(message.contains("denied: Permission denied while pushing image"))
        #expect(message.contains("stdout:"))
        #expect(message.contains("failed to solve: process exited with code 1"))
    }

    @Test("Failed command message falls back to summary when output is empty")
    func failedCommandMessageFallsBackToSummary() {
        let command = DeployCommand(
            label: "Deploying to Cloud Run",
            arguments: ["gcloud", "run", "deploy"],
            stepID: AIBDeployStep.serviceDeploy.rawValue
        )
        let result = ProcessRunResult(exitCode: 1, stdout: "", stderr: "")

        let message = DefaultDeployExecutor.commandFailureMessage(command: command, result: result)

        #expect(message == "Deploying to Cloud Run failed (exit 1)")
    }
}
