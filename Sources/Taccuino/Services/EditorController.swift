import AppKit
import Combine
import Foundation

final class EditorTextView: NSTextView {
    weak var document: Document?
    weak var controller: EditorController?

    var contextMenuHandler: ((NSPoint) -> Void)?
    var openFilesHandler: (([URL]) -> Void)?
    var zoomStepHandler: ((Bool) -> Void)?
    var layoutHandler: (() -> Void)?

    private var magnificationAccumulator: CGFloat = 0

    override var undoManager: UndoManager? {
        document?.undoManager
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let document else {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let localPoint = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: localPoint)
        let selection = selectedRange()
        let length = (string as NSString).length
        if selection.length == 0 || index < selection.location || index > NSMaxRange(selection) {
            setSelectedRange(NSRange(location: min(index, length), length: 0))
        }
        _ = document
        contextMenuHandler?(event.locationInWindow)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !fileURLs(from: sender).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !fileURLs(from: sender).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        if !urls.isEmpty {
            openFilesHandler?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            let delta = event.scrollingDeltaY
            if abs(delta) > 0.5 {
                zoomStepHandler?(delta > 0)
            }
            return
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        magnificationAccumulator += event.magnification
        if abs(magnificationAccumulator) >= 0.12 {
            zoomStepHandler?(magnificationAccumulator > 0)
            magnificationAccumulator = 0
        }
    }

    override func paste(_ sender: Any?) {
        // Il documento resta Markdown: incolla sempre come testo semplice.
        if let string = NSPasteboard.general.string(forType: .string) {
            insertText(string, replacementRange: selectedRange())
        } else {
            super.paste(sender)
        }
    }

    override func layout() {
        super.layout()
        layoutHandler?()
    }

    override func mouseDown(with event: NSEvent) {
        controller?.textViewWasClicked(self)
        super.mouseDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if controller?.continueListOnNewline(in: self) == true { return }
        super.insertNewline(sender)
    }
}

final class EditorInstance {
    let document: Document
    let scrollView: NSScrollView
    let textView: EditorTextView
    var needsScrollRestore = true
    var tableOverlays: [TableOverlayView] = []
    var tableSelection: TableCellSelection?
    var lastOverlayWidth: CGFloat = -1

    init(document: Document, scrollView: NSScrollView, textView: EditorTextView) {
        self.document = document
        self.scrollView = scrollView
        self.textView = textView
    }
}

struct TableCellSelection: Equatable {
    var tableStart: Int
    var row: Int
    var column: Int
}

final class EditorController: NSObject, NSTextViewDelegate {
    let containerView = NSView()
    weak var model: WindowModel?

    private let settings = SettingsStore.shared
    private var instances: [UUID: EditorInstance] = [:]
    private var currentID: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var themeObserver: NSObjectProtocol?
    private var currentTheme: Theme = Theme.make(dark: false)
    private var isRenderingMarkdown = false
    private var markdownRenderWorkItem: DispatchWorkItem?
    private var isUpdatingTableOverlays = false
    private var isCommittingTableCell = false
    private var pendingTableSelection: (selection: TableCellSelection, editing: Bool)?

    override init() {
        super.init()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.white.cgColor
        observeSettings()
    }

    deinit {
        if let themeObserver {
            DistributedNotificationCenter.default().removeObserver(themeObserver)
        }
    }

    private func observeSettings() {
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                // objectWillChange arriva prima dell'aggiornamento: applichiamo al ciclo successivo.
                DispatchQueue.main.async { self?.applySettings() }
            }
            .store(in: &cancellables)

        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.applySettings()
            }
        }
    }

    var activeTextView: EditorTextView? {
        guard let currentID else { return nil }
        return instances[currentID]?.textView
    }

    var displayedDocumentID: UUID? { currentID }

    func textView(for document: Document) -> EditorTextView? {
        instances[document.id]?.textView
    }

    func selectedRange(in document: Document) -> NSRange? {
        instances[document.id]?.textView.selectedRange()
    }

    // MARK: - Ciclo di vita delle schede

    func setActive(_ id: UUID?) {
        if id == currentID {
            return
        }

        persistCurrentState()

        if let currentID, let inst = instances[currentID], inst.scrollView.superview === containerView {
            inst.scrollView.removeFromSuperview()
        }
        currentID = id

        guard let id, let doc = model?.document(withID: id) else {
            containerView.window?.makeFirstResponder(nil)
            return
        }

        let instance = instance(for: doc)
        attach(instance)
        if let window = containerView.window {
            window.makeFirstResponder(instance.textView)
        }
        restoreScrollIfNeeded(instance)
        if !settings.wordWrap {
            DispatchQueue.main.async { [weak self] in
                self?.expandForNoWrap(instance.textView)
            }
        }
        model?.refreshStatusFromActive()
    }

    func focusActive() {
        guard let currentID, let inst = instances[currentID] else { return }
        containerView.window?.makeFirstResponder(inst.textView)
    }

    func removeDocument(_ document: Document) {
        guard let instance = instances.removeValue(forKey: document.id) else { return }
        if currentID == document.id {
            instance.scrollView.removeFromSuperview()
            currentID = nil
        }
        document.undoManager.removeAllActions()
        instance.textView.delegate = nil
    }

    func persistState() {
        persistCurrentState()
    }

    private func persistCurrentState() {
        guard let currentID, let inst = instances[currentID] else { return }
        let origin = inst.scrollView.contentView.bounds.origin
        inst.document.scrollX = origin.x
        inst.document.scrollY = origin.y
        inst.document.cursorLocation = inst.textView.selectedRange().location
    }

    private func instance(for document: Document) -> EditorInstance {
        if let existing = instances[document.id] { return existing }

        let layoutManager = NSLayoutManager()
        document.storage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = EditorTextView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 600),
            textContainer: textContainer
        )
        textView.document = document
        textView.controller = self
        textView.delegate = self
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = settings.autocorrect
        textView.isAutomaticSpellingCorrectionEnabled = settings.autocorrect
        textView.isContinuousSpellCheckingEnabled = settings.spellCheck
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.drawsBackground = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsCharacterPickerTouchBarItem = false
        textView.contextMenuHandler = { [weak self] point in
            self?.model?.hideEditorFocusAndShowContextMenu(at: point)
        }
        textView.openFilesHandler = { [weak self] (urls: [URL]) in
            guard let self, let model = self.model, let host = model.host else { return }
            for url in urls { host.openURL(url) }
        }
        textView.zoomStepHandler = { [weak self] (zoomIn: Bool) in
            guard let self, let model = self.model else { return }
            if zoomIn { model.zoomIn() } else { model.zoomOut() }
        }
        textView.layoutHandler = { [weak self, weak textView] in
            guard let self, let textView else { return }
            self.layoutTableOverlaysIfNeeded(in: textView)
        }

        let scrollView = NSScrollView(frame: containerView.bounds)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]

        let instance = EditorInstance(document: document, scrollView: scrollView, textView: textView)
        instances[document.id] = instance
        applySettings(to: instance)

        let length = (document.storage.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(document.cursorLocation, length), length: 0))
        return instance
    }

    private func attach(_ instance: EditorInstance) {
        if instance.scrollView.superview !== containerView {
            instance.scrollView.frame = containerView.bounds
            containerView.addSubview(instance.scrollView)
        } else {
            containerView.addSubview(instance.scrollView, positioned: .above, relativeTo: nil)
        }
    }

    private func restoreScrollIfNeeded(_ instance: EditorInstance) {
        guard instance.needsScrollRestore else { return }
        instance.needsScrollRestore = false
        let doc = instance.document
        DispatchQueue.main.async {
            instance.scrollView.layoutSubtreeIfNeeded()
            if let layout = instance.textView.layoutManager, let container = instance.textView.textContainer {
                layout.ensureLayout(for: container)
            }
            let content = instance.scrollView.contentSize
            let used = instance.textView.frame.size
            let maxX = max(0, used.width - content.width)
            let maxY = max(0, used.height - content.height)
            let point = NSPoint(x: min(max(0, doc.scrollX), maxX),
                                y: min(max(0, doc.scrollY), maxY))
            instance.scrollView.contentView.scroll(to: point)
            instance.scrollView.reflectScrolledClipView(instance.scrollView.contentView)
        }
    }

    // MARK: - Aspetto

    func applySettings() {
        currentTheme = Theme.make(dark: settings.effectiveDark)
        containerView.layer?.backgroundColor = currentTheme.nsContent.cgColor
        for instance in instances.values {
            applySettings(to: instance)
        }
    }

    private func applySettings(to instance: EditorInstance) {
        let theme = Theme.make(dark: settings.effectiveDark)
        currentTheme = theme
        let font = settings.editorFont
        let tv = instance.textView
        tv.font = font
        tv.textColor = theme.nsText
        tv.backgroundColor = theme.nsContent
        tv.insertionPointColor = theme.nsCaret
        tv.selectedTextAttributes = [.backgroundColor: theme.nsSelection, .foregroundColor: NSColor.white]
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = max(1, (" " as NSString).size(withAttributes: [.font: font]).width * 8)
        paragraph.tabStops = []
        tv.defaultParagraphStyle = paragraph
        tv.typingAttributes = [.font: font, .foregroundColor: theme.nsText, .paragraphStyle: paragraph]
        tv.isContinuousSpellCheckingEnabled = settings.spellCheck
        tv.isAutomaticSpellingCorrectionEnabled = settings.autocorrect
        tv.isAutomaticTextReplacementEnabled = settings.autocorrect
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        instance.scrollView.backgroundColor = theme.nsContent
        applyWrap(to: instance)
        renderMarkdown(instance)
    }

    private func applyWrap(to instance: EditorInstance) {
        let tv = instance.textView
        let scroll = instance.scrollView
        if settings.wordWrap {
            tv.isHorizontallyResizable = false
            tv.autoresizingMask = [NSView.AutoresizingMask.width]
            tv.textContainer?.widthTracksTextView = true
            let width = max(1, scroll.contentSize.width)
            tv.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            var frame = tv.frame
            frame.size.width = width
            tv.frame = frame
            scroll.hasHorizontalScroller = false
        } else {
            tv.isHorizontallyResizable = true
            tv.autoresizingMask = [NSView.AutoresizingMask.height]
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            scroll.hasHorizontalScroller = true
            DispatchQueue.main.async { [weak self, weak instance] in
                guard let self, let instance else { return }
                self.expandForNoWrap(instance.textView)
            }
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isRenderingMarkdown else { return }
        guard let tv = notification.object as? EditorTextView, let doc = tv.document else { return }
        let ns = tv.string as NSString
        let (line, column) = WindowModel.lineColumn(in: ns, location: tv.selectedRange().location)
        model?.editorTextChanged(doc)
        model?.editorSelectionChanged(doc, line: line, column: column)
        model?.updateFormattingStateFromEditor()
        if !settings.wordWrap {
            expandForNoWrap(tv)
        }
        if !isCommittingTableCell,
           settings.formattingEnabled,
           !(model?.showsMarkdownSource ?? false) {
            scheduleMarkdownRender()
        }
    }

    func textView(_ textView: NSTextView,
                  shouldSetSpellingState value: Int,
                  range affectedCharRange: NSRange) -> Int {
        guard value != 0,
              let instance = instances.values.first(where: { $0.textView === textView }) else {
            return value
        }
        let text = instance.textView.string as NSString
        guard text.length > 0 else { return value }
        for table in MarkdownFormatting.tables(in: text as String) {
            if NSIntersectionRange(table.blockRange, affectedCharRange).length > 0 {
                return 0
            }
        }
        return value
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? EditorTextView, let doc = tv.document else { return }
        let ns = tv.string as NSString
        let (line, column) = WindowModel.lineColumn(in: ns, location: tv.selectedRange().location)
        model?.editorSelectionChanged(doc, line: line, column: column)
        model?.updateFormattingStateFromEditor()
    }

    private func expandForNoWrap(_ tv: EditorTextView) {
        guard let layout = tv.layoutManager, let container = tv.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let needed = used.width + tv.textContainerInset.width * 2 + 4
        if needed > tv.frame.width {
            var frame = tv.frame
            frame.size.width = needed
            tv.frame = frame
        }
    }

    // MARK: - Comandi

    func deleteSelection() {
        guard let tv = activeTextView else { return }
        let range = tv.selectedRange()
        guard range.length > 0 else { return }
        if tv.shouldChangeText(in: range, replacementString: "") {
            tv.textStorage?.replaceCharacters(in: range, with: "")
            tv.didChangeText()
        }
    }

    func insertTimeDate() {
        guard let tv = activeTextView else { return }
        tv.insertText(DateTimeText.now(), replacementRange: tv.selectedRange())
    }

    func printDocument() {
        guard let source = activeTextView else { return }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic

        // Un testo bianco su nero non va stampato: creiamo una vista dedicata.
        let paper = info.paperSize
        let width = max(200, paper.width - info.leftMargin - info.rightMargin)
        let printView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: paper.height))
        let printFont = FontCatalog.font(family: settings.fontFamily, style: settings.fontStyle, size: CGFloat(max(1, settings.fontSize)))
        if settings.formattingEnabled, !(model?.showsMarkdownSource ?? false) {
            let attributed = NSMutableAttributedString(attributedString: source.attributedString())
            let original = attributed.string
            let tables = MarkdownFormatting.tables(in: original)
            if !tables.isEmpty {
                let newline = original.contains("\r\n") ? "\r\n" : "\n"
                let ns = original as NSString
                for table in tables.reversed() {
                    let block = ns.substring(with: table.blockRange)
                    let rows = table.rows
                    var widths = Array(repeating: 0, count: table.columnCount)
                    let displayRows: [[String]] = rows.map { row in
                        row.enumerated().map { index, cell in
                            MarkdownFormatting.attributedCellText(
                                cell,
                                font: printFont,
                                color: NSColor.black
                            ).string
                        }
                    }
                    for row in displayRows {
                        for (index, cell) in row.enumerated() where index < widths.count {
                            widths[index] = max(widths[index], (cell as NSString).length)
                        }
                    }
                    let lines = displayRows.map { row in
                        row.enumerated().map { index, cell -> String in
                            let target = index < widths.count ? widths[index] + 3 : cell.count
                            let padding = max(1, target - (cell as NSString).length)
                            return cell + String(repeating: " ", count: padding)
                        }.joined()
                    }
                    var replacement = lines.joined(separator: newline)
                    if block.hasSuffix("\n") { replacement += newline }
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: printFont,
                        .foregroundColor: NSColor.black
                    ]
                    attributed.replaceCharacters(
                        in: table.blockRange,
                        with: NSAttributedString(string: replacement, attributes: attributes)
                    )
                }
            }
            let range = NSRange(location: 0, length: attributed.length)
            attributed.enumerateAttribute(.foregroundColor, in: range, options: []) { value, range, _ in
                if let color = value as? NSColor, color.alphaComponent > 0.05 {
                    attributed.addAttribute(.foregroundColor, value: NSColor.black, range: range)
                }
            }
            attributed.removeAttribute(.backgroundColor, range: range)
            printView.textStorage?.setAttributedString(attributed)
        } else {
            printView.string = source.string
            printView.font = printFont
            printView.textColor = NSColor.black
        }
        printView.backgroundColor = NSColor.white
        printView.drawsBackground = true
        printView.isEditable = false
        printView.isSelectable = false
        printView.isRichText = false
        printView.textContainerInset = .zero
        printView.textContainer?.lineFragmentPadding = 0
        printView.textContainer?.widthTracksTextView = true
        printView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        printView.minSize = NSSize(width: width, height: 0)
        printView.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        printView.isVerticallyResizable = true
        printView.isHorizontallyResizable = false
        printView.autoresizingMask = [NSView.AutoresizingMask.width]
        if let layout = printView.layoutManager, let container = printView.textContainer {
            layout.ensureLayout(for: container)
        }
        printView.sizeToFit()

        let operation = NSPrintOperation(view: printView, printInfo: info)
        operation.jobTitle = activeDocumentName
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    private var activeDocumentName: String {
        guard let currentID, let doc = instances[currentID]?.document else { return L.t("Documento", "Document") }
        return doc.displayName
    }

    func pageSetup() {
        NSPageLayout().runModal(with: NSPrintInfo.shared)
    }

    // MARK: - Ricerca

    private func ranges(query: String,
                        in document: Document,
                        matchCase: Bool,
                        wholeWord: Bool) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let escaped = NSRegularExpression.escapedPattern(for: query)
        let pattern = wholeWord ? "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])" : escaped
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: matchCase ? [] : [.caseInsensitive]) else {
            return []
        }
        let text = document.storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, options: [], range: full).map(\.range)
    }

    func matchCount(query: String, in document: Document, matchCase: Bool, wholeWord: Bool) -> Int {
        ranges(query: query, in: document, matchCase: matchCase, wholeWord: wholeWord).count
    }

    @discardableResult
    func findNext(query: String,
                  in document: Document,
                  matchCase: Bool,
                  wholeWord: Bool) -> Bool {
        guard let tv = instances[document.id]?.textView else { return false }
        let matches = ranges(query: query, in: document, matchCase: matchCase, wholeWord: wholeWord)
        guard !matches.isEmpty else { return false }
        let selection = tv.selectedRange()
        let start = NSMaxRange(selection)
        let target = matches.first { $0.location >= start } ?? matches[0]
        tv.setSelectedRange(target)
        tv.scrollRangeToVisible(target)
        return true
    }

    @discardableResult
    func findPrevious(query: String,
                      in document: Document,
                      matchCase: Bool,
                      wholeWord: Bool) -> Bool {
        guard let tv = instances[document.id]?.textView else { return false }
        let matches = ranges(query: query, in: document, matchCase: matchCase, wholeWord: wholeWord)
        guard !matches.isEmpty else { return false }
        let start = tv.selectedRange().location
        let target = matches.last { NSMaxRange($0) <= start } ?? matches[matches.count - 1]
        tv.setSelectedRange(target)
        tv.scrollRangeToVisible(target)
        return true
    }

    @discardableResult
    func replaceCurrent(query: String,
                        replacement: String,
                        in document: Document,
                        matchCase: Bool,
                        wholeWord: Bool) -> Bool {
        guard let tv = instances[document.id]?.textView else { return false }
        let matches = ranges(query: query, in: document, matchCase: matchCase, wholeWord: wholeWord)
        guard !matches.isEmpty else { return false }

        let selection = tv.selectedRange()
        var target = matches.first { NSEqualRanges($0, selection) }
        if target == nil {
            _ = findNext(query: query, in: document, matchCase: matchCase, wholeWord: wholeWord)
            let newSelection = tv.selectedRange()
            target = matches.first { NSEqualRanges($0, newSelection) }
        }
        guard let range = target else { return false }

        if tv.shouldChangeText(in: range, replacementString: replacement) {
            tv.textStorage?.replaceCharacters(in: range, with: replacement)
            tv.didChangeText()
            let caret = NSRange(location: range.location + (replacement as NSString).length, length: 0)
            tv.setSelectedRange(caret)
            _ = findNext(query: query, in: document, matchCase: matchCase, wholeWord: wholeWord)
            return true
        }
        return false
    }

    @discardableResult
    func replaceAll(query: String,
                    replacement: String,
                    in document: Document,
                    matchCase: Bool,
                    wholeWord: Bool) -> Bool {
        guard let tv = instances[document.id]?.textView else { return false }
        let matches = ranges(query: query, in: document, matchCase: matchCase, wholeWord: wholeWord)
        guard !matches.isEmpty else { return false }
        let original = document.storage.string as NSString
        let mutable = NSMutableString(string: original)
        for range in matches.reversed() {
            mutable.replaceCharacters(in: range, with: replacement)
        }
        let full = NSRange(location: 0, length: original.length)
        if tv.shouldChangeText(in: full, replacementString: mutable as String) {
            tv.textStorage?.replaceCharacters(in: full, with: mutable as String)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            return true
        }
        return false
    }

    // MARK: - Formattazione Markdown

    var isMarkdownFormatted: Bool {
        settings.formattingEnabled && !(model?.showsMarkdownSource ?? false)
    }

    var isTableInteractionActive: Bool {
        guard let currentID, let instance = instances[currentID] else { return false }
        if instance.tableOverlays.contains(where: \.hasActiveEditor) { return true }
        return instance.textView.window?.firstResponder is TableOverlayView
    }

    func formattingState(for document: Document) -> MarkdownFormattingState {
        guard let instance = instances[document.id] else { return MarkdownFormattingState() }
        var state = MarkdownFormatting.state(for: document.storage.string,
                                             selection: instance.textView.selectedRange())
        if let selection = instance.tableSelection {
            state.inTable = true
            state.tableRow = selection.row
            state.tableColumn = selection.column
        }
        return state
    }

    func refreshMarkdownRendering() {
        for instance in instances.values {
            renderMarkdown(instance)
        }
        model?.updateFormattingStateFromEditor()
    }

    private func renderMarkdown(_ instance: EditorInstance) {
        guard let storage = instance.textView.textStorage else { return }
        let document = instance.document
        let tv = instance.textView
        let wasModified = document.isModified
        let selection = tv.selectedRange()
        let origin = instance.scrollView.contentView.bounds.origin
        isRenderingMarkdown = true
        MarkdownFormatting.render(
            textView: tv,
            string: storage.string,
            baseFont: settings.editorFont,
            theme: currentTheme,
            formatted: isMarkdownFormatted
        )
        isRenderingMarkdown = false
        let length = (storage.string as NSString).length
        let location = min(selection.location, length)
        tv.setSelectedRange(NSRange(location: location,
                                    length: min(selection.length, max(0, length - location))))
        instance.scrollView.contentView.scroll(to: origin)
        instance.scrollView.reflectScrolledClipView(instance.scrollView.contentView)
        if !wasModified {
            document.restoreModifiedState(false)
        }
        updateTableOverlays(in: instance)
        tv.needsDisplay = true
        if model?.activeDocument?.id == document.id {
            model?.updateFormattingStateFromEditor()
        }
    }

    /// Continua elenchi puntati/numerati quando si preme Invio; su una voce
    /// vuota esce dall'elenco.
    func continueListOnNewline(in textView: EditorTextView) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let ns = textView.string as NSString
        let caret = min(selection.location, ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
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
        let content = ns.substring(with: contentRange)
        guard let prefix = MarkdownFormatting.blockPrefix(in: content),
              prefix.listKind != nil,
              caret >= lineRange.location + prefix.length else {
            return false
        }
        let afterPrefix = String(content.dropFirst(prefix.length))
        let isEmptyItem = afterPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if isEmptyItem {
            textView.insertText("\n", replacementRange: contentRange)
            return true
        }

        guard let continuation = MarkdownFormatting.continuedListPrefix(for: prefix) else {
            return false
        }
        textView.insertText("\n" + continuation,
                            replacementRange: NSRange(location: caret, length: 0))
        return true
    }

    // MARK: - Tabelle

    func textViewWasClicked(_ textView: EditorTextView) {
        guard let instance = instances.values.first(where: { $0.textView === textView }),
              instance.tableSelection != nil else { return }
        instance.tableSelection = nil
        for overlay in instance.tableOverlays {
            overlay.clearSelection()
        }
        model?.updateFormattingStateFromEditor()
    }

    private func layoutTableOverlaysIfNeeded(in textView: EditorTextView) {
        guard let instance = instances.values.first(where: { $0.textView === textView }) else { return }
        guard isMarkdownFormatted, !instance.tableOverlays.isEmpty else { return }
        guard !instance.tableOverlays.contains(where: \.hasActiveEditor) else { return }
        let width = textView.textContainer?.size.width ?? textView.bounds.width
        guard abs(instance.lastOverlayWidth - width) > 0.5 else { return }
        updateTableOverlays(in: instance)
    }

    private func updateTableOverlays(in instance: EditorInstance) {
        guard !isUpdatingTableOverlays else { return }
        isUpdatingTableOverlays = true
        defer { isUpdatingTableOverlays = false }

        let tv = instance.textView
        for overlay in instance.tableOverlays {
            overlay.removeFromSuperview()
        }
        instance.tableOverlays.removeAll()

        let pending = pendingTableSelection
        pendingTableSelection = nil

        guard isMarkdownFormatted,
              let layoutManager = tv.layoutManager,
              let container = tv.textContainer else {
            instance.tableSelection = nil
            instance.lastOverlayWidth = -1
            return
        }

        let text = tv.string
        let tables = MarkdownFormatting.tables(in: text)
        guard !tables.isEmpty else {
            instance.tableSelection = nil
            instance.lastOverlayWidth = -1
            return
        }

        layoutManager.ensureLayout(for: container)
        let origin = tv.textContainerOrigin
        let font = settings.editorFont
        let rowHeight = MarkdownFormatting.tableRowHeight(for: font)
        let availableWidth = max(140, container.size.width)
        let totalLength = (text as NSString).length

        for (index, table) in tables.enumerated() {
            guard table.blockRange.length > 0,
                  NSMaxRange(table.blockRange) <= totalLength,
                  table.rows.count > 0 else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: table.blockRange,
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let overlay = TableOverlayView(table: table,
                                           index: index,
                                           font: font,
                                           theme: currentTheme)
            overlay.delegate = self
            let width = overlay.measure(availableWidth: availableWidth)
            let height = CGFloat(max(1, table.rows.count)) * rowHeight
            overlay.frame = NSRect(x: origin.x + rect.origin.x,
                                   y: origin.y + rect.origin.y,
                                   width: max(80, width),
                                   height: height)
            tv.addSubview(overlay)
            instance.tableOverlays.append(overlay)
        }

        instance.lastOverlayWidth = availableWidth

        if let pending,
           let overlay = instance.tableOverlays.first(where: {
               $0.table.blockRange.location == pending.selection.tableStart
           }) {
            overlay.select(row: pending.selection.row, column: pending.selection.column)
            instance.tableSelection = pending.selection
            if pending.editing {
                DispatchQueue.main.async { [weak overlay] in
                    guard let overlay, overlay.superview != nil else { return }
                    overlay.beginEditing(row: pending.selection.row,
                                         column: pending.selection.column)
                }
            }
        } else if let existing = instance.tableSelection,
                  let overlay = instance.tableOverlays.first(where: {
                      $0.table.blockRange.location == existing.tableStart
                  }) {
            overlay.select(row: existing.row, column: existing.column)
        } else {
            instance.tableSelection = nil
        }
    }

    /// Riscrive una tabella Markdown mantenendo separatore e fine riga.
    @discardableResult
    private func replaceTable(_ table: MarkdownTable,
                              rows: [[String]],
                              in instance: EditorInstance) -> Bool {
        guard !rows.isEmpty else { return false }
        let tv = instance.textView
        let ns = tv.string as NSString
        guard table.blockRange.length > 0,
              NSMaxRange(table.blockRange) <= ns.length else { return false }

        let original = ns.substring(with: table.blockRange)
        let newline = original.contains("\r\n") ? "\r\n" : "\n"
        let hasTrailingNewline = original.hasSuffix("\n") || original.hasSuffix("\r")
        let columnCount = max(1, rows[0].count)

        func renderRow(_ cells: [String]) -> String {
            var values = cells
            while values.count < columnCount { values.append("") }
            if values.count > columnCount { values = Array(values.prefix(columnCount)) }
            let escaped = values.map { value -> String in
                value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
            }
            return "| " + escaped.joined(separator: " | ") + " |"
        }

        var separatorCells = MarkdownFormatting.parseTableCells(
            ns.substring(with: table.separatorRange)
        )
        while separatorCells.count < columnCount { separatorCells.append("---") }
        if separatorCells.count > columnCount {
            separatorCells = Array(separatorCells.prefix(columnCount))
        }
        separatorCells = separatorCells.map { $0.isEmpty ? "---" : $0 }

        var lines = [renderRow(rows[0])]
        lines.append("| " + separatorCells.joined(separator: " | ") + " |")
        for row in rows.dropFirst() {
            lines.append(renderRow(row))
        }
        var replacement = lines.joined(separator: newline)
        if hasTrailingNewline { replacement += newline }
        guard replacement != original else { return false }
        guard tv.shouldChangeText(in: table.blockRange, replacementString: replacement) else {
            return false
        }
        tv.textStorage?.replaceCharacters(in: table.blockRange, with: replacement)
        tv.didChangeText()
        return true
    }

    /// Tabella sotto il cursore o selezionata con il mouse nella griglia.
    private func activeTableContext() -> (instance: EditorInstance, table: MarkdownTable,
                                           row: Int, column: Int)? {
        guard let currentID, let instance = instances[currentID] else { return nil }
        let text = instance.textView.string
        let tables = MarkdownFormatting.tables(in: text)
        guard !tables.isEmpty else { return nil }
        let ns = text as NSString

        if let selection = instance.tableSelection,
           let table = tables.first(where: { $0.blockRange.location == selection.tableStart }) {
            return (instance,
                    table,
                    min(max(0, selection.row), max(0, table.rows.count - 1)),
                    min(max(0, selection.column), max(0, table.columnCount - 1)))
        }

        let caret = min(instance.textView.selectedRange().location, ns.length)
        guard let table = tables.first(where: {
            NSLocationInRange(caret, $0.blockRange) || caret == NSMaxRange($0.blockRange)
        }) else { return nil }

        let offset = max(0, caret - table.headerRange.location)
        let headerPrefix = ns.substring(with: NSRange(
            location: table.headerRange.location,
            length: min(offset, table.headerRange.length)
        ))
        let pipesInHeader = headerPrefix.filter { $0 == "|" }.count
        var row = 0
        var linePrefix = headerPrefix
        if NSLocationInRange(caret, table.separatorRange) {
            row = 1
        } else if let dataIndex = table.dataRanges.firstIndex(where: {
            NSLocationInRange(caret, $0)
        }) {
            row = dataIndex + 1
            let lineStart = table.dataRanges[dataIndex].location
            linePrefix = ns.substring(with: NSRange(location: lineStart,
                                                    length: max(0, caret - lineStart)))
        }
        let pipeCount = row == 0 ? pipesInHeader : linePrefix.filter { $0 == "|" }.count
        let column = min(max(0, pipeCount - 1), max(0, table.columnCount - 1))
        return (instance, table, row, column)
    }

    private func applyTableSelection(_ selection: TableCellSelection,
                                     to instance: EditorInstance) {
        pendingTableSelection = (selection, false)
        instance.tableSelection = selection
    }

    private func finishTableEdit(_ instance: EditorInstance) {
        renderMarkdown(instance)
        model?.updateFormattingStateFromEditor()
    }

    func addTableRow(before: Bool) {
        guard let context = activeTableContext() else { return }
        var rows = context.table.rows
        let targetRow = context.row == 0 ? 1 : context.row
        let insertion = before ? max(1, targetRow) : min(rows.count, targetRow + 1)
        rows.insert(Array(repeating: "", count: context.table.columnCount),
                    at: min(insertion, rows.count))
        let newRow = min(insertion, rows.count - 1)
        guard replaceTable(context.table, rows: rows, in: context.instance) else { return }
        applyTableSelection(TableCellSelection(tableStart: context.table.blockRange.location,
                                               row: newRow,
                                               column: context.column),
                            to: context.instance)
        finishTableEdit(context.instance)
    }

    func addTableColumn(before: Bool) {
        guard let context = activeTableContext() else { return }
        var rows = context.table.rows
        let insertion = before ? context.column : context.column + 1
        for index in rows.indices {
            var row = rows[index]
            while row.count < context.table.columnCount { row.append("") }
            row.insert("", at: min(insertion, row.count))
            rows[index] = row
        }
        guard replaceTable(context.table, rows: rows, in: context.instance) else { return }
        let newColumn = min(insertion, context.table.columnCount)
        applyTableSelection(TableCellSelection(tableStart: context.table.blockRange.location,
                                               row: context.row,
                                               column: newColumn),
                            to: context.instance)
        finishTableEdit(context.instance)
    }

    func deleteTableRow() {
        guard let context = activeTableContext() else { return }
        guard context.table.rows.count > 1 else { return }
        var rows = context.table.rows
        let target = context.row == 0 ? min(1, rows.count - 1) : context.row
        guard target > 0, target < rows.count else { return }
        rows.remove(at: target)
        guard replaceTable(context.table, rows: rows, in: context.instance) else { return }
        applyTableSelection(TableCellSelection(tableStart: context.table.blockRange.location,
                                               row: min(target, rows.count - 1),
                                               column: context.column),
                            to: context.instance)
        finishTableEdit(context.instance)
    }

    func deleteTableColumn() {
        guard let context = activeTableContext() else { return }
        guard context.table.columnCount > 1 else { return }
        var rows = context.table.rows
        for index in rows.indices {
            guard context.column < rows[index].count else { continue }
            rows[index].remove(at: context.column)
        }
        guard replaceTable(context.table, rows: rows, in: context.instance) else { return }
        applyTableSelection(TableCellSelection(tableStart: context.table.blockRange.location,
                                               row: context.row,
                                               column: min(context.column,
                                                           context.table.columnCount - 2)),
                            to: context.instance)
        finishTableEdit(context.instance)
    }

    func insertTableFromPicker(rows: Int, columns: Int) {
        insertTable(rows: rows, columns: columns)
    }

    /// Seleziona un intervallo rettangolare di celle nella prima tabella.
    func selectTableRange(row: Int, column: Int, toRow: Int, toColumn: Int) {
        guard let currentID, let instance = instances[currentID],
              let overlay = instance.tableOverlays.first else { return }
        overlay.selectRange(anchor: TableCellTarget(row: row, column: column),
                            focus: TableCellTarget(row: toRow, column: toColumn))
        instance.tableSelection = TableCellSelection(
            tableStart: overlay.table.blockRange.location,
            row: row,
            column: column
        )
        model?.updateFormattingStateFromEditor()
    }

    /// Seleziona (e opzionalmente apre in modifica) una cella della prima
    /// tabella del documento attivo. Usato anche dai test e dalle demo.
    func focusTableCell(row: Int, column: Int, editing: Bool, tableStart: Int? = nil) {
        guard let currentID, let instance = instances[currentID] else { return }
        let overlay = instance.tableOverlays.first(where: {
            tableStart == nil || $0.table.blockRange.location == tableStart
        }) ?? instance.tableOverlays.first
        guard let overlay else { return }
        overlay.select(row: row, column: column)
        if editing {
            overlay.beginEditing(row: row, column: column)
        }
        instance.tableSelection = TableCellSelection(
            tableStart: overlay.table.blockRange.location,
            row: row,
            column: column
        )
        model?.updateFormattingStateFromEditor()
    }

    /// Aggiorna una cella e riscrive il Markdown, come il campo in-cell.
    func updateTableCell(tableStart: Int,
                         row: Int,
                         column: Int,
                         text: String,
                         moveTo target: TableCellTarget? = nil) {
        guard let currentID, let instance = instances[currentID] else { return }
        let current = MarkdownFormatting.tables(in: instance.textView.string)
        guard let table = current.first(where: { $0.blockRange.location == tableStart }),
              row >= 0, row < table.rows.count,
              column >= 0, column < table.rows[row].count else { return }

        var rows = table.rows
        if rows[row][column] != text {
            rows[row][column] = text
        }
        let clampedColumn = min(max(0, column), max(0, table.columnCount - 1))
        let selection: TableCellSelection
        if let target {
            selection = TableCellSelection(tableStart: tableStart,
                                           row: min(max(0, target.row), max(0, rows.count - 1)),
                                           column: min(max(0, target.column),
                                                       max(0, table.columnCount - 1)))
        } else {
            selection = TableCellSelection(tableStart: tableStart,
                                           row: row,
                                           column: clampedColumn)
        }
        pendingTableSelection = (selection, target != nil)
        isCommittingTableCell = true
        let changed = replaceTable(table, rows: rows, in: instance)
        isCommittingTableCell = false
        if changed {
            renderMarkdown(instance)
        } else {
            pendingTableSelection = nil
            if let currentOverlay = instance.tableOverlays.first(where: {
                $0.table.blockRange.location == tableStart
            }) {
                currentOverlay.select(row: selection.row, column: selection.column)
            }
            instance.tableSelection = selection
        }
        if target == nil {
            let source = instance.textView.string as NSString
            let caret = instance.textView.selectedRange().location
            for table in MarkdownFormatting.tables(in: source as String)
                where NSLocationInRange(caret, table.blockRange) {
                let destination = min(NSMaxRange(table.blockRange), source.length)
                instance.textView.setSelectedRange(NSRange(location: destination, length: 0))
                break
            }
            instance.textView.window?.makeFirstResponder(instance.textView)
        }
        model?.updateFormattingStateFromEditor()
    }

    private func scheduleMarkdownRender() {
        markdownRenderWorkItem?.cancel()
        guard let id = currentID else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let instance = self.instances[id] else { return }
            self.renderMarkdown(instance)
            self.model?.updateFormattingStateFromEditor()
        }
        markdownRenderWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
    }

    private func afterMarkdownEdit(selection: NSRange) {
        guard let tv = activeTextView, let doc = tv.document, let instance = instances[doc.id] else { return }
        tv.setSelectedRange(selection)
        renderMarkdown(instance)
        model?.updateFormattingStateFromEditor()
    }

    @discardableResult
    private func replaceText(in range: NSRange, with replacement: String, selection: NSRange) -> Bool {
        guard let tv = activeTextView, let storage = tv.textStorage else { return false }
        guard NSMaxRange(range) <= storage.length else { return false }
        guard tv.shouldChangeText(in: range, replacementString: replacement) else { return false }
        storage.replaceCharacters(in: range, with: replacement)
        tv.didChangeText()
        tv.setSelectedRange(selection)
        return true
    }

    // MARK: Inline

    func toggleBold() { toggleInline("**") }
    func toggleItalic() { toggleInline("*") }
    func toggleStrikethrough() { toggleInline("~~") }

    private func toggleInline(_ marker: String) {
        guard let tv = activeTextView else { return }
        let ns = tv.string as NSString
        var selection = tv.selectedRange()
        if selection.length == 0 {
            // Con il cursore su una parola formatta quella; su uno spazio
            // o una riga vuota non inserisce marcatori vuoti (****, ~~~~).
            guard let word = wordRange(at: selection.location, in: ns) else { return }
            selection = word
        }
        let markerLength = marker.utf16.count
        guard NSMaxRange(selection) <= ns.length else { return }
        let selected = ns.substring(with: selection)
        var before = ""
        var after = ""
        if selection.location >= markerLength {
            before = ns.substring(with: NSRange(location: selection.location - markerLength, length: markerLength))
        }
        if NSMaxRange(selection) + markerLength <= ns.length {
            after = ns.substring(with: NSRange(location: NSMaxRange(selection), length: markerLength))
        }
        if before == marker && after == marker {
            let range = NSRange(location: selection.location - markerLength,
                                length: selection.length + markerLength * 2)
            let newSelection = NSRange(location: selection.location - markerLength, length: selection.length)
            if replaceText(in: range, with: selected, selection: newSelection) {
                afterMarkdownEdit(selection: newSelection)
            }
        } else if selected.hasPrefix(marker), selected.hasSuffix(marker), selected.utf16.count >= markerLength * 2 {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            let newSelection = NSRange(location: selection.location, length: inner.utf16.count)
            if replaceText(in: selection, with: inner, selection: newSelection) {
                afterMarkdownEdit(selection: newSelection)
            }
        } else {
            let newSelection = NSRange(location: selection.location + markerLength, length: selection.length)
            if replaceText(in: selection, with: marker + selected + marker, selection: newSelection) {
                afterMarkdownEdit(selection: newSelection)
            }
        }
    }

    private func wordRange(at location: Int, in ns: NSString) -> NSRange? {
        guard ns.length > 0 else { return nil }
        let wordSet = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_-'’"))
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < ns.length else { return false }
            guard let scalar = UnicodeScalar(ns.character(at: index)) else { return false }
            return wordSet.contains(scalar)
        }
        var probe = min(max(0, location), ns.length)
        if probe >= ns.length || !isWord(probe) {
            probe -= 1
        }
        guard isWord(probe) else { return nil }
        var start = probe
        var end = probe
        while start > 0, isWord(start - 1) { start -= 1 }
        while end + 1 < ns.length, isWord(end + 1) { end += 1 }
        return NSRange(location: start, length: end - start + 1)
    }

    // MARK: Blocchi

    private struct LineTarget {
        var range: NSRange
        var oldPrefixLength: Int
        var oldIndent: String
        var rawPrefix: String
        var contentAfterPrefix: String
        var newline: String
        var newPrefix = ""
        var headingLevel: Int?
        var listKind: MarkdownListKind?
    }

    private func selectedLineTarget() -> (target: NSRange, selection: NSRange, lines: [LineTarget])? {
        guard let tv = activeTextView else { return nil }
        let ns = tv.string as NSString
        let selection = tv.selectedRange()
        let startLocation = min(selection.location, ns.length)
        let startLine = ns.lineRange(for: NSRange(location: startLocation, length: 0))
        let endProbe = selection.length > 0
            ? min(NSMaxRange(selection) - 1, max(0, ns.length - 1))
            : startLocation
        let endLine = ns.length > 0
            ? ns.lineRange(for: NSRange(location: max(0, endProbe), length: 0))
            : NSRange(location: 0, length: 0)
        let target = NSRange(location: startLine.location,
                             length: max(0, NSMaxRange(endLine) - startLine.location))
        var lines: [LineTarget] = []
        var index = target.location
        while index < NSMaxRange(target) {
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
            let content = ns.substring(with: contentRange)
            let newlineRange = NSRange(location: NSMaxRange(contentRange),
                                       length: lineRange.length - contentLength)
            let newline = ns.substring(with: newlineRange)
            let prefix = MarkdownFormatting.blockPrefix(in: content)
            let prefixLength = min(prefix?.length ?? 0, content.utf16.count)
            let after = String(content.dropFirst(prefixLength))
            lines.append(LineTarget(
                range: lineRange,
                oldPrefixLength: prefixLength,
                oldIndent: prefix?.indent ?? "",
                rawPrefix: prefix?.rawPrefix ?? "",
                contentAfterPrefix: after,
                newline: newline,
                headingLevel: prefix?.headingLevel,
                listKind: prefix?.listKind
            ))
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
        if lines.isEmpty {
            lines.append(LineTarget(
                range: NSRange(location: target.location, length: 0),
                oldPrefixLength: 0,
                oldIndent: "",
                rawPrefix: "",
                contentAfterPrefix: "",
                newline: "",
                headingLevel: nil,
                listKind: nil
            ))
        }
        return (target, selection, lines)
    }

    @discardableResult
    private func applyLineTransform(_ transform: (Int, inout LineTarget) -> Void) -> Bool {
        guard let context = selectedLineTarget() else { return false }
        var lines = context.lines
        for index in lines.indices {
            transform(index, &lines[index])
        }

        var newBlock = ""
        var oldStarts: [Int] = []
        var newStarts: [Int] = []
        for line in lines {
            oldStarts.append(line.range.location - context.target.location)
            newStarts.append(newBlock.utf16.count)
            newBlock += line.newPrefix + line.contentAfterPrefix + line.newline
        }

        let oldSelectionStart = context.selection.location - context.target.location
        let oldSelectionEnd = NSMaxRange(context.selection) - context.target.location
        let newLength = newBlock.utf16.count

        func mapOffset(_ offset: Int) -> Int {
            if offset <= 0 { return 0 }
            if offset >= context.target.length { return newLength }
            guard let lineIndex = lines.indices.last(where: { oldStarts[$0] <= offset }) else {
                return min(offset, newLength)
            }
            let relative = offset - oldStarts[lineIndex]
            let oldPrefix = lines[lineIndex].oldPrefixLength
            let newPrefix = lines[lineIndex].newPrefix.utf16.count
            let newRelative = relative < oldPrefix
                ? min(relative, newPrefix)
                : relative + newPrefix - oldPrefix
            return min(max(0, newStarts[lineIndex] + newRelative), newLength)
        }

        let mappedStart = mapOffset(oldSelectionStart)
        let mappedEnd = mapOffset(oldSelectionEnd)
        let newSelection = NSRange(location: context.target.location + mappedStart,
                                   length: max(0, mappedEnd - mappedStart))
        guard replaceText(in: context.target, with: newBlock, selection: newSelection) else { return false }
        afterMarkdownEdit(selection: newSelection)
        return true
    }

    func setHeadingLevel(_ level: Int) {
        guard let context = selectedLineTarget() else { return }
        let allAlready = !context.lines.isEmpty && context.lines.allSatisfy {
            ($0.headingLevel ?? 0) == level
        }
        let targetLevel = (level > 0 && allAlready) ? 0 : level
        _ = applyLineTransform { _, line in
            if line.headingLevel != nil {
                line.newPrefix = targetLevel > 0 ? String(repeating: "#", count: targetLevel) + " " : ""
            } else if line.listKind != nil {
                line.newPrefix = targetLevel > 0
                    ? String(repeating: "#", count: targetLevel) + " "
                    : line.rawPrefix
            } else {
                line.newPrefix = targetLevel > 0 ? String(repeating: "#", count: targetLevel) + " " : ""
            }
        }
    }

    func toggleList(_ kind: MarkdownListKind) {
        guard let context = selectedLineTarget() else { return }
        let allAlready = !context.lines.isEmpty && context.lines.allSatisfy { $0.listKind == kind }
        var counter = 1
        _ = applyLineTransform { _, line in
            let indent = line.headingLevel != nil ? "" : line.oldIndent
            if allAlready {
                line.newPrefix = indent
            } else {
                switch kind {
                case .bullet:
                    line.newPrefix = indent + "- "
                case .numbered:
                    line.newPrefix = indent + "\(counter). "
                    counter += 1
                }
            }
        }
    }

    func indentList(outdent: Bool) {
        guard let context = selectedLineTarget() else { return }
        let hasListLine = context.lines.contains { $0.listKind != nil }
        guard hasListLine else { return }
        _ = applyLineTransform { _, line in
            guard line.listKind != nil else {
                line.newPrefix = line.rawPrefix
                return
            }
            var indent = line.oldIndent
            if outdent {
                if indent.hasPrefix("  ") {
                    indent.removeFirst(2)
                } else if !indent.isEmpty {
                    indent.removeFirst()
                }
            } else {
                indent += "  "
            }
            let suffix = line.oldIndent.isEmpty
                ? line.rawPrefix
                : String(line.rawPrefix.dropFirst(line.oldIndent.count))
            line.newPrefix = indent + suffix
        }
    }

    // MARK: Cancella / link

    func clearFormatting() {
        guard let tv = activeTextView else { return }
        let ns = tv.string as NSString
        let selection = tv.selectedRange()
        let target = selection.length > 0 ? selection : NSRange(location: 0, length: ns.length)
        guard target.length > 0 else { return }
        let info = MarkdownFormatting.parse(tv.string)
        var units: [unichar] = []
        for index in target.location..<NSMaxRange(target) {
            if index < info.masks.count,
               info.masks[index].contains(.hidden) || info.masks[index].contains(.listMarker) { continue }
            units.append(ns.character(at: index))
        }
        let cleaned = String(decoding: units, as: UTF16.self)
        let newSelection = NSRange(location: target.location, length: 0)
        if replaceText(in: target, with: cleaned, selection: newSelection) {
            afterMarkdownEdit(selection: newSelection)
        }
    }

    func insertLink() {
        guard let tv = activeTextView else { return }
        let selection = tv.selectedRange()
        let ns = tv.string as NSString
        let selected = selection.length > 0 ? ns.substring(with: selection) : ""

        let alert = NSAlert()
        alert.messageText = L.t("Inserisci link", "Insert link")
        alert.addButton(withTitle: L.t("Inserisci", "Insert"))
        alert.addButton(withTitle: L.t("Annulla", "Cancel"))
        alert.alertStyle = .informational

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 64))
        let labelTitle = NSTextField(labelWithString: L.t("Testo:", "Text:"))
        labelTitle.frame = NSRect(x: 0, y: 38, width: 74, height: 20)
        labelTitle.alignment = .right
        let urlTitle = NSTextField(labelWithString: "URL:")
        urlTitle.frame = NSRect(x: 0, y: 6, width: 74, height: 20)
        urlTitle.alignment = .right
        let labelField = NSTextField(frame: NSRect(x: 82, y: 36, width: 290, height: 24))
        labelField.stringValue = selected.isEmpty ? L.t("testo", "text") : selected
        let urlField = NSTextField(frame: NSRect(x: 82, y: 4, width: 290, height: 24))
        urlField.placeholderString = "https://"
        accessory.addSubview(labelTitle)
        accessory.addSubview(urlTitle)
        accessory.addSubview(labelField)
        accessory.addSubview(urlField)
        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let safeLabel = (label.isEmpty ? url : label)
            .replacingOccurrences(of: "]", with: "\\]")
        let safeURL = url.replacingOccurrences(of: ")", with: "%29")
        let markdown = "[\(safeLabel)](\(safeURL))"
        let target = selection.length > 0 ? selection : NSRange(location: selection.location, length: 0)
        let newSelection = NSRange(location: target.location + 1, length: safeLabel.utf16.count)
        if replaceText(in: target, with: markdown, selection: newSelection) {
            afterMarkdownEdit(selection: newSelection)
        }
    }

    // MARK: Tabelle

    func insertTable(rows: Int, columns: Int) {
        guard let tv = activeTextView else { return }
        let rowCount = max(1, min(rows, 50))
        let columnCount = max(1, min(columns, 12))
        let header = "| " + Array(repeating: "  ", count: columnCount).joined(separator: " | ") + " |"
        let separator = "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |"
        var lines = [header, separator]
        for _ in 0..<rowCount {
            lines.append("| " + Array(repeating: "  ", count: columnCount).joined(separator: " | ") + " |")
        }
        let table = lines.joined(separator: "\n")
        let selection = tv.selectedRange()
        let target = selection.length > 0 ? selection : NSRange(location: selection.location, length: 0)
        let source = tv.string as NSString
        let prefix: String
        if target.location > 0 {
            let previous = source.substring(with: NSRange(location: target.location - 1, length: 1))
            prefix = previous == "\n" || previous == "\r" ? "" : "\n"
        } else {
            prefix = ""
        }
        let suffix: String
        let afterSelection = NSMaxRange(target)
        if afterSelection < source.length {
            let next = source.substring(with: NSRange(location: afterSelection, length: 1))
            suffix = next == "\n" || next == "\r" ? "" : "\n"
        } else {
            suffix = "\n"
        }
        let insertion = prefix + table + suffix
        let caret = target.location + prefix.utf16.count
        if replaceText(in: target, with: insertion,
                       selection: NSRange(location: caret, length: 0)) {
            pendingTableSelection = (TableCellSelection(tableStart: caret,
                                                       row: 0, column: 0), false)
            afterMarkdownEdit(selection: NSRange(location: caret, length: 0))
            focusTableCell(row: 0, column: 0, editing: true, tableStart: caret)
        }
    }

    func showInsertTableDialog() {
        let alert = NSAlert()
        alert.messageText = L.t("Inserisci tabella", "Insert table")
        alert.addButton(withTitle: L.t("Inserisci", "Insert"))
        alert.addButton(withTitle: L.t("Annulla", "Cancel"))
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 66))
        let rowsLabel = NSTextField(labelWithString: L.t("Righe:", "Rows:"))
        rowsLabel.frame = NSRect(x: 0, y: 38, width: 64, height: 20)
        rowsLabel.alignment = .right
        let columnsLabel = NSTextField(labelWithString: L.t("Colonne:", "Columns:"))
        columnsLabel.frame = NSRect(x: 0, y: 6, width: 64, height: 20)
        columnsLabel.alignment = .right
        let rowsField = NSTextField(frame: NSRect(x: 72, y: 36, width: 60, height: 24))
        rowsField.stringValue = "3"
        let columnsField = NSTextField(frame: NSRect(x: 72, y: 4, width: 60, height: 24))
        columnsField.stringValue = "3"
        accessory.addSubview(rowsLabel)
        accessory.addSubview(columnsLabel)
        accessory.addSubview(rowsField)
        accessory.addSubview(columnsField)
        alert.accessoryView = accessory
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        insertTable(rows: Int(rowsField.stringValue) ?? 3,
                    columns: Int(columnsField.stringValue) ?? 3)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL {
            NSWorkspace.shared.open(url)
            return true
        }
        if let string = link as? String, let url = URL(string: string) {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }
}

extension EditorController: TableOverlayDelegate {
    func tableOverlay(_ overlay: TableOverlayView, didSelectRow row: Int, column: Int) {
        guard let instance = instances.values.first(where: {
            $0.tableOverlays.contains(where: { $0 === overlay })
        }) else { return }
        instance.tableSelection = TableCellSelection(tableStart: overlay.table.blockRange.location,
                                                     row: row,
                                                     column: column)
        model?.updateFormattingStateFromEditor()
    }

    func tableOverlay(_ overlay: TableOverlayView,
                      didCommit text: String,
                      row: Int,
                      column: Int,
                      moveTo target: TableCellTarget?) {
        updateTableCell(tableStart: overlay.table.blockRange.location,
                        row: row,
                        column: column,
                        text: text,
                        moveTo: target)
    }

    func tableOverlay(_ overlay: TableOverlayView, perform action: TableOverlayAction) {
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
    }
}

enum DateTimeText {
    static func now() -> String {
        let now = Date()
        let locale = Locale.current
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "jm", options: 0, locale: locale) ?? "HH:mm"
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) ?? "dd/MM/yyyy"
        return "\(timeFormatter.string(from: now)) \(dateFormatter.string(from: now))"
    }
}
