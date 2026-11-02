import AppKit
import AVFoundation
import Combine
import SwiftUI

enum ActiveTab: Equatable {
    case document(UUID)
    case settings
}

struct MenuItem: Identifiable {
    var id = UUID()
    var title: String = ""
    var shortcut: String?
    var isSeparator = false
    var isEnabled = true
    var isChecked = false
    var submenu: [MenuItem]?
    var action: (() -> Void)?

    static var separator: MenuItem {
        var item = MenuItem()
        item.isSeparator = true
        return item
    }
}

struct PopupState: Identifiable {
    let id = UUID()
    var items: [MenuItem]
    var anchor: CGPoint
    var width: CGFloat = 300
}


struct FindState {
    var isVisible = false
    var isReplace = false
    var query = ""
    var replacement = ""
    var matchCase = false
    var wholeWord = false
    var focusToken = 0
    var matchCount = 0
}

protocol WindowModelHost: AnyObject {
    func newWindow()
    func openFilePanel()
    func openURL(_ url: URL)
    func saveActiveDocument(saveAs: Bool)
    func saveDocument(_ document: Document, saveAs: Bool) -> Bool
    func confirmClose(_ document: Document) -> Bool
    func printDocument()
    func pageSetup()
    func closeWindow()
    func updateWindowTitle()
    func scheduleSessionSave()
    func presentError(_ error: Error, title: String?)
    func showSettings()
    var isLastWindow: Bool { get }
}

final class WindowModel: ObservableObject {
    @Published private(set) var documents: [Document] = []
    @Published var activeTab: ActiveTab = .settings
    @Published var settingsTabOpen = false
    @Published var popup: PopupState?
    @Published var find = FindState()
    @Published var statusLine = 1
    @Published var statusColumn = 1
    @Published var windowSize: CGSize = .zero
    @Published var showsMarkdownSource = false
    @Published var formattingState = MarkdownFormattingState()

    let settings = SettingsStore.shared
    weak var host: WindowModelHost?
    weak var editor: EditorController?
    weak var coordinator: WindowController?
    weak var window: NSWindow?
    private(set) var lastDocumentID: UUID?
    private var tablePopover: NSPopover?
    private let speechSynthesizer = AVSpeechSynthesizer()

    init(documents: [Document] = [], activeID: UUID? = nil) {
        self.documents = documents
        if let activeID, documents.contains(where: { $0.id == activeID }) {
            activeTab = .document(activeID)
            lastDocumentID = activeID
        } else if let first = documents.first {
            activeTab = .document(first.id)
            lastDocumentID = first.id
        } else {
            activeTab = .settings
        }
        for document in documents {
            wire(document)
        }
    }

    // MARK: - Stato derivato

    var activeDocument: Document? {
        if case .document(let id) = activeTab {
            return documents.first { $0.id == id }
        }
        return nil
    }

    var activeDocumentIndex: Int? {
        guard let doc = activeDocument else { return nil }
        return documents.firstIndex { $0.id == doc.id }
    }

    var isSettingsActive: Bool {
        if case .settings = activeTab { return true }
        return false
    }

    var tabCount: Int {
        documents.count + (settingsTabOpen ? 1 : 0)
    }

    func document(withID id: UUID) -> Document? {
        documents.first { $0.id == id }
    }

    /// Campo di testo attivo diverso dall'editor (per esempio la barra Trova).
    private var focusedFieldEditor: NSTextView? {
        guard let responder = coordinator?.window?.firstResponder as? NSTextView,
              !(responder is EditorTextView) else { return nil }
        return responder
    }

    // MARK: - Schede

    private func wire(_ document: Document) {
        document.onMetadataChange = { [weak self, weak document] in
            guard let self else { return }
            self.host?.updateWindowTitle()
            self.host?.scheduleSessionSave()
            if let document, self.activeDocument?.id == document.id {
                self.refreshFindCount()
            }
            self.objectWillChange.send()
        }
    }

    func addDocument(_ document: Document, select: Bool = true, replacingEmpty: Bool = false) {
        wire(document)
        if replacingEmpty, documents.count == 1,
           let index = documents.firstIndex(where: { $0.isUntitled && !$0.isModified && $0.text.isEmpty }) {
            let old = documents[index]
            editor?.removeDocument(old)
            documents[index] = document
            if select { selectDocument(document.id) }
        } else {
            documents.append(document)
            if select { selectDocument(document.id) }
        }
        host?.updateWindowTitle()
        host?.scheduleSessionSave()
    }

    func newTab() {
        let document = Document()
        addDocument(document)
        editor?.focusActive()
    }

    func selectDocument(_ id: UUID) {
        guard documents.contains(where: { $0.id == id }) else { return }
        activeTab = .document(id)
        lastDocumentID = id
        refreshFindCount()
        updateFormattingStateFromEditor()
        host?.updateWindowTitle()
        host?.scheduleSessionSave()
    }

    func selectSettings() {
        if find.isVisible { closeFind() }
        if let active = activeDocument { lastDocumentID = active.id }
        settingsTabOpen = true
        activeTab = .settings
        formattingState = MarkdownFormattingState()
        host?.updateWindowTitle()
        host?.scheduleSessionSave()
    }

    func closeSettingsTab() {
        settingsTabOpen = false
        if let lastDocumentID, documents.contains(where: { $0.id == lastDocumentID }) {
            selectDocument(lastDocumentID)
        } else if let first = documents.first {
            selectDocument(first.id)
        } else {
            host?.closeWindow()
        }
    }

    func closeActiveTab() {
        switch activeTab {
        case .settings:
            closeSettingsTab()
        case .document(let id):
            closeTab(id)
        }
    }

    func closeTab(_ id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let document = documents[index]

        // Ultima scheda dell'ultima finestra: come il Blocco note, chiude senza
        // domande e conserva il contenuto nella sessione.
        if settings.restoreSession,
           documents.count == 1,
           !settingsTabOpen,
           host?.isLastWindow == true {
            host?.closeWindow()
            return
        }

        guard host?.confirmClose(document) ?? true else { return }

        editor?.removeDocument(document)
        documents.remove(at: index)

        if documents.isEmpty {
            if settingsTabOpen {
                activeTab = .settings
                host?.updateWindowTitle()
                host?.scheduleSessionSave()
                return
            }
            host?.updateWindowTitle()
            host?.scheduleSessionSave()
            host?.closeWindow()
            return
        }

        if case .document(let activeID) = activeTab, activeID == id {
            let nextIndex = min(index, documents.count - 1)
            selectDocument(documents[nextIndex].id)
        } else {
            host?.updateWindowTitle()
            host?.scheduleSessionSave()
        }
    }

    func closeOtherTabs(keeping id: UUID) {
        let targets = documents.filter { $0.id != id }
        for doc in targets {
            guard host?.confirmClose(doc) ?? true else { return }
            editor?.removeDocument(doc)
            documents.removeAll { $0.id == doc.id }
        }
        selectDocument(id)
    }

    func closeTabsToRight(of id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let targets = documents[(index + 1)...]
        for doc in targets {
            guard host?.confirmClose(doc) ?? true else { return }
            editor?.removeDocument(doc)
            documents.removeAll { $0.id == doc.id }
        }
        selectDocument(id)
    }

    func closeAllTabs() {
        let targets = documents
        for doc in targets {
            guard host?.confirmClose(doc) ?? true else { return }
            editor?.removeDocument(doc)
            documents.removeAll { $0.id == doc.id }
        }
        settingsTabOpen = false
        host?.updateWindowTitle()
        host?.scheduleSessionSave()
        host?.closeWindow()
    }

    func moveDocument(from sourceID: UUID, before targetID: UUID) {
        guard sourceID != targetID,
              let source = documents.firstIndex(where: { $0.id == sourceID }),
              let target = documents.firstIndex(where: { $0.id == targetID }) else { return }
        let doc = documents.remove(at: source)
        let insertion = source < target ? max(0, target - 1) : target
        documents.insert(doc, at: min(insertion, documents.count))
        host?.scheduleSessionSave()
    }

    func cycleTab(forward: Bool) {
        guard !documents.isEmpty else { return }
        let ids = documents.map(\.id)
        var currentIndex = 0
        if let active = activeDocument, let index = ids.firstIndex(of: active.id) {
            currentIndex = index
        }
        let next = forward
            ? (currentIndex + 1) % ids.count
            : (currentIndex - 1 + ids.count) % ids.count
        selectDocument(ids[next])
        editor?.focusActive()
    }

    // MARK: - Stato editor

    func editorTextChanged(_ document: Document) {
        document.markModified()
        if activeDocument?.id == document.id {
            refreshFindCount()
            updateFormattingStateFromEditor()
        }
        host?.scheduleSessionSave()
    }

    func editorSelectionChanged(_ document: Document, line: Int, column: Int) {
        document.cursorLocation = editor?.selectedRange(in: document)?.location ?? document.cursorLocation
        if activeDocument?.id == document.id {
            if statusLine != line { statusLine = line }
            if statusColumn != column { statusColumn = column }
        }
    }

    // MARK: - Formattazione Markdown

    var formattingAvailable: Bool {
        settings.formattingEnabled && !isSettingsActive && activeDocument != nil
    }

    var textFormattingAvailable: Bool {
        formattingAvailable && !(editor?.isTableInteractionActive ?? false)
    }

    func updateFormattingStateFromEditor() {
        guard let document = activeDocument, let editor else {
            let empty = MarkdownFormattingState()
            if formattingState != empty { formattingState = empty }
            return
        }
        let state = editor.formattingState(for: document)
        if state != formattingState {
            formattingState = state
        }
    }

    func toggleBold() {
        guard formattingAvailable else { return }
        if editor?.isTableRangeFocused == true {
            _ = editor?.toggleTableInline("**")
            updateFormattingStateFromEditor()
            return
        }
        guard textFormattingAvailable else { return }
        editor?.toggleBold()
        updateFormattingStateFromEditor()
    }

    func toggleItalic() {
        guard formattingAvailable else { return }
        if editor?.isTableRangeFocused == true {
            _ = editor?.toggleTableInline("*")
            updateFormattingStateFromEditor()
            return
        }
        guard textFormattingAvailable else { return }
        editor?.toggleItalic()
        updateFormattingStateFromEditor()
    }

    func toggleStrikethrough() {
        guard formattingAvailable else { return }
        if editor?.isTableRangeFocused == true {
            _ = editor?.toggleTableInline("~~")
            updateFormattingStateFromEditor()
            return
        }
        guard textFormattingAvailable else { return }
        editor?.toggleStrikethrough()
        updateFormattingStateFromEditor()
    }

    func setHeadingLevel(_ level: Int) {
        guard textFormattingAvailable else { return }
        editor?.setHeadingLevel(level)
        updateFormattingStateFromEditor()
    }

    func toggleList(_ kind: MarkdownListKind) {
        guard textFormattingAvailable else { return }
        editor?.toggleList(kind)
        updateFormattingStateFromEditor()
    }

    func indentList(outdent: Bool) {
        guard textFormattingAvailable else { return }
        editor?.indentList(outdent: outdent)
        updateFormattingStateFromEditor()
    }

    func clearFormatting() {
        guard formattingAvailable else { return }
        if editor?.isTableRangeFocused == true {
            _ = editor?.clearTableFormatting()
            updateFormattingStateFromEditor()
            return
        }
        guard textFormattingAvailable else { return }
        editor?.clearFormatting()
        updateFormattingStateFromEditor()
    }

    func insertLink() {
        guard textFormattingAvailable else { return }
        editor?.insertLink()
        updateFormattingStateFromEditor()
    }

    func addTableRow(before: Bool = false) {
        guard formattingAvailable else { return }
        editor?.addTableRow(before: before)
        editor?.focusActiveTableOverlay()
        updateFormattingStateFromEditor()
    }

    func addTableColumn(before: Bool = false) {
        guard formattingAvailable else { return }
        editor?.addTableColumn(before: before)
        editor?.focusActiveTableOverlay()
        updateFormattingStateFromEditor()
    }

    func deleteTableRow() {
        guard formattingAvailable else { return }
        editor?.deleteTableRow()
        editor?.focusActiveTableOverlay()
        updateFormattingStateFromEditor()
    }

    func deleteTableColumn() {
        guard formattingAvailable else { return }
        editor?.deleteTableColumn()
        editor?.focusActiveTableOverlay()
        updateFormattingStateFromEditor()
    }

    var isTablePickerVisible: Bool {
        tablePopover?.isShown == true
    }

    var tablePickerContentView: NSView? {
        tablePopover?.contentViewController?.view
    }

    func showTablePicker(at anchor: CGPoint) {
        closeTablePicker()
        popup = nil
        guard formattingAvailable,
              let window,
              let contentView = window.contentView else { return }
        let theme = Theme.make(dark: settings.effectiveDark)
        let controller = TablePickerViewController(theme: theme,
                                                   inTable: formattingState.inTable)
        controller.onInsert = { [weak self] rows, columns in
            guard let self else { return }
            self.closeTablePicker()
            DispatchQueue.main.async {
                self.insertTableFromPicker(rows: rows, columns: columns)
            }
        }
        controller.onCustomSize = { [weak self] in
            guard let self else { return }
            self.closeTablePicker()
            DispatchQueue.main.async {
                self.showInsertTableDialog()
            }
        }
        controller.onAction = { [weak self] action in
            guard let self else { return }
            self.closeTablePicker()
            DispatchQueue.main.async {
                self.performTablePickerAction(action)
            }
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: settings.effectiveDark ? .darkAqua : .aqua)
        popover.contentViewController = controller
        tablePopover = popover

        let height = contentView.bounds.height
        let point = NSPoint(x: anchor.x, y: max(0, height - anchor.y))
        popover.show(relativeTo: NSRect(x: point.x, y: point.y - 1, width: 1, height: 1),
                     of: contentView,
                     preferredEdge: .maxY)
    }

    func closeTablePicker() {
        tablePopover?.performClose(nil)
        tablePopover = nil
    }

    private func performTablePickerAction(_ action: TableOverlayAction) {
        switch action {
        case .insertTable:
            showInsertTableDialog()
        case .addRowBefore:
            addTableRow(before: true)
        case .addRowAfter:
            addTableRow(before: false)
        case .addColumnBefore:
            addTableColumn(before: true)
        case .addColumnAfter:
            addTableColumn(before: false)
        case .deleteRow:
            deleteTableRow()
        case .deleteColumn:
            deleteTableColumn()
        }
        if formattingState.inTable {
            editor?.focusActiveTableOverlay()
        } else {
            editor?.focusActive()
        }
    }

    func insertTableFromPicker(rows: Int, columns: Int) {
        closeTablePicker()
        guard formattingAvailable else { return }
        editor?.insertTableFromPicker(rows: rows, columns: columns)
        updateFormattingStateFromEditor()
    }

    func showInsertTableDialog() {
        closeTablePicker()
        guard formattingAvailable else { return }
        editor?.showInsertTableDialog()
        updateFormattingStateFromEditor()
    }

    func toggleMarkdownSource() {
        guard settings.formattingEnabled else { return }
        showsMarkdownSource.toggle()
        editor?.refreshMarkdownRendering()
        updateFormattingStateFromEditor()
    }

    func toggleFormattingToolbar() {
        settings.formattingToolbarVisible.toggle()
    }

    func toggleFormattingEnabled() {
        settings.formattingEnabled.toggle()
        editor?.refreshMarkdownRendering()
        updateFormattingStateFromEditor()
    }

    func toggleTheme() {
        settings.theme = settings.effectiveDark ? .light : .dark
        settings.applyAppearance()
    }

    func toggleReadAloud() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
            return
        }
        guard let document = activeDocument else { return }
        var text = document.text
        if let editor, let range = editor.selectedRange(in: document), range.length > 0 {
            let ns = text as NSString
            if NSMaxRange(range) <= ns.length {
                text = ns.substring(with: range)
            }
        }
        let clean = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
        guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string: clean)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }

    func refreshStatusFromActive() {
        guard let doc = activeDocument, let range = editor?.selectedRange(in: doc) else { return }
        let text = doc.text as NSString
        let (line, column) = WindowModel.lineColumn(in: text, location: range.location)
        statusLine = line
        statusColumn = column
    }

    static func lineColumn(in text: NSString, location: Int) -> (Int, Int) {
        let loc = min(max(0, location), text.length)
        var line = 1
        var index = 0
        while index < loc {
            let found = text.range(of: "\n", options: [], range: NSRange(location: index, length: loc - index))
            if found.location == NSNotFound { break }
            line += 1
            index = found.location + 1
        }
        let prefix = text.substring(to: loc) as NSString
        let lastBreak = prefix.range(of: "\n", options: .backwards)
        let column = lastBreak.location == NSNotFound ? loc + 1 : loc - NSMaxRange(lastBreak) + 1
        return (line, column)
    }

    // MARK: - Menu contestuali

    func openTabMenu(_ document: Document, at anchor: CGPoint) {
        let fullPath = document.fileURL?.path
        var items: [MenuItem] = [
            MenuItem(title: L.t("Salva", "Save"),
                     shortcut: "Ctrl+S",
                     action: { [weak self] in self?.save(document, saveAs: false) }),
            MenuItem(title: L.t("Salva con nome...", "Save as..."),
                     shortcut: "Ctrl+Shift+S",
                     action: { [weak self] in self?.save(document, saveAs: true) })
        ]
        items.append(.separator)
        items.append(MenuItem(title: L.t("Copia percorso", "Copy full path"),
                              isEnabled: fullPath != nil,
                              action: {
                                  if let fullPath {
                                      NSPasteboard.general.clearContents()
                                      NSPasteboard.general.setString(fullPath, forType: .string)
                                  }
                              }))
        items.append(MenuItem(title: L.t("Apri cartella nel Finder", "Open file location"),
                              isEnabled: document.fileURL != nil,
                              action: {
                                  if let url = document.fileURL {
                                      NSWorkspace.shared.activateFileViewerSelecting([url])
                                  }
                              }))
        items.append(.separator)
        items.append(MenuItem(title: L.t("Chiudi scheda", "Close tab"),
                              shortcut: "Ctrl+W",
                              action: { [weak self] in self?.closeTab(document.id) }))
        items.append(MenuItem(title: L.t("Chiudi altre schede", "Close other tabs"),
                              isEnabled: documents.count > 1,
                              action: { [weak self] in self?.closeOtherTabs(keeping: document.id) }))
        if let index = documents.firstIndex(where: { $0.id == document.id }), index < documents.count - 1 {
            items.append(MenuItem(title: L.t("Chiudi schede a destra", "Close tabs to the right"),
                                  action: { [weak self] in self?.closeTabsToRight(of: document.id) }))
        }
        items.append(MenuItem(title: L.t("Chiudi tutte le schede", "Close all tabs"),
                              action: { [weak self] in self?.closeAllTabs() }))
        popup = PopupState(items: items, anchor: anchor, width: 290)
    }

    func openEditorMenu(at anchor: CGPoint) {
        guard let doc = activeDocument, let textView = editor?.textView(for: doc) else { return }
        let hasSelection = textView.selectedRange().length > 0
        let canPaste = NSPasteboard.general.string(forType: .string) != nil
        var items: [MenuItem] = [
            MenuItem(title: L.t("Annulla", "Undo"),
                     shortcut: "Ctrl+Z",
                     isEnabled: doc.undoManager.canUndo,
                     action: { [weak self] in self?.undo() }),
            MenuItem(title: L.t("Ripeti", "Redo"),
                     shortcut: "Ctrl+Y",
                     isEnabled: doc.undoManager.canRedo,
                     action: { [weak self] in self?.redo() }),
            .separator,
            MenuItem(title: L.t("Taglia", "Cut"),
                     shortcut: "Ctrl+X",
                     isEnabled: hasSelection,
                     action: { [weak self] in self?.cut() }),
            MenuItem(title: L.t("Copia", "Copy"),
                     shortcut: "Ctrl+C",
                     isEnabled: hasSelection,
                     action: { [weak self] in self?.copy() }),
            MenuItem(title: L.t("Incolla", "Paste"),
                     shortcut: "Ctrl+V",
                     isEnabled: canPaste,
                     action: { [weak self] in self?.paste() }),
            MenuItem(title: L.t("Elimina", "Delete"),
                     isEnabled: hasSelection,
                     action: { [weak self] in self?.deleteSelection() }),
            .separator,
            MenuItem(title: L.t("Seleziona tutto", "Select all"),
                     shortcut: "Ctrl+A",
                     action: { [weak self] in self?.selectAll() }),
            .separator,
            MenuItem(title: L.t("Trova...", "Find..."),
                     shortcut: "Ctrl+F",
                     action: { [weak self] in self?.showFind(replace: false) }),
            MenuItem(title: L.t("Sostituisci...", "Replace..."),
                     shortcut: "Ctrl+H",
                     action: { [weak self] in self?.showFind(replace: true) }),
            .separator,
            MenuItem(title: L.t("Inserisci ora e data", "Insert time/date"),
                     shortcut: "F5",
                     action: { [weak self] in self?.insertTimeDate() })
        ]
        if settings.spellCheck {
            items.append(.separator)
            items.append(MenuItem(title: L.t("Controllo ortografico", "Spell check"),
                                  isChecked: true,
                                  action: { self.settings.spellCheck = false }))
        }
        popup = PopupState(items: items, anchor: anchor, width: 300)
    }

    func showPopup(_ items: [MenuItem], at anchor: CGPoint, width: CGFloat = 260) {
        closeTablePicker()
        popup = PopupState(items: items, anchor: anchor, width: width)
    }

    func showDropdown(options: [String],
                      selected: Int,
                      width: CGFloat = 260,
                      at anchor: CGPoint,
                      onSelect: @escaping (Int) -> Void) {
        closeTablePicker()
        var items: [MenuItem] = []
        for (index, option) in options.enumerated() {
            items.append(MenuItem(title: option,
                                  isChecked: index == selected,
                                  action: { onSelect(index) }))
        }
        popup = PopupState(items: items, anchor: anchor, width: width)
    }

    /// Punto in coordinate finestra (origine in basso a sinistra) → coordinate radice SwiftUI.
    func hideEditorFocusAndShowContextMenu(at windowPoint: NSPoint) {
        let height = windowSize.height > 0 ? windowSize.height : 600
        openEditorMenu(at: CGPoint(x: windowPoint.x, y: height - windowPoint.y))
    }

    func openFindOptions(at anchor: CGPoint) {
        let items: [MenuItem] = [
            MenuItem(title: L.t("Maiuscole/minuscole", "Match case"),
                     isChecked: find.matchCase,
                     action: { [weak self] in
                         guard let self else { return }
                         self.find.matchCase.toggle()
                         self.refreshFindCount()
                     }),
            MenuItem(title: L.t("Parola intera", "Whole word"),
                     isChecked: find.wholeWord,
                     action: { [weak self] in
                         guard let self else { return }
                         self.find.wholeWord.toggle()
                         self.refreshFindCount()
                     })
        ]
        popup = PopupState(items: items, anchor: anchor, width: 250)
    }

    func closePopup() {
        popup = nil
    }

    // MARK: - Azioni

    private func save(_ document: Document, saveAs: Bool) {
        _ = host?.saveDocument(document, saveAs: saveAs)
    }

    func saveActive(saveAs: Bool) {
        guard let doc = activeDocument else { return }
        _ = host?.saveDocument(doc, saveAs: saveAs)
    }

    func undo() {
        if let field = focusedFieldEditor {
            field.undoManager?.undo()
            return
        }
        guard let doc = activeDocument else { return }
        doc.undoManager.undo()
        editor?.focusActive()
    }

    func redo() {
        if let field = focusedFieldEditor {
            field.undoManager?.redo()
            return
        }
        guard let doc = activeDocument else { return }
        doc.undoManager.redo()
        editor?.focusActive()
    }

    func cut() {
        if let field = focusedFieldEditor {
            field.cut(nil)
            return
        }
        editor?.activeTextView?.cut(nil)
        editor?.focusActive()
    }

    func copy() {
        if let field = focusedFieldEditor {
            field.copy(nil)
            return
        }
        editor?.activeTextView?.copy(nil)
    }

    func paste() {
        if let field = focusedFieldEditor {
            field.paste(nil)
            return
        }
        editor?.activeTextView?.paste(nil)
        editor?.focusActive()
    }

    func deleteSelection() {
        if let field = focusedFieldEditor {
            field.delete(nil)
            return
        }
        editor?.deleteSelection()
        editor?.focusActive()
    }

    func selectAll() {
        if let field = focusedFieldEditor {
            field.selectAll(nil)
            return
        }
        editor?.activeTextView?.selectAll(nil)
    }

    func insertTimeDate() {
        editor?.insertTimeDate()
    }

    func zoomIn() {
        settings.zoomIn()
        editor?.applySettings()
        host?.scheduleSessionSave()
    }

    func zoomOut() {
        settings.zoomOut()
        editor?.applySettings()
        host?.scheduleSessionSave()
    }

    func zoomReset() {
        settings.resetZoom()
        editor?.applySettings()
        host?.scheduleSessionSave()
    }

    func setZoom(_ value: Double) {
        settings.zoom = min(5, max(0.1, value))
        editor?.applySettings()
        host?.scheduleSessionSave()
        updateFormattingStateFromEditor()
    }

    func toggleWordWrap() {
        settings.wordWrap.toggle()
        editor?.applySettings()
    }

    func toggleStatusBar() {
        settings.showStatusBar.toggle()
    }

    func showSettings() {
        host?.showSettings()
    }

    // MARK: - Trova / sostituisci

    func showFind(replace: Bool) {
        guard activeDocument != nil else { return }
        find.isVisible = true
        find.isReplace = replace
        find.focusToken += 1
        refreshFindCount()
    }

    func closeFind() {
        guard find.isVisible else { return }
        find.isVisible = false
        editor?.focusActive()
    }

    func refreshFindCount() {
        guard find.isVisible, let doc = activeDocument else {
            if find.matchCount != 0 { find.matchCount = 0 }
            return
        }
        let count = editor?.matchCount(query: find.query,
                                       in: doc,
                                       matchCase: find.matchCase,
                                       wholeWord: find.wholeWord) ?? 0
        if count != find.matchCount { find.matchCount = count }
    }

    func findNext() {
        guard let doc = activeDocument else { return }
        if !find.isVisible { showFind(replace: false) }
        _ = editor?.findNext(query: find.query,
                             in: doc,
                             matchCase: find.matchCase,
                             wholeWord: find.wholeWord)
        refreshFindCount()
    }

    func findPrevious() {
        guard let doc = activeDocument else { return }
        if !find.isVisible { showFind(replace: false) }
        _ = editor?.findPrevious(query: find.query,
                                 in: doc,
                                 matchCase: find.matchCase,
                                 wholeWord: find.wholeWord)
        refreshFindCount()
    }

    func replaceCurrent() {
        guard let doc = activeDocument else { return }
        _ = editor?.replaceCurrent(query: find.query,
                                   replacement: find.replacement,
                                   in: doc,
                                   matchCase: find.matchCase,
                                   wholeWord: find.wholeWord)
        refreshFindCount()
    }

    func replaceAll() {
        guard let doc = activeDocument else { return }
        _ = editor?.replaceAll(query: find.query,
                               replacement: find.replacement,
                               in: doc,
                               matchCase: find.matchCase,
                               wholeWord: find.wholeWord)
        refreshFindCount()
    }

    func handleEscape() {
        if isTablePickerVisible {
            closeTablePicker()
            return
        }
        if popup != nil {
            closePopup()
            return
        }
        if find.isVisible {
            closeFind()
        }
    }
}
