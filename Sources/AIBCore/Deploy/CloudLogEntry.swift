import Foundation

/// One Cloud-side log entry returned by `DeploymentProvider.fetchServiceLogs`
/// or yielded by `DeploymentProvider.tailServiceLogs`.
public struct CloudLogEntry: Sendable, Identifiable, Equatable, Hashable {

    public let id: UUID

    /// When the entry was produced by the service.
    public let timestamp: Date

    /// Provider-reported severity (`DEFAULT`, `INFO`, `WARNING`, `ERROR`, ...).
    /// Free-form so providers can pass through their native vocabulary.
    public let severity: String

    /// Provider-specific revision identifier (Cloud Run revision name), when known.
    public let revisionName: String?

    /// Human-readable message extracted from `textPayload` /
    /// `jsonPayload.message` / `protoPayload`, in that order.
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        severity: String,
        revisionName: String?,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.revisionName = revisionName
        self.message = message
    }
}
