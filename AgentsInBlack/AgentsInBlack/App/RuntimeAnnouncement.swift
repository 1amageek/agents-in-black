import Foundation

struct RuntimeAnnouncement: Identifiable, Equatable {
    enum Style: Equatable {
        case success
        case info
        case warning
        case error
    }

    let id: UUID
    let style: Style
    let symbolName: String
    let title: String
    let message: String?
    let autoDismissDelay: TimeInterval?
    let dedupeKey: String

    init(
        id: UUID = UUID(),
        style: Style,
        symbolName: String,
        title: String,
        message: String? = nil,
        autoDismissDelay: TimeInterval?,
        dedupeKey: String
    ) {
        self.id = id
        self.style = style
        self.symbolName = symbolName
        self.title = title
        self.message = message
        self.autoDismissDelay = autoDismissDelay
        self.dedupeKey = dedupeKey
    }

    static func runtimeStarted(port: Int?) -> RuntimeAnnouncement {
        let message: String?
        if let port {
            message = "Listening on :\(port)"
        } else {
            message = nil
        }
        return RuntimeAnnouncement(
            style: .success,
            symbolName: "hammer.fill",
            title: "Runtime Started",
            message: message,
            autoDismissDelay: 2.2,
            dedupeKey: "runtime-started-\(port ?? -1)"
        )
    }

    static func runtimeStopped() -> RuntimeAnnouncement {
        RuntimeAnnouncement(
            style: .info,
            symbolName: "stop.fill",
            title: "Runtime Stopped",
            message: nil,
            autoDismissDelay: 1.8,
            dedupeKey: "runtime-stopped"
        )
    }

    static func runtimeStartFailed(_ message: String) -> RuntimeAnnouncement {
        RuntimeAnnouncement(
            style: .error,
            symbolName: "exclamationmark.triangle.fill",
            title: "Runtime Failed",
            message: message,
            autoDismissDelay: nil,
            dedupeKey: "runtime-start-failed-\(message)"
        )
    }
}
