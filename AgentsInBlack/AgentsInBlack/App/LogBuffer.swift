import Foundation

/// A single rendered log line with a stable identity for `LazyVStack`.
struct LogLine: Identifiable, Sendable {
    let id: String
    let text: String
}

/// Bounded append-only buffer of `LogLine`s with per-buffer stable ids.
///
/// Storing logs as an array of lines — rather than a single concatenated `String` —
/// avoids O(n) reallocation on every append and enables `LazyVStack` to
/// materialize only visible rows.
struct LogBuffer: Sendable {
    private(set) var lines: [LogLine] = []
    private var nextCounter: UInt64 = 0
    let maxLines: Int
    let idNamespace: String

    init(maxLines: Int, idNamespace: String) {
        precondition(maxLines > 0, "maxLines must be > 0")
        self.maxLines = maxLines
        self.idNamespace = idNamespace
    }

    /// Appends `text` to the buffer. Multi-line input is split on `\n`; a
    /// trailing newline does not produce an empty line.
    mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        let effective: ArraySlice<Substring>
        if text.last == "\n", parts.last?.isEmpty == true {
            effective = parts.dropLast()
        } else {
            effective = parts[...]
        }
        for part in effective {
            let id = "\(idNamespace):\(nextCounter)"
            nextCounter &+= 1
            lines.append(LogLine(id: id, text: String(part)))
        }
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    mutating func clear() {
        lines.removeAll(keepingCapacity: true)
    }
}
