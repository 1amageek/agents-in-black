@testable import AIBCore
import Testing

@Test(.timeLimit(.minutes(1)))
func preflightDiagnosticsIncludesCommandExitCodeAndStreams() {
    let result = ShellProbe.Result(
        exitCode: 1,
        stdout: "",
        stderr: "Permission denied"
    )

    let lines = PreflightDiagnostics.lines(
        command: "gcloud services list",
        result: result
    )

    #expect(lines.contains("$ gcloud services list"))
    #expect(lines.contains("exit code: 1"))
    #expect(lines.contains("<empty>"))
    #expect(lines.contains("Permission denied"))
}
