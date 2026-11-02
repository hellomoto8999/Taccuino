import AppKit
import Foundation

/// Test di base eseguibili con `Taccuino --selftest` (senza interfaccia).
enum SelfTest {
    static func run() -> Bool {
        var failures = 0

        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if condition() {
                print("✓ \(name)")
            } else {
                failures += 1
                print("✗ \(name)")
            }
        }

        // Codifiche e fine riga.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("taccuino-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let sample = "Ciao mondo\nSeconda riga àèìòù\n"
        let encodings: [TextEncoding] = [.utf8, .utf8BOM, .utf16LE, .utf16BE, .ansi]
        for encoding in encodings {
            let url = temp.appendingPathComponent("test-\(encoding.rawValue).txt")
            do {
                _ = try TextFile.write(sample, to: url, encoding: encoding, lineEnding: .crlf)
                let decoded = try TextFile.read(from: url)
                check(decoded.text == sample, "round-trip \(encoding.displayName)")
                check(decoded.encoding == encoding, "rilevamento \(encoding.displayName)")
                check(decoded.lineEnding == .crlf, "fine riga CRLF \(encoding.displayName)")
            } catch {
                check(false, "round-trip \(encoding.displayName): \(error)")
            }
        }

        let bomless = "Ciao senza BOM\nseconda riga\n"
        let bomlessURL = temp.appendingPathComponent("utf16-nobom.txt")
        if let raw = bomless.data(using: .utf16LittleEndian) {
            try? raw.write(to: bomlessURL)
            let decoded = try? TextFile.read(from: bomlessURL)
            check(decoded?.text == bomless, "UTF-16 senza BOM: testo")
            check(decoded?.encoding == .utf16LE, "UTF-16 senza BOM: rilevamento")
        } else {
            check(false, "UTF-16 senza BOM: creazione")
        }

        let lfURL = temp.appendingPathComponent("lf.txt")
        try? "uno\ndue\ntre\n".write(to: lfURL, atomically: true, encoding: .utf8)
        check((try? TextFile.read(from: lfURL))?.lineEnding == .lf, "rilevamento LF")

        // Riga e colonna.
        let text = "a\nbc\nd" as NSString
        check(WindowModel.lineColumn(in: text, location: 0) == (1, 1), "riga/colonna inizio")
        check(WindowModel.lineColumn(in: text, location: 3) == (2, 2), "riga/colonna centrale")
        check(WindowModel.lineColumn(in: text, location: 6) == (3, 2), "riga/colonna ultima")

        // Sessione serializzabile.
        let session = SessionFile(windows: [
            SessionWindow(x: 10, y: 20, width: 800, height: 600,
                          activeDocumentIndex: 0,
                          tabs: [SessionTab(path: nil, displayName: "Senza titolo", text: "abc",
                                            encoding: "utf8", lineEnding: "crlf",
                                            cursor: 3, scrollX: 0, scrollY: 0, modified: true)])
        ])
        if let data = try? JSONEncoder().encode(session),
           let decoded = try? JSONDecoder().decode(SessionFile.self, from: data) {
            check(decoded.windows.first?.tabs.first?.text == "abc", "serializzazione sessione")
        } else {
            check(false, "serializzazione sessione")
        }

        // Editor: inserimento, ricerca, sostituzione.
        let controller = WindowController(session: nil)
        guard let document = controller.model.documents.first else {
            print("✗ nessun documento")
            return false
        }
        controller.editor.setActive(document.id)
        if let textView = controller.editor.textView(for: document) {
            textView.insertText("Hello world hello HELLO", replacementRange: NSRange(location: 0, length: 0))
            check(document.text == "Hello world hello HELLO", "inserimento testo")
            check(document.isModified, "stato modificato")

            let insensitive = controller.editor.matchCount(query: "hello", in: document, matchCase: false, wholeWord: true)
            check(insensitive == 3, "conteggio senza maiuscole")
            let sensitive = controller.editor.matchCount(query: "hello", in: document, matchCase: true, wholeWord: true)
            check(sensitive == 1, "conteggio con maiuscole")

            _ = controller.editor.replaceAll(query: "hello", replacement: "ciao", in: document, matchCase: false, wholeWord: false)
            check(document.text == "ciao world ciao ciao", "sostituisci tutto")

            let time = DateTimeText.now()
            check(!time.isEmpty, "data e ora")

            let undoDocument = Document()
            controller.model.addDocument(undoDocument, select: true)
            controller.editor.setActive(undoDocument.id)
            if let undoView = controller.editor.textView(for: undoDocument) {
                undoView.insertText("abc", replacementRange: NSRange(location: 0, length: 0))
                check(undoDocument.text == "abc", "testo per annullamento")
                check(undoDocument.undoManager.canUndo, "annullamento disponibile")
                undoDocument.undoManager.undo()
                check(undoDocument.text == "", "annulla inserimento")
            }

            // Formattazione Markdown.
            let formatDoc = Document(text: "Titolo\n\nHello world\n")
            controller.model.addDocument(formatDoc, select: true)
            controller.editor.setActive(formatDoc.id)
            if let formatView = controller.editor.textView(for: formatDoc) {
                let formatNS = formatDoc.text as NSString
                formatView.setSelectedRange(formatNS.range(of: "Hello"))
                controller.editor.toggleBold()
                check(formatDoc.text.contains("**Hello**"), "grassetto Markdown")
                formatView.setSelectedRange((formatDoc.text as NSString).range(of: "world"))
                controller.editor.toggleItalic()
                check(formatDoc.text.contains("*world*"), "corsivo Markdown")
                formatView.setSelectedRange((formatDoc.text as NSString).range(of: "Titolo"))
                controller.editor.setHeadingLevel(1)
                check(formatDoc.text.hasPrefix("# Titolo"), "titolo Markdown")
                formatView.setSelectedRange((formatDoc.text as NSString).range(of: "world"))
                controller.editor.toggleList(.bullet)
                check(formatDoc.text.contains("- **Hello** *world*"), "elenco Markdown")
                controller.model.updateFormattingStateFromEditor()
                check(controller.model.formattingState.hasFormatting, "stato formattazione")
                formatView.setSelectedRange(NSRange(location: 0, length: (formatDoc.text as NSString).length))
                controller.editor.clearFormatting()
                check(formatDoc.text == "Titolo\n\nHello world\n", "cancella formattazione")
                formatView.setSelectedRange(NSRange(location: (formatDoc.text as NSString).length, length: 0))
                controller.editor.insertTable(rows: 2, columns: 2)
                let inserted = MarkdownFormatting.tables(in: formatDoc.text)
                check(inserted.count == 1 && inserted.first?.columnCount == 2,
                      "inserimento tabella")
                check(MarkdownFormatting.blockPrefix(in: "# Titolo")?.headingLevel == 1, "prefisso titolo")
                check(MarkdownFormatting.blockPrefix(in: "  - voce")?.listKind == .bullet, "prefisso elenco")
            }

            // Tabelle reali: parsing, modifica celle, righe e colonne.
            let tableDoc = Document(text: "| A | B |\n| --- | --- |\n| 1 | 2 |\n")
            controller.model.addDocument(tableDoc, select: true)
            controller.editor.setActive(tableDoc.id)
            controller.editor.refreshMarkdownRendering()

            var tables = MarkdownFormatting.tables(in: tableDoc.text)
            check(tables.count == 1, "tabella rilevata")
            check(tables.first?.rows == [["A", "B"], ["1", "2"]], "celle tabella")
            check(tables.first?.columnCount == 2, "colonne tabella")

            if let table = tables.first {
                controller.editor.updateTableCell(tableStart: table.blockRange.location,
                                                  row: 1, column: 1, text: "3")
                check(tableDoc.text.contains("| 1 | 3 |"), "modifica cella")
                controller.editor.focusTableCell(row: 1, column: 1, editing: false)
                controller.editor.addTableRow(before: false)
                check(MarkdownFormatting.tables(in: tableDoc.text).first?.rows.count == 3,
                      "aggiungi riga")
                controller.editor.focusTableCell(row: 1, column: 1, editing: false)
                controller.editor.addTableColumn(before: false)
                check(MarkdownFormatting.tables(in: tableDoc.text).first?.columnCount == 3,
                      "aggiungi colonna")
                controller.editor.focusTableCell(row: 1, column: 1, editing: false)
                controller.editor.deleteTableRow()
                check(MarkdownFormatting.tables(in: tableDoc.text).first?.rows.count == 2,
                      "elimina riga")
                controller.editor.focusTableCell(row: 1, column: 1, editing: false)
                controller.editor.deleteTableColumn()
                check(MarkdownFormatting.tables(in: tableDoc.text).first?.columnCount == 2,
                      "elimina colonna")
            }

            // Formattazione senza testo: niente marcatori vuoti.
            let emptyFormatDoc = Document(text: "")
            controller.model.addDocument(emptyFormatDoc, select: true)
            controller.editor.setActive(emptyFormatDoc.id)
            if let emptyView = controller.editor.textView(for: emptyFormatDoc) {
                emptyView.setSelectedRange(NSRange(location: 0, length: 0))
                controller.editor.toggleBold()
                check(emptyFormatDoc.text.isEmpty, "grassetto su documento vuoto")
            }

            let wordFormatDoc = Document(text: "hello world")
            controller.model.addDocument(wordFormatDoc, select: true)
            controller.editor.setActive(wordFormatDoc.id)
            if let wordView = controller.editor.textView(for: wordFormatDoc) {
                wordView.setSelectedRange(NSRange(location: 2, length: 0))
                controller.editor.toggleBold()
                check(wordFormatDoc.text == "**hello** world", "grassetto sulla parola")
                wordView.setSelectedRange(NSRange(location: 4, length: 0))
                controller.editor.toggleBold()
                check(wordFormatDoc.text == "hello world", "rimuove grassetto dalla parola")
                wordView.setSelectedRange(NSRange(location: 5, length: 0))
                controller.editor.toggleStrikethrough()
                check(wordFormatDoc.text == "~~hello~~ world", "barrato sulla parola")

                let spacesDoc = Document(text: "   ")
                controller.model.addDocument(spacesDoc, select: true)
                controller.editor.setActive(spacesDoc.id)
                if let spacesView = controller.editor.textView(for: spacesDoc) {
                    spacesView.setSelectedRange(NSRange(location: 1, length: 0))
                    controller.editor.toggleItalic()
                    check(spacesDoc.text == "   ", "corsivo su soli spazi")
                }
            }

            // Continuazione degli elenchi con Invio.
            let listDoc = Document(text: "- uno")
            controller.model.addDocument(listDoc, select: true)
            controller.editor.setActive(listDoc.id)
            if let listView = controller.editor.textView(for: listDoc) {
                listView.setSelectedRange(NSRange(location: 5, length: 0))
                listView.insertNewline(nil)
                check(listDoc.text == "- uno\n- ", "continua elenco puntato")
                listView.insertText("due", replacementRange: listView.selectedRange())
                listView.insertNewline(nil)
                check(listDoc.text == "- uno\n- due\n- ", "seconda voce elenco")
            }

            let numberedDoc = Document(text: "1. primo")
            controller.model.addDocument(numberedDoc, select: true)
            controller.editor.setActive(numberedDoc.id)
            if let numberedView = controller.editor.textView(for: numberedDoc) {
                numberedView.setSelectedRange(NSRange(location: 8, length: 0))
                numberedView.insertNewline(nil)
                check(numberedDoc.text == "1. primo\n2. ", "continua elenco numerato")
            }

            let emptyItemDoc = Document(text: "- ")
            controller.model.addDocument(emptyItemDoc, select: true)
            controller.editor.setActive(emptyItemDoc.id)
            if let emptyView = controller.editor.textView(for: emptyItemDoc) {
                emptyView.setSelectedRange(NSRange(location: 2, length: 0))
                emptyView.insertNewline(nil)
                check(emptyItemDoc.text == "\n", "esce dall'elenco su voce vuota")
            }

            if let copyTable = MarkdownFormatting.tables(
                in: "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
            ).first {
                let overlay = TableOverlayView(table: copyTable,
                                               index: 0,
                                               font: NSFont.systemFont(ofSize: 12),
                                               theme: Theme.make(dark: false))
                overlay.selectRange(anchor: TableCellTarget(row: 0, column: 0),
                                    focus: TableCellTarget(row: 1, column: 1))
                overlay.copy(nil)
                let copied = NSPasteboard.general.string(forType: .string) ?? ""
                check(copied == "A\tB\n1\t2", "copia intervallo celle")
            }

            let cellText = MarkdownFormatting.attributedCellText(
                "**Grassetto** e *corsivo*",
                font: NSFont.systemFont(ofSize: 12),
                color: .black
            )
            check(cellText.string == "Grassetto e corsivo", "testo cella senza marcatori")
            tables = MarkdownFormatting.tables(in: "| Solo |\n| --- |\n| uno |\n")
            check(tables.first?.columnCount == 1, "tabella a una colonna")
            let escapedCells = MarkdownFormatting.parseTableCells("| a \\| b | c |")
            check(escapedCells == ["a | b", "c"], "pipe escapata nelle celle")

            if let snapshot = controller.snapshot(),
               let data = try? JSONEncoder().encode(snapshot),
               let decoded = try? JSONDecoder().decode(SessionWindow.self, from: data) {
                let restored = WindowController(session: decoded)
                check(restored.model.documents.first?.text == "ciao world ciao ciao", "ripristino sessione con testo")
            } else {
                check(false, "snapshot sessione")
            }
        } else {
            check(false, "creazione editor")
        }

        print(failures == 0 ? "Tutti i test sono passati." : "\(failures) test falliti.")
        return failures == 0
    }
}
