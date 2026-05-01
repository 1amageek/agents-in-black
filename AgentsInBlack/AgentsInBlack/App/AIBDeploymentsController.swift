import AIBCore
import Foundation
import Observation

/// Drives the Deployments management view.
/// Refreshes the live deployments inventory, computes drift against the
/// current workspace plan, and deletes services on demand.
@MainActor
@Observable
final class AIBDeploymentsController {

    /// Loading state for the inventory list.
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

    /// Per-row deletion state, keyed by `"\(region)/\(serviceName)"`.
    /// Cloud Run names are region-scoped, so the same name across regions
    /// must be tracked independently.
    enum DeletionState: Equatable {
        case idle
        case deleting
        case failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var services: [DeployedServiceInfo] = []
    private(set) var drift: DeploymentDriftReport = DeploymentDriftReport(entries: [])
    private(set) var deletionStates: [String: DeletionState] = [:]
    private(set) var lastRefreshedAt: Date?

    private var loadTask: Task<Void, Never>?

    /// Compose the deletion-state key from a region/service-name pair.
    static func deletionKey(name: String, region: String) -> String {
        "\(region)/\(name)"
    }

    /// Convenience lookup used by views: returns `.idle` when no entry is recorded.
    func deletionState(serviceName: String, region: String) -> DeletionState {
        deletionStates[Self.deletionKey(name: serviceName, region: region)] ?? .idle
    }

    /// Refresh the live inventory and recompute drift against the given plan.
    /// `plan` is optional — if absent, every live service becomes an orphan.
    func refresh(
        provider: any DeploymentProvider,
        targetConfig: AIBDeployTargetConfig,
        plan: AIBDeployPlan?
    ) {
        loadTask?.cancel()
        state = .loading
        print("[Deployments] controller.refresh start provider=\(provider.providerID) region=\(targetConfig.region) project=\(targetConfig.providerConfig["gcpProject"] ?? "-") planServices=\(plan?.services.count ?? -1)")
        loadTask = Task { [weak self] in
            do {
                let live = try await AIBDeployService.listDeployments(
                    provider: provider,
                    targetConfig: targetConfig
                )
                print("[Deployments] listDeployments returned \(live.count) live service(s):")
                for svc in live {
                    print("[Deployments]   - \(svc.region)/\(svc.name) image=\(svc.image ?? "-")")
                }
                let report = AIBDeployService.computeDrift(
                    plan: plan,
                    deployedServices: live,
                    provider: provider
                )
                print("[Deployments] computeDrift produced \(report.entries.count) entries (orphans=\(report.orphans.count) missing=\(report.missing.count) regionMismatch=\(report.regionMismatches.count) imageStale=\(report.imageStale.count) inSync=\(report.inSync.count))")
                guard let self, !Task.isCancelled else {
                    print("[Deployments] refresh cancelled before applying state")
                    return
                }
                self.services = live.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.drift = report
                self.lastRefreshedAt = Date()
                self.state = .loaded
                print("[Deployments] state = .loaded")
            } catch {
                print("[Deployments] refresh failed: \(error.localizedDescription)")
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Delete a single service. Refreshes the list afterwards on success.
    /// Per-row error is exposed via `deletionState(serviceName:region:)`.
    func delete(
        serviceName: String,
        region: String,
        provider: any DeploymentProvider,
        targetConfig: AIBDeployTargetConfig,
        plan: AIBDeployPlan?
    ) {
        let key = Self.deletionKey(name: serviceName, region: region)
        deletionStates[key] = .deleting
        Task { [weak self] in
            do {
                try await AIBDeployService.deleteDeployment(
                    provider: provider,
                    serviceName: serviceName,
                    region: region,
                    targetConfig: targetConfig
                )
                guard let self, !Task.isCancelled else { return }
                self.deletionStates[key] = .idle
                self.refresh(provider: provider, targetConfig: targetConfig, plan: plan)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.deletionStates[key] = .failed(error.localizedDescription)
            }
        }
    }

    func dismissDeletionError(serviceName: String, region: String) {
        let key = Self.deletionKey(name: serviceName, region: region)
        if case .failed = deletionStates[key] {
            deletionStates[key] = .idle
        }
    }

    func reset() {
        loadTask?.cancel()
        loadTask = nil
        state = .idle
        services = []
        drift = DeploymentDriftReport(entries: [])
        deletionStates = [:]
        lastRefreshedAt = nil
    }
}
