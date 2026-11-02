import AppKit
import SwiftUI

struct HDivider: View {
    let theme: Theme
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

struct VDivider: View {
    let theme: Theme

    var body: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(width: 1, height: 14)
    }
}

struct FluentButton: View {
    let title: String
    let theme: Theme
    var isDefault = false
    var isEnabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(FluentFont.ui(12.5))
                .foregroundColor(isEnabled ? theme.text : theme.tertiaryText)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovering && isEnabled ? theme.hover : theme.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(theme.strongBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
    }
}

struct FluentIconButton: View {
    let systemName: String
    let theme: Theme
    var size: CGFloat = 12
    var help: String?
    var isEnabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(isEnabled ? theme.text : theme.tertiaryText)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovering && isEnabled ? theme.hover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

struct FluentToggle: View {
    @Binding var isOn: Bool
    let theme: Theme

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() }
        } label: {
            Capsule()
                .fill(isOn ? theme.accent : Color.clear)
                .overlay(
                    Capsule().stroke(isOn ? Color.clear : theme.strongBorder, lineWidth: 1)
                )
                .frame(width: 40, height: 20)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(isOn ? Color.white : theme.secondaryText)
                        .frame(width: 12, height: 12)
                        .padding(4)
                }
        }
        .buttonStyle(.plain)
    }
}

/// Etichetta a comparsa in stile Fluent.
struct FluentCombo: View {
    let value: String
    let theme: Theme
    var width: CGFloat = 180
    var isEnabled = true
    let onOpen: (CGRect) -> Void

    @State private var frame: CGRect = .zero
    @State private var hovering = false

    var body: some View {
        Button {
            onOpen(frame)
        } label: {
            HStack(spacing: 6) {
                Text(value)
                    .font(FluentFont.ui(12.5))
                    .foregroundColor(isEnabled ? theme.text : theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 9)
            .frame(width: width, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hovering && isEnabled ? theme.accent.opacity(0.09) : theme.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(hovering && isEnabled ? theme.accent.opacity(0.55) : theme.strongBorder,
                            lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
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

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

struct AppMark: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
    }
}
