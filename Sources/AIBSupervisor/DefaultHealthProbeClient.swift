import Foundation

public struct DefaultHealthProbeClient: HealthProbeClient {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 2.0) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: configuration)
        self.timeout = timeout
    }

    public func checkLiveness(service: ServiceRuntime) async -> ProbeResult {
        await probe(service: service, path: service.service.health.livenessPath)
    }

    public func checkReadiness(service: ServiceRuntime) async -> ProbeResult {
        await probe(service: service, path: service.service.health.readinessPath)
    }

    private func probe(service: ServiceRuntime, path: String) async -> ProbeResult {
        guard let endpoint = service.backendEndpoint else {
            return .init(success: false, errorDescription: "missing backend endpoint")
        }
        guard let url = URL(string: "\(endpoint.baseURLString)\(path)") else {
            return .init(success: false, errorDescription: "invalid probe url")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            let ok = status.map { 200 ... 299 ~= $0 } ?? false
            return .init(success: ok, statusCode: status)
        } catch {
            return .init(success: false, errorDescription: "\(error)")
        }
    }
}
