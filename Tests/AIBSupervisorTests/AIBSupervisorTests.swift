import Testing
@testable import AIBSupervisor

@Test(.timeLimit(.minutes(1)))
func probeResultStoresValues() {
    let result = ProbeResult(success: true, statusCode: 200)
    #expect(result.success)
    #expect(result.statusCode == 200)
}

@Test(.timeLimit(.minutes(1)))
func hostExecutionEnvironmentRewritesContainerAlias() {
    #expect(
        normalizeHostExecutionEnvironmentValue("host.container.internal:8080")
            == "127.0.0.1:8080"
    )
    #expect(
        normalizeHostExecutionEnvironmentValue("http://host.container.internal:9000/path")
            == "http://127.0.0.1:9000/path"
    )
}
