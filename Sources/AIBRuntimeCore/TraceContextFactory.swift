import Foundation

public struct TraceContext: Sendable {
    public let requestID: String
    public let cloudTraceContext: String
    public let traceparent: String
}

public enum TraceContextFactory {
    public static func make(now: @autoclosure () -> Date = Date()) -> TraceContext {
        let requestID = UUID().uuidString.lowercased()
        let traceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let spanID = String(format: "%016llx", UInt64.random(in: .min ... .max))
        let sampled = "1"
        let cloudTrace = "\(traceID)/\(UInt64.random(in: 1 ... UInt64.max));o=\(sampled)"
        let traceparent = "00-\(traceID)-\(spanID)-01"
        _ = now()
        return .init(requestID: requestID, cloudTraceContext: cloudTrace, traceparent: traceparent)
    }
}
