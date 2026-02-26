import Foundation

public struct AccessLogEntry: Sendable, Codable {
    public var ts: String
    public var requestID: String
    public var traceID: String?
    public var serviceID: String?
    public var method: String
    public var path: String
    public var status: Int
    public var latencyMS: Double
    public var bytesIn: Int
    public var bytesOut: Int
    public var timeoutKind: String?
    public var error: String?

    public init(
        ts: String,
        requestID: String,
        traceID: String?,
        serviceID: String?,
        method: String,
        path: String,
        status: Int,
        latencyMS: Double,
        bytesIn: Int,
        bytesOut: Int,
        timeoutKind: String? = nil,
        error: String? = nil
    ) {
        self.ts = ts
        self.requestID = requestID
        self.traceID = traceID
        self.serviceID = serviceID
        self.method = method
        self.path = path
        self.status = status
        self.latencyMS = latencyMS
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.timeoutKind = timeoutKind
        self.error = error
    }
}

public enum ISO8601 {
    public static func fractionalString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
