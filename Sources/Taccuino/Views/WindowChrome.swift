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
