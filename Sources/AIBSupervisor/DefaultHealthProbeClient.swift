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
        let primary = service.service.health.livenessPath
        let result = await probe(service: service, path: primary)
        if result.success { return result }

        if result.statusCode == 404 {
            for fallback in Self.livenessFallbackPaths where fallback != primary {
                let fallbackResult = await probe(service: service, path: fallback)
                if fallbackResult.success { return fallbackResult }
                if fallbackResult.statusCode != 404 { return fallbackResult }
            }
        }
        return result
    }

    private static let livenessFallbackPaths = ["/health", "/"]

    public func checkReadiness(service: ServiceRuntime) async -> ProbeResult {
        let primary = service.service.health.readinessPath
        let result = await probe(service: service, path: primary)
        if result.success { return result }

        // Fall back to common health paths when the configured path returns 404.
        // Many frameworks implement /health rather than /health/ready.
        if result.statusCode == 404 {
            for fallback in Self.readinessFallbackPaths where fallback != primary {
                let fallbackResult = await probe(service: service, path: fallback)
                if fallbackResult.success { return fallbackResult }
                if fallbackResult.statusCode != 404 { return fallbackResult }
            }
        }
        return result
    }

    private static let readinessFallbackPaths = ["/health", "/"]

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
