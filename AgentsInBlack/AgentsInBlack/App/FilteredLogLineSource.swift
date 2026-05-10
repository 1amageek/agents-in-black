import Foundation
import LogViewer

@MainActor
final class FilteredLogSource<Line: Identifiable>: @MainActor LogSource {
    private let source: AnyLogSource<Line>
    private let text: (Line) -> String
    private let indexes: [Int]

    init<Source: LogSource>(
        source: Source,
        text: KeyPath<Line, String>,
        filterText: String
    ) where Source.Line == Line {
        self.source = AnyLogSource(source)
        self.text = { $0[keyPath: text] }

        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            self.indexes = Array(0..<source.numberOfLines)
            return
        }

        var matchingIndexes: [Int] = []
        matchingIndexes.reserveCapacity(source.numberOfLines)
        for index in 0..<source.numberOfLines {
            if self.text(source.line(at: index)).localizedStandardContains(query) {
                matchingIndexes.append(index)
            }
        }
        self.indexes = matchingIndexes
    }

    var numberOfLines: Int {
        indexes.count
    }

    func line(at index: Int) -> Line {
        source.line(at: indexes[index])
    }
}
