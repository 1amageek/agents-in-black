import AsyncHTTPClient
import Foundation
import NIOCore

public struct DefaultHealthProbeClient: HealthProbeClient {
    private let timeout: TimeAmount

    public init(timeout: TimeInterval = 2.0) {
        self.timeout = .milliseconds(Int64(timeout * 1000))
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
        let url = endpoint.requestURL(path: path)
        var request = HTTPClientRequest(url: url)
        request.method = .GET
        // AsyncHTTPClient does not guarantee Host header synthesis for all URL schemes
        // (notably http+unix). Always provide explicit authority from endpoint.
        request.headers.replaceOrAdd(name: "Host", value: endpoint.hostHeaderValue)
        do {
            let response = try await HTTPClient.shared.execute(request, timeout: timeout)
            let status = Int(response.status.code)
            return .init(success: 200...299 ~= status, statusCode: status)
        } catch {
            return .init(success: false, errorDescription: "\(error)")
        }
    }
}
