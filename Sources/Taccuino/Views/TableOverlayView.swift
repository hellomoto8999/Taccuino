import AppKit

enum TableOverlayAction: Int {
    case insertTable
    case addRowBefore
    case addRowAfter
    case addColumnBefore
    case addColumnAfter
    case deleteRow
    case deleteColumn
}

struct TableCellTarget: Equatable {
    var row: Int
    var column: Int
}

protocol TableOverlayDelegate: AnyObject {
    func tableOverlay(_ overlay: TableOverlayView,
                      didCommit text: String,
                      row: Int,
                      column: Int,
                      moveTo target: TableCellTarget?)
    func tableOverlay(_ overlay: TableOverlayView, didSelectRow row: Int, column: Int)
    func tableOverlay(_ overlay: TableOverlayView, perform action: TableOverlayAction)
}

/// Griglia reale disegnata sopra il Markdown nascosto della tabella.
final class TableOverlayView: NSView, NSTextFieldDelegate {
    let table: MarkdownTable
    let tableIndex: Int
    let font: NSFont
    let theme: Theme
    weak var delegate: TableOverlayDelegate?

    private(set) var selectedRow: Int?
    private(set) var selectedColumn: Int?
    private var selectionAnchor: TableCellTarget?
    private var selectionFocus: TableCellTarget?
    private var isDraggingSelection = false
    private var columnWidths: [CGFloat] = []
    private let rowHeight: CGFloat
    private var editorField: NSTextField?
    private var editingCell: TableCellTarget?
    private var isCommitting = false
    private var hoverRow: Int?
    private var hoverColumn: Int?
    private var hoverTracking: NSTrackingArea?

    private let horizontalPadding: CGFloat = 10
    private let minimumColumnWidth: CGFloat = 44

    init(table: MarkdownTable, index: Int, font: NSFont, theme: Theme) {
        self.table = table
        self.tableIndex = index
        self.font = font
        self.theme = theme
        self.rowHeight = MarkdownFormatting.tableRowHeight(for: font)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var selectedBounds: (top: Int, left: Int, bottom: Int, right: Int)? {
        guard let anchor = selectionAnchor ?? selectionFocus,
              let focus = selectionFocus ?? selectionAnchor else { return nil }
        return (min(anchor.row, focus.row),
                min(anchor.column, focus.column),
                max(anchor.row, focus.row),
                max(anchor.column, focus.column))
    }

    var rows: Int { max(1, table.rows.count) }
    var columns: Int { max(1, table.columnCount) }
    var hasActiveEditor: Bool { editorField != nil }

    // MARK: - Misura

    /// Calcola la larghezza delle colonne e restituisce la larghezza totale.
    @discardableResult
    func measure(availableWidth: CGFloat) -> CGFloat {
        let limit = max(120, availableWidth)
        var widths: [CGFloat] = []
        widths.reserveCapacity(columns)
        for column in 0..<columns {
            var widest: CGFloat = 0
            for row in 0..<rows {
                let text = cellText(row: row, column: column)
                let attributed = MarkdownFormatting.attributedCellText(
                    text,
                    font: row == 0 ? headerFont : font,
                    color: NSColor(theme.text)
                )
                widest = max(widest, ceil(attributed.size().width))
            }
            widths.append(max(minimumColumnWidth, widest + horizontalPadding * 2 + 4))
        }

        var total = widths.reduce(0, +)
        if total > limit, total > 0 {
            let scale = limit / total
            widths = widths.map { max(minimumColumnWidth, floor($0 * scale)) }
            total = widths.reduce(0, +)

            // Se i minimi impediscono di rientrare, riduci le colonne più larghe.
            var overflow = total - limit
            var index = widths.count - 1
            while overflow > 0.5, index >= 0 {
                let reducible = max(0, widths[index] - minimumColumnWidth)
                let reduction = min(overflow, reducible)
                widths[index] -= reduction
                overflow -= reduction
                index -= 1
            }
            total = widths.reduce(0, +)
        }

        columnWidths = widths
        return total
    }

    private func cellText(row: Int, column: Int) -> String {
        guard row < table.rows.count, column < table.rows[row].count else { return "" }
        return table.rows[row][column]
    }

    private func cellRect(row: Int, column: Int) -> NSRect {
        guard column < columnWidths.count else { return .zero }
        let x = columnWidths.prefix(column).reduce(0, +)
        return NSRect(x: x, y: CGFloat(row) * rowHeight,
                      width: columnWidths[column], height: rowHeight)
    }

    private func cell(at point: NSPoint) -> TableCellTarget? {
        guard !columnWidths.isEmpty, point.y >= 0, point.y < CGFloat(rows) * rowHeight else {
            return nil
        }
        let row = min(rows - 1, Int(floor(point.y / rowHeight)))
        var x: CGFloat = 0
        for (column, width) in columnWidths.enumerated() {
            if point.x >= x, point.x < x + width {
                return TableCellTarget(row: row, column: column)
            }
            x += width
        }
        if point.x < x, let last = columnWidths.indices.last {
            return TableCellTarget(row: row, column: last)
        }
        return nil
    }

    // MARK: - Disegno

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }

        NSColor(theme.content).setFill()
        bounds.fill()

        if columnWidths.count != columns {
            measure(availableWidth: bounds.width)
        }

        for row in 0..<rows {
            let rect = NSRect(x: 0, y: CGFloat(row) * rowHeight,
                              width: bounds.width, height: rowHeight)
            if row == 0 {
                NSColor(theme.card).setFill()
                rect.fill()
            } else if hoverRow == row, row != selectedRow {
                NSColor(theme.hover).withAlphaComponent(0.45).setFill()
                rect.fill()
            }

            for column in 0..<columns {
                let cellRect = cellRect(row: row, column: column)
                guard cellRect.width > 8 else { continue }
                if let bounds = selectedBounds,
                   row >= bounds.top, row <= bounds.bottom,
                   column >= bounds.left, column <= bounds.right {
                    let isActive = selectedRow == row && selectedColumn == column
                    NSColor(theme.accent).withAlphaComponent(isActive ? 0.20 : 0.10).setFill()
                    cellRect.fill()
                }
                let isEditing = editingCell?.row == row && editingCell?.column == column
                if !isEditing {
                    drawCellText(text: cellText(row: row, column: column),
                                 in: cellRect.insetBy(dx: horizontalPadding, dy: 4),
                                 isHeader: row == 0)
                }
            }
        }

        let gridColor = NSColor(theme.border)
        let outerColor = NSColor(theme.strongBorder)

        gridColor.setStroke()
        let horizontal = NSBezierPath()
        horizontal.lineWidth = 1
        for row in 1..<rows {
            let y = CGFloat(row) * rowHeight
            horizontal.move(to: NSPoint(x: 0, y: y))
            horizontal.line(to: NSPoint(x: bounds.width, y: y))
        }
        horizontal.stroke()

        let vertical = NSBezierPath()
        vertical.lineWidth = 1
        var x: CGFloat = 0
        for width in columnWidths.dropLast() {
            x += width
            vertical.move(to: NSPoint(x: x, y: 0))
            vertical.line(to: NSPoint(x: x, y: CGFloat(rows) * rowHeight))
        }
        vertical.stroke()

        outerColor.setStroke()
        let outer = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        outer.lineWidth = 1
        outer.stroke()

        if let bounds = selectedBounds, editingCell == nil {
            let topLeft = cellRect(row: bounds.top, column: bounds.left)
            let bottomRight = cellRect(row: bounds.bottom, column: bounds.right)
            let rect = NSRect(x: topLeft.minX,
                              y: topLeft.minY,
                              width: bottomRight.maxX - topLeft.minX,
                              height: bottomRight.maxY - topLeft.minY).insetBy(dx: 1.5, dy: 1.5)
            NSColor(theme.accent).setStroke()
            let selection = NSBezierPath(rect: rect)
            selection.lineWidth = 2
            selection.stroke()
        }
    }

    private func drawCellText(text: String, in rect: NSRect, isHeader: Bool) {
        let base = MarkdownFormatting.attributedCellText(
            text,
            font: isHeader ? headerFont : font,
            color: NSColor(theme.text)
        )
        let attributed = NSMutableAttributedString(attributedString: base)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        attributed.addAttribute(.paragraphStyle, value: paragraph,
                                range: NSRange(location: 0, length: attributed.length))
        let height = max(ceil(attributed.size().height), ceil(font.ascender - font.descender))
        attributed.draw(
            with: NSRect(x: rect.minX, y: rect.midY - height / 2,
                         width: rect.width, height: height + 2),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }

    private var headerFont: NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    // MARK: - Selezione e modifica

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let target = cell(at: point) else { return }
        if let field = editorField {
            // Un clic su un'altra cella conferma e sposta la modifica.
            move(from: field,
                 text: field.stringValue,
                 row: selectedRow ?? 0,
                 column: selectedColumn ?? 0,
                 target: target)
            return
        }

        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            select(row: target.row, column: target.column)
            beginEditing(row: target.row, column: target.column)
            return
        }

        if event.modifierFlags.contains(.shift), let anchor = selectionAnchor {
            selectionFocus = target
            selectedRow = anchor.row
            selectedColumn = anchor.column
        } else {
            selectionAnchor = target
            selectionFocus = target
            selectedRow = target.row
            selectedColumn = target.column
            delegate?.tableOverlay(self, didSelectRow: target.row, column: target.column)
        }
        isDraggingSelection = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingSelection, selectionAnchor != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let target = clampedCell(at: point)
        if selectionFocus != target {
            selectionFocus = target
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingSelection = false
    }

    override func selectAll(_ sender: Any?) {
        guard rows > 0, columns > 0 else { return }
        selectionAnchor = TableCellTarget(row: 0, column: 0)
        selectionFocus = TableCellTarget(row: rows - 1, column: columns - 1)
        selectedRow = 0
        selectedColumn = 0
        delegate?.tableOverlay(self, didSelectRow: 0, column: 0)
        needsDisplay = true
    }

    @objc func copy(_ sender: Any?) {
        guard let bounds = selectedBounds else { return }
        var lines: [String] = []
        for row in bounds.top...bounds.bottom {
            var cells: [String] = []
            for column in bounds.left...bounds.right {
                let raw = cellText(row: row, column: column)
                cells.append(MarkdownFormatting.attributedCellText(
                    raw,
                    font: font,
                    color: NSColor(theme.text)
                ).string)
            }
            lines.append(cells.joined(separator: "\t"))
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    override func keyDown(with event: NSEvent) {
        guard let active = selectionAnchor ?? selectionFocus else {
            super.keyDown(with: event)
            return
        }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: // Esc
            window?.makeFirstResponder(enclosingTextView)
        case 36, 76: // Return / keypad Enter
            beginEditing(row: active.row, column: active.column)
        case 48: // Tab
            let target = nextCell(row: active.row, column: active.column, backwards: shift)
            select(row: target.row, column: target.column)
        case 123: // Left
            moveActive(rowDelta: 0, columnDelta: -1, extend: shift)
        case 124: // Right
            moveActive(rowDelta: 0, columnDelta: 1, extend: shift)
        case 125: // Down
            moveActive(rowDelta: 1, columnDelta: 0, extend: shift)
        case 126: // Up
            moveActive(rowDelta: -1, columnDelta: 0, extend: shift)
        case 51, 117: // Delete / Forward Delete
            return
        default:
            if let characters = event.characters,
               let scalar = characters.unicodeScalars.first,
               scalar.value >= 32,
               !CharacterSet.controlCharacters.contains(scalar),
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                beginEditing(row: active.row, column: active.column)
                if let fieldEditor = window?.firstResponder as? NSTextView {
                    fieldEditor.selectAll(nil)
                    fieldEditor.insertText(characters, replacementRange: fieldEditor.selectedRange())
                }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func moveActive(rowDelta: Int, columnDelta: Int, extend: Bool) {
        let source = extend ? (selectionFocus ?? selectionAnchor) : (selectionAnchor ?? selectionFocus)
        guard let source else { return }
        let target = TableCellTarget(
            row: min(max(0, source.row + rowDelta), rows - 1),
            column: min(max(0, source.column + columnDelta), columns - 1)
        )
        if extend {
            selectionFocus = target
            needsDisplay = true
            return
        }
        select(row: target.row, column: target.column)
    }

    private func clampedCell(at point: NSPoint) -> TableCellTarget {
        if columnWidths.count != columns {
            measure(availableWidth: max(bounds.width, 200))
        }
        let row = min(max(0, Int(floor(point.y / rowHeight))), rows - 1)
        if point.x <= 0 { return TableCellTarget(row: row, column: 0) }
        var x: CGFloat = 0
        for (column, width) in columnWidths.enumerated() {
            if point.x < x + width {
                return TableCellTarget(row: row, column: column)
            }
            x += width
        }
        return TableCellTarget(row: row, column: max(0, columns - 1))
    }

    func clearSelection() {
        guard selectedRow != nil || selectedColumn != nil
                || selectionAnchor != nil || selectionFocus != nil else { return }
        selectedRow = nil
        selectedColumn = nil
        selectionAnchor = nil
        selectionFocus = nil
        needsDisplay = true
    }

    func selectRange(anchor: TableCellTarget, focus: TableCellTarget) {
        let a = TableCellTarget(row: min(max(0, anchor.row), rows - 1),
                                column: min(max(0, anchor.column), columns - 1))
        let f = TableCellTarget(row: min(max(0, focus.row), rows - 1),
                                column: min(max(0, focus.column), columns - 1))
        selectionAnchor = a
        selectionFocus = f
        selectedRow = a.row
        selectedColumn = a.column
        delegate?.tableOverlay(self, didSelectRow: a.row, column: a.column)
        needsDisplay = true
    }

    func select(row: Int, column: Int) {
        let clampedRow = min(max(0, row), rows - 1)
        let clampedColumn = min(max(0, column), columns - 1)
        selectedRow = clampedRow
        selectedColumn = clampedColumn
        selectionAnchor = TableCellTarget(row: clampedRow, column: clampedColumn)
        selectionFocus = selectionAnchor
        delegate?.tableOverlay(self, didSelectRow: clampedRow, column: clampedColumn)
        needsDisplay = true
    }

    func beginEditing(row: Int, column: Int) {
        guard row >= 0, row < rows, column >= 0, column < columns else { return }
        if columnWidths.count != columns {
            measure(availableWidth: max(bounds.width, 200))
        }
        closeEditor(commit: false)
        select(row: row, column: column)
        let cell = cellRect(row: row, column: column)
        let textHeight = ceil(("Ag" as NSString).size(withAttributes: [.font: font]).height)
        let fieldHeight = min(max(20, textHeight + 6), max(20, rowHeight - 4))
        let rect = NSRect(x: cell.minX + 2,
                          y: cell.midY - fieldHeight / 2,
                          width: max(24, cell.width - 4),
                          height: fieldHeight)
        let field = NSTextField(frame: rect)
        field.stringValue = cellText(row: row, column: column)
        field.font = font
        field.textColor = NSColor(theme.text)
        field.backgroundColor = NSColor(theme.field)
        field.drawsBackground = true
        field.isBezeled = false
        field.focusRingType = .none
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor(theme.field).cgColor
        field.layer?.borderWidth = 2
        field.layer?.borderColor = NSColor(theme.accent).cgColor
        field.layer?.cornerRadius = 2
        addSubview(field)
        editorField = field
        editingCell = TableCellTarget(row: row, column: column)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    private func closeEditor(commit: Bool) {
        guard let field = editorField else { return }
        if commit {
            finishEditing(field: field)
        } else {
            editorField = nil
            editingCell = nil
            field.delegate = nil
            field.removeFromSuperview()
            needsDisplay = true
        }
    }

    private func finishEditing(field: NSTextField) {
        guard !isCommitting, editorField === field else { return }
        isCommitting = true
        let text = field.stringValue
        let row = selectedRow ?? 0
        let column = selectedColumn ?? 0
        editorField = nil
        editingCell = nil
        field.delegate = nil
        field.removeFromSuperview()
        isCommitting = false
        needsDisplay = true
        delegate?.tableOverlay(self, didCommit: text,
                               row: row, column: column, moveTo: nil)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !isCommitting, let field = editorField else { return }
        finishEditing(field: field)
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard let field = editorField else { return false }
        let row = selectedRow ?? 0
        let column = selectedColumn ?? 0
        let text = field.stringValue

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            move(from: field, text: text, row: row, column: column,
                 target: TableCellTarget(row: min(row + 1, rows - 1), column: column))
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            move(from: field, text: text, row: row, column: column,
                 target: nextCell(row: row, column: column, backwards: false))
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            move(from: field, text: text, row: row, column: column,
                 target: nextCell(row: row, column: column, backwards: true))
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeEditor(commit: false)
            if let window, let documentView = enclosingTextView {
                window.makeFirstResponder(documentView)
            }
            return true
        }
        return false
    }

    private var enclosingTextView: NSTextView? {
        superview as? NSTextView
    }

    private func nextCell(row: Int, column: Int, backwards: Bool) -> TableCellTarget {
        var r = row
        var c = column
        if backwards {
            c -= 1
            if c < 0 {
                c = columns - 1
                r = max(0, r - 1)
            }
        } else {
            c += 1
            if c >= columns {
                c = 0
                r = min(rows - 1, r + 1)
            }
        }
        return TableCellTarget(row: r, column: c)
    }

    private func move(from field: NSTextField,
                      text: String,
                      row: Int,
                      column: Int,
                      target: TableCellTarget) {
        guard !isCommitting else { return }
        isCommitting = true
        editorField = nil
        editingCell = nil
        field.delegate = nil
        field.removeFromSuperview()
        isCommitting = false
        needsDisplay = true
        delegate?.tableOverlay(self, didCommit: text,
                               row: row, column: column, moveTo: target)
    }

    // MARK: - Menu contestuale

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let target = cell(at: point) {
            let insideSelection = selectedBounds.map {
                target.row >= $0.top && target.row <= $0.bottom
                    && target.column >= $0.left && target.column <= $0.right
            } ?? false
            if !insideSelection {
                select(row: target.row, column: target.column)
            }
        }
        window?.makeFirstResponder(self)
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: L.t("Copia celle", "Copy cells"),
                                  action: #selector(copy(_:)),
                                  keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)
        let selectAllItem = NSMenuItem(title: L.t("Seleziona tutte le celle", "Select all cells"),
                                       action: #selector(selectAll(_:)),
                                       keyEquivalent: "a")
        selectAllItem.target = self
        menu.addItem(selectAllItem)
        menu.addItem(.separator())

        func add(_ title: String, _ action: TableOverlayAction) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = action.rawValue
            menu.addItem(item)
        }

        add(L.t("Inserisci tabella…", "Insert table…"), .insertTable)
        menu.addItem(.separator())
        add(L.t("Inserisci riga sopra", "Insert row above"), .addRowBefore)
        add(L.t("Inserisci riga sotto", "Insert row below"), .addRowAfter)
        add(L.t("Inserisci colonna a sinistra", "Insert column left"), .addColumnBefore)
        add(L.t("Inserisci colonna a destra", "Insert column right"), .addColumnAfter)
        menu.addItem(.separator())
        add(L.t("Elimina riga", "Delete row"), .deleteRow)
        add(L.t("Elimina colonna", "Delete column"), .deleteColumn)
        return menu
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = TableOverlayAction(rawValue: sender.tag) else { return }
        delegate?.tableOverlay(self, perform: action)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let target = cell(at: point)
        let row = target?.row
        let column = target?.column
        if row != hoverRow || column != hoverColumn {
            hoverRow = row
            hoverColumn = column
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverRow = nil
        hoverColumn = nil
        needsDisplay = true
    }
}
