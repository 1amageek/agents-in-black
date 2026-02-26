import Foundation

public enum DurationParseError: Error, CustomStringConvertible, Sendable {
    case invalidFormat(String)
    case unsupportedUnit(String)

    public var description: String {
        switch self {
        case .invalidFormat(let s):
            return "Invalid duration format: \(s)"
        case .unsupportedUnit(let u):
            return "Unsupported duration unit: \(u)"
        }
    }
}

public enum DurationParser {
    public static func parse(_ string: String) throws -> Duration {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DurationParseError.invalidFormat(string)
        }
        let numberPart = trimmed.prefix { $0.isNumber }
        let unitPart = trimmed.dropFirst(numberPart.count)
        guard let value = Int64(numberPart), !unitPart.isEmpty else {
            throw DurationParseError.invalidFormat(string)
        }
        switch String(unitPart) {
        case "ms":
            return .milliseconds(value)
        case "s":
            return .seconds(value)
        case "m":
            return .seconds(value * 60)
        case "h":
            return .seconds(value * 3600)
        default:
            throw DurationParseError.unsupportedUnit(String(unitPart))
        }
    }
}

public extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
