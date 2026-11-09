import AppKit

/// 窗格布局。顺序与 QSpace 的布局选择器一致（图标条从上到下）。
enum LayoutMode: String, CaseIterable {
    case quad, dualV, leftSplit, rightSplit, topSplit, bottomSplit,
         dualH, single, cols3, cols4, rows3, rows4

    var title: String {
        switch self {
        case .quad: return "四宫格".localized
        case .dualV: return "左右两栏".localized
        case .leftSplit: return "左二右一".localized
        case .rightSplit: return "左一右二".localized
        case .topSplit: return "上整下二".localized
        case .bottomSplit: return "上二下整".localized
        case .dualH: return "上下两行".localized
        case .single: return "单窗格".localized
        case .cols3: return "三列".localized
        case .cols4: return "四列".localized
        case .rows3: return "三行".localized
        case .rows4: return "四行".localized
        }
    }

    var slotCount: Int {
        switch self {
        case .single: return 1
        case .dualV, .dualH: return 2
        case .cols3, .rows3, .leftSplit, .rightSplit, .topSplit, .bottomSplit: return 3
        case .quad, .cols4, .rows4: return 4
        }
    }

    /// 在给定矩形内画出布局示意图：一个直角外框 + 内部分隔线（格子之间无缝），
    /// 风格与 Maple 的 icon_layout_template_* 一致（方正、无圆角、无格间边距）。
    /// 坐标系按「左上角为原点、y 向下」，与 normalizedCells 一致（图标视图 flipped，直接可用）。
    func drawIcon(in rect: NSRect, color: NSColor) {
        color.setStroke()
        let margin = max(1, rect.width * 0.07)
        let f = NSRect(x: rect.minX + margin,
                       y: rect.minY + margin,
                       width: rect.width - margin * 2,
                       height: rect.height - margin * 2)
        let line = max(1, rect.width * 0.08)
        let minX = f.minX, maxX = f.maxX, minY = f.minY, maxY = f.maxY
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        var segs: [(NSPoint, NSPoint)] = []
        switch self {
        case .single:
            break
        case .dualV:
            segs = [(NSPoint(x: cx, y: minY), NSPoint(x: cx, y: maxY))]
        case .dualH:
            segs = [(NSPoint(x: minX, y: cy), NSPoint(x: maxX, y: cy))]
        case .quad:
            segs = [(NSPoint(x: cx, y: minY), NSPoint(x: cx, y: maxY)),
                    (NSPoint(x: minX, y: cy), NSPoint(x: maxX, y: cy))]
        case .leftSplit:
            segs = [(NSPoint(x: cx, y: minY), NSPoint(x: cx, y: maxY)),
                    (NSPoint(x: minX, y: cy), NSPoint(x: cx, y: cy))]
        case .rightSplit:
            segs = [(NSPoint(x: cx, y: minY), NSPoint(x: cx, y: maxY)),
                    (NSPoint(x: cx, y: cy), NSPoint(x: maxX, y: cy))]
        case .topSplit:
            segs = [(NSPoint(x: minX, y: cy), NSPoint(x: maxX, y: cy)),
                    (NSPoint(x: cx, y: cy), NSPoint(x: cx, y: maxY))]
        case .bottomSplit:
            segs = [(NSPoint(x: minX, y: cy), NSPoint(x: maxX, y: cy)),
                    (NSPoint(x: cx, y: minY), NSPoint(x: cx, y: cy))]
        case .cols3:
            let w = maxX - minX
            segs = [1, 2].map { let x = minX + w * CGFloat($0) / 3; return (NSPoint(x: x, y: minY), NSPoint(x: x, y: maxY)) }
        case .cols4:
            let w = maxX - minX
            segs = [1, 2, 3].map { let x = minX + w * CGFloat($0) / 4; return (NSPoint(x: x, y: minY), NSPoint(x: x, y: maxY)) }
        case .rows3:
            let h = maxY - minY
            segs = [1, 2].map { let y = minY + h * CGFloat($0) / 3; return (NSPoint(x: minX, y: y), NSPoint(x: maxX, y: y)) }
        case .rows4:
            let h = maxY - minY
            segs = [1, 2, 3].map { let y = minY + h * CGFloat($0) / 4; return (NSPoint(x: minX, y: y), NSPoint(x: maxX, y: y)) }
        }
        // 外框：直角、无圆角
        let frame = NSBezierPath(rect: f)
        frame.lineWidth = line
        frame.stroke()
        // 内部分隔线（与框相接，无格间边距）
        for (a, b) in segs {
            let p = NSBezierPath()
            p.move(to: a)
            p.line(to: b)
            p.lineWidth = line
            p.stroke()
        }
    }

    /// 工具栏 / 菜单用的 16pt 模板图标。
    var icon: NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            self.drawIcon(in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 归一化切分（原点在左上）。
    var normalizedCells: [CGRect] {
        switch self {
        case .single:
            return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        case .dualV:
            return [CGRect(x: 0, y: 0, width: 0.5, height: 1),
                    CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case .dualH:
            return [CGRect(x: 0, y: 0, width: 1, height: 0.5),
                    CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]
        case .quad:
            return [CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                    CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case .leftSplit:
            // 左栏上下两格 + 右侧一整栏
            return [CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                    CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case .rightSplit:
            // 左侧一整栏 + 右栏上下两格
            return [CGRect(x: 0, y: 0, width: 0.5, height: 1),
                    CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case .topSplit:
            // 上面一整行 + 下面左右两格
            return [CGRect(x: 0, y: 0, width: 1, height: 0.5),
                    CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                    CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case .bottomSplit:
            // 上面左右两格 + 下面一整行
            return [CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]
        case .cols3:
            return (0..<3).map { CGRect(x: CGFloat($0) / 3, y: 0, width: 1 / 3, height: 1) }
        case .cols4:
            return (0..<4).map { CGRect(x: CGFloat($0) / 4, y: 0, width: 0.25, height: 1) }
        case .rows3:
            return (0..<3).map { CGRect(x: 0, y: CGFloat($0) / 3, width: 1, height: 1 / 3) }
        case .rows4:
            return (0..<4).map { CGRect(x: 0, y: CGFloat($0) / 4, width: 1, height: 0.25) }
        }
    }
}

/// 多窗格容器：负责创建/回收窗格并按当前布局摆放。
final class WorkspaceArea: NSView {

    private(set) var panes: [PaneView] = []
    private(set) var focusedPane: PaneView?
    private(set) var mode: LayoutMode = .single

    // 分隔条：分界的原始比例（升序）+ 当前比例，两者一一对应
    private var vBoundaries: [CGFloat] = []
    private var hBoundaries: [CGFloat] = []
    private var vRatios: [CGFloat] = []
    private var hRatios: [CGFloat] = []
    /// 按下瞬间的比例快照：拖动按「总位移」计算，不会因为累加而漂移或方向反掉。
    private var dragStartV: [CGFloat] = []
    private var dragStartH: [CGFloat] = []
    private var dividers: [SplitterView] = []
    /// 点击切焦点的本地事件监听。
    private var clickMonitor: Any?

    var onFocusChange: ((PaneView) -> Void)?
    var onQuickLook: ((PaneView) -> Void)?
    var onNavigate: ((PaneView) -> Void)?
    /// 焦点窗格的显示类型变化（顶部工具栏据此同步）。
    var onViewModeChange: ((PaneView) -> Void)?
    /// 个人收藏内容变化（侧栏需要刷新）。
    var onFavoritesChange: (() -> Void)?
    /// 请求删除某个标签（弹出访达样式的删除确认遮罩弹窗）。
    var onRequestDeleteTag: ((String) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        mode = LayoutMode(rawValue: AppSettings.layout) ?? .single
        loadSplits()
        rebuildPanes()
        rebuildDividers()
        NotificationCenter.default.addObserver(forName: .paneAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.needsLayout = true
            self?.needsDisplay = true
            self?.layoutSubtreeIfNeeded()
            self?.panes.forEach { $0.updateFocusVisuals() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 点任意位置切焦点

    /// 只要点在某个窗格范围内（文件行、空白处、状态栏、路径栏都算），
    /// 就把它设为焦点窗格。用本地事件监听而不是逐个视图拦截：
    /// 这样窗口未激活时的那一次「激活点击」也能生效，也不会影响行选中与拖拽。
    private func installClickMonitor(in window: NSWindow) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, event.window === window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if let pane = self.panes.first(where: { $0.frame.contains(point) }),
               pane !== self.focusedPane {
                self.setFocused(pane)
            }
            return event
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let window { installClickMonitor(in: window) }
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    /// 窗格之间的 1pt 缝隙底色，同样用绘制填充。
    override func draw(_ dirtyRect: NSRect) {
        if AppSettings.cornerScheme == .cards {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        } else {
            Theme.hairline.setFill()
            bounds.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        let cells = cellFrames()
        let normalized = mode.normalizedCells
        for (index, pane) in panes.enumerated() where index < cells.count {
            pane.frame = cells[index]
            if index < normalized.count {
                let n = normalized[index]
                pane.isAtBottomRight = (n.maxX >= 0.9999 && n.maxY >= 0.9999)
                pane.isAtBottomLeft = (n.minX <= 0.0001 && n.maxY >= 0.9999)
                pane.isAtTopRight = (n.maxX >= 0.9999 && n.minY <= 0.0001)
                pane.isAtTopLeft = (n.minX <= 0.0001 && n.minY <= 0.0001)
            }
            pane.updateFocusVisuals()
        }
        layoutDividers()
    }

    // MARK: - 分隔条

    /// 某条分界（原始比例）在当前模式下的实际比例。
    private func mappedX(_ value: CGFloat) -> CGFloat {
        if value <= 0.0001 { return 0 }
        if value >= 0.9999 { return 1 }
        if let index = vBoundaries.firstIndex(where: { abs($0 - value) < 0.001 }), index < vRatios.count {
            return vRatios[index]
        }
        return value
    }

    private func mappedY(_ value: CGFloat) -> CGFloat {
        if value <= 0.0001 { return 0 }
        if value >= 0.9999 { return 1 }
        if let index = hBoundaries.firstIndex(where: { abs($0 - value) < 0.001 }), index < hRatios.count {
            return hRatios[index]
        }
        return value
    }

    private static func uniqueBoundaries(_ values: [CGFloat]) -> [CGFloat] {
        var result: [CGFloat] = []
        for value in values where value > 0.0001 && value < 0.9999 {
            if !result.contains(where: { abs($0 - value) < 0.001 }) { result.append(value) }
        }
        return result.sorted()
    }

    /// 载入当前布局的分界比例（优先用上次拖动保存的值）。
    private func loadSplits() {
        let cells = mode.normalizedCells
        vBoundaries = Self.uniqueBoundaries(cells.map { $0.minX })
        hBoundaries = Self.uniqueBoundaries(cells.map { $0.minY })
        let saved = AppSettings.splits(for: mode)
        vRatios = vBoundaries.enumerated().map { index, original in
            index < saved.vertical.count ? saved.vertical[index] : original
        }
        hRatios = hBoundaries.enumerated().map { index, original in
            index < saved.horizontal.count ? saved.horizontal[index] : original
        }
    }

    private func rebuildDividers() {
        dividers.forEach { $0.removeFromSuperview() }
        dividers.removeAll()

        for (index, _) in vBoundaries.enumerated() {
            let divider = SplitterView()
            divider.axis = .vertical
            divider.onDragBegan = { [weak self] in self?.beginDrag() }
            divider.onDrag = { [weak self] delta in self?.dragVertical(index, translation: delta) }
            divider.onDragEnd = { [weak self] in self?.persistSplits() }
            addSubview(divider, positioned: .above, relativeTo: nil)
            dividers.append(divider)
        }
        for (index, _) in hBoundaries.enumerated() {
            let divider = SplitterView()
            divider.axis = .horizontal
            divider.onDragBegan = { [weak self] in self?.beginDrag() }
            divider.onDrag = { [weak self] delta in self?.dragHorizontal(index, translation: delta) }
            divider.onDragEnd = { [weak self] in self?.persistSplits() }
            addSubview(divider, positioned: .above, relativeTo: nil)
            dividers.append(divider)
        }
        layoutDividers()
    }

    /// 分隔条只覆盖它相邻窗格的范围（如「上整下二」的竖线只在下方一半）。
    private func layoutDividers() {
        guard !dividers.isEmpty else { return }
        let rect = bounds
        let cells = mode.normalizedCells
        var cursor = 0

        for (index, boundary) in vBoundaries.enumerated() {
            let ratio = index < vRatios.count ? vRatios[index] : boundary
            let x = rect.minX + ratio * rect.width
            var span: NSRect = .zero
            for cell in cells {
                let touches = abs(cell.minX - boundary) < 0.001 || abs(cell.maxX - boundary) < 0.001
                guard touches else { continue }
                let y0 = rect.minY + mappedY(cell.minY) * rect.height
                let y1 = rect.minY + mappedY(cell.maxY) * rect.height
                span = span.isEmpty ? NSRect(x: x, y: y0, width: 1, height: y1 - y0)
                                    : span.union(NSRect(x: x, y: y0, width: 1, height: y1 - y0))
            }
            guard cursor < dividers.count else { return }
            let divider = dividers[cursor]
            cursor += 1
            guard !span.isEmpty else { divider.frame = .zero; continue }
            // 命中区 ±5pt（与列分隔条一致），细线也好抓。z 序由 rebuildDividers 的
            // `positioned: .above` 保证，这里只改 frame，绝不在布局时移除重建（否则会打断拖拽）。
            divider.frame = NSRect(x: x - Self.dividerHitHalf, y: span.minY,
                                   width: Self.dividerHitHalf * 2, height: span.height)
        }

        for (index, boundary) in hBoundaries.enumerated() {
            let ratio = index < hRatios.count ? hRatios[index] : boundary
            let y = rect.minY + ratio * rect.height
            var span: NSRect = .zero
            for cell in cells {
                let touches = abs(cell.minY - boundary) < 0.001 || abs(cell.maxY - boundary) < 0.001
                guard touches else { continue }
                let x0 = rect.minX + mappedX(cell.minX) * rect.width
                let x1 = rect.minX + mappedX(cell.maxX) * rect.width
                span = span.isEmpty ? NSRect(x: x0, y: y, width: x1 - x0, height: 1)
                                    : span.union(NSRect(x: x0, y: y, width: x1 - x0, height: 1))
            }
            guard cursor < dividers.count else { return }
            let divider = dividers[cursor]
            cursor += 1
            guard !span.isEmpty else { divider.frame = .zero; continue }
            divider.frame = NSRect(x: span.minX, y: y - Self.dividerHitHalf,
                                   width: span.width, height: Self.dividerHitHalf * 2)
        }
    }

    /// 分隔条命中区的半宽：线本身只有 1pt，但可抓区域放宽到 ±5pt，和列表列线一致。
    private static let dividerHitHalf: CGFloat = 5

    private func beginDrag() {
        dragStartV = vRatios
        dragStartH = hRatios
    }

    private func dragVertical(_ index: Int, translation: CGFloat) {
        guard vRatios.indices.contains(index),
              dragStartV.indices.contains(index),
              bounds.width > 0 else { return }
        let minRatio = 150 / bounds.width
        var next = dragStartV[index] + translation / bounds.width
        let lower = (index == 0 ? 0 : vRatios[index - 1]) + minRatio
        let upper = (index == vRatios.count - 1 ? 1 : vRatios[index + 1]) - minRatio
        next = min(max(next, lower), max(lower, upper))
        vRatios[index] = next
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func dragHorizontal(_ index: Int, translation: CGFloat) {
        guard hRatios.indices.contains(index),
              dragStartH.indices.contains(index),
              bounds.height > 0 else { return }
        let minRatio = 120 / bounds.height
        var next = dragStartH[index] + translation / bounds.height
        let lower = (index == 0 ? 0 : hRatios[index - 1]) + minRatio
        let upper = (index == hRatios.count - 1 ? 1 : hRatios[index + 1]) - minRatio
        next = min(max(next, lower), max(lower, upper))
        hRatios[index] = next
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func persistSplits() {
        AppSettings.setSplits(vertical: vRatios, horizontal: hRatios, for: mode)
    }

    private func cellFrames() -> [NSRect] {
        if AppSettings.cornerScheme == .cards {
            let pad: CGFloat = 6
            let cardGap: CGFloat = 6
            let innerRect = bounds.insetBy(dx: pad, dy: pad)
            guard innerRect.width > 0, innerRect.height > 0 else { return [] }
            let cells = mode.normalizedCells
            var result: [NSRect] = []
            for cell in cells {
                let x0 = mappedX(cell.minX)
                let x1 = mappedX(cell.maxX)
                let y0 = mappedY(cell.minY)
                let y1 = mappedY(cell.maxY)
                var frame = NSRect(
                    x: innerRect.minX + x0 * innerRect.width,
                    y: innerRect.minY + y0 * innerRect.height,
                    width: (x1 - x0) * innerRect.width,
                    height: (y1 - y0) * innerRect.height
                )
                let isLeftEdge = cell.minX <= 0.0001
                let isRightEdge = cell.maxX >= 0.9999
                let isTopEdge = cell.minY <= 0.0001
                let isBottomEdge = cell.maxY >= 0.9999
                let halfGap = cardGap / 2
                frame.origin.x += isLeftEdge ? 0 : halfGap
                frame.origin.y += isTopEdge ? 0 : halfGap
                frame.size.width -= (isLeftEdge ? 0 : halfGap) + (isRightEdge ? 0 : halfGap)
                frame.size.height -= (isTopEdge ? 0 : halfGap) + (isBottomEdge ? 0 : halfGap)
                result.append(frame.integral)
            }
            return result
        }

        let gap = Theme.paneGap
        let rect = bounds
        let cells = mode.normalizedCells
        var result: [NSRect] = []
        for cell in cells {
            let x0 = mappedX(cell.minX)
            let x1 = mappedX(cell.maxX)
            let y0 = mappedY(cell.minY)
            let y1 = mappedY(cell.maxY)
            var frame = NSRect(
                x: rect.minX + x0 * rect.width,
                y: rect.minY + y0 * rect.height,
                width: (x1 - x0) * rect.width,
                height: (y1 - y0) * rect.height
            )
            // 用 1pt 的缝表现分隔线（容器背景是分隔色）
            let isLeftEdge = cell.minX <= 0.0001
            let isRightEdge = cell.maxX >= 0.9999
            let isTopEdge = cell.minY <= 0.0001
            let isBottomEdge = cell.maxY >= 0.9999
            frame.origin.x += isLeftEdge ? 0 : gap
            frame.origin.y += isTopEdge ? 0 : gap
            frame.size.width -= (isLeftEdge ? 0 : gap) + (isRightEdge ? 0 : gap)
            frame.size.height -= (isTopEdge ? 0 : gap) + (isBottomEdge ? 0 : gap)
            result.append(frame.integral)
        }
        return result
    }

    // MARK: - 窗格管理

    func setMode(_ newMode: LayoutMode) {
        guard newMode != mode else { return }
        mode = newMode
        AppSettings.layout = newMode.rawValue
        loadSplits()
        rebuildPanes()
        rebuildDividers()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func rebuildPanes() {
        let needed = mode.slotCount
        let savedPaths = AppSettings.panePaths

        // 回收多余的窗格
        while panes.count > needed {
            let pane = panes.removeLast()
            pane.removeFromSuperview()
        }
        // 补齐缺少的窗格
        let savedModes = AppSettings.paneViewModes
        while panes.count < needed {
            let index = panes.count
            let startURL = Self.startURL(for: index, savedPaths: savedPaths, fallbackPane: panes.first)
            let pane = PaneView(startURL: startURL)
            // 恢复该窗格上次的显示方式
            if index < savedModes.count, let mode = ViewMode(rawValue: savedModes[index]) {
                pane.restoreViewMode(mode)
            }
            pane.delegate = self
            pane.onRequestDeleteTag = { [weak self] tag in
                self?.onRequestDeleteTag?(tag)
            }
            addSubview(pane)
            panes.append(pane)
        }

        if focusedPane == nil || !panes.contains(where: { $0 === focusedPane }) {
            // 恢复上次聚焦的窗格
            let savedIndex = AppSettings.focusedPaneIndex
            if savedIndex >= 0, savedIndex < panes.count {
                setFocused(panes[savedIndex])
            } else {
                setFocused(panes.first)
            }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private static func startURL(for index: Int, savedPaths: [String], fallbackPane: PaneView?) -> URL {
        if index < savedPaths.count {
            let url = URL(fileURLWithPath: savedPaths[index])
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let fallbackPane { return fallbackPane.currentURL }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    func setFocused(_ pane: PaneView?) {
        focusedPane?.isFocused = false
        focusedPane = pane
        pane?.isFocused = true
        if let pane { onFocusChange?(pane) }
    }

    func openInFocusedPane(_ url: URL) {
        if let focusedPane {
            focusedPane.navigate(to: url)
        } else if panes.count > 1 {
            panes[1].navigate(to: url)
        } else {
            panes.first?.navigate(to: url)
        }
    }

    /// 侧栏点击标签：交给焦点窗格。
    func showTagInFocusedPane(_ tag: String) {
        (focusedPane ?? panes.first)?.showTag(tag)
    }

    /// 侧栏点击「所有标签…」：交给焦点窗格切换为访达同款「所有标签」分栏视图。
    func showAllTagsInFocusedPane(selecting initialTag: String? = nil) {
        (focusedPane ?? panes.first)?.showAllTags(selecting: initialTag)
    }

    /// 查询是否有窗格正在展示指定标签
    func isShowingTag(_ tag: String) -> Bool {
        panes.contains(where: { $0.isTagView && $0.tagName == tag })
    }

    /// 获取所有正在展示指定标签的窗格中已加载的文件 URLs
    func getURLsForTagInPanes(_ tag: String) -> [URL] {
        var urls: [URL] = []
        for pane in panes where pane.isTagView && pane.tagName == tag {
            urls.append(contentsOf: pane.items.map { $0.url })
        }
        return urls
    }

    /// 当某个标签被删除时：清空所有正在展示此标签的窗格并置于未选中状态
    func handleTagRemoved(_ tagName: String) {
        for pane in panes {
            if pane.tagName == tagName {
                pane.clearTagView()
            }
        }
    }

    func openInOtherPane(_ url: URL) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            // 普通文件不能作为目录打开，自动转换为在另一个窗格定位该文件
            locateInOtherPane(url)
            return
        }
        if panes.count <= 1 {
            setMode(.dualV)
        }
        guard panes.count > 1 else {
            openInFocusedPane(url)
            return
        }
        let target = panes.first { $0 !== focusedPane } ?? panes[1]
        target.navigate(to: url)
        setFocused(target)
    }

    /// 在另一个窗格中打开该项目所在的父文件夹，并自动滚动高亮选中该项目
    func locateInOtherPane(_ url: URL) {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        if panes.count <= 1 {
            setMode(.dualV)
        }
        guard panes.count > 1 else {
            focusedPane?.navigate(to: parent)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.focusedPane?.select(urls: [url.standardizedFileURL])
            }
            return
        }
        let target = panes.first { $0 !== focusedPane } ?? panes[1]
        target.navigate(to: parent)
        setFocused(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            target.select(urls: [url.standardizedFileURL])
        }
    }

    func reloadAll() {
        panes.forEach { $0.reload() }
    }

    /// 「查看显示选项」：图标大小实时应用到所有窗格。
    func applyIconSize(_ size: CGFloat) {
        panes.forEach { $0.updateIconSize(size) }
    }

    /// 「查看显示选项」：列表行高实时应用到所有窗格。
    func applyRowHeight(_ height: CGFloat) {
        panes.forEach { $0.updateRowHeight(height) }
    }

    func undoAction() {
        focusedPane?.undoAction()
    }

    func redoAction() {
        focusedPane?.redoAction()
    }

    func saveState() {
        AppSettings.panePaths = panes.map { $0.currentURL.path }
        AppSettings.paneViewModes = panes.map { $0.viewMode.rawValue }
        AppSettings.layout = mode.rawValue
        if let focusedPane, let index = panes.firstIndex(where: { $0 === focusedPane }) {
            AppSettings.focusedPaneIndex = index
        }
    }

}

// MARK: - PaneViewDelegate

extension WorkspaceArea: PaneViewDelegate {

    func paneDidActivate(_ pane: PaneView) {
        setFocused(pane)
    }

    func pane(_ pane: PaneView, didNavigateTo url: URL) {
        saveState()
        onNavigate?(pane)
    }

    func pane(_ pane: PaneView, didChangeViewMode mode: ViewMode) {
        guard pane === focusedPane else { return }
        onViewModeChange?(pane)
    }

    func paneDidRequestQuickLook(_ pane: PaneView) {
        onQuickLook?(pane)
    }

    func paneCanOpenInOtherPane(_ pane: PaneView) -> Bool {
        panes.count > 1
    }

    func pane(_ pane: PaneView, openInOtherPane url: URL) {
        guard panes.count > 1 else { return }
        let target = panes.first { $0 !== pane } ?? panes[1]
        target.navigate(to: url)
        setFocused(target)
    }

    func paneDidChangeFavorites(_ pane: PaneView) {
        onFavoritesChange?()
    }
}
