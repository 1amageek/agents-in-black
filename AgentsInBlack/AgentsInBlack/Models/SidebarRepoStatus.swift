import Foundation

enum SidebarRepoStatus: String, CaseIterable, Sendable {
    case configured
    case starting
    case running
    case warning
    case error
}
