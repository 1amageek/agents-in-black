import Foundation
import Testing
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
