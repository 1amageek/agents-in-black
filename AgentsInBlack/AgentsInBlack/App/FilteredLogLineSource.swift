import Foundation
import LogViewer

@MainActor
final class FilteredLogSource<Line: Identifiable>: @MainActor LogSource {
    private let lines: [Line]

    init<Source: LogSource>(
        source: Source,
        text: KeyPath<Line, String>,
        filterText: String
    ) where Source.Line == Line {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            self.lines = (0..<source.numberOfLines).map { source.line(at: $0) }
            return
        }

        var matchingLines: [Line] = []
        matchingLines.reserveCapacity(source.numberOfLines)
        for index in 0..<source.numberOfLines {
            let line = source.line(at: index)
            if line[keyPath: text].localizedStandardContains(query) {
                matchingLines.append(line)
            }
        }
        self.lines = matchingLines
    }

    var numberOfLines: Int {
        lines.count
    }

    func line(at index: Int) -> Line {
        lines[index]
    }
}
