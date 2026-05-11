import Foundation

/// Selects the subset of services that should be included in a deployment plan.
///
/// Planning still reads the full workspace topology so selected services can resolve
/// connections to services that are already deployed but not part of this apply.
public struct AIBDeploySelection: Sendable, Equatable {
    public var serviceIDs: Set<String>
    public var kinds: Set<AIBServiceKind>

    public init(
        serviceIDs: Set<String> = [],
        kinds: Set<AIBServiceKind> = []
    ) {
        self.serviceIDs = serviceIDs
        self.kinds = kinds
    }

    public var isEmpty: Bool {
        serviceIDs.isEmpty && kinds.isEmpty
    }

    public func includes(serviceID: String, kind: AIBServiceKind) -> Bool {
        if isEmpty {
            return true
        }
        return serviceIDs.contains(serviceID) || kinds.contains(kind)
    }

    public var displayDescription: String {
        var parts: [String] = []
        if !serviceIDs.isEmpty {
            parts.append("services=\(serviceIDs.sorted().joined(separator: ","))")
        }
        if !kinds.isEmpty {
            parts.append("kinds=\(kinds.map(\.rawValue).sorted().joined(separator: ","))")
        }
        return parts.isEmpty ? "all" : parts.joined(separator: " ")
    }
}
