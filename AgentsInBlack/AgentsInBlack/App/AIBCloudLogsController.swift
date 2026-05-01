import AIBCore
import Foundation
import Observation

/// Drives the Cloud Run logs sheet for a single (service, region) pair.
/// Supports two modes — `latest` (snapshot) and `tail` (live stream) —
/// switching between them cancels any in-flight task.
@MainActor
@Observable
final class AIBCloudLogsController {

    enum Mode: Equatable {
        case latest
        case tail
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    let serviceName: String
    let region: String

    private(set) var mode: Mode = .latest
    private(set) var state: LoadState = .idle
    private(set) var entries: [CloudLogEntry] = []
    private(set) var lastRefreshedAt: Date?
    private(set) var snapshotLimit: Int = 200

    /// Cap rendered tail entries so a chatty service cannot grow the array unbounded.
    private let tailRetentionLimit: Int = 1_000

    private var activeTask: Task<Void, Never>?

    init(serviceName: String, region: String) {
        self.serviceName = serviceName
        self.region = region
    }

    func setMode(
        _ newMode: Mode,
        provider: any DeploymentProvider,
        targetConfig: AIBDeployTargetConfig
    ) {
        guard newMode != mode else { return }
        mode = newMode
        switch newMode {
        case .latest:
            stopTail()
            fetchLatest(provider: provider, targetConfig: targetConfig)
        case .tail:
            startTail(provider: provider, targetConfig: targetConfig)
        }
    }

    func fetchLatest(
        provider: any DeploymentProvider,
        targetConfig: AIBDeployTargetConfig
    ) {
        activeTask?.cancel()
        state = .loading
        let serviceName = self.serviceName
        let region = self.region
        let limit = self.snapshotLimit
        activeTask = Task { [weak self] in
            do {
                let logs = try await AIBDeployService.fetchServiceLogs(
                    provider: provider,
                    serviceName: serviceName,
                    region: region,
                    limit: limit,
                    targetConfig: targetConfig
                )
                guard let self, !Task.isCancelled else { return }
                self.entries = logs
                self.lastRefreshedAt = Date()
                self.state = .loaded
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func startTail(
        provider: any DeploymentProvider,
        targetConfig: AIBDeployTargetConfig
    ) {
        activeTask?.cancel()
        state = .loading
        entries = []
        let serviceName = self.serviceName
        let region = self.region
        let retention = self.tailRetentionLimit
        activeTask = Task { [weak self] in
            do {
                let stream = try AIBDeployService.tailServiceLogs(
                    provider: provider,
                    serviceName: serviceName,
                    region: region,
                    targetConfig: targetConfig
                )
                guard let self, !Task.isCancelled else { return }
                self.state = .loaded
                for try await entry in stream {
                    if Task.isCancelled { break }
                    self.appendTailEntry(entry, retention: retention)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func stopTail() {
        activeTask?.cancel()
        activeTask = nil
    }

    func reset() {
        activeTask?.cancel()
        activeTask = nil
        state = .idle
        entries = []
        lastRefreshedAt = nil
    }

    private func appendTailEntry(_ entry: CloudLogEntry, retention: Int) {
        // Tail UI shows newest at the top, matching the snapshot ordering.
        entries.insert(entry, at: 0)
        if entries.count > retention {
            entries.removeLast(entries.count - retention)
        }
        lastRefreshedAt = Date()
    }
}
