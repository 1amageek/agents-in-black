import AIBRuntimeCore
import Foundation
import Logging

public final class LogMux: @unchecked Sendable {
    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    /// No-op: container logs are streamed by ContainerProcessController's logTask.
    public func attach(_ handle: ChildHandle) {}

    /// No-op: logTask lifecycle is managed by ProcessController.
    public func detach(_ handle: ChildHandle) {}
}
