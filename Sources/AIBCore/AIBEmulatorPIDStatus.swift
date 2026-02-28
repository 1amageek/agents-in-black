import Foundation

public enum AIBEmulatorPIDStatus: Sendable, Equatable {
    case stopped
    case running(pid_t)
    case stale(pid_t)
}
