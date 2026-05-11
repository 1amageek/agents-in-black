import Foundation
import LogViewer

@MainActor
final class LogBuffer: @MainActor LogSource {
    struct Entry: Identifiable, Sendable, Equatable, Hashable, CustomStringConvertible {
        let id: String
        let text: String

        var description: String {
            text
        }
    }

    private(set) var lines: [Entry] = []
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
    var numberOfLines: Int {
        lines.count
    }

    func line(at index: Int) -> Entry {
        guard lines.indices.contains(index) else {
            return Entry(id: "\(idNamespace):missing:\(index)", text: "")
        }
        return lines[index]
    }

    func append(_ text: String) {
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
            lines.append(Entry(id: id, text: String(part)))
        }
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func clear() {
        lines.removeAll(keepingCapacity: true)
    }
}
