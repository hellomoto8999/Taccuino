import AppKit
import Combine
import SwiftUI

final class SaveOptionsView: NSView {
    private let encodingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let lineEndingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let encodings = TextEncoding.allCases
    private let lineEndings = LineEnding.allCases

    var selectedEncoding: TextEncoding {
        let index = encodingPopup.indexOfSelectedItem
        return index >= 0 && index < encodings.count ? encodings[index] : .utf8
    }

    var selectedLineEnding: LineEnding {
        let index = lineEndingPopup.indexOfSelectedItem
        return index >= 0 && index < lineEndings.count ? lineEndings[index] : .crlf
    }

    init(encoding: TextEncoding, lineEnding: LineEnding) {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 78))

        encodingPopup.addItems(withTitles: encodings.map(\.displayName))
        if let index = encodings.firstIndex(of: encoding) {
            encodingPopup.selectItem(at: index)
        }
        encodingPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true

        lineEndingPopup.addItems(withTitles: lineEndings.map(\.displayName))
        if let index = lineEndings.firstIndex(of: lineEnding) {
            lineEndingPopup.selectItem(at: index)
        }
        lineEndingPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let encodingLabel = NSTextField(labelWithString: L.t("Codifica:", "Encoding:"))
        encodingLabel.font = .systemFont(ofSize: 12)
        encodingLabel.textColor = .secondaryLabelColor
        encodingLabel.alignment = .right

        let lineEndingLabel = NSTextField(labelWithString: L.t("Fine riga:", "Line endings:"))
        lineEndingLabel.font = .systemFont(ofSize: 12)
        lineEndingLabel.textColor = .secondaryLabelColor
        lineEndingLabel.alignment = .right

        let grid = NSGridView(views: [
            [encodingLabel, encodingPopup],
            [lineEndingLabel, lineEndingPopup]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class WindowController: NSWindowController, NSWindowDelegate, WindowModelHost {
    let model: WindowModel
    let editor: EditorController
    private let settings = SettingsStore.shared
    private var cancellables = Set<AnyCancellable>()

    private struct FileStamp: Equatable {
        var modificationDate: Date?
        var size: Int?
    }

    private var externalChangeTimer: Timer?
    private var fileStamps: [UUID: FileStamp] = [:]

    init(session: SessionWindow?, cascadeIndex: Int = 0) {
        let restored = WindowController.restoreDocuments(from: session)
        var documents = restored.documents
        let activeID = restored.activeID
        if documents.isEmpty {
            documents = [Document()]
        }

        let model = WindowModel(documents: documents, activeID: activeID)
        let editor = EditorController()
        self.model = model
        self.editor = editor

        let frame = WindowController.frame(for: session, cascadeIndex: cascadeIndex)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        model.editor = editor
        model.coordinator = self
        model.window = window
        model.host = self
        editor.model = model

        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        window.setFrame(frame, display: false)

        let root = RootView(model: model, settings: settings, editor: editor)
        window.contentView = NSHostingView(rootView: root)

        updateWindowTitle()
        observeSettings()
        observeSystemAppearance()
        editor.applySettings()

        if let session {
            let activeIndex = session.activeDocumentIndex ?? 0
            if activeIndex >= 0 && activeIndex < documents.count {
                model.selectDocument(documents[activeIndex].id)
            }
        }

        primeFileStamps()
        startExternalChangeMonitoring()
    }

    deinit {
        externalChangeTimer?.invalidate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        DispatchQueue.main.async { [weak self] in
            self?.focusEditor()
        }
    }

    // MARK: - Modifiche esterne al file

    private func fileStamp(for url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return FileStamp(
            modificationDate: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue
        )
    }

    private func primeFileStamps() {
        for document in model.documents {
            guard let url = document.fileURL else { continue }
            if let stamp = fileStamp(for: url) {
                fileStamps[document.id] = stamp
            }
        }
    }

    private func startExternalChangeMonitoring() {
        guard !ProcessInfo.processInfo.arguments.contains("--selftest") else { return }
        externalChangeTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkForExternalFileChanges()
        }
        RunLoop.main.add(timer, forMode: .common)
        externalChangeTimer = timer
    }

    private func checkForExternalFileChanges() {
        guard NSApp.modalWindow == nil else { return }
        for document in model.documents {
            guard let url = document.fileURL else { continue }
            guard let current = fileStamp(for: url) else { continue }
            if fileStamps[document.id] == current { continue }
            guard let decoded = try? TextFile.read(from: url) else { continue }
            fileStamps[document.id] = current
            if decoded.text == document.text { continue }

            if document.isModified {
                guard NSApp.isActive else {
                    fileStamps[document.id] = nil
                    continue
                }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L.t("Il file è stato modificato",
                                        "The file has changed on disk")
                alert.informativeText = L.t(
                    "\(document.displayName) è stato modificato fuori da Taccuino. Vuoi ricaricare la versione su disco o mantenere le modifiche locali?",
                    "\(document.displayName) was changed outside Taccuino. Reload the version on disk or keep your local changes?"
                )
                alert.addButton(withTitle: L.t("Mantieni le mie modifiche", "Keep my changes"))
                alert.addButton(withTitle: L.t("Ricarica", "Reload"))
                if alert.runModal() == .alertSecondButtonReturn {
                    applyExternalReload(document, decoded: decoded)
                }
            } else {
                applyExternalReload(document, decoded: decoded)
            }
        }
    }

    private func applyExternalReload(_ document: Document, decoded: DecodedText) {
        document.reloadContents(decoded.text,
                                encoding: decoded.encoding,
                                lineEnding: decoded.lineEnding)
        editor.documentContentsDidReload(document)
        model.refreshStatusFromActive()
        updateWindowTitle()
        scheduleSessionSave()
    }

    func focusEditor() {
        if model.isSettingsActive {
            editor.setActive(nil)
        } else if let doc = model.activeDocument {
            editor.setActive(doc.id)
        }
    }

    private func observeSettings() {
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.applyTheme()
                    self.editor.applySettings()
                }
            }
            .store(in: &cancellables)
    }

    private func applyTheme() {
        window?.backgroundColor = .clear
    }

    private func observeSystemAppearance() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.applyTheme()
            }
        }
    }

    // MARK: - Finestra

    func windowDidBecomeKey(_ notification: Notification) {
        updateWindowTitle()
    }

    func windowWillClose(_ notification: Notification) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.windowWillClose(self)
        appDelegate.unregister(self)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let appDelegate = NSApp.delegate as? AppDelegate
        if appDelegate?.isTerminating == true { return true }

        // Con il ripristino sessione attivo l'ultima finestra si chiude come
        // il Blocco note: nessuna richiesta di salvataggio, tutto torna al
        // prossimo avvio.
        if settings.restoreSession, isLastWindow { return true }

        for document in model.documents where document.isModified {
            if !confirmClose(document) { return false }
        }
        return true
    }

    // MARK: - WindowModelHost

    var isLastWindow: Bool {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return true }
        return appDelegate.controllers.count <= 1
    }

    func newWindow() {
        (NSApp.delegate as? AppDelegate)?.newWindow()
    }

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.title = L.t("Apri", "Open")
        panel.prompt = L.t("Apri", "Open")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowsOtherFileTypes = true
        panel.resolvesAliases = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                openURL(url)
            }
        }
    }

    func openURL(_ url: URL) {
        let standardized = url.standardizedFileURL
        if let existing = model.documents.first(where: { $0.fileURL?.standardizedFileURL == standardized }) {
            model.selectDocument(existing.id)
            editor.setActive(existing.id)
            return
        }

        do {
            var decoded = try TextFile.read(from: standardized)
            var modified = false
            let firstLine = decoded.text.prefix { $0 != "\n" && $0 != "\r" }
            if firstLine == ".LOG" {
                if decoded.text == ".LOG" || !decoded.text.hasSuffix("\n") {
                    decoded = DecodedText(text: decoded.text + "\n" + DateTimeText.now(),
                                          encoding: decoded.encoding,
                                          lineEnding: decoded.lineEnding)
                } else {
                    decoded = DecodedText(text: decoded.text + DateTimeText.now(),
                                          encoding: decoded.encoding,
                                          lineEnding: decoded.lineEnding)
                }
                modified = true
            }
            let document = Document(text: decoded.text,
                                    fileURL: standardized,
                                    encoding: decoded.encoding,
                                    lineEnding: decoded.lineEnding,
                                    modified: modified)
            model.addDocument(document, replacingEmpty: true)
            editor.setActive(document.id)
            fileStamps[document.id] = fileStamp(for: standardized)
            settings.addRecent(standardized)
        } catch {
            presentError(error, title: L.t("Impossibile aprire il file", "Could not open the file"))
        }
    }

    func saveActiveDocument(saveAs: Bool) {
        guard let doc = model.activeDocument else { return }
        _ = saveDocument(doc, saveAs: saveAs)
    }

    @discardableResult
    func saveDocument(_ document: Document, saveAs: Bool) -> Bool {
        var url = document.fileURL
        var encoding = document.encoding
        var lineEnding = document.lineEnding

        if url == nil || saveAs {
            let panel = NSSavePanel()
            panel.title = L.t("Salva con nome", "Save as")
            panel.prompt = L.t("Salva", "Save")
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.showsTagField = false
            panel.allowsOtherFileTypes = true
            panel.nameFieldStringValue = document.isUntitled
                ? L.t("Senza titolo.txt", "Untitled.txt")
                : (document.displayName.isEmpty ? "Senza titolo.txt" : document.displayName)
            if let parent = document.fileURL?.deletingLastPathComponent() {
                panel.directoryURL = parent
            }
            let options = SaveOptionsView(encoding: encoding, lineEnding: lineEnding)
            panel.accessoryView = options
            guard panel.runModal() == .OK, var selected = panel.url else { return false }
            if selected.pathExtension.isEmpty {
                selected.appendPathExtension("txt")
            }
            url = selected
            encoding = options.selectedEncoding
            lineEnding = options.selectedLineEnding
        }

        guard let targetURL = url else { return false }

        if encoding == .ansi {
            let converted = document.text.replacingOccurrences(of: "\n", with: lineEnding.separator)
            if encoding.encode(converted)?.lossy == true {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L.t("Alcuni caratteri non possono essere salvati in ANSI",
                                        "Some characters cannot be saved in ANSI")
                alert.informativeText = L.t("I caratteri non rappresentabili verranno sostituiti. Salvare comunque?",
                                            "Characters that cannot be represented will be replaced. Save anyway?")
                alert.addButton(withTitle: L.t("Salva", "Save"))
                alert.addButton(withTitle: L.t("Annulla", "Cancel"))
                if alert.runModal() != .alertFirstButtonReturn { return false }
            }
        }

        do {
            _ = try TextFile.write(document.text, to: targetURL, encoding: encoding, lineEnding: lineEnding)
            document.markSaved(url: targetURL, encoding: encoding, lineEnding: lineEnding)
            fileStamps[document.id] = fileStamp(for: targetURL)
            settings.addRecent(targetURL)
            updateWindowTitle()
            scheduleSessionSave()
            return true
        } catch {
            presentError(error, title: L.t("Impossibile salvare il file", "Could not save the file"))
            return false
        }
    }

    @discardableResult
    func confirmClose(_ document: Document) -> Bool {
        guard document.isModified else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.t("Salvare le modifiche a \(document.displayName)?",
                                "Save changes to \(document.displayName)?")
        alert.informativeText = L.t("Se non salvi, le modifiche andranno perse.",
                                    "If you don't save, your changes will be lost.")
        alert.addButton(withTitle: L.t("Salva", "Save"))
        alert.addButton(withTitle: L.t("Non salvare", "Don't save"))
        alert.addButton(withTitle: L.t("Annulla", "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveDocument(document, saveAs: false)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func printDocument() {
        editor.printDocument()
    }

    func pageSetup() {
        editor.pageSetup()
    }

    func closeWindow() {
        window?.performClose(nil)
    }

    func updateWindowTitle() {
        let name = model.activeDocument?.displayName ?? L.appName
        let modified = model.activeDocument?.isModified == true
        window?.title = "\(name)\(modified ? " *" : "") - \(L.appName)"
        window?.isDocumentEdited = modified
        window?.representedURL = model.activeDocument?.fileURL
    }

    func scheduleSessionSave() {
        (NSApp.delegate as? AppDelegate)?.scheduleSessionSave()
    }

    func presentError(_ error: Error, title: String?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title ?? L.t("Si è verificato un errore", "An error occurred")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func showSettings() {
        model.selectSettings()
    }

    // MARK: - Sessione

    func snapshot() -> SessionWindow? {
        guard let window else { return nil }
        editor.persistState()
        let tabs = model.documents.map { doc -> SessionTab in
            let pathExists = doc.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let keepText = doc.isModified || doc.isUntitled || !pathExists
            return SessionTab(
                path: doc.fileURL?.path,
                displayName: doc.displayName,
                text: keepText ? doc.text : nil,
                encoding: doc.encoding.rawValue,
                lineEnding: doc.lineEnding.rawValue,
                cursor: doc.cursorLocation,
                scrollX: Double(doc.scrollX),
                scrollY: Double(doc.scrollY),
                modified: doc.isModified
            )
        }
        return SessionWindow(
            x: Double(window.frame.origin.x),
            y: Double(window.frame.origin.y),
            width: Double(window.frame.size.width),
            height: Double(window.frame.size.height),
            activeDocumentIndex: model.activeDocumentIndex,
            tabs: tabs
        )
    }

    private static func restoreDocuments(from session: SessionWindow?) -> (documents: [Document], activeID: UUID?) {
        guard let session else { return ([], nil) }
        var documents: [Document] = []
        var activeID: UUID?

        for (index, tab) in session.tabs.enumerated() {
            let encoding = TextEncoding(rawValue: tab.encoding) ?? .utf8
            let lineEnding = LineEnding(rawValue: tab.lineEnding) ?? .crlf
            var document: Document?

            if let path = tab.path {
                let url = URL(fileURLWithPath: path)
                if let stored = tab.text {
                    document = Document(text: stored,
                                        fileURL: url,
                                        encoding: encoding,
                                        lineEnding: lineEnding,
                                        modified: tab.modified)
                } else if let decoded = try? TextFile.read(from: url) {
                    document = Document(text: decoded.text,
                                        fileURL: url,
                                        encoding: decoded.encoding,
                                        lineEnding: decoded.lineEnding)
                }
            } else if let stored = tab.text {
                document = Document(text: stored,
                                    encoding: encoding,
                                    lineEnding: lineEnding,
                                    modified: tab.modified)
            }

            guard let document else { continue }
            document.cursorLocation = tab.cursor
            document.scrollX = CGFloat(tab.scrollX)
            document.scrollY = CGFloat(tab.scrollY)
            documents.append(document)
            if session.activeDocumentIndex == index {
                activeID = document.id
            }
        }
        return (documents, activeID)
    }

    private static func frame(for session: SessionWindow?, cascadeIndex: Int) -> NSRect {
        if let session {
            let rect = NSRect(x: session.x, y: session.y, width: session.width, height: session.height)
            if rect.width >= 480, rect.height >= 320, isVisibleOnScreen(rect) {
                return rect
            }
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = NSSize(width: min(1000, screen.width - 80), height: min(700, screen.height - 80))
        let offset = CGFloat(cascadeIndex % 6) * 26
        let origin = NSPoint(
            x: screen.midX - size.width / 2 + offset,
            y: screen.midY - size.height / 2 - offset
        )
        return NSRect(origin: origin, size: size)
    }

    private static func isVisibleOnScreen(_ rect: NSRect) -> Bool {
        for screen in NSScreen.screens {
            let intersection = rect.intersection(screen.visibleFrame)
            if intersection.width > 120, intersection.height > 80 {
                return true
            }
        }
        return false
    }
}
