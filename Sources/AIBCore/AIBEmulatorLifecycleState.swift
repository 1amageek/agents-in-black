import Foundation

public enum AIBEmulatorLifecycleState: Sendable, Equatable {
    case stopped
    case starting
    case running(pid: Int32?, port: Int?)
    case stopping
    case failed(String)
}
