@testable import AIBCore
import Testing

@Test(.timeLimit(.minutes(1)))
func deploySecretGeneratorAllowsInternalSigningSecretsOnly() {
    #expect(DeploySecretValueGenerator.canGenerate(name: "STORAGE_UPLOAD_SIGNING_SECRET"))
    #expect(DeploySecretValueGenerator.canGenerate(name: "SESSION_SECRET"))
    #expect(!DeploySecretValueGenerator.canGenerate(name: "ANTHROPIC_API_KEY"))
    #expect(!DeploySecretValueGenerator.canGenerate(name: "GITHUB_ACCESS_TOKEN"))
    #expect(!DeploySecretValueGenerator.canGenerate(name: "OAUTH_CLIENT_SECRET"))
}

@Test(.timeLimit(.minutes(1)))
func generatedDeploySecretIsHexEncoded32ByteValue() {
    let value = DeploySecretValueGenerator.generateHexSecret()
    let hexCharacters = Set("0123456789abcdef")

    #expect(value.count == 64)
    #expect(value.allSatisfy { hexCharacters.contains($0) })
}
