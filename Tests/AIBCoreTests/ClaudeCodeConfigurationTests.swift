import Testing
@testable import AIBCore

@Test(.timeLimit(.minutes(1)))
func claudeShellCommandUnsetsAPIAuthEnvironmentVariables() {
    let configuration = ClaudeCodeConfiguration(executablePath: "/usr/local/bin/claude")

    let command = configuration.shellCommand(prompt: "hello")

    #expect(command.contains("unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL"))
    #expect(command.contains("exec '/usr/local/bin/claude'"))
}
