import AppKit
import SwiftUI

/// NSTextView-backed log renderer. Uses TextKit's incremental layout and
/// appends only new lines, which keeps memory/CPU bounded even for long
/// streaming logs while preserving full range selection, Cmd+C, and Find.
struct LogTextView: NSViewRepresentable {
    let lines: [LogLine]
    var filterText: String = ""

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.font = Self.defaultFont
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = true

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        textView.defaultParagraphStyle = paragraph

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        guard let textView = coord.textView, let storage = textView.textStorage else { return }

        let filter = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible: [LogLine]
        if filter.isEmpty {
            visible = lines
        } else {
            visible = lines.filter { $0.text.localizedStandardContains(filter) }
        }

        let filterChanged = coord.lastFilter != filter

        if !filterChanged,
           let lastID = coord.lastAppendedID,
           let anchorIdx = visible.firstIndex(where: { $0.id == lastID })
        {
            let newLines = visible[(anchorIdx + 1)...]
            if newLines.isEmpty { return }
            let wasAtBottom = coord.isAtBottom()
            let appended = Self.attributedString(for: newLines)
            storage.append(appended)
            coord.lastAppendedID = newLines.last?.id
            coord.trimIfNeeded(storage: storage)
            if wasAtBottom { coord.scrollToBottom() }
            return
        }

        // Full rebuild (first render, filter change, or buffer rolled past tracked tail)
        let wasAtBottom = coord.isAtBottom() || coord.lastAppendedID == nil
        if visible.isEmpty {
            storage.mutableString.setString("")
        } else {
            storage.setAttributedString(Self.attributedString(for: visible[...]))
        }
        coord.lastAppendedID = visible.last?.id
        coord.lastFilter = filter
        coord.trimIfNeeded(storage: storage)
        if wasAtBottom { coord.scrollToBottom() }
    }

    // MARK: - Attributed string construction

    private static let defaultFont = NSFont.monospacedSystemFont(
        ofSize: 12,
        weight: .regular
    )

    private static func attributedString(for lines: ArraySlice<LogLine>) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for line in lines {
            let color = lineColor(line.text)
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: defaultFont
            ]
            result.append(NSAttributedString(string: line.text + "\n", attributes: attrs))
        }
        return result
    }

    private static func lineColor(_ line: String) -> NSColor {
        let prefix = String(line.prefix(60))
        if prefix.contains(" error ") || prefix.contains("[error]")
            || prefix.contains(" critical ") || prefix.contains("[critical]")
        {
            return .systemRed
        }
        if prefix.contains(" warning ") || prefix.contains("[warning]") {
            return .systemYellow
        }
        if prefix.contains(" debug ") || prefix.contains("[debug]")
            || prefix.contains(" trace ") || prefix.contains("[trace]")
        {
            return .secondaryLabelColor
        }
        if line.contains("\"status\":5") { return .systemRed }
        if line.contains("\"status\":4") { return .systemOrange }
        return .labelColor
    }

    // MARK: - Coordinator

    final class Coordinator {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var lastAppendedID: String?
        var lastFilter: String = ""

        /// Soft cap on textStorage length. When exceeded, the head is trimmed
        /// to ~75% of the cap so subsequent appends amortize the deletion cost.
        private static let softCapCharacters = 2_000_000
        private static let trimTargetCharacters = 1_500_000
        private static let bottomStickThreshold: CGFloat = 40

        func isAtBottom() -> Bool {
            guard let scrollView, let documentView = scrollView.documentView else {
                return true
            }
            let visible = scrollView.contentView.bounds
            let docHeight = documentView.frame.height
            return visible.maxY >= docHeight - Self.bottomStickThreshold
        }

        func scrollToBottom() {
            textView?.scrollToEndOfDocument(nil)
        }

        func trimIfNeeded(storage: NSTextStorage) {
            guard storage.length > Self.softCapCharacters else { return }
            let excess = storage.length - Self.trimTargetCharacters
            let nsString = storage.string as NSString
            let searchRange = NSRange(location: min(excess, nsString.length), length: 0)
            let paragraphRange = nsString.paragraphRange(for: searchRange)
            let deleteLength = paragraphRange.location
            if deleteLength > 0 {
                storage.deleteCharacters(in: NSRange(location: 0, length: deleteLength))
            }
        }
    }
}
