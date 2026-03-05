import Foundation

public enum AIBEmulatorEvent: Sendable {
    case lifecycleChanged(AIBEmulatorLifecycleState)
    case log(AIBEmulatorLogEntry)
    case serviceSnapshotsChanged([AIBServiceRuntimeSnapshot])
    case activeServicesChanged(Set<String>)
    case kernelDownloadStarted(Progress)
}
