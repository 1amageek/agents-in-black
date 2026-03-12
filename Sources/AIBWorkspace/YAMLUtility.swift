import Foundation
import YAML

/// Utility for converting between swift-yaml `Node` and Swift standard types,
/// and for emitting YAML strings from standard types.
public enum YAMLUtility {

    // MARK: - Node → Any

    /// Convert a YAML Node to a Swift standard type hierarchy ([String: Any], [Any], String, Int, Bool, etc.).
    public static func nodeToAny(_ node: Node) -> Any {
        switch node {
        case .scalar(let s):
            return scalarToAny(s)
        case .mapping(let m):
            var dict: [String: Any] = [:]
            for (key, value) in m {
                guard let keyStr = key.scalar?.string else { continue }
                dict[keyStr] = nodeToAny(value)
            }
            return dict
        case .sequence(let seq):
            return seq.map { nodeToAny($0) }
        }
    }

    private static func scalarToAny(_ s: Node.Scalar) -> Any {
        // Quoted scalars are always strings
        if s.style == .doubleQuoted || s.style == .singleQuoted {
            return s.string
        }
        let str = s.string
        // YAML 1.2 core schema: null
        if str.isEmpty || str == "null" || str == "~" {
            return NSNull()
        }
        // Bool
        if str == "true" { return true }
        if str == "false" { return false }
        // Int
        if let i = Int(str) { return i }
        // Float (only if contains decimal point or exponent)
        if str.contains(".") || str.lowercased().contains("e"),
           let d = Double(str) { return d }
        return str
    }

    // MARK: - Any → YAML String

    /// Emit a YAML string from a Swift standard type hierarchy.
    public static func emitYAML(_ value: Any, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)

        if value is NSNull {
            return "null"
        }

        // Distinguish Bool from Int: NSNumber bridging makes `as? Bool` match
        // integers too. Use CFBooleanGetTypeID to detect actual JSON booleans.
        if let nsNum = value as? NSNumber, CFGetTypeID(nsNum) == CFBooleanGetTypeID() {
            return nsNum.boolValue ? "true" : "false"
        }

        if let int = value as? Int {
            return "\(int)"
        }

        if let double = value as? Double {
            if double == double.rounded() && !double.isInfinite && !double.isNaN
                && abs(double) < 1e15 {
                return "\(Int(double))"
            }
            return "\(double)"
        }

        if let str = value as? String {
            return quoteScalar(str)
        }

        if let dict = value as? [String: Any] {
            if dict.isEmpty { return "{}" }
            let sortedKeys = dict.keys.sorted()
            var lines: [String] = []
            for key in sortedKeys {
                let val = dict[key]!
                if isCollection(val) {
                    lines.append("\(pad)\(quoteKey(key)):")
                    lines.append(emitYAML(val, indent: indent + 1))
                } else {
                    lines.append("\(pad)\(quoteKey(key)): \(emitYAML(val))")
                }
            }
            return lines.joined(separator: "\n")
        }

        if let arr = value as? [Any] {
            if arr.isEmpty { return "[]" }
            var lines: [String] = []
            for item in arr {
                if let dict = item as? [String: Any], !dict.isEmpty {
                    let sortedKeys = dict.keys.sorted()
                    for (i, key) in sortedKeys.enumerated() {
                        let val = dict[key]!
                        let prefix = i == 0 ? "\(pad)- " : "\(pad)  "
                        if isCollection(val) {
                            lines.append("\(prefix)\(quoteKey(key)):")
                            lines.append(emitYAML(val, indent: indent + 2))
                        } else {
                            lines.append("\(prefix)\(quoteKey(key)): \(emitYAML(val))")
                        }
                    }
                } else {
                    lines.append("\(pad)- \(emitYAML(item))")
                }
            }
            return lines.joined(separator: "\n")
        }

        return "\(value)"
    }

    private static func isCollection(_ value: Any) -> Bool {
        if let dict = value as? [String: Any] { return !dict.isEmpty }
        if let arr = value as? [Any] { return !arr.isEmpty }
        return false
    }

    private static func quoteKey(_ key: String) -> String {
        if key.contains(" ") || key.contains(":") || key.contains("#")
            || key.contains("{") || key.contains("}")
            || key.contains("[") || key.contains("]") {
            return "'\(key)'"
        }
        return key
    }

    private static func quoteScalar(_ str: String) -> String {
        if str.isEmpty { return "''" }

        let reservedPlain = str == "true" || str == "false"
            || str == "null" || str == "~"
            || str == "yes" || str == "no"
            || str == "on" || str == "off"

        let needsQuoting = reservedPlain
            || str.contains("\n")
            || str.hasPrefix("- ") || str.hasPrefix("* ")
            || str.hasPrefix("! ") || str.hasPrefix("& ")
            || str.hasPrefix("% ") || str.hasPrefix("@ ")
            || str.hasPrefix("{") || str.hasPrefix("[")
            || str.hasPrefix("'") || str.hasPrefix("\"")
            || str.contains(": ") || str.contains(" #")
            || Int(str) != nil || Double(str) != nil

        guard needsQuoting else { return str }

        if str.contains("\n") {
            let escaped = str
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }

        if str.contains("'") {
            let escaped = str
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }

        return "'\(str)'"
    }
}
