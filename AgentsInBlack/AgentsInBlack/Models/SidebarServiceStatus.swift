import Foundation

enum SidebarServiceStatus: String, CaseIterable, Sendable {
    case configured
    case starting
    case running
    case warning
    case error
}

struct SidebarServiceStatusInfo: Sendable {
    var status: SidebarServiceStatus
    var reason: String?
}
