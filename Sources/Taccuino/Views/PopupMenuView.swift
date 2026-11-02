import SwiftUI

struct PopupLayer: View {
    @ObservedObject var model: WindowModel
    let theme: Theme

    var body: some View {
        GeometryReader { geo in
            if let popup = model.popup {
                let metrics = MenuPanel.metrics(for: popup.items, width: popup.width)
                let origin = CGPoint(
                    x: min(max(8, popup.anchor.x), max(8, geo.size.width - metrics.width - 8)),
                    y: min(max(8, popup.anchor.y), max(8, geo.size.height - metrics.height - 8))
                )
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { model.closePopup() }

                    MenuPanel(
                        items: popup.items,
                        theme: theme,
                        width: metrics.width,
                        origin: origin,
                        rootSize: geo.size,
                        onAction: { item in
                            model.closePopup()
                            DispatchQueue.main.async {
                                item.action?()
                            }
                        }
                    )
                    .offset(x: origin.x, y: origin.y)
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
    }
}

struct MenuPanel: View {
    let items: [MenuItem]
    let theme: Theme
    let width: CGFloat
    let origin: CGPoint
    let rootSize: CGSize
    let onAction: (MenuItem) -> Void

    @State private var submenuIndex: Int?
    @State private var hoveringIndex: Int?

    private let itemHeight: CGFloat = 32
    private let separatorHeight: CGFloat = 9
    private let panelPadding: CGFloat = 4
    private let submenuWidth: CGFloat = 250

    static func metrics(for items: [MenuItem], width: CGFloat) -> (width: CGFloat, height: CGFloat) {
        var height: CGFloat = 8
        for item in items {
            height += item.isSeparator ? 9 : 32
        }
        if height > 460 { height = 460 }
        return (width, height)
    }

    private var hasChecks: Bool {
        items.contains { $0.isChecked }
    }

    private var rawContentHeight: CGFloat {
        8 + items.reduce(CGFloat(0)) { partial, item in
            partial + (item.isSeparator ? separatorHeight : itemHeight)
        }
    }

    private var scrollable: Bool {
        rawContentHeight > 440
    }

    private var contentHeight: CGFloat {
        let raw = 8 + items.reduce(CGFloat(0)) { partial, item in
            partial + (item.isSeparator ? separatorHeight : itemHeight)
        }
        return min(raw, 460)
    }

    private var content: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if item.isSeparator {
                    Rectangle()
                        .fill(theme.border)
                        .frame(height: 1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .frame(height: separatorHeight)
                } else {
                    row(item: item, index: index)
                }
            }
        }
        .padding(.vertical, panelPadding)
    }

    var body: some View {
        Group {
            if scrollable {
                ScrollView(.vertical, showsIndicators: true) {
                    content
                }
                .frame(width: width, height: 460)
            } else {
                content
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.menuBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.menuBorder, lineWidth: 1)
        )
        .shadow(color: theme.shadow, radius: 22, x: 0, y: 10)
        .overlay(alignment: .topLeading) {
            if !scrollable, let submenuIndex, items.indices.contains(submenuIndex),
               let submenu = items[submenuIndex].submenu, !submenu.isEmpty {
                let subMetrics = MenuPanel.metrics(for: submenu, width: submenuWidth)
                let itemTop = topOffset(for: submenuIndex)
                let opensRight = origin.x + width + submenuWidth + 8 <= rootSize.width
                let x = submenuX(preferred: opensRight ? width - 2 : -submenuWidth + 2)
                let desiredY = itemTop - panelPadding
                let globalY = origin.y + desiredY
                let maxY = max(8, rootSize.height - subMetrics.height - 8)
                let y = max(8, min(globalY, maxY)) - origin.y
                MenuPanel(
                    items: submenu,
                    theme: theme,
                    width: submenuWidth,
                    origin: CGPoint(x: origin.x + x, y: origin.y + y),
                    rootSize: rootSize,
                    onAction: onAction
                )
                .offset(x: x, y: y)
            }
        }
    }

    private func row(item: MenuItem, index: Int) -> some View {
        let isHovered = hoveringIndex == index
        let hasSubmenu = !(item.submenu?.isEmpty ?? true)
        return HStack(spacing: 8) {
            if hasChecks {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.accent)
                    .frame(width: 14)
                    .opacity(item.isChecked ? 1 : 0)
            }
            Text(item.title)
                .font(FluentFont.ui(13))
                .foregroundColor(item.isEnabled ? theme.text : theme.tertiaryText)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(FluentFont.ui(11.5))
                    .foregroundColor(theme.tertiaryText)
            }
            if hasSubmenu {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: itemHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered && item.isEnabled ? theme.accent.opacity(0.14) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveringIndex = index
                submenuIndex = hasSubmenu ? index : nil
            } else if hoveringIndex == index {
                hoveringIndex = nil
            }
        }
        .onTapGesture {
            guard item.isEnabled else { return }
            if hasSubmenu {
                submenuIndex = index
            } else {
                onAction(item)
            }
        }
    }

    private func submenuX(preferred: CGFloat) -> CGFloat {
        let absolute = origin.x + preferred
        if absolute < 8 {
            return preferred + (8 - absolute)
        }
        if absolute + submenuWidth > rootSize.width - 8 {
            return preferred - (absolute + submenuWidth - (rootSize.width - 8))
        }
        return preferred
    }

    private func topOffset(for index: Int) -> CGFloat {
        var y = panelPadding
        for i in 0..<index {
            y += items[i].isSeparator ? separatorHeight : itemHeight
        }
        return y
    }
}
