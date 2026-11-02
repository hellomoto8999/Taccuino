import AppKit
import Foundation

final class Document: ObservableObject, Identifiable {
    let id = UUID()
    let storage: NSTextStorage
    let undoManager: UndoManager

    @Published private(set) var fileURL: URL?
    @Published private(set) var encoding: TextEncoding
    @Published private(set) var lineEnding: LineEnding
    @Published private(set) var isModified: Bool = false
    @Published var cursorLocation: Int = 0
    @Published var scrollX: CGFloat = 0
    @Published var scrollY: CGFloat = 0

    /// Chiamata quando cambiano nome, stato o percorso (per aggiornare titolo e schede).
    var onMetadataChange: (() -> Void)?

    var displayName: String {
        fileURL?.lastPathComponent ?? L.t("Senza titolo", "Untitled")
    }

    var isUntitled: Bool { fileURL == nil }

    var text: String { storage.string }

    init(text: String = "",
         fileURL: URL? = nil,
         encoding: TextEncoding = .utf8,
         lineEnding: LineEnding = .crlf,
         modified: Bool = false) {
        self.storage = NSTextStorage(string: TextFile.normalizeNewlines(text))
        self.fileURL = fileURL
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.isModified = modified
        self.undoManager = UndoManager()
        self.undoManager.levelsOfUndo = 500
        self.undoManager.groupsByEvent = true
    }

    func setEncoding(_ encoding: TextEncoding) {
        guard self.encoding != encoding else { return }
        self.encoding = encoding
        onMetadataChange?()
    }

    func setLineEnding(_ lineEnding: LineEnding) {
        guard self.lineEnding != lineEnding else { return }
        self.lineEnding = lineEnding
        onMetadataChange?()
    }

    func markModified() {
        guard !isModified else { return }
        isModified = true
        onMetadataChange?()
    }

    func markSaved(url: URL, encoding: TextEncoding, lineEnding: LineEnding) {
        self.fileURL = url
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.isModified = false
        onMetadataChange?()
    }

    func markSavedInPlace() {
        guard isModified else { return }
        isModified = false
        onMetadataChange?()
    }

    func resetUndoHistory() {
        undoManager.removeAllActions()
    }

    /// Ripristina lo stato "modificato" dopo aggiornamenti puramente visuali
    /// (per esempio il rendering Markdown) senza notificare la finestra.
    func restoreModifiedState(_ value: Bool) {
        isModified = value
    }
}
