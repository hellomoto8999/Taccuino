import AppKit
import SwiftUI

struct FormattingToolbarView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var settings: SettingsStore
    let theme: Theme

    @State private var headingFrame: CGRect = .zero
    @State private var listFrame: CGRect = .zero

    private var state: MarkdownFormattingState { model.formattingState }

    var body: some View {
        HStack(spacing: 3) {
            ToolbarMenuButton(
                title: headingTitle,
                theme: theme,
                width: 48,
                isActive: state.headingLevel > 0,
                help: L.t("Titolo", "Heading")
            ) { frame in
                headingFrame = frame
                showHeadingMenu(at: CGPoint(x: frame.minX, y: frame.maxY + 2))
            }

            ToolbarMenuButton(
                systemName: state.listKind == .numbered ? "list.number" : "list.bullet",
                theme: theme,
                width: 42,
                isActive: state.listKind != nil,
                help: L.t("Elenco", "List")
            ) { frame in
                listFrame = frame
                showListMenu(at: CGPoint(x: frame.minX, y: frame.maxY + 2))
            }

            toolbarSeparator

            FormatButton(label: "B", theme: theme, isActive: state.bold,
                         labelFont: FluentFont.ui(14, weight: .bold),
                         help: L.t("Grassetto (Ctrl+B)", "Bold (Ctrl+B)")) {
                model.toggleBold()
            }
            FormatButton(label: "I", theme: theme, isActive: state.italic,
                         labelFont: FluentFont.ui(14).italic(),
                         help: L.t("Corsivo (Ctrl+I)", "Italic (Ctrl+I)")) {
                model.toggleItalic()
            }
            FormatButton(label: "S", theme: theme, isActive: state.strike,
                         labelFont: FluentFont.ui(13, weight: .semibold),
                         strike: true,
                         help: L.t("Barrato", "Strikethrough")) {
                model.toggleStrikethrough()
            }
            FormatButton(systemName: "link", theme: theme, isActive: false,
                         help: L.t("Inserisci link (Ctrl+K)", "Insert link (Ctrl+K)")) {
                model.insertLink()
            }

            ToolbarMenuButton(
                systemName: "tablecells",
                theme: theme,
                width: 42,
                isActive: state.inTable,
                help: L.t("Tabella", "Table")
            ) { frame in
                model.showTablePicker(at: CGPoint(x: frame.minX, y: frame.maxY + 2))
            }

            FormatButton(systemName: "paintbrush.pointed", theme: theme, isActive: false,
                         help: L.t("Cancella formattazione", "Clear formatting")) {
                model.clearFormatting()
            }

            Spacer(minLength: 12)

            FormatButton(systemName: "speaker.wave.2", theme: theme, isActive: false,
                         help: L.t("Leggi ad alta voce", "Read aloud")) {
                model.toggleReadAloud()
            }
            FormatButton(systemName: "circle.lefthalf.filled", theme: theme, isActive: false,
                         help: L.t("Cambia tema", "Switch theme")) {
                model.toggleTheme()
            }
            FormatButton(systemName: "gearshape", theme: theme, isActive: false,
                         help: L.t("Impostazioni", "Settings")) {
                model.selectSettings()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MicaBackground(theme: theme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
        }
        .pointerStyle(.default)
        .onContinuousHover { phase in
            if case .active = phase {
                NSCursor.arrow.set()
            }
        }
    }

    private var headingTitle: String {
        switch state.headingLevel {
        case 1: return "H1"
        case 2: return "H2"
        case 3: return "H3"
        default: return "H1"
        }
    }

    private func showHeadingMenu(at anchor: CGPoint) {
        let current = state.headingLevel
        let items: [MenuItem] = [
            MenuItem(title: L.t("Testo normale", "Normal text"),
                     isChecked: current == 0,
                     action: { model.setHeadingLevel(0) }),
            MenuItem(title: L.t("Titolo 1", "Heading 1"),
                     shortcut: "⌘⌥1",
                     isChecked: current == 1,
                     action: { model.setHeadingLevel(1) }),
            MenuItem(title: L.t("Titolo 2", "Heading 2"),
                     shortcut: "⌘⌥2",
                     isChecked: current == 2,
                     action: { model.setHeadingLevel(2) }),
            MenuItem(title: L.t("Titolo 3", "Heading 3"),
                     shortcut: "⌘⌥3",
                     isChecked: current == 3,
                     action: { model.setHeadingLevel(3) })
        ]
        model.showPopup(items, at: anchor, width: 230)
    }

    private func showListMenu(at anchor: CGPoint) {
        let state = model.formattingState
        let items: [MenuItem] = [
            MenuItem(title: L.t("Elenco puntato", "Bulleted list"),
                     shortcut: "⌘⇧8",
                     isChecked: state.listKind == .bullet,
                     action: { model.toggleList(.bullet) }),
            MenuItem(title: L.t("Elenco numerato", "Numbered list"),
                     shortcut: "⌘⇧7",
                     isChecked: state.listKind == .numbered,
                     action: { model.toggleList(.numbered) }),
            .separator,
            MenuItem(title: L.t("Aumenta rientro", "Increase indent"),
                     shortcut: "⌘]",
                     isEnabled: state.listKind != nil,
                     action: { model.indentList(outdent: false) }),
            MenuItem(title: L.t("Riduci rientro", "Decrease indent"),
                     shortcut: "⌘[",
                     isEnabled: state.listKind != nil && state.listLevel > 0,
                     action: { model.indentList(outdent: true) })
        ]
        model.showPopup(items, at: anchor, width: 260)
    }

    private var toolbarSeparator: some View {
        Rectangle()
            .fill(theme.border)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 4)
    }
}

private struct FormatButton: View {
    var label: String?
    var systemName: String?
    let theme: Theme
    let isActive: Bool
    var labelFont: Font = FluentFont.ui(13)
    var strike = false
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let label {
                    Text(label)
                        .font(labelFont)
                        .strikethrough(strike)
                } else if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 12, weight: .regular))
                }
            }
            .foregroundColor(isActive ? theme.accent : theme.text)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? theme.accent.opacity(0.16) : (hovering ? theme.accent.opacity(0.10) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.default)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ToolbarMenuButton: View {
    var title: String?
    var systemName: String?
    let theme: Theme
    let width: CGFloat
    let isActive: Bool
    var showsChevron = true
    var help: String?
    let onOpen: (CGRect) -> Void

    @State private var hovering = false
    @State private var frame: CGRect = .zero

    private var helpText: String {
        help ?? title ?? systemName ?? ""
    }

    var body: some View {
        Button {
            onOpen(frame)
        } label: {
            Group {
                if let title {
                    Text(title)
                        .font(FluentFont.ui(12.5, weight: .semibold))
                } else if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 12))
                }
            }
            .foregroundColor(isActive ? theme.accent : theme.text)
            .frame(width: width, height: 28)
            .overlay(alignment: .trailing) {
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(isActive ? theme.accent : theme.secondaryText)
                        .padding(.trailing, 5)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? theme.accent.opacity(0.16) : (hovering ? theme.accent.opacity(0.10) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.default)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { frame = proxy.frame(in: .named("root")) }
                    .onChange(of: proxy.frame(in: .named("root"))) { _, newValue in
                        frame = newValue
                    }
            }
        )
    }
}
