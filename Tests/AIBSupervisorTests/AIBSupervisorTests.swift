import Testing
@testable import AIBSupervisor

@Test(.timeLimit(.minutes(1)))
func probeResultStoresValues() {
    let result = ProbeResult(success: true, statusCode: 200)
    #expect(result.success)
    #expect(result.statusCode == 200)
}
