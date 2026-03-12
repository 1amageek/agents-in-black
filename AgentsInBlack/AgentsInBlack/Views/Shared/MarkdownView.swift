import SwiftUI

struct MarkdownView: View {
    let markdown: String
    var style: Style = .standard

    private var blocks: [Block] {
        Parser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineMarkdown(text, font: style.headingFont(for: level), color: style.headingColor)
        case .paragraph(let lines):
            VStack(alignment: .leading, spacing: style.lineSpacing) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    inlineMarkdown(line, font: style.bodyFont, color: style.textColor)
                }
            }
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: style.lineSpacing + 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{2022}")
                            .font(style.bodyFont.weight(.semibold))
                            .foregroundStyle(style.secondaryTextColor)
                        inlineMarkdown(item, font: style.bodyFont, color: style.textColor)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: style.lineSpacing + 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(style.captionFont.monospacedDigit().weight(.semibold))
                            .foregroundStyle(style.secondaryTextColor)
                        inlineMarkdown(item.text, font: style.bodyFont, color: style.textColor)
                    }
                }
            }
        case .blockquote(let lines):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(style.quoteBarColor)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: style.lineSpacing) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        inlineMarkdown(line, font: style.bodyFont, color: style.textColor)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(style.quoteBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .codeBlock(_, let lines):
            Text(lines.joined(separator: "\n"))
                .font(style.codeFont)
                .foregroundStyle(style.codeTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(style.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .thematicBreak:
            Rectangle()
                .fill(style.ruleColor)
                .frame(height: 1)
                .padding(.vertical, 2)
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        }
    }

    @ViewBuilder
    private func inlineMarkdown(_ source: String, font: Font, color: AnyShapeStyle) -> some View {
        if let attributed = parseInlineMarkdown(source) {
            Text(attributed)
                .font(font)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(source)
                .font(font)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func parseInlineMarkdown(_ source: String) -> AttributedString? {
        do {
            return try AttributedString(
                markdown: source,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            return nil
        }
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    inlineMarkdown(header, font: style.captionFont.weight(.semibold), color: style.headingColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(style.tableHeaderBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        inlineMarkdown(cell, font: style.bodyFont, color: style.textColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(style.tableCellBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(10)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(style.tableBorderColor, lineWidth: 1)
        }
    }
}

extension MarkdownView {
    struct Style {
        var textColor: AnyShapeStyle
        var secondaryTextColor: AnyShapeStyle
        var headingColor: AnyShapeStyle
        var codeTextColor: AnyShapeStyle
        var codeBackground: Color
        var quoteBarColor: Color
        var quoteBackground: Color
        var ruleColor: Color
        var tableBorderColor: Color
        var tableHeaderBackground: Color
        var tableCellBackground: Color
        var bodyFont: Font
        var captionFont: Font
        var codeFont: Font
        var h1Font: Font
        var h2Font: Font
        var h3Font: Font
        var h4Font: Font
        var h5Font: Font
        var h6Font: Font
        var blockSpacing: CGFloat
        var lineSpacing: CGFloat

        func headingFont(for level: Int) -> Font {
            switch level {
            case 1:
                return h1Font
            case 2:
                return h2Font
            case 3:
                return h3Font
            case 4:
                return h4Font
            case 5:
                return h5Font
            default:
                return h6Font
            }
        }

        static let standard = Style(
            textColor: AnyShapeStyle(.primary),
            secondaryTextColor: AnyShapeStyle(.secondary),
            headingColor: AnyShapeStyle(.primary),
            codeTextColor: AnyShapeStyle(.primary),
            codeBackground: Color(nsColor: .controlBackgroundColor),
            quoteBarColor: Color.accentColor.opacity(0.75),
            quoteBackground: Color(nsColor: .controlBackgroundColor).opacity(0.5),
            ruleColor: Color.primary.opacity(0.16),
            tableBorderColor: Color.primary.opacity(0.16),
            tableHeaderBackground: Color.primary.opacity(0.07),
            tableCellBackground: Color.clear,
            bodyFont: .body,
            captionFont: .caption,
            codeFont: .system(.body, design: .monospaced),
            h1Font: .system(.title2, design: .rounded).weight(.bold),
            h2Font: .system(.title3, design: .rounded).weight(.bold),
            h3Font: .system(.headline, design: .rounded).weight(.semibold),
            h4Font: .system(.subheadline, design: .rounded).weight(.semibold),
            h5Font: .system(.subheadline, design: .rounded).weight(.medium),
            h6Font: .system(.footnote, design: .rounded).weight(.semibold),
            blockSpacing: 10,
            lineSpacing: 4
        )
    }
}

extension MarkdownView.Style {
    func chatBubble(
        textColor: AnyShapeStyle,
        secondaryTextColor: AnyShapeStyle,
        headingColor: AnyShapeStyle,
        codeTextColor: AnyShapeStyle,
        codeBackground: Color,
        quoteBackground: Color,
        ruleColor: Color,
        tableBorderColor: Color,
        tableHeaderBackground: Color,
        tableCellBackground: Color
    ) -> Self {
        var style = self
        style.textColor = textColor
        style.secondaryTextColor = secondaryTextColor
        style.headingColor = headingColor
        style.codeTextColor = codeTextColor
        style.codeBackground = codeBackground
        style.quoteBarColor = ruleColor
        style.quoteBackground = quoteBackground
        style.ruleColor = ruleColor
        style.tableBorderColor = tableBorderColor
        style.tableHeaderBackground = tableHeaderBackground
        style.tableCellBackground = tableCellBackground
        return style
    }
}

private extension MarkdownView {
    struct OrderedListItem {
        let marker: String
        let text: String
    }

    enum Block {
        case heading(level: Int, text: String)
        case paragraph(lines: [String])
        case unorderedList([String])
        case orderedList([OrderedListItem])
        case blockquote([String])
        case codeBlock(language: String?, lines: [String])
        case thematicBreak
        case table(headers: [String], rows: [[String]])
    }

    enum Parser {
        static func parse(_ source: String) -> [Block] {
            let normalized = source
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            var blocks: [Block] = []
            var index = 0

            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty {
                    index += 1
                    continue
                }

                if let fence = fenceDelimiter(for: trimmed) {
                    let block = parseCodeBlock(lines: lines, startIndex: index, fence: fence)
                    blocks.append(block.block)
                    index = block.nextIndex
                    continue
                }

                if let heading = parseHeading(trimmed) {
                    blocks.append(.heading(level: heading.level, text: heading.text))
                    index += 1
                    continue
                }

                if isThematicBreak(trimmed) {
                    blocks.append(.thematicBreak)
                    index += 1
                    continue
                }

                if isTableHeaderLine(lines: lines, index: index) {
                    let block = parseTable(lines: lines, startIndex: index)
                    blocks.append(block.block)
                    index = block.nextIndex
                    continue
                }

                if trimmed.hasPrefix(">") {
                    let block = parseBlockQuote(lines: lines, startIndex: index)
                    blocks.append(block.block)
                    index = block.nextIndex
                    continue
                }

                if isUnorderedListItem(trimmed) {
                    let block = parseUnorderedList(lines: lines, startIndex: index)
                    blocks.append(block.block)
                    index = block.nextIndex
                    continue
                }

                if orderedListItem(from: trimmed) != nil {
                    let block = parseOrderedList(lines: lines, startIndex: index)
                    blocks.append(block.block)
                    index = block.nextIndex
                    continue
                }

                let block = parseParagraph(lines: lines, startIndex: index)
                blocks.append(block.block)
                index = block.nextIndex
            }

            return blocks
        }

        private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
            var level = 0
            for character in line {
                if character == "#" {
                    level += 1
                } else {
                    break
                }
            }

            guard (1...6).contains(level) else {
                return nil
            }

            let remainder = line.dropFirst(level)
            guard remainder.first == " " else {
                return nil
            }

            return (level, remainder.trimmingCharacters(in: .whitespaces))
        }

        private static func fenceDelimiter(for line: String) -> String? {
            if line.hasPrefix("```") {
                return "```"
            }
            if line.hasPrefix("~~~") {
                return "~~~"
            }
            return nil
        }

        private static func parseCodeBlock(lines: [String], startIndex: Int, fence: String) -> (block: Block, nextIndex: Int) {
            let firstLine = lines[startIndex].trimmingCharacters(in: .whitespaces)
            let language = String(firstLine.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
            var codeLines: [String] = []
            var index = startIndex + 1

            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    return (.codeBlock(language: language.isEmpty ? nil : language, lines: codeLines), index + 1)
                }
                codeLines.append(line)
                index += 1
            }

            return (.codeBlock(language: language.isEmpty ? nil : language, lines: codeLines), index)
        }

        private static func isThematicBreak(_ line: String) -> Bool {
            let compact = line.replacingOccurrences(of: " ", with: "")
            guard compact.count >= 3 else {
                return false
            }

            let allowed = CharacterSet(charactersIn: "-*_")
            return compact.unicodeScalars.allSatisfy { allowed.contains($0) }
        }

        private static func isTableHeaderLine(lines: [String], index: Int) -> Bool {
            guard index + 1 < lines.count else {
                return false
            }

            let header = lines[index]
            let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
            return header.contains("|") && isTableSeparator(separator)
        }

        private static func isTableSeparator(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("|") else {
                return false
            }

            let cells = splitTableRow(trimmed)
            guard !cells.isEmpty else {
                return false
            }

            for cell in cells {
                let marker = cell.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
                if !marker.isEmpty {
                    return false
                }
                if cell.filter({ $0 == "-" }).count < 3 {
                    return false
                }
            }

            return true
        }

        private static func parseTable(lines: [String], startIndex: Int) -> (block: Block, nextIndex: Int) {
            let headers = splitTableRow(lines[startIndex])
            var rows: [[String]] = []
            var index = startIndex + 2

            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || !line.contains("|") {
                    break
                }
                rows.append(splitTableRow(line))
                index += 1
            }

            return (.table(headers: headers, rows: rows), index)
        }

        private static func splitTableRow(_ line: String) -> [String] {
            var normalized = line.trimmingCharacters(in: .whitespaces)
            if normalized.hasPrefix("|") {
                normalized.removeFirst()
            }
            if normalized.hasSuffix("|") {
                normalized.removeLast()
            }
            return normalized.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }

        private static func parseBlockQuote(lines: [String], startIndex: Int) -> (block: Block, nextIndex: Int) {
            var collected: [String] = []
            var index = startIndex

            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(">") else {
                    break
                }

                let content = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                collected.append(String(content))
                index += 1
            }

            return (.blockquote(collected), index)
        }

        private static func isUnorderedListItem(_ line: String) -> Bool {
            line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
        }

        private static func parseUnorderedList(lines: [String], startIndex: Int) -> (block: Block, nextIndex: Int) {
            var items: [String] = []
            var index = startIndex

            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard isUnorderedListItem(trimmed) else {
                    break
                }

                items.append(String(trimmed.dropFirst(2)))
                index += 1
            }

            return (.unorderedList(items), index)
        }

        private static func orderedListItem(from line: String) -> OrderedListItem? {
            var digits = ""

            for character in line {
                if character.isNumber {
                    digits.append(character)
                    continue
                }

                guard character == ".", !digits.isEmpty else {
                    return nil
                }

                let remainder = line.dropFirst(digits.count + 1)
                guard remainder.first == " " else {
                    return nil
                }

                return OrderedListItem(marker: digits + ".", text: remainder.trimmingCharacters(in: .whitespaces))
            }

            return nil
        }

        private static func parseOrderedList(lines: [String], startIndex: Int) -> (block: Block, nextIndex: Int) {
            var items: [OrderedListItem] = []
            var index = startIndex

            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard let item = orderedListItem(from: trimmed) else {
                    break
                }

                items.append(item)
                index += 1
            }

            return (.orderedList(items), index)
        }

        private static func parseParagraph(lines: [String], startIndex: Int) -> (block: Block, nextIndex: Int) {
            var collected: [String] = []
            var index = startIndex

            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty || beginsNewBlock(lines: lines, index: index) {
                    break
                }

                collected.append(line)
                index += 1
            }

            if collected.isEmpty {
                collected.append(lines[startIndex])
                index = startIndex + 1
            }

            return (.paragraph(lines: collected), index)
        }

        private static func beginsNewBlock(lines: [String], index: Int) -> Bool {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if fenceDelimiter(for: trimmed) != nil || parseHeading(trimmed) != nil || isThematicBreak(trimmed) {
                return true
            }

            if trimmed.hasPrefix(">") || isUnorderedListItem(trimmed) || orderedListItem(from: trimmed) != nil {
                return true
            }

            return isTableHeaderLine(lines: lines, index: index)
        }
    }
}
