import AppKit
import Foundation

enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L.t("Sistema", "System")
        case .light: return L.t("Chiaro", "Light")
        case .dark: return L.t("Scuro", "Dark")
        }
    }
}

enum WindowChromeStyle: String, CaseIterable, Identifiable {
    case macOS
    case windows

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .windows: return L.t("Windows", "Windows")
        }
    }
}

enum FontStyle: String, CaseIterable, Identifiable {
    case regular
    case bold
    case italic
    case boldItalic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .regular: return L.t("Regolare", "Regular")
        case .bold: return L.t("Grassetto", "Bold")
        case .italic: return L.t("Corsivo", "Italic")
        case .boldItalic: return L.t("Grassetto corsivo", "Bold italic")
        }
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Key {
        static let theme = "taccuino.theme"
        static let fontFamily = "taccuino.fontFamily"
        static let fontStyle = "taccuino.fontStyle"
        static let fontSize = "taccuino.fontSize"
        static let zoom = "taccuino.zoom"
        static let wordWrap = "taccuino.wordWrap"
        static let statusBar = "taccuino.statusBar"
        static let spellCheck = "taccuino.spellCheck"
        static let autocorrect = "taccuino.autocorrect"
        static let restoreSession = "taccuino.restoreSession"
        static let windowChrome = "taccuino.windowChrome"
        static let formattingEnabled = "taccuino.formattingEnabled"
        static let formattingToolbarVisible = "taccuino.formattingToolbarVisible"
        static let recent = "taccuino.recentFiles"
    }

    private let defaults = UserDefaults.standard

    @Published var theme: ThemeMode {
        didSet {
            defaults.set(theme.rawValue, forKey: Key.theme)
            applyAppearance()
        }
    }

    @Published var fontFamily: String {
        didSet { defaults.set(fontFamily, forKey: Key.fontFamily) }
    }

    @Published var fontStyle: FontStyle {
        didSet { defaults.set(fontStyle.rawValue, forKey: Key.fontStyle) }
    }

    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Key.fontSize) }
    }

    @Published var zoom: Double {
        didSet { defaults.set(zoom, forKey: Key.zoom) }
    }

    @Published var wordWrap: Bool {
        didSet { defaults.set(wordWrap, forKey: Key.wordWrap) }
    }

    @Published var showStatusBar: Bool {
        didSet { defaults.set(showStatusBar, forKey: Key.statusBar) }
    }

    @Published var spellCheck: Bool {
        didSet { defaults.set(spellCheck, forKey: Key.spellCheck) }
    }

    @Published var autocorrect: Bool {
        didSet { defaults.set(autocorrect, forKey: Key.autocorrect) }
    }

    @Published var restoreSession: Bool {
        didSet { defaults.set(restoreSession, forKey: Key.restoreSession) }
    }

    @Published var windowChrome: WindowChromeStyle {
        didSet { defaults.set(windowChrome.rawValue, forKey: Key.windowChrome) }
    }

    @Published var formattingEnabled: Bool {
        didSet { defaults.set(formattingEnabled, forKey: Key.formattingEnabled) }
    }

    @Published var formattingToolbarVisible: Bool {
        didSet { defaults.set(formattingToolbarVisible, forKey: Key.formattingToolbarVisible) }
    }

    @Published private(set) var recentFiles: [String]

    private init() {
        let savedFamily = defaults.string(forKey: Key.fontFamily)
        let familyIsAvailable = savedFamily.map { NSFontManager.shared.availableFontFamilies.contains($0) } ?? false
        fontFamily = familyIsAvailable ? (savedFamily ?? FluentFont.monoFallback) : FluentFont.monoFallback
        theme = ThemeMode(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system
        fontStyle = FontStyle(rawValue: defaults.string(forKey: Key.fontStyle) ?? "") ?? .regular
        let size = defaults.double(forKey: Key.fontSize)
        fontSize = size > 0 ? size : 11
        let savedZoom = defaults.double(forKey: Key.zoom)
        zoom = savedZoom > 0 ? min(5, max(0.1, savedZoom)) : 1
        wordWrap = defaults.object(forKey: Key.wordWrap) as? Bool ?? true
        showStatusBar = defaults.object(forKey: Key.statusBar) as? Bool ?? true
        spellCheck = defaults.object(forKey: Key.spellCheck) as? Bool ?? true
        autocorrect = defaults.object(forKey: Key.autocorrect) as? Bool ?? false
        restoreSession = defaults.object(forKey: Key.restoreSession) as? Bool ?? true
        windowChrome = WindowChromeStyle(rawValue: defaults.string(forKey: Key.windowChrome) ?? "") ?? .windows
        formattingEnabled = defaults.object(forKey: Key.formattingEnabled) as? Bool ?? true
        formattingToolbarVisible = defaults.object(forKey: Key.formattingToolbarVisible) as? Bool ?? true
        recentFiles = defaults.stringArray(forKey: Key.recent) ?? []
    }

    var effectiveDark: Bool {
        switch theme {
        case .light: return false
        case .dark: return true
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    var editorFont: NSFont {
        FontCatalog.font(family: fontFamily,
                         style: fontStyle,
                         size: CGFloat(max(1, fontSize * zoom)))
    }

    var zoomPercent: Int {
        Int((zoom * 100).rounded())
    }

    var fontSizeOptions: [Int] {
        let base = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 28, 32, 36, 48, 72]
        let current = Int(fontSize.rounded())
        return base.contains(current) ? base : (base + [current]).sorted()
    }

    func applyAppearance() {
        switch theme {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func zoomIn() {
        zoom = min(5.0, (zoom * 10).rounded() / 10 + 0.1)
    }

    func zoomOut() {
        zoom = max(0.1, (zoom * 10).rounded() / 10 - 0.1)
    }

    func resetZoom() {
        zoom = 1
    }

    func addRecent(_ url: URL) {
        let path = url.standardizedFileURL.path
        var list = recentFiles.filter { $0 != path }
        list.insert(path, at: 0)
        recentFiles = Array(list.prefix(10))
        defaults.set(recentFiles, forKey: Key.recent)
    }

    func removeRecent(_ path: String) {
        recentFiles.removeAll { $0 == path }
        defaults.set(recentFiles, forKey: Key.recent)
    }

    func clearRecent() {
        recentFiles = []
        defaults.set(recentFiles, forKey: Key.recent)
    }
}
