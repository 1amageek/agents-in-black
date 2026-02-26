import AIBConfig
import AIBRuntimeCore
import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1

final class HTTPProxyHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let control: GatewayControl
    private let httpClient: HTTPClient
    private let logger: Logger
    private let gatewayConfig: GatewayConfig

    private var requestHead: HTTPRequestHead?
    private var requestBody = ByteBuffer()
    private var readingRequestBody = false
    private var responseStarted = false

    init(control: GatewayControl, httpClient: HTTPClient, logger: Logger, gatewayConfig: GatewayConfig) {
        self.control = control
        self.httpClient = httpClient
        self.logger = logger
        self.gatewayConfig = gatewayConfig
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            requestBody.clear()
            readingRequestBody = true
            responseStarted = false
        case .body(var buffer):
            guard readingRequestBody else { return }
            requestBody.writeBuffer(&buffer)
        case .end:
            guard let head = requestHead else { return }
            readingRequestBody = false
            handleRequest(head: head, body: requestBody, context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Gateway connection error", metadata: ["error": "\(error)"])
        context.close(promise: nil)
    }

    private func handleRequest(head: HTTPRequestHead, body: ByteBuffer, context: ChannelHandlerContext) {
        let startedAt = DispatchTime.now()
        let (path, query) = splitURI(head.uri)
        let boxedContext = UncheckedSendableBox(value: context)

        Task {
            let trace = TraceContextFactory.make()
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
                await writeSimpleResponse(
                    context: boxedContext.value,
                    status: status,
                    body: reason,
                    keepAlive: head.isKeepAlive,
                    requestHead: head,
                    accessLog: .init(
                        ts: ISO8601.fractionalString(from: .now),
                        requestID: trace.requestID,
                        traceID: trace.cloudTraceContext.split(separator: "/").first.map(String.init),
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
                let acquired = await control.tryAcquire(serviceID: match.entry.serviceID, maxInflight: match.entry.maxInflight)
                guard acquired else {
                    await writeSimpleResponse(
                        context: boxedContext.value,
                        status: .serviceUnavailable,
                        body: "concurrency_limit",
                        keepAlive: head.isKeepAlive,
                        requestHead: head,
                        extraHeaders: ["Retry-After": "1"],
                        accessLog: .init(
                            ts: ISO8601.fractionalString(from: .now),
                            requestID: trace.requestID,
                            traceID: trace.cloudTraceContext.split(separator: "/").first.map(String.init),
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

                let gatewayControl = control
                defer {
                    Task { await gatewayControl.release(serviceID: match.entry.serviceID) }
                }

                do {
                    let response = try await proxy(head: head, body: body, match: match, trace: trace)
                    await writeUpstreamResponse(
                        context: boxedContext.value,
                        head: head,
                        upstream: response,
                        match: match,
                        startedAt: startedAt,
                        trace: trace,
                        requestBytesIn: body.readableBytes
                    )
                } catch {
                    await writeSimpleResponse(
                        context: boxedContext.value,
                        status: .badGateway,
                        body: "bad_gateway",
                        keepAlive: head.isKeepAlive,
                        requestHead: head,
                        accessLog: .init(
                            ts: ISO8601.fractionalString(from: .now),
                            requestID: trace.requestID,
                            traceID: trace.cloudTraceContext.split(separator: "/").first.map(String.init),
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
    }

    private struct UpstreamResponse {
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
        var url = match.entry.backend.baseURLString + match.backendPath
        if let query = match.query, !query.isEmpty {
            url += "?\(query)"
        }

        var request = HTTPClientRequest(url: url)
        request.method = .RAW(value: head.method.rawValue)
        var headers = sanitizedRequestHeaders(from: head.headers, originalHead: head, match: match, trace: trace)
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
        var bodyBuffer = ByteBufferAllocator().buffer(capacity: responseBody.readableBytes)
        var collected = responseBody
        bodyBuffer.writeBuffer(&collected)
        return UpstreamResponse(status: response.status, headers: response.headers, body: bodyBuffer)
    }

    private func splitURI(_ uri: String) -> (String, String?) {
        if let index = uri.firstIndex(of: "?") {
            return (String(uri[..<index]), String(uri[uri.index(after: index)...]))
        }
        return (uri, nil)
    }

    private func sanitizedRequestHeaders(
        from incoming: HTTPHeaders,
        originalHead: HTTPRequestHead,
        match: RouteMatch,
        trace: TraceContext
    ) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for header in incoming where !hopByHopHeaders.contains(header.name.lowercased()) {
            if header.name.caseInsensitiveCompare("Host") == .orderedSame {
                headers.add(name: "Host", value: incoming.first(name: "Host") ?? "localhost")
            } else {
                headers.add(name: header.name, value: header.value)
            }
        }
        let existingXFF = incoming.first(name: "X-Forwarded-For")
        let appended = existingXFF.map { "\($0), 127.0.0.1" } ?? "127.0.0.1"
        headers.replaceOrAdd(name: "X-Forwarded-For", value: appended)
        _ = originalHead
        _ = match
        _ = trace
        return headers
    }

    private func writeUpstreamResponse(
        context: ChannelHandlerContext,
        head requestHead: HTTPRequestHead,
        upstream: UpstreamResponse,
        match: RouteMatch,
        startedAt: DispatchTime,
        trace: TraceContext,
        requestBytesIn: Int
    ) async {
        var headers = rewriteResponseHeaders(upstream.headers, match: match)
        headers.replaceOrAdd(name: "X-Request-Id", value: trace.requestID)
        let responseHead = HTTPResponseHead(version: requestHead.version, status: upstream.status, headers: headers)
        let promise = context.eventLoop.makePromise(of: Void.self)
        let responseBody = upstream.body
        context.eventLoop.execute { [self] in
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            if responseBody.readableBytes > 0 {
                context.write(wrapOutboundOut(.body(.byteBuffer(responseBody))), promise: nil)
            }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        }
        do {
            try await promise.futureResult.get()
        } catch {
            logger.error("Failed to write upstream response", metadata: ["error": "\(error)"])
        }
        let entry = AccessLogEntry(
            ts: ISO8601.fractionalString(from: .now),
            requestID: trace.requestID,
            traceID: trace.cloudTraceContext.split(separator: "/").first.map(String.init),
            serviceID: match.entry.serviceID.rawValue,
            method: requestHead.method.rawValue,
            path: requestHead.uri,
            status: Int(upstream.status.code),
            latencyMS: elapsedMS(since: startedAt),
            bytesIn: requestBytesIn,
            bytesOut: upstream.body.readableBytes
        )
        logAccess(entry)
        if !requestHead.isKeepAlive {
            context.eventLoop.execute {
                context.close(promise: nil)
            }
        }
    }

    private func writeSimpleResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        body: String,
        keepAlive: Bool,
        requestHead: HTTPRequestHead,
        extraHeaders: [String: String] = [:],
        accessLog: AccessLogEntry
    ) async {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.utf8.count)")
        for (key, value) in extraHeaders {
            headers.add(name: key, value: value)
        }
        let responseHead = HTTPResponseHead(version: requestHead.version, status: status, headers: headers)
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.eventLoop.execute { [self] in
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        }
        do {
            try await promise.futureResult.get()
        } catch {
            logger.error("Failed to write response", metadata: ["error": "\(error)"])
        }
        logAccess(accessLog)
        if !keepAlive {
            context.eventLoop.execute {
                context.close(promise: nil)
            }
        }
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

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

private extension DurationString {
    var timeInterval: TimeInterval {
        (try? parse().timeInterval) ?? 30
    }

    var asTimeAmount: TimeAmount {
        .nanoseconds(Int64(timeInterval * 1_000_000_000))
    }
}
