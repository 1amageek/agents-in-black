import Foundation

public struct AIBFileNode: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var url: URL
    public var isDirectory: Bool
    public var children: [AIBFileNode]
    public var repoID: String
    public var childNodes: [AIBFileNode]? { isDirectory ? children : nil }

    public init(name: String, url: URL, isDirectory: Bool, children: [AIBFileNode] = [], repoID: String) {
        self.id = url.path
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
        self.repoID = repoID
    }
}
