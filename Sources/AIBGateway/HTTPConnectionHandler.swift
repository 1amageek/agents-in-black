import AIBConfig
import AIBRuntimeCore
import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1

/// Pure async HTTP connection handler.
///
/// Each instance handles one accepted TCP connection. Multiple HTTP request/response
/// cycles may occur on the same connection (HTTP keep-alive). All channel I/O is
/// performed via NIOAsyncChannel's async read/write, eliminating EventLoop threading concerns.
struct HTTPConnectionHandler: Sendable {
    let control: GatewayControl
    let httpClient: HTTPClient
    let logger: Logger
    let gatewayConfig: GatewayConfig

    /// Handle one TCP connection, processing all HTTP requests on it until the client disconnects.
    func handle(_ channel: HTTPRequestChannel) async {
        do {
            try await channel.executeThenClose { inbound, outbound in
                try await processRequests(inbound: inbound, outbound: outbound)
            }
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Connection error", metadata: ["error": "\(error)"])
        }
    }

    // MARK: - Request Processing

    private func processRequests(
        inbound: NIOAsyncChannelInboundStream<HTTPServerRequestPart>,
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        var requestHead: HTTPRequestHead?
        var requestBody = ByteBuffer()

        for try await part in inbound {
            switch part {
            case .head(let head):
                requestHead = head
                requestBody.clear()

            case .body(var buffer):
                requestBody.writeBuffer(&buffer)

            case .end:
                guard let head = requestHead else { continue }
                requestHead = nil
                try await handleSingleRequest(head: head, body: requestBody, outbound: outbound)
            }
        }
    }

    private func handleSingleRequest(
        head: HTTPRequestHead,
        body: ByteBuffer,
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        let startedAt = DispatchTime.now()
        let trace = TraceContextFactory.make()
        let (path, query) = splitURI(head.uri)

        let matchResult = await control.match(path: path, query: query)
        switch matchResult {
        case .failure(let failure):
            let status: HTTPResponseStatus
            let reason: String
            switch failure {
            case .noRoute:
                status = .notFound
                reason = "not_found"
            case .unavailable(let unavailable):
                status = .serviceUnavailable
                reason = unavailable.rawValue
            }
            try await writeSimpleResponse(
                outbound: outbound,
                version: head.version,
                status: status,
                body: reason,
                accessLog: .init(
                    ts: ISO8601.fractionalString(from: .now),
                    requestID: trace.requestID,
                    traceID: extractTraceID(trace),
                    serviceID: nil,
                    method: head.method.rawValue,
                    path: head.uri,
                    status: Int(status.code),
                    latencyMS: elapsedMS(since: startedAt),
                    bytesIn: body.readableBytes,
                    bytesOut: reason.utf8.count,
                    error: reason
                )
            )

        case .success(let match):
            let acquired = await control.tryAcquire(
                serviceID: match.entry.serviceID,
                maxInflight: match.entry.maxInflight
            )
            guard acquired else {
                try await writeSimpleResponse(
                    outbound: outbound,
                    version: head.version,
                    status: .serviceUnavailable,
                    body: "concurrency_limit",
                    extraHeaders: ["Retry-After": "1"],
                    accessLog: .init(
                        ts: ISO8601.fractionalString(from: .now),
                        requestID: trace.requestID,
                        traceID: extractTraceID(trace),
                        serviceID: match.entry.serviceID.rawValue,
                        method: head.method.rawValue,
                        path: head.uri,
                        status: 503,
                        latencyMS: elapsedMS(since: startedAt),
                        bytesIn: body.readableBytes,
                        bytesOut: 17,
                        error: "concurrency_limit"
                    )
                )
                return
            }

            do {
                let response = try await proxy(head: head, body: body, match: match, trace: trace)
                await control.release(serviceID: match.entry.serviceID)
                try await writeUpstreamResponse(
                    outbound: outbound,
                    version: head.version,
                    upstream: response,
                    match: match,
                    trace: trace,
                    accessLog: .init(
                        ts: ISO8601.fractionalString(from: .now),
                        requestID: trace.requestID,
                        traceID: extractTraceID(trace),
                        serviceID: match.entry.serviceID.rawValue,
                        method: head.method.rawValue,
                        path: head.uri,
                        status: Int(response.status.code),
                        latencyMS: elapsedMS(since: startedAt),
                        bytesIn: body.readableBytes,
                        bytesOut: response.body.readableBytes
                    )
                )
            } catch {
                await control.release(serviceID: match.entry.serviceID)
                try await writeSimpleResponse(
                    outbound: outbound,
                    version: head.version,
                    status: .badGateway,
                    body: "bad_gateway",
                    accessLog: .init(
                        ts: ISO8601.fractionalString(from: .now),
                        requestID: trace.requestID,
                        traceID: extractTraceID(trace),
                        serviceID: match.entry.serviceID.rawValue,
                        method: head.method.rawValue,
                        path: head.uri,
                        status: 502,
                        latencyMS: elapsedMS(since: startedAt),
                        bytesIn: body.readableBytes,
                        bytesOut: 11,
                        error: "\(error)"
                    )
                )
            }
        }
    }

    // MARK: - Upstream Proxy

    private struct UpstreamResponse: Sendable {
        var status: HTTPResponseStatus
        var headers: HTTPHeaders
        var body: ByteBuffer
    }

    private func proxy(
        head: HTTPRequestHead,
        body: ByteBuffer,
        match: RouteMatch,
        trace: TraceContext
    ) async throws -> UpstreamResponse {
        let url = match.entry.backend.requestURL(path: match.backendPath, query: match.query)

        var request = HTTPClientRequest(url: url)
        request.method = .RAW(value: head.method.rawValue)
        var headers = sanitizedRequestHeaders(from: head.headers, match: match)
        if headers.first(name: "Host") == nil {
            headers.replaceOrAdd(name: "Host", value: match.entry.backend.hostHeaderValue)
        }
        headers.replaceOrAdd(name: "X-Forwarded-Proto", value: "http")
        headers.replaceOrAdd(name: "X-Forwarded-Host", value: head.headers.first(name: "Host") ?? "localhost")
        if match.entry.pathRewrite == .stripPrefix {
            headers.replaceOrAdd(name: "X-Forwarded-Prefix", value: match.entry.mountPath)
        }
        headers.replaceOrAdd(name: "X-Request-Id", value: trace.requestID)
        headers.replaceOrAdd(name: "X-Cloud-Trace-Context", value: trace.cloudTraceContext)
        headers.replaceOrAdd(name: "traceparent", value: trace.traceparent)
        request.headers = headers
        if body.readableBytes > 0 {
            request.body = .bytes(body)
        }

        let timeout = gatewayConfig.timeouts.request.asTimeAmount
        let response = try await httpClient.execute(request, timeout: timeout)
        let responseBody = try await response.body.collect(upTo: 16 * 1024 * 1024)
        return UpstreamResponse(status: response.status, headers: response.headers, body: responseBody)
    }

    // MARK: - Response Writing

    private func writeSimpleResponse(
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        body: String,
        extraHeaders: [String: String] = [:],
        accessLog: AccessLogEntry
    ) async throws {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.utf8.count)")
        for (key, value) in extraHeaders {
            headers.add(name: key, value: value)
        }
        let responseHead = HTTPResponseHead(version: version, status: status, headers: headers)
        var buffer = ByteBufferAllocator().buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        try await outbound.write(contentsOf: [
            .head(responseHead),
            .body(buffer),
            .end(nil),
        ])
        logAccess(accessLog)
    }

    private func writeUpstreamResponse(
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>,
        version: HTTPVersion,
        upstream: UpstreamResponse,
        match: RouteMatch,
        trace: TraceContext,
        accessLog: AccessLogEntry
    ) async throws {
        var headers = rewriteResponseHeaders(upstream.headers, match: match)
        headers.replaceOrAdd(name: "X-Request-Id", value: trace.requestID)
        let responseHead = HTTPResponseHead(version: version, status: upstream.status, headers: headers)
        try await outbound.write(contentsOf: [
            .head(responseHead),
            .body(upstream.body),
            .end(nil),
        ])
        logAccess(accessLog)
    }

    // MARK: - Header Utilities

    private func sanitizedRequestHeaders(
        from incoming: HTTPHeaders,
        match: RouteMatch
    ) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for header in incoming where !hopByHopHeaders.contains(header.name.lowercased()) {
            headers.add(name: header.name, value: header.value)
        }
        let existingXFF = incoming.first(name: "X-Forwarded-For")
        let appended = existingXFF.map { "\($0), 127.0.0.1" } ?? "127.0.0.1"
        headers.replaceOrAdd(name: "X-Forwarded-For", value: appended)
        return headers
    }

    private func rewriteResponseHeaders(_ incoming: HTTPHeaders, match: RouteMatch) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for header in incoming where !hopByHopHeaders.contains(header.name.lowercased()) {
            switch header.name.lowercased() {
            case "location":
                headers.add(name: header.name, value: rewriteLocation(header.value, match: match))
            case "set-cookie" where match.entry.cookiePathRewrite:
                headers.add(name: header.name, value: rewriteSetCookie(header.value, mountPath: match.entry.mountPath))
            default:
                headers.add(name: header.name, value: header.value)
            }
        }
        return headers
    }

    private func rewriteLocation(_ value: String, match: RouteMatch) -> String {
        guard match.entry.pathRewrite == .stripPrefix else { return value }
        guard value.hasPrefix("/") else { return value }
        if value.hasPrefix(match.entry.mountPath + "/") || value == match.entry.mountPath {
            return value
        }
        if value == "/" {
            return match.entry.mountPath
        }
        return match.entry.mountPath + value
    }

    private func rewriteSetCookie(_ value: String, mountPath: String) -> String {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false).map { String($0) }
        var sawPath = false
        let rewritten = parts.map { rawPart -> String in
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            if part.lowercased().hasPrefix("path=") {
                sawPath = true
                return " Path=\(mountPath)"
            }
            return rawPart
        }
        if sawPath { return rewritten.joined(separator: ";") }
        return value + "; Path=\(mountPath)"
    }

    // MARK: - Helpers

    private func splitURI(_ uri: String) -> (String, String?) {
        if let index = uri.firstIndex(of: "?") {
            return (String(uri[..<index]), String(uri[uri.index(after: index)...]))
        }
        return (uri, nil)
    }

    private func extractTraceID(_ trace: TraceContext) -> String? {
        trace.cloudTraceContext.split(separator: "/").first.map(String.init)
    }

    private func logAccess(_ entry: AccessLogEntry) {
        do {
            let data = try JSONEncoder().encode(entry)
            if let line = String(data: data, encoding: .utf8) {
                logger.info("\(line)")
            }
        } catch {
            logger.error("Failed to encode access log", metadata: ["error": "\(error)"])
        }
    }

    private func elapsedMS(since start: DispatchTime) -> Double {
        let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000.0
    }

    private let hopByHopHeaders: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade",
    ]
}

// MARK: - DurationString Extension

extension DurationString {
    var asTimeAmount: TimeAmount {
        do {
            let duration = try parse()
            return .nanoseconds(Int64(duration.timeInterval * 1_000_000_000))
        } catch {
            fatalError("Invalid duration string '\(rawValue)': \(error)")
        }
    }
}
