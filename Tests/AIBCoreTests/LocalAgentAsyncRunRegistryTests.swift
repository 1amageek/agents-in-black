import Foundation
import Testing
@testable import AIBCore

private actor CancellationProbe {
    private var cancelled = false

    func markCancelled() {
        cancelled = true
    }

    func wasCancelled() -> Bool {
        cancelled
    }
}

@Test(.timeLimit(.minutes(1)))
func localAgentAsyncRunRegistryCancelsPreviousDuplicateRun() async throws {
    let registry = LocalAgentAsyncRunRegistry()
    let probe = CancellationProbe()

    let firstRunID = UUID()
    let firstTask = Task<Void, Never> {
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            await probe.markCancelled()
        }
    }

    _ = await registry.register(
        runID: firstRunID,
        serviceID: "agent/node",
        duplicateKey: "agent/node:proposal:test",
        task: firstTask
    )

    let secondRunID = UUID()
    let secondTask = Task<Void, Never> {}

    let result = await registry.register(
        runID: secondRunID,
        serviceID: "agent/node",
        duplicateKey: "agent/node:proposal:test",
        task: secondTask
    )

    #expect(result.replacedRunID == firstRunID)

    try await Task.sleep(for: .milliseconds(50))
    #expect(await probe.wasCancelled())

    secondTask.cancel()
    await registry.cancelAll()
}
