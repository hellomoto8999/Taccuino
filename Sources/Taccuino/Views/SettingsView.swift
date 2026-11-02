import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var settings: SettingsStore
    let theme: Theme

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(L.t("Impostazioni", "Settings"))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(theme.text)
                    .padding(.bottom, 2)

                section(L.t("Aspetto", "Appearance")) {
                    SettingsCard(theme: theme) {
                        themeRow
                        rowDivider
                        chromeRow
                        rowDivider
                        fontRow
                        rowDivider
                        zoomRow
                        rowDivider
                        toggleRow(title: L.t("Testo a capo", "Word wrap"),
                                  description: L.t("Adatta le righe lunghe alla larghezza della finestra.",
                                                   "Wrap long lines to the window width."),
                                  isOn: $settings.wordWrap)
                        rowDivider
                        toggleRow(title: L.t("Barra di stato", "Status bar"),
                                  description: L.t("Mostra riga, colonna, zoom, fine riga e codifica.",
                                                   "Show line, column, zoom, line endings and encoding."),
                                  isOn: $settings.showStatusBar)
                    }
                }

                section(L.t("Formattazione", "Formatting")) {
                    SettingsCard(theme: theme) {
                        toggleRow(title: L.t("Abilita formattazione", "Enable formatting"),
                                  description: L.t("Markdown leggero: grassetto, corsivo, barrato, titoli, elenchi, link e tabelle.",
                                                   "Lightweight Markdown: bold, italic, strikethrough, headings, lists, links and tables."),
                                  isOn: $settings.formattingEnabled)
                        rowDivider
                        toggleRow(title: L.t("Mostra barra formattazione", "Show formatting toolbar"),
                                  description: L.t("Mostra la barra degli strumenti sotto le schede.",
                                                   "Show the formatting toolbar below the tabs."),
                                  isOn: $settings.formattingToolbarVisible)
                    }
                }

                section(L.t("Controllo ortografico", "Spelling")) {
                    SettingsCard(theme: theme) {
                        toggleRow(title: L.t("Controllo ortografico", "Spell check"),
                                  description: L.t("Sottolinea le parole non riconosciute mentre scrivi.",
                                                   "Underline unrecognized words as you type."),
                                  isOn: $settings.spellCheck)
                        rowDivider
                        toggleRow(title: L.t("Correzione automatica", "Autocorrect"),
                                  description: L.t("Corregge automaticamente gli errori di battitura più comuni.",
                                                   "Automatically fix common typing mistakes."),
                                  isOn: $settings.autocorrect)
                    }
                }

                section(L.t("Avvio", "Startup")) {
                    SettingsCard(theme: theme) {
                        toggleRow(title: L.t("Ripristina la sessione precedente", "Restore previous session"),
                                  description: L.t("All'avvio riapre le schede, i cursori e i contenuti non salvati.",
                                                   "Reopen tabs, cursors and unsaved content at launch."),
                                  isOn: $settings.restoreSession)
                    }
                }

                section(L.t("Informazioni", "About")) {
                    SettingsCard(theme: theme) {
                        HStack(spacing: 14) {
                            AppMark()
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Taccuino")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(theme.text)
                                Text(L.t("Versione \(version)", "Version \(version)"))
                                    .font(FluentFont.ui(11.5))
                                    .foregroundColor(theme.secondaryText)
                                Text(L.t("Replica indipendente del Blocco note per macOS.",
                                         "An independent Notepad replica for macOS."))
                                    .font(FluentFont.ui(11.5))
                                    .foregroundColor(theme.secondaryText)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                    }
                }

                Text(L.t("Taccuino non è affiliato a Microsoft. Il Blocco note è un marchio di Microsoft Corporation.",
                         "Taccuino is not affiliated with Microsoft. Notepad is a trademark of Microsoft Corporation."))
                    .font(FluentFont.ui(11))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(MicaBackground(theme: theme))
    }

    // MARK: - Sezioni

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.text)
                .padding(.leading, 2)
            content()
        }
    }

    private var themeRow: some View {
        row(title: L.t("Tema", "Theme")) {
            FluentCombo(value: settings.theme.displayName, theme: theme, width: 180) { frame in
                let options = ThemeMode.allCases
                let selected = options.firstIndex(of: settings.theme) ?? 0
                model.showDropdown(
                    options: options.map(\.displayName),
                    selected: selected,
                    at: CGPoint(x: frame.minX, y: frame.maxY + 2)
                ) { index in
                    settings.theme = options[index]
                }
            }
        }
    }

    private var chromeRow: some View {
        row(title: L.t("Controlli finestra", "Window controls")) {
            FluentCombo(value: settings.windowChrome.displayName, theme: theme, width: 180) { frame in
                let options = WindowChromeStyle.allCases
                let selected = options.firstIndex(of: settings.windowChrome) ?? 0
                model.showDropdown(
                    options: options.map(\.displayName),
                    selected: selected,
                    at: CGPoint(x: frame.minX, y: frame.maxY + 2)
                ) { index in
                    settings.windowChrome = options[index]
                }
            }
        }
    }

    private var zoomRow: some View {
        row(title: L.t("Zoom predefinito", "Default zoom")) {
            FluentCombo(value: "\(settings.zoomPercent)%", theme: theme, width: 110) { frame in
                let options = zoomPercentOptions
                let selected = options.firstIndex(of: settings.zoomPercent) ?? (options.firstIndex(of: 100) ?? 0)
                model.showDropdown(
                    options: options.map { "\($0)%" },
                    selected: selected,
                    at: CGPoint(x: frame.minX, y: frame.maxY + 2)
                ) { index in
                    model.setZoom(Double(options[index]) / 100)
                }
            }
        }
    }

    private var zoomPercentOptions: [Int] {
        let base = [50, 75, 100, 125, 150, 175, 200, 250, 300, 400, 500]
        let current = settings.zoomPercent
        return base.contains(current) ? base : (base + [current]).sorted()
    }

    private var fontRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(L.t("Carattere", "Font"))
                        .font(FluentFont.ui(13))
                        .foregroundColor(theme.text)
                    Spacer(minLength: 12)
                    fontFamilyCombo(width: 200)
                    fontStyleCombo(width: 126)
                    fontSizeCombo(width: 72)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t("Carattere", "Font"))
                        .font(FluentFont.ui(13))
                        .foregroundColor(theme.text)
                    HStack(spacing: 8) {
                        fontFamilyCombo(width: 150)
                        fontStyleCombo(width: 112)
                        fontSizeCombo(width: 64)
                    }
                }
            }

            Text("AaBbCc 123 — \(L.t("Il veloce zaino blu", "The quick brown fox"))")
                .font(.custom(settings.editorFont.fontName, size: 15))
                .foregroundColor(theme.text)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(theme.border, lineWidth: 1)
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func fontFamilyCombo(width: CGFloat) -> some View {
        FluentCombo(value: settings.fontFamily, theme: theme, width: width) { frame in
            let families = FontCatalog.families
            let selected = families.firstIndex(of: settings.fontFamily) ?? 0
            model.showDropdown(
                options: families,
                selected: selected,
                width: 300,
                at: CGPoint(x: frame.minX, y: frame.maxY + 2)
            ) { index in
                settings.fontFamily = families[index]
            }
        }
    }

    private func fontStyleCombo(width: CGFloat) -> some View {
        FluentCombo(value: settings.fontStyle.displayName, theme: theme, width: width) { frame in
            let styles = FontStyle.allCases
            let selected = styles.firstIndex(of: settings.fontStyle) ?? 0
            model.showDropdown(
                options: styles.map(\.displayName),
                selected: selected,
                at: CGPoint(x: frame.minX, y: frame.maxY + 2)
            ) { index in
                settings.fontStyle = styles[index]
            }
        }
    }

    private func fontSizeCombo(width: CGFloat) -> some View {
        let sizes = settings.fontSizeOptions
        let current = Int(settings.fontSize.rounded())
        let selected = sizes.firstIndex(of: current) ?? 0
        return FluentCombo(value: "\(current)", theme: theme, width: width) { frame in
            model.showDropdown(
                options: sizes.map(String.init),
                selected: selected,
                at: CGPoint(x: frame.minX, y: frame.maxY + 2)
            ) { index in
                settings.fontSize = Double(sizes[index])
            }
        }
    }

    private func toggleRow(title: String, description: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(FluentFont.ui(13))
                    .foregroundColor(theme.text)
                Text(description)
                    .font(FluentFont.ui(11.5))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            FluentToggle(isOn: isOn, theme: theme)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.12)) {
                isOn.wrappedValue.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func row<Content: View>(title: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(FluentFont.ui(13))
                .foregroundColor(theme.text)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var rowDivider: some View {
        HDivider(theme: theme, inset: 14)
    }
}

private struct SettingsCard<Content: View>: View {
    let theme: Theme
    let content: Content

    init(theme: Theme, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.border, lineWidth: 1)
        )
    }
}
