import AIBRuntimeCore
import Foundation
import Testing
@testable import AIBConfig

@Suite("Env scope — local vs deploy resolver and scope rule")
struct EnvScopeTests {

    @Test("Local target merges localEnv on top of universal env")
    func localTargetMergesLocalEnv() {
        let service = makeService(
            env: ["GCLOUD_PROJECT": "vi-dev", "LOG_LEVEL": "info"],
            localEnv: ["FIRESTORE_EMULATOR_HOST": "host.container.internal:8080", "LOG_LEVEL": "debug"],
            deployEnv: ["LOG_LEVEL": "warn"]
        )
        let resolved = service.resolvedEnv(for: .local)
        // Universal vars survive.
        #expect(resolved["GCLOUD_PROJECT"] == "vi-dev")
        // Local-only vars are present.
        #expect(resolved["FIRESTORE_EMULATOR_HOST"] == "host.container.internal:8080")
        // Local override wins on key collisions.
        #expect(resolved["LOG_LEVEL"] == "debug")
        // Deploy-only vars are excluded.
        #expect(resolved.count == 3)
    }

    @Test("Deploy target merges deployEnv but excludes localEnv")
    func deployTargetExcludesLocalEnv() {
        let service = makeService(
            env: ["GCLOUD_PROJECT": "vi-prod"],
            localEnv: ["FIRESTORE_EMULATOR_HOST": "host.container.internal:8080"],
            deployEnv: ["LOG_LEVEL": "warn"]
        )
        let resolved = service.resolvedEnv(for: .deploy)
        // Local-only emulator host must not leak into deploy — this is the
        // entire reason this layer exists.
        #expect(resolved["FIRESTORE_EMULATOR_HOST"] == nil)
        #expect(resolved["GCLOUD_PROJECT"] == "vi-prod")
        #expect(resolved["LOG_LEVEL"] == "warn")
    }

    @Test("EnvScopeRule flags emulator host keys in universal scope")
    func ruleFlagsEmulatorKeys() {
        let env = [
            "FIRESTORE_EMULATOR_HOST": "host.container.internal:8080",
            "STORAGE_EMULATOR_HOST": "http://localhost:9199",
            "GCLOUD_PROJECT": "vi-prod",
        ]
        let violations = EnvScopeRule.violations(in: env)
        let keys = Set(violations.map(\.key))
        #expect(keys == ["FIRESTORE_EMULATOR_HOST", "STORAGE_EMULATOR_HOST"])
    }

    @Test("EnvScopeRule flags suspicious values pointing at local hosts")
    func ruleFlagsLocalHostValues() {
        let env = [
            "API_URL": "http://host.container.internal:9000",
            "OTHER_URL": "http://127.0.0.1:9090",
            "PROD_URL": "https://api.example.com",
        ]
        let violations = EnvScopeRule.violations(in: env)
        let keys = Set(violations.map(\.key))
        #expect(keys == ["API_URL", "OTHER_URL"])
    }

    @Test("Validator emits a warning for local-only entries in universal env")
    func validatorWarnsForUniversalEmulatorEntry() throws {
        let service = makeService(
            id: "leaky-mcp",
            kind: .mcp,
            env: ["FIRESTORE_EMULATOR_HOST": "host.container.internal:8080"],
            localEnv: [:],
            deployEnv: [:]
        )
        let config = AIBConfig(
            version: 1,
            gateway: .init(),
            services: [service]
        )
        let result = try AIBConfigValidator.validate(config)
        #expect(result.warnings.contains { $0.contains("FIRESTORE_EMULATOR_HOST") })
    }

    // MARK: - Helpers

    private func makeService(
        id: ServiceID = "svc",
        kind: ServiceKind = .mcp,
        env: [String: String] = [:],
        localEnv: [String: String] = [:],
        deployEnv: [String: String] = [:]
    ) -> ServiceConfig {
        ServiceConfig(
            id: id,
            kind: kind,
            mountPath: "/svc",
            port: 0,
            run: ["node", "server.js"],
            watchMode: .internal,
            env: env,
            localEnv: localEnv,
            deployEnv: deployEnv,
            health: .init(),
            restart: .init()
        )
    }
}
