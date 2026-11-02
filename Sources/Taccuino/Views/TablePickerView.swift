import AppKit

/// Griglia di scelta rapida per inserire una tabella, come nel Blocco note.
final class TablePickerGrid: NSView {
    var onInsert: ((Int, Int) -> Void)?
    var onHoverChanged: ((Int, Int) -> Void)?

    let theme: Theme
    private let maximum = 8
    private let cellSize: CGFloat = 22
    private let spacing: CGFloat = 3
    private var hoverRows = 3
    private var hoverColumns = 3
    private var hoverTracking: NSTrackingArea?

    init(theme: Theme) {
        self.theme = theme
        let side = CGFloat(maximum) * cellSize + CGFloat(maximum - 1) * spacing
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for row in 0..<maximum {
            for column in 0..<maximum {
                let rect = cellRect(row: row, column: column)
                let active = row < hoverRows && column < hoverColumns
                (active ? NSColor(theme.accent).withAlphaComponent(0.22)
                        : NSColor(theme.hover).withAlphaComponent(0.55)).setFill()
                let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
                path.fill()
                NSColor(theme.border).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    private func cellRect(row: Int, column: Int) -> NSRect {
        NSRect(x: CGFloat(column) * (cellSize + spacing),
               y: CGFloat(row) * (cellSize + spacing),
               width: cellSize,
               height: cellSize)
    }

    private func cell(at point: NSPoint) -> (row: Int, column: Int)? {
        let stride = cellSize + spacing
        let column = Int(floor(point.x / stride))
        let row = Int(floor(point.y / stride))
        guard row >= 0, row < maximum, column >= 0, column < maximum else { return nil }
        guard cellRect(row: row, column: column).contains(point) else { return nil }
        return (row, column)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
        }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let target = cell(at: point) {
            updateHover(rows: target.row + 1, columns: target.column + 1)
        }
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(rows: 3, columns: 3)
    }

    private func updateHover(rows: Int, columns: Int) {
        guard rows != hoverRows || columns != hoverColumns else { return }
        hoverRows = rows
        hoverColumns = columns
        onHoverChanged?(rows, columns)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let target = cell(at: point) else { return }
        onInsert?(target.row + 1, target.column + 1)
    }
}

/// Contenuto del popover del selettore tabelle. Include le azioni di
/// modifica quando il cursore si trova già dentro una tabella.
final class TablePickerViewController: NSViewController {
    var onInsert: ((Int, Int) -> Void)?
    var onCustomSize: (() -> Void)?
    var onAction: ((TableOverlayAction) -> Void)?

    private let theme: Theme
    private let inTable: Bool
    private let grid: TablePickerGrid
    private let sizeLabel = NSTextField(labelWithString: "3 × 3")

    init(theme: Theme, inTable: Bool) {
        self.theme = theme
        self.inTable = inTable
        self.grid = TablePickerGrid(theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let padding: CGFloat = 12
        let width = grid.frame.width + padding * 2
        var height = padding + grid.frame.height + 8 + 18

        let actions: [TableOverlayAction] = inTable
            ? [.addRowBefore, .addRowAfter, .addColumnBefore, .addColumnAfter,
               .deleteRow, .deleteColumn]
            : []
        if inTable {
            height += 10 + 1 + 10 + CGFloat(actions.count) * 27
        }
        height += 10 + 1 + 10 + 26 + padding

        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        self.view = view

        grid.frame.origin = NSPoint(x: padding, y: padding)
        grid.onInsert = { [weak self] rows, columns in
            self?.onInsert?(rows, columns)
        }
        grid.onHoverChanged = { [weak self] rows, columns in
            self?.sizeLabel.stringValue = L.t("\(rows) × \(columns) tabella",
                                             "\(rows) × \(columns) table")
        }
        view.addSubview(grid)

        sizeLabel.frame = NSRect(x: padding, y: padding + grid.frame.height + 8,
                                 width: grid.frame.width, height: 18)
        sizeLabel.font = FluentFont.nsUIFont(11.5)
        sizeLabel.textColor = NSColor(theme.secondaryText)
        sizeLabel.stringValue = L.t("3 × 3 tabella", "3 × 3 table")
        view.addSubview(sizeLabel)

        var y = padding + grid.frame.height + 8 + 18

        if !actions.isEmpty {
            y += 10
            addSeparator(at: y, width: width, padding: padding, to: view)
            y += 10
            for action in actions {
                let button = actionButton(title: action.title, action: action)
                button.frame = NSRect(x: padding, y: y, width: grid.frame.width, height: 26)
                view.addSubview(button)
                y += 27
            }
        }

        y += 10
        addSeparator(at: y, width: width, padding: padding, to: view)
        y += 10

        let customTitle = L.t("Inserisci tabella…", "Insert table…")
        let custom = NSButton(title: customTitle,
                              target: self,
                              action: #selector(customSizePressed(_:)))
        custom.isBordered = false
        custom.alignment = .left
        custom.attributedTitle = NSAttributedString(
            string: customTitle,
            attributes: [
                .font: FluentFont.nsUIFont(12),
                .foregroundColor: NSColor(theme.text)
            ]
        )
        custom.frame = NSRect(x: padding, y: y, width: grid.frame.width, height: 26)
        view.addSubview(custom)
    }

    private func addSeparator(at y: CGFloat, width: CGFloat, padding: CGFloat, to view: NSView) {
        let line = NSBox(frame: NSRect(x: padding, y: y, width: width - padding * 2, height: 1))
        line.boxType = .separator
        view.addSubview(line)
    }

    private func actionButton(title: String, action: TableOverlayAction) -> NSButton {
        let button = ClosureButton(title: title)
        button.isBordered = false
        button.alignment = .left
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: FluentFont.nsUIFont(12),
                .foregroundColor: NSColor(theme.text)
            ]
        )
        button.onClick = { [weak self] in
            self?.onAction?(action)
        }
        return button
    }

    @objc private func customSizePressed(_ sender: Any?) {
        onCustomSize?()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class ClosureButton: NSButton {
    var onClick: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(pressed(_:))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func pressed(_ sender: Any?) {
        onClick?()
    }
}

private extension TableOverlayAction {
    var title: String {
        switch self {
        case .insertTable: return L.t("Inserisci tabella…", "Insert table…")
        case .addRowBefore: return L.t("Inserisci riga sopra", "Insert row above")
        case .addRowAfter: return L.t("Inserisci riga sotto", "Insert row below")
        case .addColumnBefore: return L.t("Inserisci colonna a sinistra", "Insert column left")
        case .addColumnAfter: return L.t("Inserisci colonna a destra", "Insert column right")
        case .deleteRow: return L.t("Elimina riga", "Delete row")
        case .deleteColumn: return L.t("Elimina colonna", "Delete column")
        }
    }
}
