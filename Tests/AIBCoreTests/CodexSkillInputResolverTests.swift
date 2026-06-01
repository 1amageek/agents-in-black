import Foundation
import Testing
import AIBRuntimeCore
@testable import AIBCore

@Test(.timeLimit(.minutes(1)))
func codexSkillInputUsesAppServerAdvertisedNameMatchingAgentCard() throws {
    let pluginRoot = try makePluginRoot()

    let inputs = try CodexSkillInputResolver.skillInputs(
        pluginRootPath: pluginRoot.path,
        prompt: "必須指定の contact-research skill を使ってください。"
    )

    #expect(inputs.count == 1)
    #expect(inputs.first?["type"] as? String == "skill")
    #expect(inputs.first?["name"] as? String == "aib-agent-node:contact-research")
    #expect((inputs.first?["path"] as? String)?.hasSuffix("/skills/contact-research/SKILL.md") == true)
    #expect(try CodexSkillInputResolver.selectedSkillIDs(
        pluginRootPath: pluginRoot.path,
        prompt: "必須指定の contact-research skill を使ってください。"
    ) == ["contact-research"])

    let cardSkills = try CodexSkillInputResolver.agentCardSkills(pluginRootPath: pluginRoot.path)
    #expect(cardSkills.map(\.id) == ["aib-agent-node:contact-research"])
    #expect(cardSkills.map(\.name) == ["Contact Research"])
}

@Test(.timeLimit(.minutes(1)))
func requiredSkillDetectionDoesNotTreatGenericSkillTextAsAnID() {
    #expect(CodexSkillInputResolver.requiredSkillID(prompt: "Use this skill for the current job.") == nil)
    #expect(CodexSkillInputResolver.requiredSkillID(prompt: "Use contact-research skill for the current job.") == "contact-research")
}

@Test(.timeLimit(.minutes(1)))
func requestedSkillIDSelectsSkillWithoutPromptMention() throws {
    let pluginRoot = try makePluginRoot()

    let inputs = try CodexSkillInputResolver.skillInputs(
        pluginRootPath: pluginRoot.path,
        prompt: "Please run the current job.",
        requestedSkillID: "contact-research"
    )

    #expect(inputs.count == 1)
    #expect(inputs.first?["name"] as? String == "aib-agent-node:contact-research")
}

@Test(.timeLimit(.minutes(1)))
func requiredSkillSelectionDoesNotAttachOtherMentionedSkills() throws {
    let pluginRoot = try makePluginRoot()
    try writeSkill(
        id: "proposal-deck",
        name: "Proposal Deck",
        description: "Create proposal decks.",
        tags: "proposal-deck, deck",
        root: pluginRoot
    )

    let selectedSkillIDs = try CodexSkillInputResolver.selectedSkillIDs(
        pluginRootPath: pluginRoot.path,
        prompt: "You MUST use the `contact-research` skill. Do not create a proposal-deck in this job."
    )

    #expect(selectedSkillIDs == ["contact-research"])
}

@Test(.timeLimit(.minutes(1)))
func codexAppServerRuntimeConfigDisablesHostCodexFeatures() throws {
    let config = try CodexAppServerRuntimeConfig(
        context: AgentRunnerContext(serviceID: "agent-a/app")
    )

    #expect(config.mcpServerNames.isEmpty)
    #expect(config.configOverrides.contains("include_apps_instructions=false"))
    #expect(config.configOverrides.contains("include_environment_context=false"))
    #expect(config.configOverrides.contains("include_permissions_instructions=false"))
    #expect(config.configOverrides.contains("project_doc_max_bytes=0"))
    #expect(config.configOverrides.contains("features.apps=false"))
    #expect(config.configOverrides.contains("features.plugins=false"))
    #expect(config.configOverrides.contains("features.tool_search=false"))
    #expect(config.configOverrides.contains("features.tool_suggest=false"))
    #expect(config.configOverrides.contains("features.image_generation=false"))
    #expect(config.configOverrides.contains("features.browser_use=false"))
    #expect(config.configOverrides.contains("features.computer_use=false"))
    #expect(config.configOverrides.contains("skills.bundled={enabled=false}"))
    #expect(!config.configOverrides.contains("tools.web_search=true"))
}

@Test(.timeLimit(.minutes(1)))
func codexJSONEncodesTopLevelFragments() throws {
    #expect(try CodexJSON.stringify("accept") == #""accept""#)
    #expect(try CodexJSON.stringify(NSNull()) == "null")
}

@Test(.timeLimit(.minutes(1)))
func codexAppServerServerRequestResponderUsesCurrentSchema() throws {
    let commandApproval = CodexAppServerServerRequestResponder.result(
        for: "item/commandExecution/requestApproval"
    )
    let commandData = try JSONSerialization.data(withJSONObject: commandApproval)
    let commandObject = try #require(JSONSerialization.jsonObject(with: commandData) as? [String: String])
    #expect(commandObject == ["decision": "accept"])

    let userInput = CodexAppServerServerRequestResponder.result(for: "item/tool/requestUserInput")
    let userInputData = try JSONSerialization.data(withJSONObject: userInput)
    let userInputObject = try #require(JSONSerialization.jsonObject(with: userInputData) as? [String: Any])
    #expect(userInputObject["answers"] is [String: Any])

    let elicitation = CodexAppServerServerRequestResponder.result(
        for: "mcpServer/elicitation/request",
        params: [
            "mode": "form",
            "requestedSchema": [
                "type": "object",
                "properties": [
                    "confirmed": [
                        "type": "boolean",
                    ],
                    "limit": [
                        "type": "integer",
                        "default": 100,
                    ],
                ],
                "required": ["confirmed"],
            ],
        ]
    )
    let elicitationData = try JSONSerialization.data(withJSONObject: elicitation)
    let elicitationObject = try #require(JSONSerialization.jsonObject(with: elicitationData) as? [String: Any])
    #expect(elicitationObject["action"] as? String == "accept")
    let elicitationContent = try #require(elicitationObject["content"] as? [String: Any])
    #expect(elicitationContent["confirmed"] as? Bool == true)
    #expect(elicitationContent["limit"] as? Int == 100)

    let urlElicitation = CodexAppServerServerRequestResponder.result(
        for: "mcpServer/elicitation/request",
        params: [
            "mode": "url",
            "url": "https://example.com/auth",
        ]
    )
    let urlElicitationData = try JSONSerialization.data(withJSONObject: urlElicitation)
    let urlElicitationObject = try #require(JSONSerialization.jsonObject(with: urlElicitationData) as? [String: Any])
    #expect(urlElicitationObject["action"] as? String == "decline")
    #expect(urlElicitationObject["content"] is NSNull)
}

@Test(.timeLimit(.minutes(1)))
func codexAppServerRuntimeConfigKeepsOnlyAIBMCPServers() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-codex-config-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // Best-effort cleanup for temp test directory.
        }
    }

    let mcpConfig = root.appendingPathComponent("mcp.json")
    try """
    {
      "mcpServers": {
        "agent/api": {
          "url": "http://127.0.0.1:18080/mcp",
          "headers": {
            "X-AIB-Service": "agent"
          }
        }
      }
    }
    """.write(to: mcpConfig, atomically: true, encoding: .utf8)

    let config = try CodexAppServerRuntimeConfig(
        context: AgentRunnerContext(
            serviceID: "agent-a/app",
            mcpConfigPath: mcpConfig.path
        )
    )

    #expect(config.mcpServerNames == ["agent-api"])
    #expect(config.configOverrides.contains("features.apps=false"))
    #expect(config.configOverrides.contains("mcp_servers.agent-api.type=\"http\""))
    #expect(config.configOverrides.contains("mcp_servers.agent-api.url=\"http://127.0.0.1:18080/mcp\""))
    #expect(config.configOverrides.contains("mcp_servers.agent-api.http_headers={ \"X-AIB-Service\" = \"agent\" }"))
}

@Test(.timeLimit(.minutes(1)))
func codexAppServerRuntimeConfigReadsMCPFromPluginRoot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-codex-plugin-config-test-\(UUID().uuidString)", isDirectory: true)
    let pluginRoot = root.appendingPathComponent(".aib/generated/runtime/plugins/agent-a__app", isDirectory: true)
    try FileManager.default.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // Best-effort cleanup for temp test directory.
        }
    }

    try """
    {
      "mcpServers": {
        "hubspot-mcp-main": {
          "type": "http",
          "url": "http://127.0.0.1:18080/hubspot-mcp/mcp"
        },
        "proposal-mcp-main": {
          "type": "http",
          "url": "http://127.0.0.1:18080/proposal-mcp/mcp"
        }
      }
    }
    """.write(
        to: pluginRoot.appendingPathComponent(CodexAppServerPluginBundle.mcpConfigFileName),
        atomically: true,
        encoding: .utf8
    )

    let config = try CodexAppServerRuntimeConfig(
        context: AgentRunnerContext(
            serviceID: "agent-a/app",
            pluginRootPath: pluginRoot.path
        )
    )

    #expect(config.mcpServerNames == ["hubspot-mcp-main", "proposal-mcp-main"])
    #expect(config.configOverrides.contains("features.apps=false"))
    #expect(config.configOverrides.contains("mcp_servers.hubspot-mcp-main.type=\"http\""))
    #expect(config.configOverrides.contains("mcp_servers.hubspot-mcp-main.url=\"http://127.0.0.1:18080/hubspot-mcp/mcp\""))
    #expect(config.configOverrides.contains("mcp_servers.proposal-mcp-main.type=\"http\""))
    #expect(config.configOverrides.contains("mcp_servers.proposal-mcp-main.url=\"http://127.0.0.1:18080/proposal-mcp/mcp\""))
}

@Test(.timeLimit(.minutes(1)))
func codexAppServerEnvironmentUsesServiceScopedCodexHome() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-codex-env-test-\(UUID().uuidString)", isDirectory: true)
    let pluginRoot = root
        .appendingPathComponent(".aib/generated/runtime/plugins/agent-a__app", isDirectory: true)
    let authSourceRoot = root.appendingPathComponent("host-codex", isDirectory: true)
    try FileManager.default.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: authSourceRoot, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // Best-effort cleanup for temp test directory.
        }
    }

    try #"{"tokens":[]}"#.write(
        to: authSourceRoot.appendingPathComponent("auth.json"),
        atomically: true,
        encoding: .utf8
    )
    try """
    [mcp_servers.host]
    command = "host-only"
    """.write(
        to: authSourceRoot.appendingPathComponent("config.toml"),
        atomically: true,
        encoding: .utf8
    )

    let environment = try CodexAppServerEnvironment.processEnvironment(
        context: AgentRunnerContext(
            serviceID: "agent-a/app",
            pluginRootPath: pluginRoot.path
        ),
        authSourceRoot: authSourceRoot,
        baseEnvironment: ["PATH": "/usr/bin", "CODEX_HOME": authSourceRoot.path]
    )

    let codexHome = try #require(environment["CODEX_HOME"])
    #expect(codexHome.hasSuffix("/.aib/state/codex-home/agent-a__app"))
    #expect(codexHome != authSourceRoot.path)
    #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json").path))
    #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: codexHome).appendingPathComponent("config.toml").path))
    #expect(environment["HOME"] == codexHome)
    #expect(environment["AIB_PLUGIN_DIR"] == pluginRoot.path)
    #expect(environment["AIB_PLUGIN_SKILLS_DIR"] == pluginRoot.appendingPathComponent("skills").path)
    #expect(environment["AIB_SKILL_DISCOVERY_MODE"] == "closed-plugin")
}

@Test(.timeLimit(.minutes(1)))
func codexAppServerEnvironmentIsolatesEvenWithoutPluginRoot() throws {
    let authSourceRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-codex-env-auth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: authSourceRoot, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: authSourceRoot)
        } catch {
            // Best-effort cleanup for temp test directory.
        }
    }

    try #"{"tokens":[]}"#.write(
        to: authSourceRoot.appendingPathComponent("auth.json"),
        atomically: true,
        encoding: .utf8
    )

    let environment = try CodexAppServerEnvironment.processEnvironment(
        context: AgentRunnerContext(serviceID: "agent-a/app"),
        authSourceRoot: authSourceRoot,
        baseEnvironment: ["PATH": "/usr/bin", "CODEX_HOME": authSourceRoot.path]
    )

    let codexHome = try #require(environment["CODEX_HOME"])
    #expect(codexHome != authSourceRoot.path)
    #expect(codexHome.contains("/aib-codex-home/agent-a__app"))
    #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json").path))
    #expect(environment["HOME"] == codexHome)
}

@Test(.timeLimit(.minutes(1)))
func codexAppServerEnvironmentCopiesMountedAuthJSONIntoWritableCodexHome() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-codex-env-mounted-auth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // Best-effort cleanup for temp test directory.
        }
    }

    let mountedAuthJSON = root.appendingPathComponent("codex-auth.json", isDirectory: false)
    let writableCodexHome = root.appendingPathComponent("tmp-codex", isDirectory: true)
    try #"{"auth_mode":"chatgpt","tokens":{"refresh_token":"token"}}"#.write(
        to: mountedAuthJSON,
        atomically: true,
        encoding: .utf8
    )

    let environment = try CodexAppServerEnvironment.processEnvironment(
        context: AgentRunnerContext(serviceID: "agent-a/app"),
        baseEnvironment: [
            "PATH": "/usr/bin",
            "AIB_CODEX_AUTH_JSON": mountedAuthJSON.path,
            "CODEX_HOME": writableCodexHome.path,
        ]
    )

    let codexHome = try #require(environment["CODEX_HOME"])
    #expect(codexHome == writableCodexHome.path)
    #expect(environment["HOME"] == writableCodexHome.path)
    #expect(FileManager.default.fileExists(atPath: writableCodexHome.appendingPathComponent("auth.json").path))
}

@Test(.timeLimit(.minutes(1)))
func codexAppServerSandboxPolicyUsesWorkspaceWrite() {
    let policy = CodexAppServerSandboxPolicy.workspaceWrite(executionDirectory: "/tmp/aib-service")

    #expect(policy["type"] as? String == "workspaceWrite")
    #expect(policy["networkAccess"] as? Bool == true)
    #expect(policy["writableRoots"] as? [String] == ["/tmp/aib-service"])
}

private func makePluginRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-skill-test-\(UUID().uuidString)", isDirectory: true)
    let metadata = root.appendingPathComponent(".codex-plugin", isDirectory: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    try #"{"name":"aib-agent-node"}"#.write(
        to: metadata.appendingPathComponent("plugin.json"),
        atomically: true,
        encoding: .utf8
    )
    try writeSkill(
        id: "contact-research",
        name: "Contact Research",
        description: "Research contacts.",
        tags: "contact-research, contact",
        root: root
    )
    return root
}

private func writeSkill(
    id: String,
    name: String,
    description: String,
    tags: String,
    root: URL
) throws {
    let skill = root
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try """
    ---
    name: \(name)
    description: \(description)
    tags: [\(tags)]
    ---

    # \(name)
    """.write(
        to: skill.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
}
