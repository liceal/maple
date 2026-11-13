import AppKit

/// 布局选择器：原生竖向图标条。
/// 每行一个布局示意图，当前布局高亮并带勾选，点一下立刻切换。
final class LayoutPickerController: NSObject {

    var onPick: ((LayoutMode) -> Void)?
    var onDismiss: (() -> Void)?

    private let panel = LayoutPanel(contentRect: NSRect(x: 0, y: 0, width: 68, height: 372),
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered,
                                    defer: false)
    private let list: LayoutListView
    private var monitor: Any?
    private weak var hostWindow: NSWindow?
    /// 锚点矩形（屏幕坐标）：点在按钮上时这次点击被吃掉，表现为「再点一次收起」。
    private var anchorScreenRect: NSRect = .zero

    private static let width: CGFloat = 68
    private static let padding: CGFloat = 6

    init(selected: LayoutMode) {
        list = LayoutListView(selected: selected)
        super.init()
        build()
        list.onPick = { [weak self] mode in self?.pick(mode) }
    }

    // MARK: - 构建

    private func build() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        // 切换到其它应用时面板要跟着隐藏，不能继续浮在屏幕最前面
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true

        let effect = LayoutVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Theme.roundedCornerMask(radius: 12)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        list.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: effect.topAnchor, constant: Self.padding),
            list.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -Self.padding),
            list.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: effect.trailingAnchor)
        ])
        panel.contentView = effect
    }

    // MARK: - 显示 / 关闭

    func show(anchoredTo anchor: NSView, in window: NSWindow) {
        hostWindow = window
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        anchorScreenRect = anchorRect

        let height = CGFloat(LayoutMode.allCases.count) * LayoutListView.rowHeight + Self.padding * 2
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero

        let spaceBelow = anchorRect.minY - visible.minY - 8
        let spaceAbove = visible.maxY - anchorRect.maxY - 8
        let placeBelow = spaceBelow >= height || spaceBelow >= spaceAbove
        let panelHeight = min(height, max(160, placeBelow ? spaceBelow : spaceAbove))

        var x = anchorRect.midX - Self.width / 2
        var y = placeBelow ? anchorRect.minY - panelHeight - 6 : anchorRect.maxY + 6
        x = min(max(x, visible.minX + 6), max(visible.minX + 6, visible.maxX - Self.width - 6))
        y = min(max(y, visible.minY + 6), max(visible.minY + 6, visible.maxY - panelHeight - 6))

        panel.setFrame(NSRect(x: x, y: y, width: Self.width, height: panelHeight), display: true)
        panel.orderFront(nil)

        // 应用失去焦点（切到别的 App）时收起面板
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidResignActive),
                                               name: NSApplication.didResignActiveNotification,
                                               object: nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }   // Esc 收起
                return event
            }
            if event.window === self.panel { return event }
            let screenPoint: NSPoint = event.window.map {
                $0.convertPoint(toScreen: event.locationInWindow)
            } ?? NSEvent.mouseLocation
            if self.panel.frame.contains(screenPoint) { return event }
            let insideAnchor = self.anchorScreenRect.contains(screenPoint)
            self.close()
            return insideAnchor ? nil : event
        }
    }

    /// 切到别的应用时收起面板。
    @objc private func applicationDidResignActive() {
        close()
    }

    private func pick(_ mode: LayoutMode) {
        let handler = onPick
        close()
        handler?(mode)
    }

    func close() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        NotificationCenter.default.removeObserver(self)
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        if wasVisible { hostWindow?.makeKey() }
        onDismiss?()
    }
}

// MARK: - 视觉容器

private final class LayoutVisualEffectView: NSVisualEffectView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - 图标条

/// 纯绘制的竖向图标条：12 个布局，当前项强调色底 + 白色勾选。
private final class LayoutListView: NSView {

    static let rowHeight: CGFloat = 30

    private(set) var selected: LayoutMode
    var onPick: ((LayoutMode) -> Void)?

    private var hoverIndex: Int?
    private var hoverArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(selected: LayoutMode) {
        self.selected = selected
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    private func rowRect(_ index: Int) -> NSRect {
        NSRect(x: 4,
               y: CGFloat(index) * Self.rowHeight + 1,
               width: max(0, bounds.width - 8),
               height: Self.rowHeight - 2)
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        let index = Int(floor(point.y / Self.rowHeight))
        return LayoutMode.allCases.indices.contains(index) ? index : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, mode) in LayoutMode.allCases.enumerated() {
            let row = rowRect(index)
            let isSelected = mode == selected
            if isSelected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill()
            } else if hoverIndex == index {
                NSColor.labelColor.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill()
            }

            if isSelected {
                drawCheckmark(in: NSRect(x: row.minX + 5, y: row.midY - 4.5, width: 9, height: 9))
            }

            let size: CGFloat = 18
            let iconRect = NSRect(x: bounds.midX - size / 2,
                                  y: row.midY - size / 2,
                                  width: size,
                                  height: size)
            mode.drawIcon(in: iconRect, color: isSelected ? .white : .labelColor)
        }
    }

    private func drawCheckmark(in rect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.midY))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.white.setStroke()
        path.stroke()
    }

    override func mouseMoved(with event: NSEvent) {
        let index = rowIndex(at: convert(event.locationInWindow, from: nil))
        if hoverIndex != index {
            hoverIndex = index
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverIndex != nil {
            hoverIndex = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = rowIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        let mode = LayoutMode.allCases[index]
        selected = mode
        needsDisplay = true
        onPick?(mode)
    }
}

// MARK: - 面板

/// 不会抢走主窗口 key 状态的浮动面板，点外面或 Esc 就收起。
private final class LayoutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
