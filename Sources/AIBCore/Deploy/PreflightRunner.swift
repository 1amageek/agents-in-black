import Foundation

/// Orchestrates the execution of preflight checks provided by a DeploymentProvider.
/// Runs independent checks in parallel using TaskGroup.
/// Checks are phased: prerequisite checks first, then dependent checks.
public final class PreflightRunner: Sendable {

    private let checkers: [any PreflightChecker]

    /// Prerequisite check IDs that run first (phase 1).
    /// If a prerequisite fails, its dependent checks are skipped.
    private let prerequisiteCheckIDs: Set<PreflightCheckID>

    /// Mapping from a prerequisite check ID to its dependent check IDs.
    private let dependencies: [PreflightCheckID: [PreflightCheckID]]

    /// Initialize with checkers and provider-specified dependency mappings.
    /// - Parameters:
    ///   - checkers: The preflight checkers to run.
    ///   - dependencies: Mapping from prerequisite check ID to dependent check IDs.
    ///                   Provided by `DeploymentProvider.preflightDependencies()`.
    public init(checkers: [any PreflightChecker], dependencies: [PreflightCheckID: [PreflightCheckID]] = [:]) {
        self.checkers = checkers
        let allIDs = Set(checkers.map(\.checkID))

        // Filter dependencies to only include check IDs present in checkers
        var filteredDeps: [PreflightCheckID: [PreflightCheckID]] = [:]
        for (prereq, deps) in dependencies where allIDs.contains(prereq) {
            let validDeps = deps.filter { allIDs.contains($0) }
            if !validDeps.isEmpty {
                filteredDeps[prereq] = validDeps
            }
        }
        self.dependencies = filteredDeps
        self.prerequisiteCheckIDs = Set(filteredDeps.keys)
    }

    /// Run all checks and yield events as each completes.
    public func run() -> AsyncStream<PreflightCheckEvent> {
        AsyncStream { continuation in
            Task {
                var results: [PreflightCheckResult] = []

                // Phase 1: Tool installation checks (parallel)
                let toolIDs = Array(self.prerequisiteCheckIDs)
                let installResults = await self.runParallel(
                    checkerIDs: toolIDs,
                    continuation: continuation
                )
                results.append(contentsOf: installResults)

                // Phase 2: Dependent checks
                var dependentIDs: [PreflightCheckID] = []
                var skippedIDs: [(PreflightCheckID, String)] = []

                for toolID in toolIDs {
                    let passed = installResults.first(where: { $0.id == toolID })?.isPassed ?? false
                    let deps = self.dependencies[toolID] ?? []
                    if passed {
                        dependentIDs.append(contentsOf: deps)
                    } else {
                        let toolChecker = self.checkers.first(where: { $0.checkID == toolID })
                        let toolName = toolChecker?.title ?? toolID.rawValue
                        for depID in deps {
                            skippedIDs.append((depID, "\(toolName) not installed"))
                        }
                    }
                }

                // Emit skipped results
                for (id, reason) in skippedIDs {
                    let checker = self.checkers.first(where: { $0.checkID == id })
                    let result = PreflightCheckResult(
                        id: id,
                        title: checker?.title ?? id.rawValue,
                        status: .skipped(reason)
                    )
                    continuation.yield(.checkCompleted(result))
                    results.append(result)
                }

                // Also run any checks not covered by tool dependencies
                let allIDs = Set(self.checkers.map(\.checkID))
                let handledIDs = Set(toolIDs + dependentIDs + skippedIDs.map(\.0))
                let standaloneIDs = allIDs.subtracting(handledIDs)
                dependentIDs.append(contentsOf: standaloneIDs)

                // Run dependent checks in parallel
                let dependentResults = await self.runParallel(
                    checkerIDs: dependentIDs,
                    continuation: continuation
                )
                results.append(contentsOf: dependentResults)

                let report = PreflightReport(results: results)
                continuation.yield(.allCompleted(report))
                continuation.finish()
            }
        }
    }

    private func runParallel(
        checkerIDs: [PreflightCheckID],
        continuation: AsyncStream<PreflightCheckEvent>.Continuation
    ) async -> [PreflightCheckResult] {
        let matchedCheckers = checkerIDs.compactMap { id in
            checkers.first(where: { $0.checkID == id })
        }

        return await withTaskGroup(of: PreflightCheckResult.self, returning: [PreflightCheckResult].self) { group in
            for checker in matchedCheckers {
                group.addTask {
                    continuation.yield(.checkStarted(checker.checkID))
                    let result = await checker.run()
                    continuation.yield(.checkCompleted(result))
                    return result
                }
            }
            var results: [PreflightCheckResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
}
