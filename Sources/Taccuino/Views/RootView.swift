import AppKit
import SwiftUI

struct RootView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var settings: SettingsStore
    let editor: EditorController

    @Environment(\.colorScheme) private var colorScheme

    private var theme: Theme {
        Theme.make(dark: colorScheme == .dark)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                TabBarView(model: model, settings: settings, theme: theme)

                if settings.formattingEnabled && settings.formattingToolbarVisible && !model.isSettingsActive {
                    FormattingToolbarView(model: model, settings: settings, theme: theme)
                }

                ZStack(alignment: .top) {
                    theme.content

                    EditorHost(
                        editor: editor,
                        activeID: model.activeDocument?.id,
                        settingsActive: model.isSettingsActive
                    )
                    .opacity(model.isSettingsActive ? 0 : 1)
                    .allowsHitTesting(!model.isSettingsActive)

                    if model.isSettingsActive {
                        SettingsView(model: model, settings: settings, theme: theme)
                            .transition(.opacity)
                    }

                    if model.find.isVisible && !model.isSettingsActive {
                        FindBarView(model: model, theme: theme)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                if settings.showStatusBar && !model.isSettingsActive {
                    StatusBarView(model: model, settings: settings, theme: theme)
                }
            }
            .background(Color.clear)
            .coordinateSpace(name: "root")
            .onAppear {
                model.windowSize = geo.size
                editor.applySettings()
            }
            .onChange(of: geo.size) { _, newValue in
                model.windowSize = newValue
            }
            .overlay {
                PopupLayer(model: model, theme: theme)
            }
        }
        .ignoresSafeArea()
    }
}

struct EditorHost: NSViewRepresentable {
    let editor: EditorController
    let activeID: UUID?
    let settingsActive: Bool

    func makeNSView(context: Context) -> NSView {
        let view = editor.containerView
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let target = settingsActive ? nil : activeID
        guard editor.displayedDocumentID != target else { return }
        DispatchQueue.main.async {
            editor.setActive(target)
        }
    }
}

struct StatusBarView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var settings: SettingsStore
    let theme: Theme

    var body: some View {
        HStack(spacing: 0) {
            Text(L.t("Riga \(model.statusLine), Colonna \(model.statusColumn)",
                     "Ln \(model.statusLine), Col \(model.statusColumn)"))
                .font(FluentFont.ui(11.5))
                .foregroundColor(theme.secondaryText)
                .padding(.leading, 14)
                .layoutPriority(1)

            if model.activeDocument != nil {
                Text(L.t("\(model.formattingState.characterCount) caratteri",
                         "\(model.formattingState.characterCount) characters"))
                    .font(FluentFont.ui(11.5))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 12)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            if let document = model.activeDocument {
                if settings.formattingEnabled {
                    FormattingStatusButton(model: model, theme: theme)
                    statusSeparator
                }

                statusItem("\(settings.zoomPercent)%")
                statusSeparator
                statusItem(document.lineEnding.displayName)
                statusSeparator
                statusItem(document.encoding.displayName)
            }
        }
        .padding(.trailing, 4)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .background(theme.statusBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
        }
    }

    private func statusItem(_ text: String) -> some View {
        Text(text)
            .font(FluentFont.ui(11.5))
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 12)
            .lineLimit(1)
    }

    private var statusSeparator: some View {
        Rectangle()
            .fill(theme.border)
            .frame(width: 1, height: 14)
    }
}

private struct FormattingStatusButton: View {
    @ObservedObject var model: WindowModel
    let theme: Theme

    @State private var hovering = false

    private var label: String {
        if model.showsMarkdownSource {
            return "Markdown"
        }
        if model.formattingState.hasFormatting {
            return L.t("Formattato", "Formatted")
        }
        return L.t("Testo semplice", "Plain text")
    }

    var body: some View {
        Button {
            model.toggleMarkdownSource()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "textformat")
                    .font(.system(size: 10, weight: .regular))
                Text(label)
                    .font(FluentFont.ui(11.5))
                    .lineLimit(1)
            }
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(hovering ? theme.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L.t("Passa da Formattato a Markdown", "Switch between Formatted and Markdown"))
    }
}
