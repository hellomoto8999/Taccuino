import AppKit
import SwiftUI

struct FindBarView: View {
    @ObservedObject var model: WindowModel
    let theme: Theme

    @State private var collapsed = false
    @State private var optionsFrame: CGRect = .zero
    @FocusState private var findFocused: Bool
    @FocusState private var replaceFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let width = min(700, max(300, geo.size.width - 48))
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    if model.find.isReplace {
                        FluentIconButton(
                            systemName: collapsed ? "chevron.down" : "chevron.up",
                            theme: theme,
                            size: 10
                        ) {
                            collapsed.toggle()
                            if !collapsed { focusFind() }
                        }
                    }

                    FluentFindField(
                        text: $model.find.query,
                        placeholder: L.t("Trova", "Find"),
                        theme: theme,
                        focused: $findFocused,
                        showSearchIcon: true,
                        count: model.find.query.isEmpty ? nil : model.find.matchCount,
                        onSubmit: submitFind,
                        onEscape: { model.closeFind() }
                    )

                    FluentIconButton(systemName: "arrow.down", theme: theme, size: 11,
                                     help: L.t("Trova successivo", "Find next")) {
                        model.findNext()
                    }
                    FluentIconButton(systemName: "arrow.up", theme: theme, size: 11,
                                     help: L.t("Trova precedente", "Find previous")) {
                        model.findPrevious()
                    }

                    FluentIconButton(systemName: "line.3.horizontal.decrease", theme: theme, size: 12,
                                     help: L.t("Opzioni di ricerca", "Search options")) {
                        model.openFindOptions(at: CGPoint(x: optionsFrame.minX, y: optionsFrame.maxY + 2))
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { optionsFrame = proxy.frame(in: .named("root")) }
                                .onChange(of: proxy.frame(in: .named("root"))) { _, newValue in
                                    optionsFrame = newValue
                                }
                        }
                    )

                    FluentIconButton(systemName: "xmark", theme: theme, size: 11,
                                     help: L.t("Chiudi", "Close")) {
                        model.closeFind()
                    }
                }

                if model.find.isReplace && !collapsed {
                    HStack(spacing: 6) {
                        Color.clear.frame(width: 32, height: 1)
                        FluentFindField(
                            text: $model.find.replacement,
                            placeholder: L.t("Sostituisci con", "Replace with"),
                            theme: theme,
                            focused: $replaceFocused,
                            showSearchIcon: false,
                            count: nil,
                            onSubmit: { model.replaceCurrent() },
                            onEscape: { model.closeFind() }
                        )

                        FluentButton(title: L.t("Sostituisci", "Replace"),
                                     theme: theme,
                                     isDefault: true,
                                     isEnabled: !model.find.query.isEmpty && model.find.matchCount > 0) {
                            model.replaceCurrent()
                        }
                        FluentButton(title: L.t("Sostituisci tutto", "Replace all"),
                                     theme: theme,
                                     isEnabled: !model.find.query.isEmpty && model.find.matchCount > 0) {
                            model.replaceAll()
                        }
                    }
                }
            }
            .padding(10)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.menuBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.menuBorder, lineWidth: 1)
            )
            .shadow(color: theme.shadow, radius: 18, x: 0, y: 8)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 38)
            .onExitCommand { model.closeFind() }
        }
        .onAppear {
            model.refreshFindCount()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusFind()
            }
        }
        .onChange(of: model.find.focusToken) { _, _ in
            collapsed = false
            DispatchQueue.main.async { focusFind() }
        }
        .onChange(of: model.find.isReplace) { _, _ in
            collapsed = false
            DispatchQueue.main.async { focusFind() }
        }
        .onChange(of: model.find.query) { _, _ in
            model.refreshFindCount()
        }
    }

    private func focusFind() {
        findFocused = true
    }

    private func submitFind() {
        if NSEvent.modifierFlags.contains(.shift) {
            model.findPrevious()
        } else {
            model.findNext()
        }
    }
}

private struct FluentFindField: View {
    @Binding var text: String
    let placeholder: String
    let theme: Theme
    @FocusState.Binding var focused: Bool
    var showSearchIcon: Bool
    var count: Int?
    var onSubmit: () -> Void
    var onEscape: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(FluentFont.ui(13))
                .foregroundColor(theme.text)
                .focused($focused)
                .onSubmit(onSubmit)
                .onExitCommand(perform: onEscape)

            if let count {
                Text("\(count)")
                    .font(FluentFont.ui(11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize()
                    .help(L.t("Corrispondenze", "Matches"))
            }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(theme.hover)
                        )
                }
                .buttonStyle(.plain)
                .help(L.t("Cancella", "Clear"))
            }

            if showSearchIcon {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.field)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(theme.strongBorder, lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.accent)
                .frame(height: 2)
                .padding(.horizontal, 1)
                .opacity(focused ? 1 : 0)
        }
    }
}
