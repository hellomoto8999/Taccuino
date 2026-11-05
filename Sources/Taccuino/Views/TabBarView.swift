import AppKit
import SwiftUI

/// Altezze condivise della barra delle schede (circa 10% più compatta).
enum TabMetrics {
    static let barHeight: CGFloat = 40
    static let itemHeight: CGFloat = 31
}

struct TabShape: Shape {
    var topRadius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topRadius, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + topRadius),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Cattura il clic destro senza intercettare quelli sinistri.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (NSPoint) -> Void
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.onRightClick = onRightClick
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ nsView: RightClickView, context: Context) {
        nsView.onRightClick = onRightClick
        nsView.onMiddleClick = onMiddleClick
    }

    final class RightClickView: NSView {
        var onRightClick: ((NSPoint) -> Void)?
        var onMiddleClick: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .otherMouseDown:
                return self
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(event.locationInWindow)
        }

        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 {
                onMiddleClick?()
            } else {
                super.otherMouseDown(with: event)
            }
        }
    }
}

struct TabBarView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var settings: SettingsStore
    let theme: Theme

    @State private var hoveredDocument: UUID?
    @State private var hoveringSettings = false
    @State private var hoveringPlus = false
    @State private var dropTarget: UUID?
    @State private var draggingDocument: UUID?

    var body: some View {
        GeometryReader { geo in
            let isMac = settings.windowChrome == .macOS
            let leading: CGFloat = isMac ? 14 : 8
            let lights: CGFloat = isMac ? 52 : 0
            let captions: CGFloat = isMac ? 0 : 138
            let trailing: CGFloat = isMac ? 8 : 0
            let dragWidth: CGFloat = 50
            let fixed = leading + lights + 18 + 18 + dragWidth + 30 + trailing + captions
            let available = max(200, geo.size.width - fixed)
            let count = max(1, model.tabCount)
            let tabWidth = min(320, max(84, available / CGFloat(count) - 2))

            HStack(spacing: 6) {
                if isMac {
                    MacTrafficLights(model: model, theme: theme)
                        .frame(width: lights)
                    AppMark()
                        .frame(width: 18, height: 18)
                }

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(model.documents) { document in
                                tab(for: document, width: tabWidth)
                                    .id(document.id)
                            }
                            if model.settingsTabOpen {
                                settingsTab(width: tabWidth)
                                    .id("taccuino.settings.tab")
                            }
                            plusButton
                        }
                        .padding(.trailing, 4)
                    }
                    .scrollDisabled(false)
                    .onAppear {
                        scrollToActive(proxy)
                    }
                    .onChange(of: model.activeTab) { _, _ in
                        scrollToActive(proxy)
                    }
                    .onChange(of: model.documents.count) { _, _ in
                        scrollToActive(proxy)
                    }
                }

                WindowDragArea()
                    .frame(width: dragWidth, height: TabMetrics.barHeight)

                if !isMac {
                    WindowsCaptionButtons(model: model, theme: theme)
                        .frame(width: captions)
                }
            }
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(height: TabMetrics.barHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: TabMetrics.barHeight)
        .background(MicaBackground(theme: theme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
        }
    }

    private func scrollToActive(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            switch model.activeTab {
            case .document(let id):
                proxy.scrollTo(id, anchor: .center)
            case .settings:
                proxy.scrollTo("taccuino.settings.tab", anchor: .center)
            }
        }
    }

    private func tab(for document: Document, width: CGFloat) -> some View {
        TabItemView(
            document: document,
            isActive: model.activeTab == .document(document.id),
            width: width,
            theme: theme,
            isHovered: hoveredDocument == document.id,
            isDropTarget: dropTarget == document.id,
            onSelect: {
                model.selectDocument(document.id)
                model.editor?.focusActive()
            },
            onClose: { model.closeTab(document.id) },
            onHover: { hovering in
                if hovering {
                    hoveredDocument = document.id
                } else if hoveredDocument == document.id {
                    hoveredDocument = nil
                }
            },
            onRightClick: { point in
                model.openTabMenu(document, at: rootPoint(from: point))
            },
            onMiddleClick: { model.closeTab(document.id) },
            onDrag: {
                draggingDocument = document.id
                model.editor?.persistState()
            },
            onDrop: { draggedID in
                if let draggedID, draggedID != document.id {
                    model.moveDocument(from: draggedID, before: document.id)
                }
                dropTarget = nil
                draggingDocument = nil
            },
            onDropTarget: { hovering in
                dropTarget = hovering ? document.id : nil
            }
        )
        .zIndex(draggingDocument == document.id ? 1 : 0)
    }

    private func settingsTab(width: CGFloat) -> some View {
        let active = model.isSettingsActive
        return HStack(spacing: 7) {
            if width >= 150 {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(active ? theme.text : theme.secondaryText)
            }
            Text(L.t("Impostazioni", "Settings"))
                .font(FluentFont.ui(12.5))
                .foregroundColor(active ? theme.text : theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if hoveringSettings || (active && width >= 150) {
                FluentIconButton(systemName: "xmark", theme: theme, size: 9) {
                    model.closeSettingsTab()
                }
                .frame(width: 18, height: 18)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .frame(width: width, height: TabMetrics.itemHeight)
        .background(
            TabShape()
                .fill(active ? theme.tabActive : (hoveringSettings ? theme.hover.opacity(0.75) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectSettings() }
        .onHover { hoveringSettings = $0 }
        .background(
            RightClickCatcher(
                onRightClick: { point in
                    model.popup = PopupState(
                        items: [
                            MenuItem(title: L.t("Chiudi scheda", "Close tab"),
                                     shortcut: "Ctrl+W",
                                     action: { model.closeSettingsTab() })
                        ],
                        anchor: rootPoint(from: point),
                        width: 240
                    )
                },
                onMiddleClick: { model.closeSettingsTab() }
            )
        )
    }

    private var plusButton: some View {
        Button {
            model.newTab()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.text)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hoveringPlus ? theme.hover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 2)
        .onHover { hoveringPlus = $0 }
        .help(L.t("Nuova scheda", "New tab"))
    }

    private func rootPoint(from windowPoint: NSPoint) -> CGPoint {
        CGPoint(x: windowPoint.x, y: model.windowSize.height - windowPoint.y)
    }
}

private struct TabItemView: View {
    @ObservedObject var document: Document
    let isActive: Bool
    let width: CGFloat
    let theme: Theme
    let isHovered: Bool
    let isDropTarget: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void
    let onRightClick: (NSPoint) -> Void
    let onMiddleClick: () -> Void
    let onDrag: () -> Void
    let onDrop: (UUID?) -> Void
    let onDropTarget: (Bool) -> Void

    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            if width >= 120 {
                Image(systemName: "doc.text")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(isActive ? theme.text : theme.secondaryText)
            }
            Text(document.displayName)
                .font(FluentFont.ui(12.5))
                .foregroundColor(isActive ? theme.text : theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                if isHovered {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 18, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(hoveringClose ? theme.pressed : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveringClose = $0 }
                } else if document.isModified {
                    Circle()
                        .fill(theme.secondaryText)
                        .frame(width: 7, height: 7)
                } else if isActive {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 18, height: 18)
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(width: width, height: TabMetrics.itemHeight)
        .background(
            TabShape()
                .fill(isActive ? theme.tabActive : (isHovered ? theme.hover.opacity(0.7) : Color.clear))
        )
        .overlay(alignment: .leading) {
            if isDropTarget {
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: 2, height: 22)
                    .padding(.leading, -1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { onHover($0) }
        .background(
            RightClickCatcher(onRightClick: onRightClick, onMiddleClick: onMiddleClick)
        )
        .onDrag {
            onDrag()
            return NSItemProvider(object: document.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(
            targetID: document.id,
            onTarget: onDropTarget,
            onPerform: onDrop
        ))
        .help(L.t("\(document.displayName) — clic centrale per chiudere, clic destro per il menu",
                  "\(document.displayName) — middle-click to close, right-click for the menu"))
    }
}

private struct TabDropDelegate: DropDelegate {
    let targetID: UUID
    let onTarget: (Bool) -> Void
    let onPerform: (UUID?) -> Void

    func dropEntered(info: DropInfo) {
        onTarget(true)
    }

    func dropExited(info: DropInfo) {
        onTarget(false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { onTarget(false) }
        guard let provider = info.itemProviders(for: [.text]).first else {
            onPerform(nil)
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            let string = object as? NSString
            DispatchQueue.main.async {
                onPerform(string.flatMap { UUID(uuidString: $0 as String) })
            }
        }
        return true
    }
}
