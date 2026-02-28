import Foundation

enum SelectionTarget: Hashable {
    case topology
    case repo(String)
    case service(String)
    case file(String)
}
