import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private(set) var controllers: [WindowController] = []
    private(set) var isTerminating = false

    private let settings = SettingsStore.shared
    private var pendingOpenURLs: [URL] = []
    private var sessionWorkItem: DispatchWorkItem?
    private var keyMonitor: Any?
    private var didLaunch = false
    private var pendingLastWindowSnapshot: SessionWindow?
    private var recentMenu = NSMenu()
    private var hasRestored = false

    private var isDemoMode: Bool {
        ProcessInfo.processInfo.environment["TACCUINO_DEMO"] == "1"
    }

    // MARK: - Ciclo di vita

    func applicationWillFinishLaunching(_ notification: Notification) {
        settings.applyAppearance()
        buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installKeyMonitor()
        restoreSessionIfNeeded()
        didLaunch = true
        openPendingFiles()
        applyDemoStateIfNeeded()
        applyAutomationEnvironmentIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.activeController?.focusEditor()
        }
    }

    /// Apertura file e chiusura automatica usate dai test di integrazione.
    private func applyAutomationEnvironmentIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        if let path = env["TACCUINO_OPEN_FILE"] {
            activeController?.openURL(URL(fileURLWithPath: path))
        }
        if let reloadPath = env["TACCUINO_SNAPSHOT_RELOAD"],
           let content = try? String(contentsOfFile: reloadPath, encoding: .utf8) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let controller = self?.activeController,
                      let document = controller.model.activeDocument else { return }
                document.storage.mutableString.setString(content)
                if let textView = controller.editor.textView(for: document) {
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                    textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
                }
                controller.editor.refreshMarkdownRendering()
                controller.model.updateFormattingStateFromEditor()
            }
        }
        if env["TACCUINO_AUTOQUIT_EDIT"] == "1",
           let controller = activeController,
           let document = controller.model.activeDocument,
           let textView = controller.editor.textView(for: document) {
            textView.insertText("\nModifica non salvata, ripristinata dalla sessione.",
                                replacementRange: NSRange(location: document.storage.length, length: 0))
        }
        if let raw = env["TACCUINO_AUTOQUIT"], let delay = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.terminate(nil)
            }
        }
        if let raw = env["TACCUINO_AUTOCLOSE"], let delay = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.activeController?.window?.performClose(nil)
            }
        }
        if let raw = env["TACCUINO_AUTOCLOSE_TAB"], let delay = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.activeController?.model.closeActiveTab()
            }
        }
        if let controller = activeController {
            if env["TACCUINO_DEMO_SYNTAX"] == "1" {
                controller.model.showsMarkdownSource = true
                controller.editor.refreshMarkdownRendering()
            }
            if env["TACCUINO_DEMO_NO_TOOLBAR"] == "1" {
                settings.formattingToolbarVisible = false
            }
            if env["TACCUINO_DEMO_NO_FORMATTING"] == "1" {
                settings.formattingEnabled = false
            }
        }
        if let path = env["TACCUINO_DUMP_MENU"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                var lines: [String] = []
                for item in NSApp.mainMenu?.items ?? [] {
                    lines.append("MENU: \(item.title)")
                    for sub in item.submenu?.items ?? [] {
                        lines.append("  \(sub.title) | key=\(sub.keyEquivalent) | target=\(sub.target.map { String(describing: type(of: $0)) } ?? "-")")
                    }
                }
                try? lines.joined(separator: "\n").write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            }
        }
        if let path = env["TACCUINO_SNAPSHOT"] {
            let snapshotDelay = Double(env["TACCUINO_SNAPSHOT_DELAY"] ?? "") ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + snapshotDelay) { [weak self] in
                if let dumpPath = env["TACCUINO_DUMP_TEXT"], let self {
                    let controller = self.activeController
                    let text = controller?.editor.activeTextView?.string ?? "<nil>"
                    let info = "formatted=\(self.settings.formattingEnabled) source=\(controller?.model.showsMarkdownSource ?? false) picker=\(controller?.model.isTablePickerVisible ?? false) popup=\(controller?.model.popup != nil)\n\(text)"
                    try? info.write(to: URL(fileURLWithPath: dumpPath), atomically: true, encoding: .utf8)
                }
                guard let view = self?.activeController?.window?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    /// Stato dimostrativo per screenshot e verifica visiva (solo tramite variabili d'ambiente).
    private func applyDemoStateIfNeeded() {
        let env = ProcessInfo.processInfo.environment

        switch env["TACCUINO_APPEARANCE"] {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            break
        }

        guard env["TACCUINO_DEMO"] == "1", let controller = activeController else { return }

        let sample: String
        let firstPath: String
        let secondPath: String
        let thirdPath: String
        let thirdText: String
        if L.isItalian {
            sample = """
            # Taccuino

            Un editor di testo **essenziale**, con l'aspetto del _Blocco note di Windows 11_.

            • Schede multiple, ripristino della sessione e contenuti non salvati
            • A capo automatico, zoom e barra di stato
            • Codifiche **UTF-8**, **UTF-16** e **ANSI**, fine riga CRLF, LF e CR
            • Trova e sostituisci, controllo ortografico, stampa

            ## Scorciatoie principali

            Ctrl+N nuova finestra      Ctrl+T nuova scheda
            Ctrl+O apri                Ctrl+S salva
            Ctrl+Shift+S salva come    Ctrl+P stampa
            Ctrl+F trova               Ctrl+H sostituisci
            F5 inserisci data e ora    Ctrl+rotella zoom

            Il veloce zaino blu salta sopra il cane pigro.
            """
            firstPath = "/tmp/benvenuto.txt"
            secondPath = "/tmp/appunti.md"
            thirdPath = "/tmp/taccuino.log"
            thirdText = "2026-10-23 12:00  Avvio di Taccuino\n"
        } else {
            sample = """
            # Taccuino

            An **essential** text editor with the look of _Windows 11 Notepad_.

            • Multiple tabs, session restore and unsaved content
            • Word wrap, zoom and status bar
            • **UTF-8**, **UTF-16** and **ANSI** encodings, CRLF, LF and CR line endings
            • Find and replace, spell check, printing

            ## Main shortcuts

            Ctrl+N new window      Ctrl+T new tab
            Ctrl+O open            Ctrl+S save
            Ctrl+Shift+S save as   Ctrl+P print
            Ctrl+F find            Ctrl+H replace
            F5 insert time/date    Ctrl+wheel zoom

            The quick brown fox jumps over the lazy dog.
            """
            firstPath = "/tmp/welcome.txt"
            secondPath = "/tmp/notes.md"
            thirdPath = "/tmp/taccuino.log"
            thirdText = "2026-10-23 12:00  Taccuino started\n"
        }

        var secondText = sample.replacingOccurrences(
            of: "Taccuino\n",
            with: L.t("Appunti\n", "Notes\n")
        )
        if env["TACCUINO_DEMO_LONG"] == "1" {
            secondText += "\n" + String(repeating: "0123456789 · long line for testing ", count: 8)
        }
        let first = Document(text: sample, fileURL: URL(fileURLWithPath: firstPath))
        let second = Document(text: secondText,
                              fileURL: URL(fileURLWithPath: secondPath))
        let third = Document(text: thirdText,
                             fileURL: URL(fileURLWithPath: thirdPath))
        controller.model.addDocument(first, select: true, replacingEmpty: true)
        controller.model.addDocument(second, select: false)
        controller.model.addDocument(third, select: false)
        controller.model.selectDocument(second.id)
        controller.editor.setActive(second.id)
        controller.editor.applySettings()

        if env["TACCUINO_DEMO_SETTINGS"] == "1" {
            controller.model.selectSettings()
        }

        if env["TACCUINO_DEMO_SCROLLRIGHT"] == "1", let tv = controller.editor.textView(for: second) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let scroll = tv.enclosingScrollView {
                    let maxX = max(0, tv.frame.width - scroll.contentSize.width)
                    scroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }

        if env["TACCUINO_DEMO_SELECT"] == "1", let tv = controller.editor.textView(for: second) {
            let ns = second.text as NSString
            let range = ns.range(of: "essenziale")
            if range.location != NSNotFound {
                tv.setSelectedRange(range)
                controller.window?.makeFirstResponder(tv)
                let (line, column) = WindowModel.lineColumn(in: ns, location: range.location)
                controller.model.editorSelectionChanged(second, line: line, column: column)
            }
        }

        if env["TACCUINO_DEMO_TABMENU"] == "1" {
            let doc = controller.model.activeDocument ?? second
            controller.model.openTabMenu(doc, at: CGPoint(x: 470, y: 52))
        }

        if env["TACCUINO_DEMO_FIND"] == "1" {
            controller.model.find.query = L.t("schede", "tabs")
            controller.model.find.replacement = L.t("linguette", "tab")
            controller.model.showFind(replace: true)
            controller.model.refreshFindCount()
        }

        if env["TACCUINO_DEMO_CLEAN"] == "1", let tv = controller.editor.textView(for: second) {
            tv.isEditable = false
            tv.isContinuousSpellCheckingEnabled = false
        }

        if let reloadPath = env["TACCUINO_DEMO_RELOAD_FILE"],
           let content = try? String(contentsOfFile: reloadPath, encoding: .utf8) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard let controller = self.activeController,
                      let document = controller.model.activeDocument else { return }
                document.storage.mutableString.setString(content)
                if let textView = controller.editor.textView(for: document) {
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                    textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
                }
                controller.editor.refreshMarkdownRendering()
                controller.model.updateFormattingStateFromEditor()
            }
        }

        if let text = env["TACCUINO_DEMO_TABLE_COMMIT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let source = controller.editor.activeTextView?.string,
                      let table = MarkdownFormatting.tables(in: source).first else { return }
                controller.editor.updateTableCell(tableStart: table.blockRange.location,
                                                  row: 1, column: 1, text: text)
            }
        }

        if env["TACCUINO_DEMO_TABLE_EDIT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                controller.editor.focusTableCell(row: 1, column: 1, editing: true)
            }
        }

        if let typed = env["TACCUINO_DEMO_TABLE_TYPE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                controller.editor.focusTableCell(row: 1, column: 1, editing: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let fieldEditor = controller.window?.firstResponder as? NSTextView {
                        fieldEditor.selectAll(nil)
                        fieldEditor.insertText(typed,
                                               replacementRange: fieldEditor.selectedRange())
                    }
                    if let textView = controller.editor.activeTextView {
                        controller.window?.makeFirstResponder(textView)
                    }
                }
            }
        }

        if env["TACCUINO_DEMO_LIST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                guard let textView = controller.editor.activeTextView else { return }
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length,
                                                  length: 0))
                textView.insertNewline(nil)
            }
        }

        if env["TACCUINO_DEMO_TABLE_INSERT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                controller.model.insertTableFromPicker(rows: 3, columns: 3)
            }
        }

        if env["TACCUINO_DEMO_TABLE_PASTE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("Pasted A\tPasted B\nPasted C\tPasted D", forType: .string)
                controller.editor.selectTableRange(row: 1, column: 0,
                                                   toRow: 1, toColumn: 1)
                controller.editor.focusActiveTableOverlay()
                controller.editor.pasteIntoTableSelection()
            }
        }

        if env["TACCUINO_DEMO_TABLE_DELETE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                controller.editor.selectTableRange(row: 1, column: 0,
                                                   toRow: 2, toColumn: 1)
                controller.editor.focusActiveTableOverlay()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard let window = controller.window else { return }
                    let event = NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        characters: "\u{7F}",
                        charactersIgnoringModifiers: "\u{7F}",
                        isARepeat: false,
                        keyCode: 51
                    )
                    if let event { window.sendEvent(event) }
                }
            }
        }

        if env["TACCUINO_DEMO_TABLE_RANGE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                controller.editor.selectTableRange(row: 0, column: 0,
                                                   toRow: 2, toColumn: 2)
            }
        }

        if env["TACCUINO_DEMO_TABLE_PICKER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                controller.model.showTablePicker(at: CGPoint(x: 452, y: 118))
            }
        }

        if env["TACCUINO_DEMO_TABLE_PICKER_SELECT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                controller.editor.focusTableCell(row: 1, column: 1, editing: false)
                controller.model.showTablePicker(at: CGPoint(x: 452, y: 118))
            }
        }

        if env["TACCUINO_DEMO_TABLE_SELECT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                controller.editor.focusTableCell(row: 1, column: 1, editing: false)
            }
        }

        if let rawSize = env["TACCUINO_DEMO_SIZE"] {
            let parts = rawSize.lowercased().split(separator: "x")
            if parts.count == 2,
               let width = Double(parts[0]),
               let height = Double(parts[1]) {
                controller.window?.setContentSize(NSSize(width: width, height: height))
            }
        }

        if env["TACCUINO_DEMO_SAVEPANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                controller.model.saveActive(saveAs: true)
            }
        }

        controller.window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionWorkItem?.cancel()
        for controller in controllers {
            controller.flushAutosaves()
        }
        if !isTerminating {
            saveSessionNow()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        for controller in controllers {
            controller.flushAutosaves()
        }
        scheduleSessionSave()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !settings.restoreSession {
            for controller in controllers {
                for document in controller.model.documents where document.isModified {
                    if !controller.confirmClose(document) {
                        return .terminateCancel
                    }
                }
            }
        }
        isTerminating = true
        sessionWorkItem?.cancel()
        saveSessionNow()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            newWindow()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if didLaunch {
            for url in urls {
                openInActiveWindow(url)
            }
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
    }

    private func openPendingFiles() {
        guard !pendingOpenURLs.isEmpty else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        for url in urls {
            openInActiveWindow(url)
        }
    }

    private func openInActiveWindow(_ url: URL) {
        if let controller = activeController {
            controller.openURL(url)
        } else {
            let controller = newWindow()
            controller.openURL(url)
        }
    }

    // MARK: - Finestre

    @discardableResult
    func newWindow() -> WindowController {
        pendingLastWindowSnapshot = nil
        let controller = WindowController(session: nil, cascadeIndex: controllers.count)
        register(controller)
        controller.showWindow(nil)
        return controller
    }

    func register(_ controller: WindowController) {
        controllers.append(controller)
    }

    func unregister(_ controller: WindowController) {
        controllers.removeAll { $0 === controller }
        if pendingLastWindowSnapshot != nil {
            sessionWorkItem?.cancel()
            saveSessionNow()
        } else {
            scheduleSessionSave()
        }
    }

    /// Cattura lo stato dell'ultima finestra prima che venga distrutta.
    func windowWillClose(_ controller: WindowController) {
        guard !isTerminating, !isDemoMode, settings.restoreSession else { return }
        guard controllers.count == 1, controllers.first === controller else { return }
        pendingLastWindowSnapshot = controller.snapshot()
    }

    var activeController: WindowController? {
        if let key = NSApp.keyWindow?.windowController as? WindowController {
            return key
        }
        if let main = NSApp.mainWindow?.windowController as? WindowController {
            return main
        }
        return controllers.last
    }

    // MARK: - Sessione

    private func restoreSessionIfNeeded() {
        guard !hasRestored else { return }
        hasRestored = true
        pendingLastWindowSnapshot = nil

        if isDemoMode {
            newWindow()
            return
        }

        if settings.restoreSession, let session = SessionStore.load(), !session.windows.isEmpty {
            for windowSession in session.windows {
                let controller = WindowController(session: windowSession)
                register(controller)
                controller.showWindow(nil)
            }
            if controllers.isEmpty {
                newWindow()
            } else {
                controllers.first?.window?.makeKeyAndOrderFront(nil)
            }
        } else {
            newWindow()
        }
    }

    func scheduleSessionSave() {
        guard didLaunch, !isTerminating, !isDemoMode else { return }
        sessionWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveSession()
        }
        sessionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func currentSessionFile() -> SessionFile? {
        let snapshots = controllers.compactMap { $0.snapshot() }
        if !snapshots.isEmpty {
            return SessionFile(windows: snapshots)
        }
        if let pendingLastWindowSnapshot {
            return SessionFile(windows: [pendingLastWindowSnapshot])
        }
        return nil
    }

    private func saveSession() {
        guard !isDemoMode else { return }
        if let session = currentSessionFile() {
            SessionStore.save(session)
        } else {
            SessionStore.clear()
        }
    }

    func saveSessionNow() {
        guard !isDemoMode else { return }
        if let session = currentSessionFile() {
            SessionStore.saveSynchronously(session)
        } else {
            SessionStore.clear()
        }
    }

    // MARK: - Comandi

    @objc private func menuNewTab(_ sender: Any?) {
        activeController?.model.newTab()
    }

    @objc private func menuNewWindow(_ sender: Any?) {
        newWindow()
    }

    @objc private func menuOpen(_ sender: Any?) {
        if let controller = activeController {
            controller.openFilePanel()
        } else {
            newWindow().openFilePanel()
        }
    }

    @objc private func menuSave(_ sender: Any?) {
        activeController?.model.saveActive(saveAs: false)
    }

    @objc private func menuSaveAs(_ sender: Any?) {
        activeController?.model.saveActive(saveAs: true)
    }

    @objc private func menuPageSetup(_ sender: Any?) {
        activeController?.pageSetup()
    }

    @objc private func menuPrint(_ sender: Any?) {
        activeController?.printDocument()
    }

    @objc private func menuCloseTab(_ sender: Any?) {
        activeController?.model.closeActiveTab()
    }

    @objc private func menuCloseWindow(_ sender: Any?) {
        activeController?.closeWindow()
    }

    @objc private func menuUndo(_ sender: Any?) {
        guard let controller = activeController else { return }
        if let field = fieldEditor(in: controller) {
            field.undoManager?.undo()
        } else {
            controller.model.undo()
        }
    }

    @objc private func menuRedo(_ sender: Any?) {
        guard let controller = activeController else { return }
        if let field = fieldEditor(in: controller) {
            field.undoManager?.redo()
        } else {
            controller.model.redo()
        }
    }

    private func fieldEditor(in controller: WindowController) -> NSTextView? {
        guard let responder = controller.window?.firstResponder else { return nil }
        guard let textView = responder as? NSTextView, !(textView is EditorTextView) else { return nil }
        return textView
    }

    @objc private func menuFind(_ sender: Any?) {
        activeController?.model.showFind(replace: false)
    }

    @objc private func menuFindNext(_ sender: Any?) {
        activeController?.model.findNext()
    }

    @objc private func menuFindPrevious(_ sender: Any?) {
        activeController?.model.findPrevious()
    }

    @objc private func menuReplace(_ sender: Any?) {
        activeController?.model.showFind(replace: true)
    }

    @objc private func menuTimeDate(_ sender: Any?) {
        activeController?.model.insertTimeDate()
    }

    @objc private func menuZoomIn(_ sender: Any?) {
        activeController?.model.zoomIn()
    }

    @objc private func menuZoomOut(_ sender: Any?) {
        activeController?.model.zoomOut()
    }

    @objc private func menuZoomReset(_ sender: Any?) {
        activeController?.model.zoomReset()
    }

    @objc private func menuWordWrap(_ sender: Any?) {
        activeController?.model.toggleWordWrap()
    }

    @objc private func menuStatusBar(_ sender: Any?) {
        activeController?.model.toggleStatusBar()
    }

    @objc private func menuSettings(_ sender: Any?) {
        activeController?.model.showSettings()
    }

    @objc private func openRecent(_ sender: Any?) {
        guard let path = (sender as? NSMenuItem)?.representedObject as? String else { return }
        openInActiveWindow(URL(fileURLWithPath: path))
    }

    // MARK: - Formattazione

    @objc private func menuToggleSpellCheck(_ sender: Any?) {
        settings.spellCheck.toggle()
        activeController?.editor.applySettings()
    }

    @objc private func menuToggleAutocorrect(_ sender: Any?) {
        settings.autocorrect.toggle()
        activeController?.editor.applySettings()
    }

    @objc private func menuToggleBold(_ sender: Any?) { activeController?.model.toggleBold() }
    @objc private func menuToggleItalic(_ sender: Any?) { activeController?.model.toggleItalic() }
    @objc private func menuToggleStrike(_ sender: Any?) { activeController?.model.toggleStrikethrough() }
    @objc private func menuHeadingNormal(_ sender: Any?) { activeController?.model.setHeadingLevel(0) }
    @objc private func menuHeading1(_ sender: Any?) { activeController?.model.setHeadingLevel(1) }
    @objc private func menuHeading2(_ sender: Any?) { activeController?.model.setHeadingLevel(2) }
    @objc private func menuHeading3(_ sender: Any?) { activeController?.model.setHeadingLevel(3) }
    @objc private func menuBulletList(_ sender: Any?) { activeController?.model.toggleList(.bullet) }
    @objc private func menuNumberedList(_ sender: Any?) { activeController?.model.toggleList(.numbered) }
    @objc private func menuIndentList(_ sender: Any?) { activeController?.model.indentList(outdent: false) }
    @objc private func menuOutdentList(_ sender: Any?) { activeController?.model.indentList(outdent: true) }
    @objc private func menuInsertLink(_ sender: Any?) { activeController?.model.insertLink() }
    @objc private func menuInsertTable(_ sender: Any?) { activeController?.model.showInsertTableDialog() }
    @objc private func menuAddTableRowAbove(_ sender: Any?) {
        activeController?.model.addTableRow(before: true)
    }
    @objc private func menuAddTableRowBelow(_ sender: Any?) {
        activeController?.model.addTableRow(before: false)
    }
    @objc private func menuAddTableColumnBefore(_ sender: Any?) {
        activeController?.model.addTableColumn(before: true)
    }
    @objc private func menuAddTableColumnAfter(_ sender: Any?) {
        activeController?.model.addTableColumn(before: false)
    }
    @objc private func menuDeleteTableRow(_ sender: Any?) { activeController?.model.deleteTableRow() }
    @objc private func menuDeleteTableColumn(_ sender: Any?) { activeController?.model.deleteTableColumn() }
    @objc private func menuClearFormatting(_ sender: Any?) { activeController?.model.clearFormatting() }
    @objc private func menuToggleMarkdownView(_ sender: Any?) { activeController?.model.toggleMarkdownSource() }
    @objc private func menuToggleFormattingEnabled(_ sender: Any?) {
        settings.formattingEnabled.toggle()
        activeController?.editor.refreshMarkdownRendering()
    }

    @objc private func menuToggleFormattingToolbar(_ sender: Any?) {
        settings.formattingToolbarVisible.toggle()
    }

    // MARK: - Menu principale macOS

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: L.appName)
        appItem.submenu = appMenu

        addItem(appMenu,
                L.t("Informazioni su Taccuino", "About Taccuino"),
                #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                key: "",
                target: NSApp)
        appMenu.addItem(.separator())
        addItem(appMenu,
                L.t("Impostazioni…", "Settings…"),
                #selector(menuSettings(_:)),
                key: ",")
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: L.t("Servizi", "Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: L.t("Servizi", "Services"))
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())

        addItem(appMenu,
                L.t("Nascondi Taccuino", "Hide Taccuino"),
                #selector(NSApplication.hide(_:)),
                key: "h",
                target: NSApp)
        addItem(appMenu,
                L.t("Nascondi altre", "Hide Others"),
                #selector(NSApplication.hideOtherApplications(_:)),
                key: "h",
                modifiers: [.command, .option],
                target: NSApp)
        addItem(appMenu,
                L.t("Mostra tutto", "Show All"),
                #selector(NSApplication.unhideAllApplications(_:)),
                key: "",
                target: NSApp)
        appMenu.addItem(.separator())
        addItem(appMenu,
                L.t("Esci da Taccuino", "Quit Taccuino"),
                #selector(NSApplication.terminate(_:)),
                key: "q",
                target: NSApp)

        // File
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: L.t("File", "File"))
        fileMenuItem.submenu = fileMenu

        addItem(fileMenu, L.t("Nuova scheda", "New tab"), #selector(menuNewTab(_:)), key: "t")
        addItem(fileMenu, L.t("Nuova finestra", "New window"), #selector(menuNewWindow(_:)), key: "n")
        addItem(fileMenu, L.t("Apri…", "Open…"), #selector(menuOpen(_:)), key: "o")
        fileMenu.addItem(.separator())
        addItem(fileMenu, L.t("Salva", "Save"), #selector(menuSave(_:)), key: "s")
        addItem(fileMenu, L.t("Salva con nome…", "Save as…"), #selector(menuSaveAs(_:)), key: "s", modifiers: [.command, .shift])

        let recentItem = NSMenuItem(title: L.t("Recenti", "Recent"), action: nil, keyEquivalent: "")
        recentMenu = NSMenu(title: L.t("Recenti", "Recent"))
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)

        fileMenu.addItem(.separator())
        addItem(fileMenu, L.t("Imposta pagina…", "Page setup…"), #selector(menuPageSetup(_:)), key: "")
        addItem(fileMenu, L.t("Stampa…", "Print…"), #selector(menuPrint(_:)), key: "p")
        fileMenu.addItem(.separator())
        addItem(fileMenu, L.t("Chiudi scheda", "Close tab"), #selector(menuCloseTab(_:)), key: "w")
        addItem(fileMenu,
                L.t("Chiudi finestra", "Close window"),
                #selector(menuCloseWindow(_:)),
                key: "w",
                modifiers: [.command, .shift])

        // Modifica
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: L.t("Modifica", "Edit"))
        editMenuItem.submenu = editMenu

        addItem(editMenu, L.t("Annulla", "Undo"), #selector(menuUndo(_:)), key: "z")
        addItem(editMenu, L.t("Ripeti", "Redo"), #selector(menuRedo(_:)), key: "z", modifiers: [.command, .shift])
        editMenu.addItem(.separator())
        let cut = addItem(editMenu, L.t("Taglia", "Cut"), #selector(NSText.cut(_:)), key: "x"); cut.target = nil
        let copy = addItem(editMenu, L.t("Copia", "Copy"), #selector(NSText.copy(_:)), key: "c"); copy.target = nil
        let paste = addItem(editMenu, L.t("Incolla", "Paste"), #selector(NSText.paste(_:)), key: "v"); paste.target = nil
        let delete = addItem(editMenu, L.t("Elimina", "Delete"), #selector(NSText.delete(_:)), key: ""); delete.target = nil
        let selectAll = addItem(editMenu, L.t("Seleziona tutto", "Select all"), #selector(NSText.selectAll(_:)), key: "a"); selectAll.target = nil
        editMenu.addItem(.separator())
        addItem(editMenu, L.t("Trova…", "Find…"), #selector(menuFind(_:)), key: "f")
        addItem(editMenu, L.t("Trova successivo", "Find next"), #selector(menuFindNext(_:)), key: "g")
        addItem(editMenu,
                L.t("Trova precedente", "Find previous"),
                #selector(menuFindPrevious(_:)),
                key: "g",
                modifiers: [.command, .shift])
        addItem(editMenu,
                L.t("Sostituisci…", "Replace…"),
                #selector(menuReplace(_:)),
                key: "f",
                modifiers: [.command, .option])
        editMenu.addItem(.separator())
        addItem(editMenu, L.t("Ora/data", "Time/date"), #selector(menuTimeDate(_:)), key: "\u{F708}", modifiers: [])
        editMenu.addItem(.separator())
        addItem(editMenu, L.t("Cancella formattazione", "Clear formatting"),
                #selector(menuClearFormatting(_:)), key: "")
        editMenu.addItem(.separator())
        let spellingItem = NSMenuItem(title: L.t("Ortografia", "Spelling"), action: nil, keyEquivalent: "")
        let spellingMenu = NSMenu(title: L.t("Ortografia", "Spelling"))
        addItem(spellingMenu, L.t("Controllo ortografico", "Check spelling"),
                #selector(menuToggleSpellCheck(_:)), key: "")
        addItem(spellingMenu, L.t("Correzione automatica", "Autocorrect"),
                #selector(menuToggleAutocorrect(_:)), key: "")
        spellingItem.submenu = spellingMenu
        editMenu.addItem(spellingItem)

        // Visualizza
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: L.t("Visualizza", "View"))
        viewMenuItem.submenu = viewMenu

        addItem(viewMenu, L.t("Zoom avanti", "Zoom in"), #selector(menuZoomIn(_:)), key: "=")
        addItem(viewMenu, L.t("Zoom indietro", "Zoom out"), #selector(menuZoomOut(_:)), key: "-")
        addItem(viewMenu, L.t("Ripristina zoom", "Restore default zoom"), #selector(menuZoomReset(_:)), key: "0")
        viewMenu.addItem(.separator())
        addItem(viewMenu, L.t("Testo a capo", "Word wrap"), #selector(menuWordWrap(_:)), key: "")
        addItem(viewMenu, L.t("Barra di stato", "Status bar"), #selector(menuStatusBar(_:)), key: "")
        addItem(viewMenu, L.t("Visualizza Markdown", "Show Markdown"), #selector(menuToggleMarkdownView(_:)), key: "")
        addItem(viewMenu, L.t("Abilita formattazione", "Enable formatting"),
                #selector(menuToggleFormattingEnabled(_:)), key: "")
        addItem(viewMenu, L.t("Mostra barra formattazione", "Show formatting toolbar"),
                #selector(menuToggleFormattingToolbar(_:)), key: "")

        // Formato
        let formatMenuItem = NSMenuItem()
        mainMenu.addItem(formatMenuItem)
        let formatMenu = NSMenu(title: L.t("Formato", "Format"))
        formatMenuItem.submenu = formatMenu

        addItem(formatMenu, L.t("Grassetto", "Bold"), #selector(menuToggleBold(_:)), key: "b")
        addItem(formatMenu, L.t("Corsivo", "Italic"), #selector(menuToggleItalic(_:)), key: "i")
        addItem(formatMenu, L.t("Barrato", "Strikethrough"), #selector(menuToggleStrike(_:)),
                key: "x", modifiers: [.command, .shift])
        formatMenu.addItem(.separator())

        let headingItem = NSMenuItem(title: L.t("Intestazione", "Heading"), action: nil, keyEquivalent: "")
        let headingMenu = NSMenu(title: L.t("Intestazione", "Heading"))
        addItem(headingMenu, L.t("Testo normale", "Normal text"), #selector(menuHeadingNormal(_:)),
                key: "0", modifiers: [.command, .option])
        addItem(headingMenu, L.t("Titolo 1", "Heading 1"), #selector(menuHeading1(_:)),
                key: "1", modifiers: [.command, .option])
        addItem(headingMenu, L.t("Titolo 2", "Heading 2"), #selector(menuHeading2(_:)),
                key: "2", modifiers: [.command, .option])
        addItem(headingMenu, L.t("Titolo 3", "Heading 3"), #selector(menuHeading3(_:)),
                key: "3", modifiers: [.command, .option])
        headingItem.submenu = headingMenu
        formatMenu.addItem(headingItem)

        let listItem = NSMenuItem(title: L.t("Elenco", "List"), action: nil, keyEquivalent: "")
        let listMenu = NSMenu(title: L.t("Elenco", "List"))
        addItem(listMenu, L.t("Elenco puntato", "Bulleted list"), #selector(menuBulletList(_:)),
                key: "8", modifiers: [.command, .shift])
        addItem(listMenu, L.t("Elenco numerato", "Numbered list"), #selector(menuNumberedList(_:)),
                key: "7", modifiers: [.command, .shift])
        listMenu.addItem(.separator())
        addItem(listMenu, L.t("Aumenta rientro", "Increase indent"), #selector(menuIndentList(_:)),
                key: "]", modifiers: [.command])
        addItem(listMenu, L.t("Riduci rientro", "Decrease indent"), #selector(menuOutdentList(_:)),
                key: "[", modifiers: [.command])
        listItem.submenu = listMenu
        formatMenu.addItem(listItem)

        addItem(formatMenu, L.t("Link…", "Link…"), #selector(menuInsertLink(_:)), key: "k")

        let tableItem = NSMenuItem(title: L.t("Tabella", "Table"), action: nil, keyEquivalent: "")
        let tableMenu = NSMenu(title: L.t("Tabella", "Table"))
        addItem(tableMenu, L.t("Inserisci tabella…", "Insert table…"), #selector(menuInsertTable(_:)), key: "")
        tableMenu.addItem(.separator())
        addItem(tableMenu, L.t("Inserisci riga sopra", "Insert row above"), #selector(menuAddTableRowAbove(_:)), key: "")
        addItem(tableMenu, L.t("Inserisci riga sotto", "Insert row below"), #selector(menuAddTableRowBelow(_:)), key: "")
        addItem(tableMenu, L.t("Inserisci colonna a sinistra", "Insert column left"), #selector(menuAddTableColumnBefore(_:)), key: "")
        addItem(tableMenu, L.t("Inserisci colonna a destra", "Insert column right"), #selector(menuAddTableColumnAfter(_:)), key: "")
        tableMenu.addItem(.separator())
        addItem(tableMenu, L.t("Elimina riga", "Delete row"), #selector(menuDeleteTableRow(_:)), key: "")
        addItem(tableMenu, L.t("Elimina colonna", "Delete column"), #selector(menuDeleteTableColumn(_:)), key: "")
        tableItem.submenu = tableMenu
        formatMenu.addItem(tableItem)

        formatMenu.addItem(.separator())
        addItem(formatMenu, L.t("Cancella formattazione", "Clear formatting"),
                #selector(menuClearFormatting(_:)), key: "")
        formatMenu.addItem(.separator())
        addItem(formatMenu, L.t("Visualizza Markdown", "Show Markdown"), #selector(menuToggleMarkdownView(_:)),
                key: "m", modifiers: [.command, .shift])
        addItem(formatMenu, L.t("Abilita formattazione", "Enable formatting"),
                #selector(menuToggleFormattingEnabled(_:)), key: "")
        addItem(formatMenu, L.t("Mostra barra formattazione", "Show formatting toolbar"),
                #selector(menuToggleFormattingToolbar(_:)), key: "t", modifiers: [.command, .option])

        // Finestra
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: L.t("Finestra", "Window"))
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let minimize = addItem(windowMenu, L.t("Riduci a icona", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), key: "m"); minimize.target = nil
        let zoom = addItem(windowMenu, L.t("Zoom", "Zoom"), #selector(NSWindow.performZoom(_:)), key: ""); zoom.target = nil
        let fullScreen = addItem(windowMenu,
                                 L.t("Schermo intero", "Enter full screen"),
                                 #selector(NSWindow.toggleFullScreen(_:)),
                                 key: "f",
                                 modifiers: [.command, .control])
        fullScreen.target = nil
        windowMenu.addItem(.separator())
        addItem(windowMenu, L.t("Porta tutto in primo piano", "Bring all to front"),
                #selector(NSApplication.arrangeInFront(_:)), key: "", target: NSApp)
    }

    @discardableResult
    private func addItem(_ menu: NSMenu,
                         _ title: String,
                         _ action: Selector?,
                         key: String,
                         modifiers: NSEvent.ModifierFlags = [.command],
                         target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        item.target = target ?? self
        menu.addItem(item)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let paths = settings.recentFiles
        if paths.isEmpty {
            let empty = NSMenuItem(title: L.t("Nessun file recente", "No recent files"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for path in paths {
            let item = NSMenuItem(title: (path as NSString).lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.isEnabled = FileManager.default.fileExists(atPath: path)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L.t("Svuota elenco", "Clear list"), action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func clearRecent(_ sender: Any?) {
        settings.clearRecent()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let controller = activeController else {
            switch menuItem.action {
            case #selector(menuNewWindow(_:)), #selector(menuOpen(_:)): return true
            default: return false
            }
        }
        let hasDocument = controller.model.activeDocument != nil
        switch menuItem.action {
        case #selector(menuSave(_:)),
             #selector(menuSaveAs(_:)),
             #selector(menuPageSetup(_:)),
             #selector(menuPrint(_:)),
             #selector(menuFind(_:)),
             #selector(menuFindNext(_:)),
             #selector(menuFindPrevious(_:)),
             #selector(menuReplace(_:)),
             #selector(menuTimeDate(_:)),
             #selector(menuZoomIn(_:)),
             #selector(menuZoomOut(_:)),
             #selector(menuZoomReset(_:)),
             #selector(menuWordWrap(_:)),
             #selector(menuStatusBar(_:)):
            return hasDocument
        case #selector(menuUndo(_:)):
            if let field = fieldEditor(in: controller) {
                return field.undoManager?.canUndo ?? false
            }
            return controller.model.activeDocument?.undoManager.canUndo ?? false
        case #selector(menuRedo(_:)):
            if let field = fieldEditor(in: controller) {
                return field.undoManager?.canRedo ?? false
            }
            return controller.model.activeDocument?.undoManager.canRedo ?? false
        case #selector(menuCloseTab(_:)):
            return controller.model.tabCount > 0
        case #selector(menuToggleBold(_:)):
            let available = inlineFormattingMenuAvailable(controller)
            menuItem.state = available && controller.model.formattingState.bold ? .on : .off
            return available
        case #selector(menuToggleItalic(_:)):
            let available = inlineFormattingMenuAvailable(controller)
            menuItem.state = available && controller.model.formattingState.italic ? .on : .off
            return available
        case #selector(menuToggleStrike(_:)):
            let available = inlineFormattingMenuAvailable(controller)
            menuItem.state = available && controller.model.formattingState.strike ? .on : .off
            return available
        case #selector(menuHeadingNormal(_:)),
             #selector(menuHeading1(_:)),
             #selector(menuHeading2(_:)),
             #selector(menuHeading3(_:)):
            let level: Int
            switch menuItem.action {
            case #selector(menuHeading1(_:)): level = 1
            case #selector(menuHeading2(_:)): level = 2
            case #selector(menuHeading3(_:)): level = 3
            default: level = 0
            }
            let available = textFormattingMenuAvailable(controller)
            menuItem.state = available && controller.model.formattingState.headingLevel == level ? .on : .off
            return available
        case #selector(menuBulletList(_:)):
            let available = textFormattingMenuAvailable(controller)
            menuItem.state = available && controller.model.formattingState.listKind == .bullet ? .on : .off
            return available
        case #selector(menuNumberedList(_:)):
            let available = textFormattingMenuAvailable(controller)
            menuItem.state = available && controller.model.formattingState.listKind == .numbered ? .on : .off
            return available
        case #selector(menuIndentList(_:)):
            return textFormattingMenuAvailable(controller) && controller.model.formattingState.listKind != nil
        case #selector(menuOutdentList(_:)):
            return textFormattingMenuAvailable(controller)
                && controller.model.formattingState.listKind != nil
                && controller.model.formattingState.listLevel > 0
        case #selector(menuClearFormatting(_:)):
            return inlineFormattingMenuAvailable(controller)
        case #selector(menuInsertLink(_:)):
            return textFormattingMenuAvailable(controller)
        case #selector(menuInsertTable(_:)):
            return formattingMenuAvailable(controller)
        case #selector(menuAddTableRowAbove(_:)),
             #selector(menuAddTableRowBelow(_:)),
             #selector(menuAddTableColumnBefore(_:)),
             #selector(menuAddTableColumnAfter(_:)),
             #selector(menuDeleteTableRow(_:)),
             #selector(menuDeleteTableColumn(_:)):
            return formattingMenuAvailable(controller) && controller.model.formattingState.inTable
        case #selector(menuToggleMarkdownView(_:)):
            menuItem.state = controller.model.showsMarkdownSource ? .on : .off
            return settings.formattingEnabled
        case #selector(menuToggleSpellCheck(_:)):
            menuItem.state = settings.spellCheck ? .on : .off
            return true
        case #selector(menuToggleAutocorrect(_:)):
            menuItem.state = settings.autocorrect ? .on : .off
            return true
        case #selector(menuToggleFormattingEnabled(_:)):
            menuItem.state = settings.formattingEnabled ? .on : .off
            return true
        case #selector(menuToggleFormattingToolbar(_:)):
            menuItem.state = settings.formattingToolbarVisible ? .on : .off
            return true
        default:
            return true
        }
    }

    private func formattingMenuAvailable(_ controller: WindowController) -> Bool {
        guard settings.formattingEnabled, controller.model.activeDocument != nil else { return false }
        // Se il fuoco è nella barra Trova, non formattare il documento.
        if let responder = controller.window?.firstResponder as? NSTextView,
           !(responder is EditorTextView) {
            return false
        }
        return true
    }

    private func textFormattingMenuAvailable(_ controller: WindowController) -> Bool {
        formattingMenuAvailable(controller) && !controller.editor.isTableInteractionActive
    }

    private func inlineFormattingMenuAvailable(_ controller: WindowController) -> Bool {
        guard formattingMenuAvailable(controller) else { return false }
        if controller.editor.isTableRangeFocused { return true }
        return !controller.editor.isTableInteractionActive
    }

    // MARK: - Scorciatoie in stile Windows

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let controller = activeController else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasControl = flags.contains(.control)
        let hasCommand = flags.contains(.command)
        let hasOption = flags.contains(.option)
        let isEditor = controller.window?.firstResponder is EditorTextView

        if isEditor, hasControl, !hasCommand {
            let characters = (event.charactersIgnoringModifiers ?? "").lowercased()
            if hasOption {
                switch event.keyCode {
                case 18: controller.model.setHeadingLevel(1); return true
                case 19: controller.model.setHeadingLevel(2); return true
                case 20: controller.model.setHeadingLevel(3); return true
                case 29: controller.model.setHeadingLevel(0); return true
                default: break
                }
            } else {
                switch characters {
                case "b": controller.model.toggleBold(); return true
                case "i": controller.model.toggleItalic(); return true
                case "k": controller.model.insertLink(); return true
                case "]": controller.model.indentList(outdent: false); return true
                case "[": controller.model.indentList(outdent: true); return true
                default: break
                }
                if flags.contains(.shift) {
                    switch characters {
                    case "x": controller.model.toggleStrikethrough(); return true
                    case "m": controller.model.toggleMarkdownSource(); return true
                    default: break
                    }
                    if event.keyCode == 28 { controller.model.toggleList(.bullet); return true }
                    if event.keyCode == 26 { controller.model.toggleList(.numbered); return true }
                }
            }
        }

        if isEditor, !hasCommand, !hasOption {
            if let handled = handleEditingKey(event, controller: controller, hasControl: hasControl, shift: flags.contains(.shift)) {
                return handled
            }
        }

        // Esc chiude menu o barra di ricerca.
        if event.keyCode == 53 {
            if controller.model.popup != nil
                || controller.model.isTablePickerVisible
                || controller.model.find.isVisible {
                controller.model.handleEscape()
                return true
            }
            return false
        }

        // F3 / Shift+F3: trova successivo/precedente.
        if event.keyCode == 99 && !hasControl && !hasCommand {
            if flags.contains(.shift) {
                controller.model.findPrevious()
            } else {
                controller.model.findNext()
            }
            return true
        }

        // F5: inserisce ora e data.
        if event.keyCode == 96 && !hasControl && !hasCommand {
            controller.model.insertTimeDate()
            return true
        }

        guard hasControl, !hasCommand, !hasOption else { return false }

        // Ctrl+Tab / Ctrl+PagSu / Ctrl+PagGiù.
        if event.keyCode == 48 {
            controller.model.cycleTab(forward: !flags.contains(.shift))
            return true
        }
        if event.keyCode == 116 || event.keyCode == 121 {
            controller.model.cycleTab(forward: event.keyCode == 121)
            return true
        }

        let characters = (event.charactersIgnoringModifiers ?? "").lowercased()
        let shift = flags.contains(.shift)

        switch characters {
        case ",":
            controller.model.showSettings()
            return true
        case "n":
            newWindow()
            return true
        case "t":
            controller.model.newTab()
            return true
        case "o":
            controller.openFilePanel()
            return true
        case "s":
            controller.model.saveActive(saveAs: shift)
            return true
        case "p":
            controller.printDocument()
            return true
        case "f":
            controller.model.showFind(replace: false)
            return true
        case "h":
            controller.model.showFind(replace: true)
            return true
        case "w":
            if shift {
                controller.closeWindow()
            } else {
                controller.model.closeActiveTab()
            }
            return true
        case "+", "=":
            controller.model.zoomIn()
            return true
        case "-", "_":
            controller.model.zoomOut()
            return true
        case "0":
            controller.model.zoomReset()
            return true
        case "g":
            if shift {
                controller.model.findPrevious()
            } else {
                controller.model.findNext()
            }
            return true
        case "x", "c", "v", "a", "z", "y":
            guard isEditor else { return false }
            switch characters {
            case "x": controller.model.cut()
            case "c": controller.model.copy()
            case "v": controller.model.paste()
            case "a": controller.model.selectAll()
            case "z": controller.model.undo()
            case "y": controller.model.redo()
            default: break
            }
            return true
        default:
            return false
        }
    }

    /// Tasti di navigazione in stile Windows quando l'editor ha il fuoco.
    private func handleEditingKey(_ event: NSEvent,
                                  controller: WindowController,
                                  hasControl: Bool,
                                  shift: Bool) -> Bool? {
        guard let textView = controller.editor.activeTextView else { return nil }
        let selector: Selector?
        if hasControl {
            switch event.keyCode {
            case 51:
                selector = #selector(NSTextView.deleteWordBackward(_:))
            case 117:
                selector = #selector(NSTextView.deleteWordForward(_:))
            case 123:
                selector = shift ? #selector(NSTextView.moveWordLeftAndModifySelection(_:))
                                 : #selector(NSTextView.moveWordLeft(_:))
            case 124:
                selector = shift ? #selector(NSTextView.moveWordRightAndModifySelection(_:))
                                 : #selector(NSTextView.moveWordRight(_:))
            case 115:
                selector = shift ? #selector(NSTextView.moveToBeginningOfDocumentAndModifySelection(_:))
                                 : #selector(NSTextView.moveToBeginningOfDocument(_:))
            case 119:
                selector = shift ? #selector(NSTextView.moveToEndOfDocumentAndModifySelection(_:))
                                 : #selector(NSTextView.moveToEndOfDocument(_:))
            default:
                selector = nil
            }
        } else {
            switch event.keyCode {
            case 115:
                selector = shift ? #selector(NSTextView.moveToBeginningOfLineAndModifySelection(_:))
                                 : #selector(NSTextView.moveToBeginningOfLine(_:))
            case 119:
                selector = shift ? #selector(NSTextView.moveToEndOfLineAndModifySelection(_:))
                                 : #selector(NSTextView.moveToEndOfLine(_:))
            default:
                selector = nil
            }
        }
        guard let selector else { return nil }
        textView.perform(selector, with: nil)
        return true
    }
}
