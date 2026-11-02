import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    init(ns: NSColor) {
        self.init(nsColor: ns)
    }
}

/// Palette Fluent/Windows 11 usata da tutta l'interfaccia.
struct Theme {
    let dark: Bool

    let mica: Color
    let content: Color
    let text: Color
    let secondaryText: Color
    let tertiaryText: Color
    let border: Color
    let strongBorder: Color
    let hover: Color
    let pressed: Color
    let tabActive: Color
    let card: Color
    let field: Color
    let menuBackground: Color
    let menuBorder: Color
    let accent: Color
    let accentHover: Color
    let statusBackground: Color
    let divider: Color
    let shadow: Color

    let nsContent: NSColor
    let nsText: NSColor
    let nsSelection: NSColor
    let nsCaret: NSColor
    let nsAccent: NSColor

    static func make(dark: Bool) -> Theme {
        if dark {
            return Theme(
                dark: true,
                mica: Color(hex: 0x202020),
                content: Color(hex: 0x202020),
                text: Color(hex: 0xF2F2F2),
                secondaryText: Color(hex: 0xA9A9A9),
                tertiaryText: Color(hex: 0x808080),
                border: Color(hex: 0x3A3A3A),
                strongBorder: Color(hex: 0x464646),
                hover: Color(hex: 0x323232),
                pressed: Color(hex: 0x3C3C3C),
                tabActive: Color(hex: 0x2B2B2B),
                card: Color(hex: 0x282828),
                field: Color(hex: 0x242424),
                menuBackground: Color(hex: 0x2D2D2D),
                menuBorder: Color(hex: 0x414141),
                accent: Color(hex: 0x60CDFF),
                accentHover: Color(hex: 0x7AD8FF),
                statusBackground: Color(hex: 0x1F1F1F),
                divider: Color(hex: 0x3A3A3A),
                shadow: Color.black.opacity(0.45),
                nsContent: NSColor(hex: 0x202020),
                nsText: NSColor(hex: 0xF2F2F2),
                nsSelection: NSColor(hex: 0x0078D4, alpha: 1),
                nsCaret: NSColor(hex: 0xFFFFFF),
                nsAccent: NSColor(hex: 0x60CDFF)
            )
        }
        return Theme(
            dark: false,
            mica: Color(hex: 0xF3F3F3),
            content: Color(hex: 0xFFFFFF),
            text: Color(hex: 0x1B1B1B),
            secondaryText: Color(hex: 0x616161),
            tertiaryText: Color(hex: 0x8A8A8A),
            border: Color(hex: 0xE2E2E2),
            strongBorder: Color(hex: 0xCFCFCF),
            hover: Color(hex: 0xE9E9E9),
            pressed: Color(hex: 0xDDDDDD),
            tabActive: Color(hex: 0xFCFCFC),
            card: Color(hex: 0xFAFAFA),
            field: Color(hex: 0xFFFFFF),
            menuBackground: Color(hex: 0xFCFCFC),
            menuBorder: Color(hex: 0xE0E0E0),
            accent: Color(hex: 0x0067C0),
            accentHover: Color(hex: 0x1975C5),
            statusBackground: Color(hex: 0xF3F3F3),
            divider: Color(hex: 0xE2E2E2),
            shadow: Color.black.opacity(0.2),
            nsContent: NSColor(hex: 0xFFFFFF),
            nsText: NSColor(hex: 0x1B1B1B),
            nsSelection: NSColor(hex: 0x0078D4, alpha: 1),
            nsCaret: NSColor(hex: 0x000000),
            nsAccent: NSColor(hex: 0x0067C0)
        )
    }
}

enum FluentFont {
    static let uiName = "Segoe UI"

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // Dimensioni intere: evitano il posizionamento a metà pixel dei glifi
        // sulle scale non Retina e rendono il testo più nitido.
        let pointSize = size.rounded()
        if FontLoader.hasSelawik {
            return .custom(faceName(for: weight), size: pointSize)
        }
        if NSFont(name: uiName, size: pointSize) != nil {
            return .custom(uiName, size: pointSize).weight(weight)
        }
        return .system(size: pointSize, weight: weight)
    }

    static func uiSemibold(_ size: CGFloat) -> Font {
        ui(size, weight: .semibold)
    }

    static func nsUIFont(_ size: CGFloat) -> NSFont {
        if FontLoader.hasSelawik, let font = NSFont(name: "Selawik-Regular", size: size) {
            return font
        }
        if let font = NSFont(name: uiName, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size)
    }

    private static func faceName(for weight: Font.Weight) -> String {
        switch weight {
        case .light, .thin, .ultraLight:
            return "Selawik-Light"
        case .semibold, .medium:
            return "Selawik-Semibold"
        case .bold, .heavy, .black:
            return "Selawik-Bold"
        default:
            return "Selawik-Regular"
        }
    }

    static var monoFallback: String {
        if NSFont(name: "Consolas", size: 11) != nil { return "Consolas" }
        if FontLoader.hasCascadiaMono { return "Cascadia Mono" }
        if NSFont(name: "Menlo", size: 11) != nil { return "Menlo" }
        return "Monaco"
    }
}

enum FontCatalog {
    static var families: [String] {
        NSFontManager.shared.availableFontFamilies.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func font(family: String, style: FontStyle, size: CGFloat) -> NSFont {
        var traits: NSFontTraitMask = []
        let bold = style == .bold || style == .boldItalic
        let italic = style == .italic || style == .boldItalic
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }

        if var font = NSFontManager.shared.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: size) {
            if italic && !font.fontDescriptor.symbolicTraits.contains(.italic) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            return font
        }
        if var font = NSFont(name: family, size: size) {
            if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }
}
