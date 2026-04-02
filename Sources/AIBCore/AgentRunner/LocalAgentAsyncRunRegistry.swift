import Foundation

actor LocalAgentAsyncRunRegistry {
    struct RegistrationResult: Sendable {
        var replacedRunID: UUID?
    }

    private struct Entry: Sendable {
        var serviceID: String
        var duplicateKey: String?
        var task: Task<Void, Never>
    }

    static let shared = LocalAgentAsyncRunRegistry()

    private var entries: [UUID: Entry] = [:]
    private var duplicateIndex: [String: UUID] = [:]

    func register(
        runID: UUID,
        serviceID: String,
        duplicateKey: String?,
        task: Task<Void, Never>
    ) -> RegistrationResult {
        var replacedRunID: UUID?

        if let duplicateKey,
           let existingRunID = duplicateIndex[duplicateKey],
           let existingEntry = entries.removeValue(forKey: existingRunID)
        {
            existingEntry.task.cancel()
            duplicateIndex.removeValue(forKey: duplicateKey)
            replacedRunID = existingRunID
        }

        entries[runID] = Entry(serviceID: serviceID, duplicateKey: duplicateKey, task: task)
        if let duplicateKey {
            duplicateIndex[duplicateKey] = runID
        }

        return RegistrationResult(replacedRunID: replacedRunID)
    }

    func finish(runID: UUID) {
        guard let entry = entries.removeValue(forKey: runID) else { return }
        if let duplicateKey = entry.duplicateKey, duplicateIndex[duplicateKey] == runID {
            duplicateIndex.removeValue(forKey: duplicateKey)
        }
    }

    func cancelAll() {
        for entry in entries.values {
            entry.task.cancel()
        }
        entries.removeAll()
        duplicateIndex.removeAll()
    }
}
