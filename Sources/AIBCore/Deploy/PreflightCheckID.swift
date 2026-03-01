import Foundation

/// Identifies a specific preflight dependency check.
/// Uses struct instead of enum so each provider can define its own check IDs.
public struct PreflightCheckID: RawRepresentable, Sendable, Hashable, Identifiable {
    public var rawValue: String
    public var id: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

// MARK: - Common Check IDs (shared across providers)

extension PreflightCheckID {
    public static let dockerInstalled = PreflightCheckID(rawValue: "dockerInstalled")
    public static let dockerDaemonRunning = PreflightCheckID(rawValue: "dockerDaemonRunning")
}

// MARK: - GCP-specific Check IDs

extension PreflightCheckID {
    public static let gcloudInstalled = PreflightCheckID(rawValue: "gcloudInstalled")
    public static let gcloudAuthenticated = PreflightCheckID(rawValue: "gcloudAuthenticated")
    public static let gcloudProjectConfigured = PreflightCheckID(rawValue: "gcloudProjectConfigured")
    public static let artifactRegistryConfigured = PreflightCheckID(rawValue: "artifactRegistryConfigured")
    public static let cloudRunAPIEnabled = PreflightCheckID(rawValue: "cloudRunAPIEnabled")
}
