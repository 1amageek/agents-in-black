import Foundation

enum EmulatorState: Equatable {
    case stopped
    case starting
    case running(pid: Int32?, port: Int?)
    case stopping
    case error(String)

    var isBusy: Bool {
        switch self {
        case .starting, .stopping:
            return true
        case .stopped, .running, .error:
            return false
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running(_, let port):
            if let port {
                return "Running :\(port)"
            }
            return "Running"
        case .stopping: return "Stopping"
        case .error: return "Error"
        }
    }
}
