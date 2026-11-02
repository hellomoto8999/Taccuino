import Foundation

/// Localizzazione minimale: italiano se la lingua di sistema è italiana, altrimenti inglese.
enum L {
    static let isItalian: Bool = {
        let preferred = Bundle.main.preferredLocalizations.first
            ?? Locale.preferredLanguages.first
            ?? "en"
        return preferred.lowercased().hasPrefix("it")
    }()

    static func t(_ it: String, _ en: String) -> String {
        isItalian ? it : en
    }

    static var appName: String { "Taccuino" }
}
