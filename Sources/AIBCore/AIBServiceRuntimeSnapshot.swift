import AIBRuntimeCore
import Foundation

public struct AIBServiceRuntimeSnapshot: Sendable, Equatable {
    public let serviceID: String
    public let lifecycleState: LifecycleState
    public let desiredState: DesiredState
    public let mountPath: String
    public let backendPort: Int?
    public let consecutiveProbeFailures: Int
    public let lastExitStatus: Int32?

    public init(
        serviceID: String,
        lifecycleState: LifecycleState,
        desiredState: DesiredState,
        mountPath: String,
        backendPort: Int?,
        consecutiveProbeFailures: Int,
        lastExitStatus: Int32?
    ) {
        self.serviceID = serviceID
        self.lifecycleState = lifecycleState
        self.desiredState = desiredState
        self.mountPath = mountPath
        self.backendPort = backendPort
        self.consecutiveProbeFailures = consecutiveProbeFailures
        self.lastExitStatus = lastExitStatus
    }

    /// String representation of the lifecycle state for cross-module access.
    public var lifecycleStateString: String {
        lifecycleState.rawValue
    }
}
