import Foundation
import Testing
@testable import AIBCore

@Suite("LocalSecretResolver — env, file, and chain semantics")
struct LocalSecretResolverTests {

    // MARK: - Env passthrough

    @Test("Env passthrough resolves via AIB_SECRET_<UPPER_UNDERSCORE> key")
    func envPassthroughHits() async {
        let resolver = EnvPassthroughSecretResolver(environment: [
            "AIB_SECRET_OPENAI_PROD": "sk-from-env",
        ])
        let value = await resolver.resolve(secretName: "openai-prod")
        #expect(value == "sk-from-env")
    }

    @Test("Env passthrough returns nil when env key is absent")
    func envPassthroughMisses() async {
        let resolver = EnvPassthroughSecretResolver(environment: [:])
        let value = await resolver.resolve(secretName: "openai-prod")
        #expect(value == nil)
    }

    // MARK: - Local file parser

    @Test("Local file parser handles flat string entries")
    func parserFlatEntries() throws {
        let raw = """
        openai-prod: "sk-abc"
        stripe: 'sk_test'
        bare-name: plain-value
        """
        let parsed = try LocalFileSecretResolver.parse(raw)
        #expect(parsed["openai-prod"] == "sk-abc")
        #expect(parsed["stripe"] == "sk_test")
        #expect(parsed["bare-name"] == "plain-value")
    }

    @Test("Local file parser handles nested value/version form")
    func parserNestedEntries() throws {
        let raw = """
        my-secret:
          value: "nested-value"
          version: "2"
        """
        let parsed = try LocalFileSecretResolver.parse(raw)
        #expect(parsed["my-secret"] == "nested-value")
    }

    @Test("Local file parser ignores comments and blank lines")
    func parserIgnoresComments() throws {
        let raw = """
        # top-level comment
        openai-prod: "sk-abc"   # trailing comment

        stripe: 'sk_test'
        """
        let parsed = try LocalFileSecretResolver.parse(raw)
        #expect(parsed["openai-prod"] == "sk-abc")
        #expect(parsed["stripe"] == "sk_test")
    }

    @Test("Local file parser preserves '#' inside quoted values")
    func parserKeepsHashInQuotes() throws {
        let raw = #"""
        secret-with-hash: "value#with#hash"
        """#
        let parsed = try LocalFileSecretResolver.parse(raw)
        #expect(parsed["secret-with-hash"] == "value#with#hash")
    }

    @Test("Local file load returns empty resolver when file is absent")
    func loadMissingFileIsEmpty() async throws {
        let tempRoot = NSTemporaryDirectory() + "aib-secrets-missing-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tempRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }

        let resolver = try LocalFileSecretResolver.load(workspaceRoot: tempRoot)
        let value = await resolver.resolve(secretName: "anything")
        #expect(value == nil)
    }

    // MARK: - Chain semantics

    @Test("Chained resolver returns first non-nil and stops")
    func chainShortCircuits() async {
        let counter = HitCounter()
        let chain = ChainedLocalSecretResolver([
            CountingResolver(counter: counter, value: nil),
            CountingResolver(counter: counter, value: "from-second"),
            CountingResolver(counter: counter, value: "from-third"),
        ])
        let value = await chain.resolve(secretName: "x")
        #expect(value == "from-second")
        #expect(await counter.count == 2)
    }

    @Test("Chained resolver returns nil when all resolvers miss")
    func chainAllMiss() async {
        let chain = ChainedLocalSecretResolver([
            CountingResolver(counter: HitCounter(), value: nil),
            CountingResolver(counter: HitCounter(), value: nil),
        ])
        let value = await chain.resolve(secretName: "x")
        #expect(value == nil)
    }
}

// MARK: - Test doubles

private actor HitCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

private struct CountingResolver: LocalSecretResolver {
    let counter: HitCounter
    let value: String?
    func resolve(secretName: String) async -> String? {
        await counter.bump()
        return value
    }
}
