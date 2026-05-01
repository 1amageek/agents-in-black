import Foundation

enum SelectionTarget: Hashable {
    case topology
    case repo(String)
    case service(String)
    case file(String)
    case issue(UUID)
    case skill(String)
    case deployments
}
