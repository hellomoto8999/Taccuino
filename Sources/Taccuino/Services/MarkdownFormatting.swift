import AppKit
import Foundation

// MARK: - Modello

enum MarkdownListKind: String, Equatable {
    case bullet
    case numbered
}

struct MarkdownInlineStyle: OptionSet {
    let rawValue: Int
    static let bold = MarkdownInlineStyle(rawValue: 1 << 0)
    static let italic = MarkdownInlineStyle(rawValue: 1 << 1)
    static let strike = MarkdownInlineStyle(rawValue: 1 << 2)
    static let code = MarkdownInlineStyle(rawValue: 1 << 3)
    static let hidden = MarkdownInlineStyle(rawValue: 1 << 4)
    static let listMarker = MarkdownInlineStyle(rawValue: 1 << 5)
}

struct MarkdownLinkInfo {
    var range: NSRange
    var url: URL
}

struct MarkdownLineInfo {
    var range: NSRange
    var contentRange: NSRange
    var headingLevel = 0
    var listKind: MarkdownListKind?
    var listLevel = 0
    var listPrefixRange: NSRange?
    var listMarkerRange: NSRange?
    var listMarkerText: String?
    var isTableRow = false
}

struct MarkdownParseResult {
    var lines: [MarkdownLineInfo] = []
    var masks: [MarkdownInlineStyle] = []
    var headingLevels: [Int] = []
    var links: [MarkdownLinkInfo] = []
    var hasFormatting = false
}

struct MarkdownTable {
    var blockRange: NSRange
    var headerRange: NSRange
    var separatorRange: NSRange
    var dataRanges: [NSRange]
    var rows: [[String]]
    var columnCount: Int
}

struct MarkdownFormattingState: Equatable {
    var bold = false
    var italic = false
    var strike = false
    var headingLevel = 0
    var listKind: MarkdownListKind?
    var listLevel = 0
    var inTable = false
    var tableRow: Int?
    var tableColumn: Int?
    var hasFormatting = false
    var characterCount = 0
}

// MARK: - Parser e rendering

enum MarkdownFormatting {
    private static let headingRegex = try! NSRegularExpression(pattern: #"^( {0,3})(#{1,6})([ \t]+)"#)
    private static let listRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-+*]|\d{1,9}[.)])([ \t]+)"#)
    private static let tableSeparatorRegex = try! NSRegularExpression(
        pattern: #"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$"#
    )
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\n]*)\)"#)
    private static let boldStarRegex = try! NSRegularExpression(pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#)
    private static let boldUnderscoreRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])__(?=\S)(.+?)(?<=\S)__(?![A-Za-z0-9])"#
    )
    private static let italicStarRegex = try! NSRegularExpression(
        pattern: #"(?<![*_])\*(?=\S)(.+?)(?<=\S)\*(?![*_])"#
    )
    private static let italicUnderscoreRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])_(?=\S)(.+?)(?<=\S)_(?![A-Za-z0-9])"#
    )
    private static let strikeRegex = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)

    // MARK: Parsing

    static func parse(_ string: String) -> MarkdownParseResult {
        let ns = string as NSString
        let length = ns.length
        var result = MarkdownParseResult(
            lines: [],
            masks: Array(repeating: [], count: length),
            headingLevels: Array(repeating: 0, count: length),
            links: [],
            hasFormatting: false
        )
        guard length > 0 else { return result }

        var index = 0
        while index < length {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            var contentLength = lineRange.length
            while contentLength > 0 {
                let character = ns.character(at: lineRange.location + contentLength - 1)
                if character == 10 || character == 13 {
                    contentLength -= 1
                } else {
                    break
                }
            }
            let contentRange = NSRange(location: lineRange.location, length: contentLength)
            let lineString = ns.substring(with: contentRange)
            let localRange = NSRange(location: 0, length: lineString.utf16.count)

            var info = MarkdownLineInfo(range: lineRange, contentRange: contentRange)

            if let match = headingRegex.firstMatch(in: lineString, options: [], range: localRange) {
                let prefix = NSRange(
                    location: contentRange.location + match.range.location,
                    length: match.range.length
                )
                markHidden(prefix, masks: &result.masks)
                info.headingLevel = match.range(at: 2).length
                info.contentRange = NSRange(
                    location: NSMaxRange(prefix),
                    length: max(0, NSMaxRange(contentRange) - NSMaxRange(prefix))
                )
                if info.contentRange.length > 0 {
                    for i in info.contentRange.location..<NSMaxRange(info.contentRange) {
                        if i < result.headingLevels.count {
                            result.headingLevels[i] = info.headingLevel
                        }
                    }
                }
                result.hasFormatting = true
            } else if let match = listRegex.firstMatch(in: lineString, options: [], range: localRange) {
                let prefix = NSRange(
                    location: contentRange.location + match.range.location,
                    length: match.range.length
                )
                markTrait(prefix, trait: .listMarker, masks: &result.masks)
                let marker = match.range(at: 2)
                let markerText = (lineString as NSString).substring(with: marker)
                info.listKind = markerText.rangeOfCharacter(from: .decimalDigits) != nil ? .numbered : .bullet
                let indent = (lineString as NSString).substring(with: match.range(at: 1))
                let columns = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                info.listLevel = min(6, columns / 2)
                info.listPrefixRange = NSRange(location: lineRange.location,
                                               length: NSMaxRange(prefix) - lineRange.location)
                info.listMarkerRange = NSRange(location: contentRange.location + marker.location,
                                               length: marker.length)
                info.listMarkerText = markerText
                info.contentRange = NSRange(
                    location: NSMaxRange(prefix),
                    length: max(0, NSMaxRange(contentRange) - NSMaxRange(prefix))
                )
                result.hasFormatting = true
            }

            // Stili inline nel contenuto della riga.
            if info.contentRange.length > 0 {
                parseInline(
                    ns,
                    range: info.contentRange,
                    masks: &result.masks,
                    links: &result.links,
                    hasFormatting: &result.hasFormatting
                )
            }
            result.lines.append(info)
            index = NSMaxRange(lineRange)
        }

        markTables(in: ns, lines: &result.lines, hasFormatting: &result.hasFormatting)
        return result
    }

    private static func parseInline(
        _ ns: NSString,
        range: NSRange,
        masks: inout [MarkdownInlineStyle],
        links: inout [MarkdownLinkInfo],
        hasFormatting: inout Bool
    ) {
        guard range.length > 0 else { return }
        let line = ns.substring(with: range) as NSString
        let localRange = NSRange(location: 0, length: line.length)

        func adjusted(_ local: NSRange) -> NSRange {
            NSRange(location: range.location + local.location, length: local.length)
        }

        func process(
            _ regex: NSRegularExpression,
            trait: MarkdownInlineStyle,
            skipIfHidden: Bool = true
        ) {
            for match in regex.matches(in: line as String, options: [], range: localRange) {
                let full = adjusted(match.range)
                guard full.length > 0 else { continue }
                if skipIfHidden && intersectsHidden(full, masks: masks) { continue }
                let contentLocal = match.range(at: 1)
                guard contentLocal.location != NSNotFound, contentLocal.length > 0 else { continue }
                let content = adjusted(contentLocal)
                let before = NSRange(location: full.location, length: content.location - full.location)
                let after = NSRange(location: NSMaxRange(content), length: NSMaxRange(full) - NSMaxRange(content))
                markHidden(before, masks: &masks)
                markHidden(after, masks: &masks)
                markTrait(content, trait: trait, masks: &masks)
                hasFormatting = true
            }
        }

        // Link per primi: le parentesi e l'URL vengono nascosti, l'etichetta resta.
        for match in linkRegex.matches(in: line as String, options: [], range: localRange) {
            let full = adjusted(match.range)
            let label = adjusted(match.range(at: 1))
            let urlText = line.substring(with: match.range(at: 2))
            guard full.length > 0, label.length > 0 else { continue }
            markHidden(NSRange(location: full.location, length: label.location - full.location), masks: &masks)
            markHidden(NSRange(location: NSMaxRange(label), length: NSMaxRange(full) - NSMaxRange(label)), masks: &masks)
            let url = URL(string: urlText) ?? URL(string: "https://\(urlText)")
            if let url {
                links.append(MarkdownLinkInfo(range: label, url: url))
            }
            hasFormatting = true
        }

        process(boldStarRegex, trait: .bold)
        process(boldUnderscoreRegex, trait: .bold)
        process(italicStarRegex, trait: .italic)
        process(italicUnderscoreRegex, trait: .italic)
        process(strikeRegex, trait: .strike)
        process(codeRegex, trait: .code)
    }

    private static func markTables(
        in ns: NSString,
        lines: inout [MarkdownLineInfo],
        hasFormatting: inout Bool
    ) {
        guard lines.count > 0 else { return }
        for index in lines.indices {
            let content = lines[index].contentRange
            let text = ns.substring(with: content)
            guard tableSeparatorRegex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) != nil else {
                continue
            }
            if index > 0 {
                lines[index - 1].isTableRow = true
            }
            lines[index].isTableRow = true
            var next = index + 1
            while next < lines.count {
                let nextText = ns.substring(with: lines[next].contentRange)
                guard nextText.contains("|") else { break }
                lines[next].isTableRow = true
                next += 1
            }
            hasFormatting = true
        }
    }

    private static func markHidden(_ range: NSRange, masks: inout [MarkdownInlineStyle]) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        let start = max(0, range.location)
        let end = min(masks.count, NSMaxRange(range))
        guard start < end else { return }
        for i in start..<end {
            masks[i].insert(.hidden)
        }
    }

    private static func markTrait(_ range: NSRange, trait: MarkdownInlineStyle, masks: inout [MarkdownInlineStyle]) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        let start = max(0, range.location)
        let end = min(masks.count, NSMaxRange(range))
        guard start < end else { return }
        for i in start..<end {
            masks[i].insert(trait)
        }
    }

    private static func intersectsHidden(_ range: NSRange, masks: [MarkdownInlineStyle]) -> Bool {
        guard range.location != NSNotFound, range.length > 0 else { return false }
        let start = max(0, range.location)
        let end = min(masks.count, NSMaxRange(range))
        guard start < end else { return false }
        for i in start..<end where masks[i].contains(.hidden) {
            return true
        }
        return false
    }

    struct BlockPrefix {
        var length: Int
        var headingLevel: Int?
        var listKind: MarkdownListKind?
        var indent: String
        var rawPrefix: String
    }

    /// Prefisso da usare quando si preme Invio alla fine di una voce di elenco.
    static func continuedListPrefix(for prefix: BlockPrefix) -> String? {
        guard let kind = prefix.listKind else { return nil }
        switch kind {
        case .bullet:
            return prefix.rawPrefix
        case .numbered:
            guard let range = prefix.rawPrefix.range(of: #"\d+"#, options: .regularExpression),
                  let number = Int(prefix.rawPrefix[range]) else {
                return prefix.rawPrefix
            }
            return prefix.rawPrefix.replacingCharacters(in: range, with: String(number + 1))
        }
    }

    /// Prefisso di blocco (titolo o elenco) di una singola riga senza newline.
    static func blockPrefix(in line: String) -> BlockPrefix? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = headingRegex.firstMatch(in: line, options: [], range: range) {
            return BlockPrefix(length: match.range.length,
                               headingLevel: match.range(at: 2).length,
                               listKind: nil,
                               indent: "",
                               rawPrefix: ns.substring(with: match.range))
        }
        if let match = listRegex.firstMatch(in: line, options: [], range: range) {
            let indent = ns.substring(with: match.range(at: 1))
            let marker = ns.substring(with: match.range(at: 2))
            let kind: MarkdownListKind = marker.rangeOfCharacter(from: .decimalDigits) != nil ? .numbered : .bullet
            return BlockPrefix(length: match.range.length,
                               headingLevel: nil,
                               listKind: kind,
                               indent: indent,
                               rawPrefix: ns.substring(with: match.range))
        }
        return nil
    }

    // MARK: Tabelle

    static func tables(in string: String) -> [MarkdownTable] {
        let ns = string as NSString
        guard ns.length > 0 else { return [] }
        var entries: [(full: NSRange, content: NSRange, text: String)] = []
        var index = 0
        while index < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            var contentLength = lineRange.length
            while contentLength > 0 {
                let c = ns.character(at: lineRange.location + contentLength - 1)
                if c == 10 || c == 13 { contentLength -= 1 } else { break }
            }
            let contentRange = NSRange(location: lineRange.location, length: contentLength)
            entries.append((lineRange, contentRange, ns.substring(with: contentRange)))
            index = NSMaxRange(lineRange)
        }

        var result: [MarkdownTable] = []
        var entryIndex = 1
        while entryIndex < entries.count {
            let separatorText = entries[entryIndex].text
            guard tableSeparatorRegex.firstMatch(in: separatorText,
                                                 options: [],
                                                 range: NSRange(location: 0, length: separatorText.utf16.count)) != nil,
                  entries[entryIndex - 1].text.contains("|") else {
                entryIndex += 1
                continue
            }
            let header = entries[entryIndex - 1]
            let separator = entries[entryIndex]
            var dataEntries: [(full: NSRange, content: NSRange, text: String)] = []
            var next = entryIndex + 1
            while next < entries.count, entries[next].text.contains("|") {
                dataEntries.append(entries[next])
                next += 1
            }
            var rows = [parseTableCells(header.text)]
            for data in dataEntries {
                rows.append(parseTableCells(data.text))
            }
            let columnCount = max(1, rows.map(\.count).max() ?? 1)
            for rowIndex in rows.indices {
                while rows[rowIndex].count < columnCount {
                    rows[rowIndex].append("")
                }
                if rows[rowIndex].count > columnCount {
                    rows[rowIndex] = Array(rows[rowIndex].prefix(columnCount))
                }
            }
            let end = dataEntries.last.map { NSMaxRange($0.full) } ?? NSMaxRange(separator.full)
            let block = NSRange(location: header.full.location, length: end - header.full.location)
            result.append(MarkdownTable(
                blockRange: block,
                headerRange: header.full,
                separatorRange: separator.full,
                dataRanges: dataEntries.map(\.full),
                rows: rows,
                columnCount: columnCount
            ))
            entryIndex = max(entryIndex + 1, next)
        }
        return result
    }

    static func parseTableCells(_ line: String) -> [String] {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                if character == "|" || character == "\\" {
                    current.append(character)
                } else {
                    current.append("\\")
                    current.append(character)
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        if text.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        if text.hasSuffix("|"), !cells.isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func tableRowHeight(for font: NSFont) -> CGFloat {
        max(28, ceil(font.pointSize * 2.2))
    }

    /// Testo di una cella senza i marcatori Markdown, con grassetto/corsivo/
    /// barrato applicati e i link ridotti alla sola etichetta.
    static func attributedCellText(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var bold = false
        var italic = false
        var strike = false
        var code = false
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            var runFont = font
            if bold {
                runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask)
            }
            if italic {
                runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: color
            ]
            if strike {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if code {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.95,
                                                                weight: .regular)
            }
            result.append(NSAttributedString(string: buffer, attributes: attributes))
            buffer = ""
        }

        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            if rest.hasPrefix("**") || rest.hasPrefix("__") {
                flush()
                bold.toggle()
                index = text.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("~~") {
                flush()
                strike.toggle()
                index = text.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("`") {
                flush()
                code.toggle()
                index = text.index(after: index)
                continue
            }
            if rest.hasPrefix("*") || rest.hasPrefix("_") {
                flush()
                italic.toggle()
                index = text.index(after: index)
                continue
            }
            if rest.hasPrefix("["),
               let close = text[index...].firstIndex(of: "]") {
                let afterClose = text.index(after: close)
                if afterClose < text.endIndex, text[afterClose] == "(" {
                    let urlStart = text.index(after: afterClose)
                    if let paren = text[urlStart...].firstIndex(of: ")") {
                        flush()
                        let label = String(text[text.index(after: index)..<close])
                        result.append(attributedCellText(label, font: font, color: color))
                        index = text.index(after: paren)
                        continue
                    }
                }
            }
            buffer.append(text[index])
            index = text.index(after: index)
        }
        flush()
        return result
    }

    // MARK: Stato corrente

    static func state(for string: String, selection: NSRange) -> MarkdownFormattingState {
        let ns = string as NSString
        let info = parse(string)
        var state = MarkdownFormattingState()
        state.characterCount = string.count
        state.hasFormatting = info.hasFormatting
        guard ns.length > 0 else { return state }

        let rawLocation = min(max(0, selection.location), ns.length)
        let line = info.lines.last { $0.range.location <= rawLocation } ?? info.lines.first
        state.headingLevel = line?.headingLevel ?? 0
        state.listKind = line?.listKind
        state.listLevel = line?.listLevel ?? 0
        state.inTable = line?.isTableRow ?? false

        var probe = min(ns.length - 1, max(0, selection.length > 0 ? NSMaxRange(selection) - 1 : rawLocation - 1))
        if probe >= 0, probe < info.masks.count {
            while probe > (line?.contentRange.location ?? 0), info.masks[probe].contains(.hidden) {
                probe -= 1
            }
            let mask = info.masks[probe]
            state.bold = mask.contains(.bold)
            state.italic = mask.contains(.italic)
            state.strike = mask.contains(.strike)
        }
        return state
    }

    // MARK: Rendering

    static func render(
        textView: NSTextView,
        string: String,
        baseFont: NSFont,
        theme: Theme,
        formatted: Bool
    ) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        let baseParagraph = baseParagraphStyle(baseFont)
        storage.beginEditing()
        storage.setAttributes(
            [.font: baseFont, .foregroundColor: theme.nsText, .paragraphStyle: baseParagraph],
            range: full
        )
        guard formatted, storage.length > 0 else {
            storage.endEditing()
            textView.typingAttributes = [
                .font: baseFont,
                .foregroundColor: theme.nsText,
                .paragraphStyle: baseParagraph
            ]
            return
        }

        let info = parse(string)
        applyInlineRuns(info, to: storage, baseFont: baseFont, theme: theme)
        applyTableBlocks(in: string, to: storage, baseFont: baseFont)
        storage.endEditing()

        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: theme.nsText,
            .paragraphStyle: baseParagraph
        ]
    }

    private static func baseParagraphStyle(_ font: NSFont) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = max(1, (" " as NSString).size(withAttributes: [.font: font]).width * 8)
        paragraph.tabStops = []
        return paragraph
    }

    private static func applyInlineRuns(
        _ info: MarkdownParseResult,
        to storage: NSTextStorage,
        baseFont: NSFont,
        theme: Theme
    ) {
        let length = storage.length
        guard length > 0, info.masks.count == length else { return }
        var runStart = 0
        var index = 1
        while index <= length {
            let atEnd = index == length
            if atEnd ||
                info.masks[index] != info.masks[runStart] ||
                info.headingLevels[index] != info.headingLevels[runStart] {
                let range = NSRange(location: runStart, length: index - runStart)
                let mask = info.masks[runStart]
                let heading = info.headingLevels[runStart]
                var font = baseFont
                if heading > 0 {
                    let scale: CGFloat
                    switch heading {
                    case 1: scale = 2.0
                    case 2: scale = 1.6
                    case 3: scale = 1.35
                    default: scale = 1.15
                    }
                    font = NSFontManager.shared.convert(font, toSize: font.pointSize * scale)
                }
                if mask.contains(.hidden) {
                    font = NSFontManager.shared.convert(baseFont, toSize: 0.1)
                    storage.addAttributes(
                        [.font: font, .foregroundColor: NSColor.clear, .spellingState: 0],
                        range: range
                    )
                } else {
                    if mask.contains(.listMarker) {
                        storage.addAttributes(
                            [.foregroundColor: theme.secondaryText],
                            range: range
                        )
                    }
                    if mask.contains(.bold) || heading > 0 {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    }
                    if mask.contains(.italic) {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    }
                    var attributes: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: theme.nsText
                    ]
                    if mask.contains(.strike) {
                        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    }
                    if mask.contains(.code) {
                        attributes[.backgroundColor] = NSColor(theme.hover)
                    }
                    storage.addAttributes(attributes, range: range)
                }
                runStart = index
            }
            index += 1
        }

        for link in info.links {
            guard NSMaxRange(link.range) <= length else { continue }
            storage.addAttributes(
                [
                    .foregroundColor: theme.nsAccent,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: link.url
                ],
                range: link.range
            )
        }
    }

    private static func applyTableBlocks(
        in string: String,
        to storage: NSTextStorage,
        baseFont: NSFont
    ) {
        let tables = tables(in: string)
        guard !tables.isEmpty else { return }

        let rowHeight = tableRowHeight(for: baseFont)
        let hiddenFont = NSFontManager.shared.convert(baseFont, toSize: 0.1)
        let length = storage.length

        func hideRow(_ range: NSRange, height: CGFloat) {
            guard range.length > 0, NSMaxRange(range) <= length else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
            paragraph.lineSpacing = 0
            paragraph.paragraphSpacing = 0
            paragraph.paragraphSpacingBefore = 0
            storage.addAttributes(
                [
                    .font: hiddenFont,
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: paragraph,
                    .spellingState: 0
                ],
                range: range
            )
        }

        for table in tables {
            hideRow(table.headerRange, height: rowHeight)
            hideRow(table.separatorRange, height: 0.1)
            for range in table.dataRanges {
                hideRow(range, height: rowHeight)
            }
        }
    }
}
