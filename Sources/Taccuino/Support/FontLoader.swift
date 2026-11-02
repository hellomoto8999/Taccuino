import AppKit
import CoreText
import Foundation

/// Registra i font inclusi nel bundle (Selawik, Cascadia Mono).
enum FontLoader {
    static let uiFamily = "Selawik"
    static let monoFamily = "Cascadia Mono"

    static func registerBundledFonts() {
        registerConsolasIfAvailable()

        guard let resourceURL = Bundle.main.resourceURL else { return }
        let fontsURL = resourceURL.appendingPathComponent("Fonts", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fontsURL,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where ["ttf", "otf"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    /// Consolas è il font predefinito del Blocco note. Non viene ridistribuito:
    /// se è presente (per esempio con Microsoft Office) lo usiamo dal sistema.
    private static func registerConsolasIfAvailable() {
        let directories = [
            "/Applications/Microsoft Word.app/Contents/Resources/DFonts",
            "/Applications/Microsoft Excel.app/Contents/Resources/DFonts",
            "/Applications/Microsoft PowerPoint.app/Contents/Resources/DFonts",
            "/Applications/Microsoft Outlook.app/Contents/Resources/DFonts",
            "/Applications/Microsoft OneNote.app/Contents/Resources/DFonts"
        ]
        let files = ["Consola.ttf", "Consolab.ttf", "Consolai.ttf", "Consolaz.ttf"]

        for directory in directories {
            var registeredAny = false
            for file in files {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                registeredAny = true
            }
            if registeredAny { break }
        }
    }

    static var hasSelawik: Bool {
        NSFont(name: "Selawik-Regular", size: 12) != nil
    }

    static var hasCascadiaMono: Bool {
        NSFont(name: "CascadiaMono-Regular", size: 12) != nil
    }
}
