import SwiftUI

/// Semafori macOS disegnati da Taccuino, centrati nella barra delle schede.
struct MacTrafficLights: View {
    @ObservedObject var model: WindowModel
    let theme: Theme

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            light(color: Color(hex: 0xFF5F57), symbol: "xmark",
                  help: L.t("Chiudi", "Close")) {
                model.window?.performClose(nil)
            }
            light(color: Color(hex: 0xFEBC2E), symbol: "minus",
                  help: L.t("Riduci a icona", "Minimize")) {
                model.window?.performMiniaturize(nil)
            }
            light(color: Color(hex: 0x28C840), symbol: "arrow.up.left.and.arrow.down.right",
                  help: L.t("Schermo intero", "Enter full screen")) {
                model.window?.toggleFullScreen(nil)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L.t("Controlli finestra", "Window controls"))
    }

    private func light(color: Color, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 5.5, weight: .bold))
                        .foregroundColor(.black.opacity(0.55))
                        .opacity(hovering ? 1 : 0)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Pulsanti di riduzione, ingrandimento e chiusura nello stile di Windows 11.
struct WindowsCaptionButtons: View {
    @ObservedObject var model: WindowModel
    let theme: Theme

    var body: some View {
        HStack(spacing: 0) {
            captionButton(kind: .minimize)
            captionButton(kind: .maximize)
            captionButton(kind: .close)
        }
        .frame(height: TabMetrics.barHeight)
        .accessibilityElement(children: .contain)
    }

    fileprivate enum Kind {
        case minimize
        case maximize
        case close
    }

    private func captionButton(kind: Kind) -> some View {
        CaptionButton(kind: kind, theme: theme) {
            switch kind {
            case .minimize:
                model.window?.performMiniaturize(nil)
            case .maximize:
                model.window?.performZoom(nil)
            case .close:
                model.window?.performClose(nil)
            }
        }
    }
}

private struct CaptionButton: View {
    let kind: WindowsCaptionButtons.Kind
    let theme: Theme
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Rectangle()
                    .fill(background)
                glyph
            }
            .frame(width: 46, height: TabMetrics.barHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var background: Color {
        if hovering {
            return kind == .close ? Color(hex: 0xC42B1C) : theme.hover
        }
        return .clear
    }

    private var glyphColor: Color {
        hovering && kind == .close ? .white : theme.text
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .minimize:
            Rectangle()
                .fill(glyphColor)
                .frame(width: 10, height: 1)
        case .maximize:
            RoundedRectangle(cornerRadius: 1)
                .stroke(glyphColor, lineWidth: 1)
                .frame(width: 10, height: 10)
        case .close:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(glyphColor)
        }
    }

    private var helpText: String {
        switch kind {
        case .minimize: return L.t("Riduci a icona", "Minimize")
        case .maximize: return L.t("Ingrandisci", "Maximize")
        case .close: return L.t("Chiudi", "Close")
        }
    }
}
