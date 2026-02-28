import Foundation

struct RuntimeIssue: Identifiable, Hashable, Sendable {
    let id: UUID
    let severity: RuntimeIssueSeverity
    let sourceTitle: String
    let message: String
    let serviceSelectionID: String?
    let repoID: String?
    var count: Int
    var lastUpdatedAt: Date

    init(
        id: UUID = UUID(),
        severity: RuntimeIssueSeverity,
        sourceTitle: String,
        message: String,
        serviceSelectionID: String?,
        repoID: String?,
        count: Int = 1,
        lastUpdatedAt: Date = .now
    ) {
        self.id = id
        self.severity = severity
        self.sourceTitle = sourceTitle
        self.message = message
        self.serviceSelectionID = serviceSelectionID
        self.repoID = repoID
        self.count = count
        self.lastUpdatedAt = lastUpdatedAt
    }
}
