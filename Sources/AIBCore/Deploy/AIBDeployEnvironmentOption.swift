import Foundation

/// Environment option discovered from `.aib/environments`.
public struct AIBDeployEnvironmentOption: Identifiable, Sendable, Equatable, Hashable {
    public let name: String
    public let targetProject: String?
    public let region: String?
    public let serviceAccount: String?

    public var id: String { name }

    public init(
        name: String,
        targetProject: String?,
        region: String?,
        serviceAccount: String?
    ) {
        self.name = name
        self.targetProject = targetProject
        self.region = region
        self.serviceAccount = serviceAccount
    }
}
