import Foundation
import Testing
@testable import AIBConfig

@Suite("SecretRef — JSON codec + version handling")
struct SecretRefCodecTests {

    @Test("Default version resolves to 'latest' when not pinned")
    func defaultVersionIsLatest() {
        let ref = SecretRef(secret: "ANTHROPIC_API_KEY")
        #expect(ref.resolvedVersion == "latest")
    }

    @Test("Explicit version pins to numeric value")
    func explicitVersionPinned() {
        let ref = SecretRef(secret: "DB_PASSWORD", version: "3")
        #expect(ref.resolvedVersion == "3")
    }

    @Test("JSON round-trip preserves secret + version")
    func jsonRoundTripWithVersion() throws {
        let original = SecretRef(secret: "STRIPE_SK", version: "7")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SecretRef.self, from: data)
        #expect(decoded.secret == "STRIPE_SK")
        #expect(decoded.version == "7")
        #expect(decoded == original)
    }

    @Test("JSON round-trip preserves a missing version as nil (not 'latest')")
    func jsonRoundTripWithoutVersion() throws {
        let original = SecretRef(secret: "OPENAI_API_KEY")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SecretRef.self, from: data)
        // The on-disk representation must not silently bake in 'latest' — the
        // user's intent (track latest) is encoded by the *absence* of a version.
        #expect(decoded.version == nil)
        #expect(decoded.resolvedVersion == "latest")
    }

    @Test("Hashable + Equatable so dictionaries can key on SecretRef")
    func hashableAndEquatable() {
        let a = SecretRef(secret: "K", version: "1")
        let b = SecretRef(secret: "K", version: "1")
        let c = SecretRef(secret: "K", version: "2")
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }
}
