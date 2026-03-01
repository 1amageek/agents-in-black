import Foundation

/// An error that occurred during the deployment pipeline.
public struct AIBDeployError: Error, Sendable, LocalizedError {
    public var phase: String
    public var message: String
    public var serviceID: String?

    public init(phase: String, message: String, serviceID: String? = nil) {
        self.phase = phase
        self.message = message
        self.serviceID = serviceID
    }

    public var errorDescription: String? {
        if let serviceID {
            return "Deploy \(phase) error for \(serviceID): \(message)"
        }
        return "Deploy \(phase) error: \(message)"
    }
}
