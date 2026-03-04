import Foundation

/// Caches A2A Agent Cards per service, fetched when services become ready.
@MainActor
@Observable
public final class A2AAgentCardCache {
    public private(set) var cardsByServiceID: [String: A2AAgentCard] = [:]
    public private(set) var errorsByServiceID: [String: String] = [:]
    private var fetchTasks: [String: Task<Void, Never>] = [:]

    public init() {}

    /// Trigger an Agent Card fetch for a service. Deduplicates in-flight requests.
    public func fetchCard(serviceID: String, baseURL: URL, cardPath: String) {
        guard fetchTasks[serviceID] == nil else { return }

        fetchTasks[serviceID] = Task {
            let client = A2AClient(baseURL: baseURL)
            do {
                let card = try await client.fetchAgentCard(cardPath: cardPath)
                cardsByServiceID[serviceID] = card
                errorsByServiceID.removeValue(forKey: serviceID)
            } catch {
                errorsByServiceID[serviceID] = error.localizedDescription
            }
            fetchTasks.removeValue(forKey: serviceID)
        }
    }

    /// Get the cached Agent Card for a service.
    public func card(for serviceID: String) -> A2AAgentCard? {
        cardsByServiceID[serviceID]
    }

    /// Whether a fetch is in progress for the given service.
    public func isFetching(serviceID: String) -> Bool {
        fetchTasks[serviceID] != nil
    }

    /// Clear all cached cards and errors (e.g., on workspace reload).
    public func clearAll() {
        for task in fetchTasks.values {
            task.cancel()
        }
        fetchTasks.removeAll()
        cardsByServiceID.removeAll()
        errorsByServiceID.removeAll()
    }

    /// Clear the card for a specific service.
    public func clearCard(for serviceID: String) {
        fetchTasks[serviceID]?.cancel()
        fetchTasks.removeValue(forKey: serviceID)
        cardsByServiceID.removeValue(forKey: serviceID)
        errorsByServiceID.removeValue(forKey: serviceID)
    }
}
