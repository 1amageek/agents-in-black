import Foundation

public enum DeploySecretValueGenerator {
    private static let generatedByteCount = 32
    private static let generatedSuffixes: [String] = [
        "_SIGNING_SECRET",
        "_WEBHOOK_SECRET",
        "_SESSION_SECRET",
        "_ENCRYPTION_KEY",
        "_SECRET_KEY",
    ]
    private static let generatedExactNames: Set<String> = [
        "SIGNING_SECRET",
        "WEBHOOK_SECRET",
        "SESSION_SECRET",
        "ENCRYPTION_KEY",
        "SECRET_KEY",
    ]
    private static let externallyIssuedMarkers: [String] = [
        "API_KEY",
        "ACCESS_TOKEN",
        "REFRESH_TOKEN",
        "PRIVATE_KEY",
        "CLIENT_SECRET",
    ]

    public static func canGenerate(name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return false }
        guard !externallyIssuedMarkers.contains(where: { normalized.contains($0) }) else { return false }
        return generatedExactNames.contains(normalized)
            || generatedSuffixes.contains(where: { normalized.hasSuffix($0) })
    }

    public static func generateHexSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<generatedByteCount)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }
}
