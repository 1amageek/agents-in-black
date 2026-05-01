import Foundation

/// The outcome of a single preflight dependency check.
public struct PreflightCheckResult: Sendable, Identifiable {

    public enum Status: Sendable {
        case pending
        case running
        case passed(detail: String? = nil)
        case failed(String)
        case warning(String)
        case skipped(String)
    }

    public let id: PreflightCheckID
    public var title: String
    public var status: Status
    public var remediationURL: URL?
    public var remediationCommand: String?
    public var diagnostics: [String]

    public init(
        id: PreflightCheckID,
        title: String,
        status: Status,
        remediationURL: URL? = nil,
        remediationCommand: String? = nil,
        diagnostics: [String] = []
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.remediationURL = remediationURL
        self.remediationCommand = remediationCommand
        self.diagnostics = diagnostics
    }

    public var isPassed: Bool {
        if case .passed = status { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    public var isWarning: Bool {
        if case .warning = status { return true }
        return false
    }
}
