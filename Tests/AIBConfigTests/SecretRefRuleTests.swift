import AIBRuntimeCore
import Foundation
import Testing
@testable import AIBConfig

@Suite("SecretRef rule — S001-S004 lint coverage")
struct SecretRefRuleTests {

    @Test("S001: empty secret name is flagged as error")
    func s001EmptySecretIsError() {
        let violations = SecretRefRule.violations(
            secrets: ["OPENAI_API_KEY": SecretRef(secret: "  ")],
            env: [:],
            localEnv: [:],
            deployEnv: [:]
        )
        let s001 = violations.filter { $0.ruleID == "S001" }
        #expect(s001.count == 1)
        #expect(s001.first?.severity == .error)
        #expect(s001.first?.key == "OPENAI_API_KEY")
    }

    @Test("S002: lowercase / dashed env-style key is flagged as warning")
    func s002InvalidEnvKeyIsWarning() {
        let violations = SecretRefRule.violations(
            secrets: ["openai-api-key": SecretRef(secret: "openai-prod")],
            env: [:],
            localEnv: [:],
            deployEnv: [:]
        )
        let s002 = violations.filter { $0.ruleID == "S002" }
        #expect(s002.count == 1)
        #expect(s002.first?.severity == .warning)
    }

    @Test("S002: leading digit on env key is flagged")
    func s002LeadingDigitIsFlagged() {
        let violations = SecretRefRule.violations(
            secrets: ["1KEY": SecretRef(secret: "valid-name")],
            env: [:],
            localEnv: [:],
            deployEnv: [:]
        )
        #expect(violations.contains { $0.ruleID == "S002" })
    }

    @Test("S003: invalid Secret Manager name (slash) is flagged as error")
    func s003InvalidSecretNameIsError() {
        let violations = SecretRefRule.violations(
            secrets: ["OPENAI_API_KEY": SecretRef(secret: "openai/prod")],
            env: [:],
            localEnv: [:],
            deployEnv: [:]
        )
        let s003 = violations.filter { $0.ruleID == "S003" }
        #expect(s003.count == 1)
        #expect(s003.first?.severity == .error)
    }

    @Test("S003: 256-char secret name is flagged")
    func s003TooLongSecretNameIsFlagged() {
        let longName = String(repeating: "a", count: 256)
        let violations = SecretRefRule.violations(
            secrets: ["KEY": SecretRef(secret: longName)],
            env: [:],
            localEnv: [:],
            deployEnv: [:]
        )
        #expect(violations.contains { $0.ruleID == "S003" })
    }

    @Test("S004: same key in env and secrets is flagged as error")
    func s004CollisionWithEnvIsError() {
        let violations = SecretRefRule.violations(
            secrets: ["DATABASE_URL": SecretRef(secret: "db-url")],
            env: ["DATABASE_URL": "postgres://example"],
            localEnv: [:],
            deployEnv: [:]
        )
        let s004 = violations.filter { $0.ruleID == "S004" }
        #expect(s004.count == 1)
        #expect(s004.first?.severity == .error)
        #expect(s004.first?.reason.contains("env") == true)
    }

    @Test("S004: collision across all three env maps lists each map")
    func s004CollisionListsAllMaps() {
        let violations = SecretRefRule.violations(
            secrets: ["DATABASE_URL": SecretRef(secret: "db")],
            env: ["DATABASE_URL": "x"],
            localEnv: ["DATABASE_URL": "y"],
            deployEnv: ["DATABASE_URL": "z"]
        )
        let s004 = violations.filter { $0.ruleID == "S004" }
        #expect(s004.count == 1)
        let reason = s004.first?.reason ?? ""
        #expect(reason.contains("env"))
        #expect(reason.contains("local_env"))
        #expect(reason.contains("deploy_env"))
    }

    @Test("Valid SecretRef yields no violations")
    func validSecretRefYieldsNothing() {
        let violations = SecretRefRule.violations(
            secrets: ["OPENAI_API_KEY": SecretRef(secret: "openai-prod", version: "2")],
            env: ["LOG_LEVEL": "info"],
            localEnv: [:],
            deployEnv: [:]
        )
        #expect(violations.isEmpty)
    }

    @Test("Validator surfaces SecretRef violations partitioned by severity")
    func validatorPartitionsBySeverity() throws {
        let service = makeService(
            id: "svc",
            secrets: [
                "GOOD_KEY": SecretRef(secret: "good-name"),
                "openapi-key": SecretRef(secret: ""),    // S001 (error) + S002 (warning)
            ]
        )
        let config = AIBConfig(version: 1, gateway: .init(), services: [service])
        let result = try AIBConfigValidator.validate(config)

        #expect(result.errors.contains { $0.contains("[S001]") })
        #expect(result.warnings.contains { $0.contains("[S002]") })
    }

    @Test("Validator hard-errors on collision with env map")
    func validatorErrorsOnCollision() throws {
        let service = makeService(
            id: "svc",
            env: ["API_KEY": "static"],
            secrets: ["API_KEY": SecretRef(secret: "api-key-secret")]
        )
        let config = AIBConfig(version: 1, gateway: .init(), services: [service])
        let result = try AIBConfigValidator.validate(config)
        #expect(result.errors.contains { $0.contains("[S004]") })
    }

    // MARK: - Helpers

    private func makeService(
        id: ServiceID,
        env: [String: String] = [:],
        localEnv: [String: String] = [:],
        deployEnv: [String: String] = [:],
        secrets: [String: SecretRef] = [:]
    ) -> ServiceConfig {
        ServiceConfig(
            id: id,
            kind: .mcp,
            mountPath: "/\(id.rawValue)",
            port: 0,
            run: ["node", "server.js"],
            watchMode: .internal,
            env: env,
            localEnv: localEnv,
            deployEnv: deployEnv,
            secrets: secrets,
            health: .init(),
            restart: .init()
        )
    }
}
