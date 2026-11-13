import AppKit
import QuartzCore

/// 拖拽分隔线时实际改变宽度的目标：名称列，或某一数据列。
/// 左对齐布局下，抓住两条列之间的分隔线，改的是「左侧」那一列（与访达一致）。
enum ResizableColumn: Equatable {
    case name
    case column(ListColumn)
}

/// 列表视图：访达式分层列表。
/// 文件夹左侧带展开三角，点三角就地展开子目录（树形结构），双击仍然进入目录。
final class FileListView: NSView {

    var onOpen: ((FileItem) -> Void)?
    var onSelectionChange: ((Set<URL>) -> Void)?
    var onActivate: (() -> Void)?
    var onSortChange: ((SortField) -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((FileItem?) -> NSMenu?)?
    var onFileRenamed: ((URL, URL) -> Void)?
    var currentFolderURL: URL?
    var onDropFiles: (([URL], URL, Bool) -> Void)?

    /// 触摸板双指左右滑动手势回调（右滑回退上一级 / 历史后退，左滑历史前进）。
    var canSwipeBack: (() -> Bool)?
    var canSwipeForward: (() -> Bool)?
    var onSwipeBack: (() -> Void)?
    var onSwipeForward: (() -> Void)?

    static let trailingInset: CGFloat = 12
    /// 单元格内图标相对展开三角右侧的间距：和访达一致（紧贴三角右侧约 4pt，彻底消除过宽空隙）
    static let rowIconInset: CGFloat = 4
    /// 名称列单元格内部坐标：图标左沿
    static var nameIconX: CGFloat { rowIconInset }
    /// 名称列单元格内部坐标：文件名左沿
    static var nameTextX: CGFloat { nameIconX + Theme.listIconSize + 6 }
    /// 表头「名称」在列表坐标中的左沿（与访达一致）
    static var headerNameX: CGFloat { 12 }
    /// 名称列至少要留出的宽度
    static let minNameWidth: CGFloat = 108
    /// 名称列最大宽度无限制
    static let maxNameWidth: CGFloat = 10000
    /// 最右侧列分隔线右侧预留的拖拽缓冲留白
    static let trailingBreathingSpace: CGFloat = 28

    /// 表头与列表行共用的列布局：名称列在左，其余列向右依次按各自独立宽度排开，
    /// 超出可视宽度时支持水平滚动。
    struct ColumnLayout {
        var nameRect: NSRect = .zero
        var entries: [(column: ListColumn, rect: NSRect)] = []
        var totalWidth: CGFloat {
            entries.last?.rect.maxX ?? nameRect.maxX
        }
    }

    /// 某一列允许的宽度范围（仅限制最小宽度，最大宽度无上限）。
    struct WidthRange {
        let min: CGFloat
        let max: CGFloat
        /// 光标方向：1 = 只能往右拖（已到最小宽），-1 = 只能往左拖（已到最大宽），0 = 双向。
        func direction(for width: CGFloat) -> Int {
            if width <= min + 0.5 { return 1 }
            if width >= max - 0.5 { return -1 }
            return 0
        }
    }

    /// 一条可拖动的列分隔线：文档坐标位置 x，以及它**左侧**被调整宽度的列。
    struct ColumnDivider {
        let target: ResizableColumn
        let x: CGFloat
        let isRightmost: Bool
    }

    /// 拖拽过程中的临时列宽：先在内存里改，松手才落盘（避免每个鼠标事件都写 UserDefaults）。
    private var sessionWidths: [String: CGFloat] = [:]
    private var sessionNameWidth: CGFloat?

    /// 当前生效的名称列宽。
    private var nameWidth: CGFloat { sessionNameWidth ?? AppSettings.nameColumnWidth }
    /// 当前生效的某列宽度（拖拽中的临时值优先）。
    private func width(of column: ListColumn) -> CGFloat {
        sessionWidths[column.rawValue] ?? column.width
    }

    /// 列表图标尺寸（由右下角自适应滑块调节，16~32）
    var iconSize: CGFloat = AppSettings.listIconSize {
        didSet {
            guard oldValue != iconSize else { return }
            outline.reloadData()
        }
    }

    func applyListSize(iconSize: CGFloat) {
        self.iconSize = iconSize
        self.rowHeight = max(20, iconSize + 6)
        outline.rowHeight = self.rowHeight
        outline.reloadData()
    }

    /// 用户勾选要显示的列（按固定顺序排列）。
    static var selectedColumns: [ListColumn] {
        let enabled = Set(AppSettings.visibleColumns)
        return ListColumn.allCases.filter { enabled.contains($0.rawValue) }
    }

    /// 可见的数据列：完整展示用户勾选的所有列，不再因窗口变窄而隐藏列（过长时可左右滑动）。
    private func visibleColumns() -> [ListColumn] {
        Self.selectedColumns
    }

    /// 计算列布局（左对齐）：名称列与各数据列（含最右侧列）均使用各自独立的列宽，
    /// 调整任意一列（包括最右侧列）都不会影响其他列的宽度。
    private func makeLayout(columns: [ListColumn]) -> ColumnLayout {
        let nameW = max(Self.minNameWidth, nameWidth)
        var x = nameW
        var entries: [(column: ListColumn, rect: NSRect)] = []
        for column in columns {
            let columnWidth = max(column.minWidth, width(of: column))
            entries.append((column, NSRect(x: x, y: 0, width: columnWidth, height: 0)))
            x += columnWidth
        }
        return ColumnLayout(nameRect: NSRect(x: 0, y: 0, width: nameW, height: 0),
                            entries: entries)
    }

    /// 某一列允许的宽度范围：仅保留最小宽度限制，最大宽度无限制，且不随窗口宽度或其他列变化而受限。
    fileprivate func widthRange(for target: ResizableColumn) -> WidthRange {
        switch target {
        case .name:
            return WidthRange(min: Self.minNameWidth, max: Self.maxNameWidth)
        case .column(let column):
            return WidthRange(min: column.minWidth, max: column.maxWidth)
        }
    }

    /// 目标列当前的实际宽度。
    fileprivate func currentWidth(of target: ResizableColumn) -> CGFloat {
        switch target {
        case .name:
            return max(Self.minNameWidth, nameWidth)
        case .column(let column):
            return columnLayout.entries.first { $0.column == column }?.rect.width ?? max(column.minWidth, width(of: column))
        }
    }

    /// 当前列表水平滚动偏移量（文档左边缘相对可视区域左边缘的偏移）。
    fileprivate var scrollOffsetX: CGFloat {
        scroll.contentView.bounds.origin.x
    }

    /// 列表的滚动视图（分隔线层转发滚轮事件用）。
    fileprivate var listScrollView: NSScrollView { scroll }

    /// 分组标题行
    fileprivate final class GroupNode: NSObject {
        let title: String
        let count: Int

        init(title: String, count: Int) {
            self.title = title
            self.count = count
        }
    }

    /// 树节点：children 为 nil 表示还没读取过子目录
    private final class FileNode: NSObject {
        let item: FileItem
        var children: [FileNode]?
        /// 目录里是否有内容（空目录不显示展开三角，与访达一致）
        private var expandable: Bool?

        init(item: FileItem) {
            self.item = item
        }

        func isExpandable() -> Bool {
            if let children, !children.isEmpty { return true }
            if let expandable { return expandable }
            guard item.isNavigable else {
                expandable = false
                return false
            }
            let result = Self.directoryHasVisibleEntry(atPath: item.url.path, showHidden: AppSettings.showHidden)
            expandable = result
            return result
        }

        /// 使用底层 POSIX opendir/readdir 探测目录是否包含至少一个可见子项，零数组分配，遇到首个有效项立即返回。
        private static func directoryHasVisibleEntry(atPath path: String, showHidden: Bool) -> Bool {
            guard let dir = opendir(path) else { return false }
            defer { closedir(dir) }
            while let entry = readdir(dir) {
                let nameLen = Int(entry.pointee.d_namlen)
                guard nameLen > 0 else { continue }
                let isVisible: Bool = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: nameLen) { cStr in
                        if cStr[0] == 46 { // '.'
                            if nameLen == 1 { return false }
                            if nameLen == 2 && cStr[1] == 46 { return false }
                            return showHidden
                        }
                        return true
                    }
                }
                if isVisible { return true }
            }
            return false
        }
    }

    private let header = ListHeaderBar()
    /// 列分隔线层：唯一绘制列间竖线的地方，并统一处理拖拽改宽
    /// （表头和列表正文里的竖线都能拖）。
    private let dividerLayer = ColumnDividerLayer()
    private let scroll = IconScrollView()
    private let outline = KeyOutlineView()
    var outlineView: NSOutlineView { outline }
    private let swipeBadge = SwipeIndicatorBadge()
    private let swipeTriggerThreshold: CGFloat = 128
    private var badgeLeadingConstraint: NSLayoutConstraint!
    private var badgeCenterYConstraint: NSLayoutConstraint!
    private var topLevel: [Any] = []
    private var sections: [FileSection] = []
    /// 展开状态按路径记住，刷新/排序后仍然保持
    private var expandedPaths: Set<String> = []
    /// 当前列布局：表头、列分隔线、行内单元格共用同一套文档坐标（列表文档左沿为 0）。
    fileprivate var columnLayout = ColumnLayout()

    override func layout() {
        super.layout()
        let previous = columnLayout.entries.map { $0.column }
        let columns = visibleColumns()
        columnLayout = makeLayout(columns: columns)
        updateDocumentWidth()
        let offsetX = scrollOffsetX
        header.scrollOffsetX = offsetX
        header.apply(layout: columnLayout, sort: sortField, ascending: ascending)
        dividerLayer.scrollOffsetX = offsetX
        dividerLayer.apply(layout: columnLayout)
        if previous != columns {
            // 列集合变了：让复用的单元格按新列数重排
            outline.reloadData()
            restoreExpansion()
        }
        // 窗口变宽变窄时列位置会变，行内内容要跟着重排
        relayoutVisibleCells()
    }

    var sortField: SortField = .name {
        didSet {
            header.apply(layout: columnLayout, sort: sortField, ascending: ascending)
            invalidateChildren()
        }
    }
    var ascending: Bool = true {
        didSet {
            header.apply(layout: columnLayout, sort: sortField, ascending: ascending)
            invalidateChildren()
        }
    }

    /// 行高（「查看显示选项」可调）。
    var rowHeight: CGFloat = AppSettings.listRowHeight {
        didSet {
            guard oldValue != rowHeight else { return }
            outline.rowHeight = rowHeight
            outline.reloadData()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 构建

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        outline.wantsLayer = true
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .fullWidth
        outline.rowHeight = rowHeight
        outline.indentationPerLevel = 16
        outline.indentationMarkerFollowsCell = true
        // 让唯一的一列撑满整个列表文档宽度：支持列宽无上限时横向滚动，点右侧列也能正常选中行。
        outline.autoresizesOutlineColumn = false
        // 斑马线用系统自带的交替行底色与自定义行绘制联动：根据偏好设置控制
        outline.usesAlternatingRowBackgroundColors = AppSettings.showZebraStripes
        outline.backgroundColor = .controlBackgroundColor
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = false
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.selectionHighlightStyle = .regular
        outline.focusRingType = .none
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(handleDoubleClick)
        outline.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
        outline.menuProvider = { [weak self] event in
            guard let self else { return nil }
            if let event {
                let point = self.outline.convert(event.locationInWindow, from: nil)
                let row = self.outline.row(at: point)
                let item = (row >= 0) ? self.item(at: row) : nil
                return self.menuProvider?(item)
            } else {
                return self.menuProvider?(nil)
            }
        }
        outline.onTriggerRename = { [weak self] row in self?.startRename(at: row) }
        outline.setAccessibilityLabel("文件列表")
        outline.registerForDraggedTypes([.fileURL])
        outline.urlsForRows = { [weak self] rows in
            guard let self else { return [] }
            return rows.compactMap { r in
                guard let node = self.outline.item(atRow: r) as? FileNode else { return nil }
                return node.item.url
            }
        }
        outline.isPointInName = { [weak self] row, point in
            guard let self, row >= 0, row < self.outline.numberOfRows else { return false }
            if let cell = self.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileRowCell {
                return cell.isPointInName(point, in: self.outline)
            }
            return false
        }

        NotificationCenter.default.addObserver(forName: .zebraStripesDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.outline.usesAlternatingRowBackgroundColors = AppSettings.showZebraStripes
            self.outline.enumerateAvailableRowViews { rowView, _ in
                rowView.needsDisplay = true
            }
            self.outline.needsDisplay = true
            self.outline.reloadData()
        }

        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.onSort = { [weak self] field in self?.onSortChange?(field) }
        header.onContextMenu = { [weak self] in self?.makeColumnMenu() }
        addSubview(header)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClipBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        scroll.onSwipeBegin = { [weak self] in
            self?.handleSwipeBegin()
        }
        scroll.canSwipe = { [weak self] in
            guard let self else { return false }
            return (self.canSwipeBack?() ?? false) || (self.canSwipeForward?() ?? false)
        }
        scroll.canSwipeDirection = { [weak self] isBack in
            guard let self else { return false }
            return isBack ? (self.canSwipeBack?() ?? false) : (self.canSwipeForward?() ?? false)
        }
        scroll.onSwipeChange = { [weak self] totalFingerDX in
            self?.handleSwipeChange(totalFingerDX: totalFingerDX)
        }
        scroll.onSwipeEnd = { [weak self] totalFingerDX, velocityX, cancelled in
            self?.handleSwipeEnd(totalFingerDX: totalFingerDX, velocityX: velocityX, cancelled: cancelled)
        }
        addSubview(scroll)

        // 分隔线层最后添加 → 画在最上层（表头与列表内容之上），
        // 这样列间竖线从头到尾只有这一条，且不受单元格/分组行影响。
        dividerLayer.translatesAutoresizingMaskIntoConstraints = false
        dividerLayer.wantsLayer = true
        dividerLayer.owner = self
        addSubview(dividerLayer)

        swipeBadge.translatesAutoresizingMaskIntoConstraints = false
        swipeBadge.alphaValue = 0
        swipeBadge.isHidden = true
        addSubview(swipeBadge)

        badgeLeadingConstraint = swipeBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -44)
        badgeCenterYConstraint = swipeBadge.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 22),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            dividerLayer.topAnchor.constraint(equalTo: topAnchor),
            dividerLayer.leadingAnchor.constraint(equalTo: leadingAnchor),
            dividerLayer.trailingAnchor.constraint(equalTo: trailingAnchor),
            dividerLayer.bottomAnchor.constraint(equalTo: bottomAnchor),

            badgeLeadingConstraint,
            badgeCenterYConstraint,
            swipeBadge.widthAnchor.constraint(equalToConstant: SwipeIndicatorBadge.diameter),
            swipeBadge.heightAnchor.constraint(equalToConstant: SwipeIndicatorBadge.diameter)
        ])

        header.apply(layout: columnLayout, sort: sortField, ascending: ascending)
    }

    @objc private func handleClipBoundsDidChange(_ notification: Notification) {
        let offsetX = scrollOffsetX
        if abs(header.scrollOffsetX - offsetX) > 0.05 {
            header.scrollOffsetX = offsetX
        }
        dividerLayer.scrollOffsetX = offsetX
        dividerLayer.needsDisplay = true
        window?.invalidateCursorRects(for: dividerLayer)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        outline.backgroundColor = .controlBackgroundColor
        scroll.backgroundColor = .controlBackgroundColor
        outline.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
        header.needsDisplay = true
        dividerLayer.needsDisplay = true
        needsDisplay = true
    }

    // MARK: - 触摸板丝滑左右滑动手势（右滑回退 / 左滑前进，Chrome 级阻尼与触发阈值）

    private func handleSwipeBegin() {
        outline.layer?.removeAllAnimations()
        header.layer?.removeAllAnimations()
        dividerLayer.layer?.removeAllAnimations()
        swipeBadge.layer?.removeAllAnimations()
        swipeBadge.resetScale(animated: false)
        swipeBadge.alphaValue = 0
        swipeBadge.isHidden = true
    }

    private func handleSwipeChange(totalFingerDX: CGFloat) {
        let canBack = canSwipeBack?() ?? false
        let canFwd = canSwipeForward?() ?? false
        guard canBack || canFwd else {
            swipeBadge.isHidden = true
            swipeBadge.alphaValue = 0
            return
        }
        let isBack = (totalFingerDX >= 0)
        let isRightSlide = isBack
        let allowed = isBack ? canBack : canFwd
        let absDX = abs(totalFingerDX)

        let maxVisualShift: CGFloat = allowed ? 44 : 10
        let damping: CGFloat = allowed ? 0.30 : 0.08
        let rawShift = absDX * damping
        let dampedShift = maxVisualShift * (1 - exp(-rawShift / max(1, maxVisualShift)))
        let signedShift = isRightSlide ? dampedShift : -dampedShift

        // 表头、中缝竖线、列表正文整体联动平移，保持 100% 相对位置对齐，绝不偏移割裂
        let t = CATransform3DMakeTranslation(signedShift, 0, 0)
        let op: Float = allowed ? Float(max(0.88, 1.0 - (absDX / swipeTriggerThreshold) * 0.08)) : 1.0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.layer?.transform = t
        outline.layer?.opacity = op
        header.layer?.transform = t
        header.layer?.opacity = op
        dividerLayer.layer?.transform = t
        dividerLayer.layer?.opacity = op
        CATransaction.commit()

        guard allowed else {
            swipeBadge.isHidden = true
            swipeBadge.alphaValue = 0
            return
        }

        let progress = absDX / swipeTriggerThreshold
        let clamped = min(1.0, progress)
        let ready = absDX >= swipeTriggerThreshold

        swipeBadge.isHidden = false
        swipeBadge.configure(isBack: isBack, progress: progress, isArmed: ready)
        // 透明度从浅变深：0.0 渐进平滑过渡至 1.0
        swipeBadge.alphaValue = min(1.0, max(0.0, pow(clamped, 1.05)))

        let badgeD = SwipeIndicatorBadge.diameter
        let startMargin: CGFloat = 8
        let maxTravel: CGFloat = 26
        let currentTravel = min(maxTravel, absDX * 0.20)
        if isRightSlide {
            badgeLeadingConstraint.constant = startMargin + currentTravel
        } else {
            badgeLeadingConstraint.constant = bounds.width - badgeD - startMargin - currentTravel
        }
    }

    private func handleSwipeEnd(totalFingerDX: CGFloat, velocityX: CGFloat, cancelled: Bool) {
        let canBack = canSwipeBack?() ?? false
        let canFwd = canSwipeForward?() ?? false
        let isBack = (totalFingerDX >= 0)
        let isRightSlide = isBack
        let allowed = isBack ? canBack : canFwd
        let absDX = abs(totalFingerDX)
        let sameDirVelocity = isRightSlide ? velocityX : -velocityX

        let triggered = !cancelled && allowed && sameDirVelocity >= -1.5 && (
            absDX >= swipeTriggerThreshold ||
            (absDX >= swipeTriggerThreshold * 0.75 && sameDirVelocity > 18.0)
        )

        if triggered {
            onActivate?()
            if isBack {
                onSwipeBack?()
            } else {
                onSwipeForward?()
            }
            animateTransitionAfterTrigger(isBack: isBack)
        } else {
            animateCancelReset()
        }
    }

    private func animateTransitionAfterTrigger(isBack: Bool) {
        let entryOffset: CGFloat = isBack ? -36 : 36
        let layersToAnimate = [outline.layer, header.layer, dividerLayer.layer].compactMap { $0 }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layersToAnimate {
            layer.transform = CATransform3DIdentity
            layer.opacity = 1.0
        }
        CATransaction.commit()

        for layer in layersToAnimate {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = entryOffset
            slide.toValue = 0
            slide.duration = 0.20
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.65
            fade.toValue = 1.0
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

            layer.add(slide, forKey: "swipeSlideIn")
            layer.add(fade, forKey: "swipeFadeIn")
        }

        hideSwipeBadgeAnimated(triggered: true)
    }

    private func animateCancelReset() {
        let layersToAnimate = [outline.layer, header.layer, dividerLayer.layer].compactMap { $0 }
        let currentX = (outline.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
        let currentOpacity = outline.layer?.opacity ?? 1.0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layersToAnimate {
            layer.transform = CATransform3DIdentity
            layer.opacity = 1.0
        }
        CATransaction.commit()

        if abs(currentX) > 0.5 {
            for layer in layersToAnimate {
                let spring = CABasicAnimation(keyPath: "transform.translation.x")
                spring.fromValue = currentX
                spring.toValue = 0
                spring.duration = 0.18
                spring.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                layer.add(spring, forKey: "swipeCancelResetX")

                if currentOpacity < 0.99 {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = currentOpacity
                    fade.toValue = 1.0
                    fade.duration = 0.15
                    layer.add(fade, forKey: "swipeCancelOpacity")
                }
            }
        }
        hideSwipeBadgeAnimated(triggered: false)
    }

    private func hideSwipeBadgeAnimated(triggered: Bool) {
        guard !swipeBadge.isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = triggered ? 0.14 : 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            swipeBadge.animator().alphaValue = 0
            if !triggered {
                swipeBadge.resetScale(animated: true)
            }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if self.swipeBadge.alphaValue == 0 {
                self.swipeBadge.isHidden = true
            }
        })
    }

    // MARK: - 数据

    func update(sections: [FileSection]) {
        let previous = selectedURLs()
        self.sections = sections

        var nodes: [Any] = []
        for section in sections {
            if !section.title.isEmpty {
                nodes.append(GroupNode(title: section.title, count: section.items.count))
            }
            nodes.append(contentsOf: section.items.map { FileNode(item: $0) })
        }
        topLevel = nodes
        outline.reloadData()
        restoreExpansion()
        restoreSelection(previous)
    }

    /// 搜索专用列表展示：纯粹展示当前搜索命中的条目，不显示父级别，且全部初始保持折叠（不展开），用户点击三角可手动就地展开
    func updateWithSearchResults(_ items: [FileItem]) {
        let previous = selectedURLs()
        self.sections = [FileSection(title: "", rank: 0, items: items)]
        self.expandedPaths.removeAll()
        self.topLevel = items.map { FileNode(item: $0) }
        outline.reloadData()
        restoreSelection(previous)
    }

    var items: [FileItem] { sections.flatMap { $0.items } }

    var selectedItems: [FileItem] {
        outline.selectedRowIndexes.compactMap { row in
            (outline.item(atRow: row) as? FileNode)?.item
        }
    }

    private func selectedURLs() -> Set<URL> { Set(selectedItems.map { $0.url }) }

    private func restoreSelection(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        selectRows(matching: urls)
    }

    private func selectRows(matching urls: Set<URL>) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        var indexes = IndexSet()
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, paths.contains(node.item.url.standardizedFileURL.path) {
                indexes.insert(row)
            }
        }
        outline.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    func select(urls: Set<URL>) {
        selectRows(matching: urls)
        if let first = outline.selectedRowIndexes.first {
            outline.scrollRowToVisible(first)
        }
    }

    func selectAll() { outline.selectAll(nil) }

    // MARK: - 就地重命名（访达同款）

    func startRenameSelected() {
        let row = outline.selectedRow
        guard row >= 0, outline.selectedRowIndexes.count == 1 else { return }
        startRename(at: row)
    }

    func startRename(at row: Int) {
        guard row >= 0, row < outline.numberOfRows else { return }
        outline.scrollRowToVisible(row)
        outline.layoutSubtreeIfNeeded()
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileRowCell else { return }
        focus()
        cell.startInlineEditing()
    }

    func performRename(item: FileItem, newName: String) {
        FileOperations.performRename(item: item, newName: newName, window: window) { [weak self] oldURL, newURL in
            self?.onFileRenamed?(oldURL, newURL)
        }
    }

    func focus() { window?.makeFirstResponder(outline) }

    func scrollToTop() {
        if outline.numberOfRows > 0 { outline.scrollRowToVisible(0) }
    }

    func item(at row: Int) -> FileItem? {
        (outline.item(atRow: row) as? FileNode)?.item
    }

    /// 键盘上下方向键快速移动选中行（跳过分组标题行）。
    func moveSelection(by delta: Int) {
        let count = outline.numberOfRows
        guard count > 0 else { return }
        let current = outline.selectedRow
        var next = current < 0 ? (delta >= 0 ? 0 : count - 1) : (current + delta)
        next = min(max(0, next), count - 1)
        while next >= 0 && next < count && !(outline.item(atRow: next) is FileNode) {
            next += (delta >= 0 ? 1 : -1)
        }
        guard next >= 0 && next < count else { return }
        outline.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        outline.scrollRowToVisible(next)
    }

    // MARK: - 树

    private func children(of node: FileNode) -> [FileNode] {
        if let cached = node.children { return cached }
        let found = FileItem.contents(of: node.item.url, showHidden: AppSettings.showHidden)
        let sorted = FileOrganizer.sections(items: found,
                                            sort: sortField,
                                            ascending: ascending,
                                            group: .none).first?.items ?? found
        let nodes = sorted.map { FileNode(item: $0) }
        node.children = nodes
        return nodes
    }

    /// 排序变化后丢弃已读子目录，重新按新规则读取。
    private func invalidateChildren() {
        clearChildren(topLevel.compactMap { $0 as? FileNode })
        outline.reloadData()
        restoreExpansion()
    }

    private func clearChildren(_ nodes: [FileNode]) {
        for node in nodes {
            if let kids = node.children { clearChildren(kids) }
            node.children = nil
        }
    }

    private func restoreExpansion() {
        guard !expandedPaths.isEmpty else { return }
        for path in expandedPaths {
            if let node = findNode(path: path) {
                outline.expandItem(node)
            }
        }
    }

    private func findNode(path: String, in pool: [FileNode]? = nil) -> FileNode? {
        let nodes = pool ?? topLevel.compactMap { $0 as? FileNode }
        for node in nodes {
            if node.item.url.path == path { return node }
            if node.item.isNavigable, path.hasPrefix(node.item.url.path + "/") {
                if let found = findNode(path: path, in: children(of: node)) { return found }
            }
        }
        return nil
    }

    private func node(of item: Any?) -> FileNode? { item as? FileNode }

    // MARK: - 动作

    @objc private func handleDoubleClick() {
        let row = outline.clickedRow
        guard let item = item(at: row) else { return }
        onOpen?(item)
    }

    // MARK: - 列显示设置（表头右键）

    /// 表头右键菜单：勾选要显示的列，底部可自动适配列宽 / 恢复 / 设为默认。
    private func makeColumnMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for column in ListColumn.allCases {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = AppSettings.visibleColumns.contains(column.rawValue) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let fitAll = NSMenuItem(title: "自动适配所有列宽", action: #selector(autoFitAllColumns), keyEquivalent: "")
        fitAll.target = self
        menu.addItem(fitAll)
        let restore = NSMenuItem(title: "恢复到默认", action: #selector(restoreDefaultColumns), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)
        let setDefault = NSMenuItem(title: "设置为默认", action: #selector(setDefaultColumns), keyEquivalent: "")
        setDefault.target = self
        menu.addItem(setDefault)
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        var columns = AppSettings.visibleColumns
        if let index = columns.firstIndex(of: raw) {
            columns.remove(at: index)
        } else {
            columns.append(raw)
        }
        AppSettings.visibleColumns = columns
        reloadColumns()
    }

    @objc private func restoreDefaultColumns() {
        AppSettings.visibleColumns = AppSettings.defaultColumns
        AppSettings.resetColumnWidths()
        reloadColumns()
    }

    @objc private func setDefaultColumns() {
        AppSettings.defaultColumns = AppSettings.visibleColumns
    }

    private func reloadColumns() {
        let columns = visibleColumns()
        columnLayout = makeLayout(columns: columns)
        updateDocumentWidth()
        let offsetX = scrollOffsetX
        header.scrollOffsetX = offsetX
        header.apply(layout: columnLayout, sort: sortField, ascending: ascending)
        dividerLayer.scrollOffsetX = offsetX
        dividerLayer.apply(layout: columnLayout)
        outline.reloadData()
        restoreExpansion()
    }

    // MARK: - 列宽拖拽与双击自适应

    /// 正在进行的拖拽：被调整的列 + 起始窗口 X + 起始列宽（1:1 跟随鼠标增量，不受滚动条位置影响）。
    private var resizeSession: (target: ResizableColumn, startWindowX: CGFloat, initialWidth: CGFloat)?

    /// 当前所有可拖动的分隔线（文档坐标）。
    /// 每条分隔线仅调整它**左侧**紧邻的那一列（名称列或某一数据列），
    /// 最右侧列同样拥有右侧专属分隔线，拉宽时完全不影响其他列宽度。
    fileprivate func dividers() -> [ColumnDivider] {
        var result: [ColumnDivider] = [
            ColumnDivider(
                target: .name,
                x: columnLayout.nameRect.maxX,
                isRightmost: columnLayout.entries.isEmpty
            )
        ]
        for (index, entry) in columnLayout.entries.enumerated() {
            let isLast = (index == columnLayout.entries.count - 1)
            result.append(ColumnDivider(
                target: .column(entry.column),
                x: entry.rect.maxX,
                isRightmost: isLast
            ))
        }
        return result
    }

    /// 命中某条分隔线（docX 为文档坐标；最右侧列分隔线向右放宽热区，更方便抓握拉宽）。
    fileprivate func divider(at docX: CGFloat, tolerance: CGFloat) -> ColumnDivider? {
        for div in dividers() {
            let leftTol = tolerance
            let rightTol = div.isRightmost ? tolerance + 8 : tolerance
            if docX >= div.x - leftTol && docX <= div.x + rightTol {
                return div
            }
        }
        return nil
    }

    /// 抓住一条分隔线开始拖拽。
    fileprivate func beginColumnResize(_ target: ResizableColumn, startWindowX: CGFloat) {
        resizeSession = (target, startWindowX, currentWidth(of: target))
    }

    /// 拖拽移动：目标列宽度按鼠标位移增量 1:1 变化，不影响其他任何列。
    fileprivate func updateColumnResize(currentWindowX: CGFloat) {
        guard let session = resizeSession else { return }
        let delta = currentWindowX - session.startWindowX
        applyColumnWidth(session.target, session.initialWidth + delta)
    }

    /// 松手：把本次拖拽结果落盘。
    fileprivate func endColumnResize() {
        guard resizeSession != nil else { return }
        resizeSession = nil
        persistColumnWidths()
    }

    /// 双击分隔线：自动测量该列当前最长内容并适配列宽（不影响其他列）。
    fileprivate func autoFitColumn(_ target: ResizableColumn) {
        let fitted = idealWidth(for: target)
        applyColumnWidth(target, fitted)
        persistColumnWidths()
    }

    @objc private func autoFitAllColumns() {
        sessionNameWidth = idealWidth(for: .name)
        for col in visibleColumns() {
            sessionWidths[col.rawValue] = idealWidth(for: .column(col))
        }
        persistColumnWidths()
    }

    private func idealWidth(for target: ResizableColumn) -> CGFloat {
        let rowCount = outline.numberOfRows
        switch target {
        case .name:
            let font = NSFont.systemFont(ofSize: 12.5)
            var maxW = Self.minNameWidth
            let baseTextX = Self.nameIconX + iconSize + 6
            for row in 0..<rowCount {
                guard let node = outline.item(atRow: row) as? FileNode else { continue }
                let level = CGFloat(max(0, outline.level(forRow: row)))
                let indent = KeyOutlineView.leftIndentOffset + (level + 1) * outline.indentationPerLevel
                let nameW = ceil((node.item.name as NSString).size(withAttributes: [.font: font]).width)
                let tagW = node.item.tags.isEmpty ? 0 : (TagDotsView.preferredWidth(count: node.item.tags.count) + 6)
                let needed = indent + baseTextX + nameW + tagW + 20
                if needed > maxW { maxW = needed }
            }
            return min(Self.maxNameWidth, maxW)

        case .column(let column):
            let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let cellFont = NSFont.systemFont(ofSize: 11.5)
            let headerW = ceil((column.title as NSString).size(withAttributes: [.font: headerFont]).width) + 28
            var maxW = max(column.minWidth, headerW)
            for row in 0..<rowCount {
                guard let node = outline.item(atRow: row) as? FileNode else { continue }
                let text: String
                if column == .size {
                    if node.item.isPackage || (node.item.isNavigable && AppSettings.calculateFolderSizes) {
                        if let cached = BundleSizeCache.shared.size(for: node.item.url) {
                            text = Format.bytes(cached)
                        } else {
                            text = "--"
                        }
                    } else if node.item.isNavigable {
                        text = "--"
                    } else {
                        text = column.value(for: node.item)
                    }
                } else {
                    text = column.value(for: node.item)
                }
                let textW = ceil((text as NSString).size(withAttributes: [.font: cellFont]).width) + 20
                if textW > maxW { maxW = textW }
            }
            return min(column.maxWidth, maxW)
        }
    }

    /// 应用新的列宽：夹在 [最小宽, 最大宽] 内，重新计算布局并刷新表头、分隔线与可见行。
    private func applyColumnWidth(_ target: ResizableColumn, _ requested: CGFloat) {
        let range = widthRange(for: target)
        let newWidth = min(max(requested, range.min), range.max)
        switch target {
        case .name:
            sessionNameWidth = newWidth
        case .column(let column):
            sessionWidths[column.rawValue] = newWidth
        }
        refreshColumnLayout()
    }

    /// 松手后把本次拖拽结果写入设置（拖拽过程中只改内存，避免频繁写盘）。
    private func persistColumnWidths() {
        if let name = sessionNameWidth {
            AppSettings.nameColumnWidth = name
        }
        if !sessionWidths.isEmpty {
            var all = AppSettings.columnWidths
            for (key, value) in sessionWidths { all[key] = Double(value) }
            AppSettings.columnWidths = all
        }
        sessionNameWidth = nil
        sessionWidths.removeAll()
        refreshColumnLayout()
    }

    /// 根据所有列总宽度与可视区域宽度同步更新文档宽度，超出时自动激活水平滚动。
    private func updateDocumentWidth() {
        let clipWidth = scroll.contentView.bounds.width
        let minWidthForCurrentScroll = resizeSession != nil
            ? (scroll.contentView.bounds.origin.x + clipWidth)
            : 0
        let targetWidth = max(
            clipWidth,
            columnLayout.totalWidth + Self.trailingBreathingSpace,
            minWidthForCurrentScroll
        )
        outline.minimumDocumentWidth = targetWidth
        if let col = outline.tableColumns.first, abs(col.width - targetWidth) > 0.5 {
            col.minWidth = targetWidth
            col.maxWidth = max(100000, targetWidth)
            col.width = targetWidth
        }
        if abs(outline.frame.width - targetWidth) > 0.5 {
            outline.setFrameSize(NSSize(width: targetWidth, height: outline.frame.height))
        }
    }

    /// 重新计算列布局并刷新相关界面。
    private func refreshColumnLayout() {
        let columns = visibleColumns()
        columnLayout = makeLayout(columns: columns)
        updateDocumentWidth()
        let offsetX = scrollOffsetX
        header.scrollOffsetX = offsetX
        header.apply(layout: columnLayout, sort: sortField, ascending: ascending)
        dividerLayer.scrollOffsetX = offsetX
        dividerLayer.apply(layout: columnLayout)
        relayoutVisibleCells()
        window?.invalidateCursorRects(for: dividerLayer)
    }

    /// 当前是否包含分组标题行（无分组时斑马线与分隔线裁剪可跳过逐行探测，达到 O(1) 性能）。
    fileprivate var hasGroupHeaders: Bool {
        sections.contains { !$0.title.isEmpty }
    }

    /// 让当前可见的文件行按最新的列布局重排
    /// （仅遍历屏幕已挂载的可见行视图，大目录下拖拽列宽依然丝滑跟手）。
    private func relayoutVisibleCells() {
        outline.enumerateAvailableRowViews { rowView, _ in
            if let cell = rowView.view(atColumn: 0) as? FileRowCell {
                cell.updateFrames()
            }
        }
    }
}

// MARK: - 数据源 / 代理

extension FileListView: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func deselectAll() {
        outline.deselectAll(nil)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return topLevel.count }
        if let node = node(of: item) { return children(of: node).count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return topLevel[index] }
        guard let node = node(of: item) else { return topLevel[index] }
        return children(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = node(of: item) else { return false }
        return node.isExpandable()
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !(item is GroupNode)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is GroupNode {
            let row = outlineView.row(forItem: item)
            return row <= 0 ? 22 : 28
        }
        return rowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if item is GroupNode {
            let row = outlineView.row(forItem: item)
            let identifier = NSUserInterfaceItemIdentifier("GroupTableRowView")
            let rowView = (outlineView.makeView(withIdentifier: identifier, owner: self) as? GroupTableRowView)
                ?? GroupTableRowView()
            rowView.identifier = identifier
            rowView.isFirstGroup = (row <= 0)
            return rowView
        }
        let identifier = NSUserInterfaceItemIdentifier("FileListRowView")
        let rowView = (outlineView.makeView(withIdentifier: identifier, owner: self) as? FileListRowView)
            ?? FileListRowView()
        rowView.identifier = identifier
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? GroupNode {
            let row = outlineView.row(forItem: item)
            let identifier = NSUserInterfaceItemIdentifier("group")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? GroupRowCell)
                ?? GroupRowCell(identifier: identifier)
            cell.configure(title: group.title, count: group.count, isFirst: row <= 0)
            return cell
        }
        guard let node = node(of: item) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("file")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? FileRowCell)
            ?? FileRowCell(identifier: identifier)
        cell.owner = self
        cell.configure(with: node.item)
        cell.onCommitRename = { [weak self, weak node] newName in
            guard let self, let node else { return }
            self.performRename(item: node.item, newName: newName)
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        outline.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
        onActivate?()
        onSelectionChange?(selectedURLs())
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedPaths.insert(node.item.url.path)
        outline.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
        outline.needsDisplay = true
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedPaths.remove(node.item.url.path)
        outline.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
        outline.needsDisplay = true
    }

    // MARK: 拖拽数据源与接收

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? FileNode else { return nil }
        return node.item.url as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let urls = FileOperations.readURLs(from: info)
        guard !urls.isEmpty else { return [] }
        let destURL: URL
        if let fileNode = item as? FileNode, fileNode.item.isDirectory {
            destURL = fileNode.item.url
        } else {
            guard let current = currentFolderURL else { return [] }
            destURL = current
        }
        return FileOperations.shouldCopy(for: info, destination: destURL) ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let urls = FileOperations.readURLs(from: info)
        guard !urls.isEmpty else { return false }
        let destURL: URL
        if let fileNode = item as? FileNode, fileNode.item.isDirectory {
            destURL = fileNode.item.url
        } else {
            guard let current = currentFolderURL else { return false }
            destURL = current
        }
        let isCopy = FileOperations.shouldCopy(for: info, destination: destURL)
        onDropFiles?(urls, destURL, isCopy)
        return true
    }
}

// MARK: - 表格子类

/// 分栏视图与本列表共用的按键/右键菜单转发版本，支持原生文件拖拽、划选多选以及「点击选中后再次点击就地重命名」。
enum InlineRenameTracker {
    private static var lastEndEventNumber: Int?
    private static var lastEndUptime: TimeInterval = 0

    static func markEditingEnded() {
        lastEndEventNumber = NSApp.currentEvent?.eventNumber
        lastEndUptime = ProcessInfo.processInfo.systemUptime
    }

    static func didEndDuring(event: NSEvent) -> Bool {
        if let endNum = lastEndEventNumber, endNum == event.eventNumber {
            return true
        }
        return (ProcessInfo.processInfo.systemUptime - lastEndUptime) < 0.08
    }
}

final class KeyTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((NSEvent?) -> NSMenu?)?
    var onTriggerRename: ((Int) -> Void)?
    var urlsForRows: (([Int]) -> [URL])?
    var isPointInName: ((Int, NSPoint) -> Bool)?

    private var dragStartRow: Int?
    private var dragInitialSelection = IndexSet()
    private var potentialRenameRow: Int?
    private var pendingRenameWorkItem: DispatchWorkItem?
    private var mouseDidDrag = false
    private var mouseDownPoint: NSPoint?
    private var didClickOnMultiSelection = false
    /// 列布局要求的最少文档宽度（超出可视区域宽度时激活水平滚动）。
    var minimumDocumentWidth: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let clip = enclosingScrollView?.contentView {
            let visibleSize = clip.bounds.size
            let targetWidth = max(visibleSize.width, minimumDocumentWidth)
            if size.width < targetWidth || (targetWidth > 0 && abs(size.width - targetWidth) > 0.5) {
                size.width = targetWidth
            }
            if size.height < visibleSize.height { size.height = visibleSize.height }
        }
        super.setFrameSize(size)
        if let col = tableColumns.first, abs(col.width - size.width) > 0.5 {
            col.minWidth = size.width
            col.maxWidth = max(100000, size.width)
            col.width = size.width
        }
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        // 按回车键：与访达一致进入重命名
        if event.keyCode == 36, selectedRow >= 0, selectedRowIndexes.count == 1 {
            pendingRenameWorkItem?.cancel()
            pendingRenameWorkItem = nil
            onTriggerRename?(selectedRow)
            return
        }
        super.keyDown(with: event)
    }

    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        super.selectRowIndexes(indexes, byExtendingSelection: extend)
        enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
    }

    override func deselectAll(_ sender: Any?) {
        super.deselectAll(sender)
        enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
    }

    override func deselectRow(_ row: Int) {
        super.deselectRow(row)
        enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
    }

    override func reloadData() {
        super.reloadData()
        enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        pendingRenameWorkItem?.cancel()
        pendingRenameWorkItem = nil
        potentialRenameRow = nil

        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 {
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            return menuProvider?(event) ?? super.menu(for: event)
        } else {
            // 右键点在空白处：访达同款清空选中，并展示文件夹右键菜单
            deselectAll(nil)
            return menuProvider?(nil) ?? super.menu(for: event)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let editor = window?.firstResponder as? NSTextView, editor.isDescendant(of: self),
           let superview = self.superview {
            let ptInEditor = editor.convert(point, from: superview)
            if editor.bounds.insetBy(dx: -3, dy: -2).contains(ptInEditor) {
                return editor
            }
        }
        return super.hitTest(point)
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is NSTextView {
            return true
        }
        if let tf = responder as? NSTextField, tf.isEditable {
            return true
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    override func mouseDown(with event: NSEvent) {
        pendingRenameWorkItem?.cancel()
        pendingRenameWorkItem = nil
        mouseDidDrag = false
        potentialRenameRow = nil
        mouseDownPoint = event.locationInWindow

        let wasEditingBeforeClick: Bool
        if let editor = window?.firstResponder as? NSTextView, editor.isDescendant(of: self) {
            let ptInEditor = editor.convert(event.locationInWindow, from: nil)
            if editor.bounds.insetBy(dx: -3, dy: -2).contains(ptInEditor) {
                editor.mouseDown(with: event)
                return
            }
            wasEditingBeforeClick = true
        } else {
            wasEditingBeforeClick = InlineRenameTracker.didEndDuring(event: event)
        }

        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        dragStartRow = row
        dragInitialSelection = selectedRowIndexes

        // 双击或多击：交由 doubleAction 打开文件
        if event.clickCount >= 2 {
            didClickOnMultiSelection = false
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        let didEndEditingOnThisClick = wasEditingBeforeClick || InlineRenameTracker.didEndDuring(event: event)

        // 点击空白处：与访达一致清空选中并直接返回，防止触发系统内置划选导致多行意外变灰选中
        guard row >= 0 else {
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
                if !selectedRowIndexes.isEmpty {
                    deselectAll(nil)
                }
            }
            didClickOnMultiSelection = false
            return
        }

        // 判断该项在点击前是否已被单独选中，并且点击在文件名文本区域（若本次点击刚退出了重命名，则不重新触发重命名）
        let wasAlreadySingleSelected = (selectedRowIndexes.count == 1 && selectedRowIndexes.contains(row))
        let hitName = isPointInName?(row, point) ?? false

        if !didEndEditingOnThisClick && wasAlreadySingleSelected && hitName && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
            potentialRenameRow = row
        }

        if event.modifierFlags.contains(.command) {
            didClickOnMultiSelection = false
            if selectedRowIndexes.contains(row) {
                deselectRow(row)
            } else {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
            }
        } else if event.modifierFlags.contains(.shift) && allowsMultipleSelection {
            didClickOnMultiSelection = false
            let anchor = selectedRow >= 0 ? selectedRow : row
            let range = IndexSet(integersIn: min(anchor, row)...max(anchor, row))
            selectRowIndexes(range, byExtendingSelection: false)
        } else if selectedRowIndexes.contains(row) && selectedRowIndexes.count > 1 {
            // 在已多选的多个项目中点击了其中某一项：延迟至鼠标抬起时再单选它，以便拖拽时完整带出所有选中文件
            didClickOnMultiSelection = true
        } else if wasAlreadySingleSelected {
            // 已被单独选中的项再次单击：保留选中，使后续 mouseUp 能准确收到事件并触发重命名
            didClickOnMultiSelection = false
        } else {
            didClickOnMultiSelection = false
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let curWindowPoint = event.locationInWindow
        let startWindowPoint = mouseDownPoint ?? curWindowPoint
        let dist = hypot(curWindowPoint.x - startWindowPoint.x, curWindowPoint.y - startWindowPoint.y)

        // 仅当位移达到系统拖拽阈值（>= 3pt）时才视为拖拽
        // 触摸板微小晃动（< 3pt）保留重命名状态，不触发拖动
        if dist >= 3.0 {
            mouseDidDrag = true
            potentialRenameRow = nil
            pendingRenameWorkItem?.cancel()
            pendingRenameWorkItem = nil
        }

        guard mouseDidDrag else { return }

        // 若拖拽起始于某一行且鼠标位移超过 3pt：启动文件拖拽（不触发多行划选，避免鼠标移动导致多行意外选中）
        if let start = dragStartRow, start >= 0 {
            let targetRows: IndexSet
            if selectedRowIndexes.contains(start) {
                targetRows = selectedRowIndexes
            } else {
                selectRowIndexes(IndexSet(integer: start), byExtendingSelection: false)
                targetRows = IndexSet(integer: start)
            }
            let rowsArray = Array(targetRows)
            let urls = urlsForRows?(rowsArray) ?? []
            if !urls.isEmpty {
                let localPoint = convert(curWindowPoint, from: nil)
                let items = FileDragHelper.createDraggingItems(for: urls, at: localPoint)
                let session = beginDraggingSession(with: items, event: event, source: self)
                session.animatesToStartingPositionsOnCancelOrFail = true
                dragStartRow = nil
                didClickOnMultiSelection = false
                mouseDownPoint = nil
                return
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let didDrag = mouseDidDrag
        let targetRow = potentialRenameRow
        potentialRenameRow = nil

        if didClickOnMultiSelection && !didDrag {
            if let r = dragStartRow, r >= 0 {
                selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
            }
        }
        dragStartRow = nil
        didClickOnMultiSelection = false
        mouseDidDrag = false
        mouseDownPoint = nil
        super.mouseUp(with: event)

        // 访达同款：未拖拽、单选状态、单次单击且在同一个有效项上抬起时，延迟双击间隔触发就地重命名
        if !didDrag, let r = targetRow, r >= 0, selectedRow == r, selectedRowIndexes.count == 1, event.clickCount == 1 {
            let delay = NSEvent.doubleClickInterval
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.mouseDidDrag, self.selectedRow == r, self.selectedRowIndexes.count == 1 else { return }
                self.onTriggerRename?(r)
            }
            pendingRenameWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.copy, .move, .generic]
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mouseDidDrag = true
        potentialRenameRow = nil
        pendingRenameWorkItem?.cancel()
        pendingRenameWorkItem = nil
        dragStartRow = nil
        mouseDownPoint = nil
    }
}

// MARK: - 分组与列表行视图

/// 分组标题行视图：完全独立于斑马线，始终使用统一纯色底色与顶部细腻分隔线
final class GroupTableRowView: NSTableRowView {
    var isFirstGroup: Bool = false
    override var isFlipped: Bool { true }

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.paneBackground.setFill()
        bounds.fill()

        if !isFirstGroup {
            Theme.hairline.setFill()
            NSRect(x: 10, y: 0, width: bounds.width - 20, height: 1).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // 分组标题行不可选中
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 列表文件行视图：支持组内独立斑马线交替底色与四边拉满高亮（树形/列表视图四边拉满无圆角，圆角仅保留给分栏视图）
final class FileListRowView: ColumnTableRowView {

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let color = isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        bounds.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let baseColor = NSColor.controlBackgroundColor
        guard AppSettings.showZebraStripes else {
            // 没有斑马线设置时，行背景统一显示纯白（暗黑模式下为系统底色）
            baseColor.setFill()
            bounds.fill()
            return
        }

        var candidateView: NSView? = superview
        var table: NSOutlineView?
        while let v = candidateView {
            if let t = v as? NSOutlineView {
                table = t
                break
            }
            candidateView = v.superview
        }
        guard let table else {
            baseColor.setFill()
            bounds.fill()
            return
        }
        let row = table.row(for: self)
        guard row >= 0 else {
            baseColor.setFill()
            bounds.fill()
            return
        }

        // 计算当前文件行在所属分组内的相对序号（从 0 开始），确保每个分组下的文件从第一行纯白开始交替
        let fileIndexWithinGroup: Int
        if let listOwner = table.dataSource as? FileListView, !listOwner.hasGroupHeaders {
            fileIndexWithinGroup = row
        } else {
            var idx = 0
            for r in (0..<row).reversed() {
                if let item = table.item(atRow: r), item is FileListView.GroupNode {
                    break
                }
                idx += 1
            }
            fileIndexWithinGroup = idx
        }

        let stripeColor = NSColor.alternatingContentBackgroundColors.count > 1
            ? NSColor.alternatingContentBackgroundColors[1]
            : (baseColor.blended(withFraction: 0.04, of: .labelColor) ?? baseColor)
        let color = (fileIndexWithinGroup % 2 == 1) ? stripeColor : baseColor
        color.setFill()
        bounds.fill()
    }
}

final class KeyOutlineView: NSOutlineView {
    var keyHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((NSEvent?) -> NSMenu?)?
    var onTriggerRename: ((Int) -> Void)?
    var urlsForRows: (([Int]) -> [URL])?
    var isPointInName: ((Int, NSPoint) -> Bool)?

    static let leftIndentOffset: CGFloat = 10.0

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var rect = super.frameOfOutlineCell(atRow: row)
        if rect.width > 0 {
            rect.origin.x += Self.leftIndentOffset
        }
        return rect
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var rect = super.frameOfCell(atColumn: column, row: row)
        if column == 0 {
            rect.origin.x += Self.leftIndentOffset
            rect.size.width = max(0, rect.size.width - Self.leftIndentOffset)
        }
        return rect
    }

    private var dragStartRow: Int?
    private var dragInitialSelection = IndexSet()
    private var potentialRenameRow: Int?
    private var pendingRenameWorkItem: DispatchWorkItem?
    private var mouseDidDrag = false
    private var mouseDownPoint: NSPoint?
    private var didClickOnMultiSelection = false
    /// 列布局要求的最少文档宽度（超出可视区域宽度时激活水平滚动）。
    var minimumDocumentWidth: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let clip = enclosingScrollView?.contentView {
            let visibleSize = clip.bounds.size
            let targetWidth = max(visibleSize.width, minimumDocumentWidth)
            if size.width < targetWidth || (targetWidth > 0 && abs(size.width - targetWidth) > 0.5) {
                size.width = targetWidth
            }
            if size.height < visibleSize.height { size.height = visibleSize.height }
        }
        super.setFrameSize(size)
        if let col = tableColumns.first, abs(col.width - size.width) > 0.5 {
            col.minWidth = size.width
            col.maxWidth = max(100000, size.width)
            col.width = size.width
        }
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        if event.keyCode == 36, selectedRow >= 0, selectedRowIndexes.count == 1 {
            pendingRenameWorkItem?.cancel()
            pendingRenameWorkItem = nil
            onTriggerRename?(selectedRow)
            return
        }
        super.keyDown(with: event)
    }

    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        super.selectRowIndexes(indexes, byExtendingSelection: extend)
        enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
    }

    override func deselectAll(_ sender: Any?) {
        super.deselectAll(sender)
        enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
    }

    override func deselectRow(_ row: Int) {
        super.deselectRow(row)
        enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
    }

    override func reloadData() {
        super.reloadData()
        enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        pendingRenameWorkItem?.cancel()
        pendingRenameWorkItem = nil
        potentialRenameRow = nil

        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 {
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            return menuProvider?(event) ?? super.menu(for: event)
        } else {
            // 右键点在空白处：访达同款清空选中，并展示文件夹右键菜单
            deselectAll(nil)
            return menuProvider?(nil) ?? super.menu(for: event)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let editor = window?.firstResponder as? NSTextView, editor.isDescendant(of: self),
           let superview = self.superview {
            let ptInEditor = editor.convert(point, from: superview)
            if editor.bounds.insetBy(dx: -3, dy: -2).contains(ptInEditor) {
                return editor
            }
        }
        return super.hitTest(point)
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is NSTextView {
            return true
        }
        if let tf = responder as? NSTextField, tf.isEditable {
            return true
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    override func mouseDown(with event: NSEvent) {
        pendingRenameWorkItem?.cancel()
        pendingRenameWorkItem = nil
        mouseDidDrag = false
        potentialRenameRow = nil
        mouseDownPoint = event.locationInWindow

        let wasEditingBeforeClick: Bool
        if let editor = window?.firstResponder as? NSTextView, editor.isDescendant(of: self) {
            let ptInEditor = editor.convert(event.locationInWindow, from: nil)
            if editor.bounds.insetBy(dx: -3, dy: -2).contains(ptInEditor) {
                editor.mouseDown(with: event)
                return
            }
            wasEditingBeforeClick = true
        } else {
            wasEditingBeforeClick = InlineRenameTracker.didEndDuring(event: event)
        }

        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        dragStartRow = row
        dragInitialSelection = selectedRowIndexes

        // 排除展开三角与分组行
        let arrowFrame = frameOfOutlineCell(atRow: row)
        let clickedArrow = (arrowFrame.width > 0 && point.x <= arrowFrame.maxX + 4)
        let isGroup = (row >= 0 && item(atRow: row) is FileListView.GroupNode)

        if clickedArrow {
            didClickOnMultiSelection = false
            super.mouseDown(with: event)
            return
        }

        // 双击或多击：交由 doubleAction 打开文件
        if event.clickCount >= 2 {
            didClickOnMultiSelection = false
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        let didEndEditingOnThisClick = wasEditingBeforeClick || InlineRenameTracker.didEndDuring(event: event)

        // 点击空白处或分组标题行：不进入系统内置划选循环，防止移动鼠标时多行被意外划选变灰
        guard row >= 0, !isGroup else {
            if row < 0 && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
                if !selectedRowIndexes.isEmpty {
                    deselectAll(nil)
                }
            }
            didClickOnMultiSelection = false
            return
        }

        // 判断该项在点击前是否已被单独选中，并且点击在文件名文本区域（若本次点击刚退出了重命名，则不重新触发重命名）
        let wasAlreadySingleSelected = (selectedRowIndexes.count == 1 && selectedRowIndexes.contains(row))
        let hitName = isPointInName?(row, point) ?? false

        if !didEndEditingOnThisClick && wasAlreadySingleSelected && hitName && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
            potentialRenameRow = row
        }

        if event.modifierFlags.contains(.command) {
            didClickOnMultiSelection = false
            if selectedRowIndexes.contains(row) {
                deselectRow(row)
            } else {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
            }
        } else if event.modifierFlags.contains(.shift) && allowsMultipleSelection {
            didClickOnMultiSelection = false
            let anchor = selectedRow >= 0 ? selectedRow : row
            let r1 = min(anchor, row)
            let r2 = max(anchor, row)
            let validRows = (r1...r2).filter { !(self.item(atRow: $0) is FileListView.GroupNode) }
            selectRowIndexes(IndexSet(validRows), byExtendingSelection: false)
        } else if selectedRowIndexes.contains(row) && selectedRowIndexes.count > 1 {
            // 如果用户在已多选的多个项目中点击了其中某一项，且未按 ⌘ / ⇧：
            // 延迟至鼠标抬起时再单选它，以便在拖拽时能完整带出所有选中的文件
            didClickOnMultiSelection = true
        } else if wasAlreadySingleSelected {
            // 已被单独选中的项再次单击：保留选中，使后续 mouseUp 能准确收到事件并触发重命名
            didClickOnMultiSelection = false
        } else {
            didClickOnMultiSelection = false
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let curWindowPoint = event.locationInWindow
        let startWindowPoint = mouseDownPoint ?? curWindowPoint
        let dist = hypot(curWindowPoint.x - startWindowPoint.x, curWindowPoint.y - startWindowPoint.y)

        // 仅当位移达到系统拖拽阈值（>= 3pt）时才视为拖拽
        // 触摸板微小晃动（< 3pt）保留重命名状态，不触发拖动
        if dist >= 3.0 {
            mouseDidDrag = true
            potentialRenameRow = nil
            pendingRenameWorkItem?.cancel()
            pendingRenameWorkItem = nil
        }

        guard mouseDidDrag else { return }

        // 若拖拽起始于某一文件行且鼠标位移超过 3pt：启动文件拖拽（不触发多行划选，避免鼠标移动导致多行意外选中）
        if let start = dragStartRow, start >= 0 {
            if !(item(atRow: start) is FileListView.GroupNode) {
                let targetRows: IndexSet
                if selectedRowIndexes.contains(start) {
                    targetRows = selectedRowIndexes
                } else {
                    selectRowIndexes(IndexSet(integer: start), byExtendingSelection: false)
                    targetRows = IndexSet(integer: start)
                }
                let rowsArray = Array(targetRows).filter { !(self.item(atRow: $0) is FileListView.GroupNode) }
                let urls = urlsForRows?(rowsArray) ?? []
                if !urls.isEmpty {
                    let localPoint = convert(curWindowPoint, from: nil)
                    let items = FileDragHelper.createDraggingItems(for: urls, at: localPoint)
                    let session = beginDraggingSession(with: items, event: event, source: self)
                    session.animatesToStartingPositionsOnCancelOrFail = true
                    dragStartRow = nil
                    didClickOnMultiSelection = false
                    mouseDownPoint = nil
                    return
                }
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let didDrag = mouseDidDrag
        let targetRow = potentialRenameRow
        potentialRenameRow = nil

        if didClickOnMultiSelection && !didDrag {
            if let r = dragStartRow, r >= 0 {
                selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
            }
        }
        dragStartRow = nil
        didClickOnMultiSelection = false
        mouseDidDrag = false
        mouseDownPoint = nil
        super.mouseUp(with: event)

        // 访达同款：未拖拽、单选状态、单次单击且在同一个有效项上抬起时，延迟双击间隔触发就地重命名
        if !didDrag, let r = targetRow, r >= 0, selectedRow == r, selectedRowIndexes.count == 1, event.clickCount == 1 {
            let delay = NSEvent.doubleClickInterval
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.mouseDidDrag, self.selectedRow == r, self.selectedRowIndexes.count == 1 else { return }
                self.onTriggerRename?(r)
            }
            pendingRenameWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.copy, .move, .generic]
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mouseDidDrag = true
        potentialRenameRow = nil
        pendingRenameWorkItem?.cancel()
        pendingRenameWorkItem = nil
        dragStartRow = nil
        mouseDownPoint = nil
    }
}

// MARK: - 表头

/// 自绘表头：列名加粗、列之间有贯通的竖线、排序用与左右箭头同风格的细箭头图标。
/// 右键表头可以控制显示哪些列（访达同款），并随列表水平滚动同步平移。
private final class ListHeaderBar: NSView {

    var onSort: ((SortField) -> Void)?
    /// 右键表头：返回列显示设置菜单。
    var onContextMenu: (() -> NSMenu?)?

    private var layout = FileListView.ColumnLayout()
    private var sortField: SortField = .name
    private var ascending = true
    var scrollOffsetX: CGFloat = 0 {
        didSet {
            guard abs(oldValue - scrollOffsetX) > 0.05 else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    // MARK: 排序

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let docX = point.x + scrollOffsetX
        // 名称列
        let nameRight = layout.nameRect.maxX
        if docX >= 0 && docX < nameRight {
            onSort?(.name)
            return
        }
        // 其它列
        for entry in layout.entries where docX >= entry.rect.minX && docX <= entry.rect.maxX {
            if let field = entry.column.sortField { onSort?(field) }
            return
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paneBackground.setFill()
        bounds.fill()

        let height = bounds.height

        // 注意：列之间的竖线不在这里画——统一交给上层的 ColumnDividerLayer，
        // 保证每个列间隙从头到尾只有一条线，不会出现表头一条、正文一条的错位。

        // 名称列
        let nameRight = layout.nameRect.maxX
        drawTitle("名称",
                  in: NSRect(x: FileListView.headerNameX - scrollOffsetX,
                             y: 0,
                             width: max(0, nameRight - FileListView.headerNameX),
                             height: height),
                  inset: 0,
                  sorted: sortField == .name)

        // 其它列
        for entry in layout.entries {
            let rect = entry.rect.offsetBy(dx: -scrollOffsetX, dy: 0)
            drawTitle(entry.column.title, in: rect, inset: 6,
                      sorted: entry.column.sortField == sortField)
        }

        // 底部细线
        Theme.hairline.setFill()
        NSRect(x: 0, y: height - 1, width: bounds.width, height: 1).fill()
    }

    /// 画一列的标题（加粗）。所有表头文字统一左对齐，排序中的列在文字右侧补一个细箭头。
    /// 注意：列布局里 entry.rect 的高度为 0，垂直居中必须用表头自身高度。
    private func drawTitle(_ text: String, in rect: NSRect, inset: CGFloat, sorted: Bool) {
        let h = bounds.height
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: sorted ? NSColor.labelColor : NSColor.secondaryLabelColor
        ])
        let textSize = attributed.size()
        let arrowGap: CGFloat = 4
        let arrowW: CGFloat = 9
        let available = max(0, rect.width - inset * 2 - (sorted ? arrowGap + arrowW : 0))
        let drawWidth = min(textSize.width, available)
        // 表头文字统一左对齐
        let x = rect.minX + inset
        attributed.draw(with: NSRect(x: x,
                                     y: (h - textSize.height) / 2 + 1,
                                     width: drawWidth,
                                     height: textSize.height),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        guard sorted else { return }
        // 排序箭头放到列的最右侧（贴右边界），与列名文字脱开
        let arrowX = rect.maxX - inset - arrowW
        drawSortArrow(in: NSRect(x: arrowX, y: 0, width: arrowW, height: h), up: ascending)
    }

    /// 排序箭头：细而浅灰的小三角（参考系统风格，比之前更小更灰）。
    private func drawSortArrow(in rect: NSRect, up: Bool) {
        let halfWidth: CGFloat = 2.8
        let halfHeight: CGFloat = 2.0
        let path = NSBezierPath()
        let cx = rect.minX + rect.width / 2
        let cy = rect.midY
        if up {
            path.move(to: NSPoint(x: cx - halfWidth, y: cy + halfHeight))
            path.line(to: NSPoint(x: cx, y: cy - halfHeight))
            path.line(to: NSPoint(x: cx + halfWidth, y: cy + halfHeight))
        } else {
            path.move(to: NSPoint(x: cx - halfWidth, y: cy - halfHeight))
            path.line(to: NSPoint(x: cx, y: cy + halfHeight))
            path.line(to: NSPoint(x: cx + halfWidth, y: cy - halfHeight))
        }
        path.lineWidth = 1.1
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.secondaryLabelColor.setStroke()
        path.stroke()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?() ?? super.menu(for: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func apply(layout: FileListView.ColumnLayout, sort: SortField, ascending: Bool) {
        self.layout = layout
        self.sortField = sort
        self.ascending = ascending
        needsDisplay = true
    }
}

// MARK: - 列分隔线层

/// 列之间的分隔线层：覆盖整块列表区域（表头 + 正文），从上到下贯穿，
/// **每个列间隙以及最右侧列右边缘各有一条线**。
///
/// 它同时是唯一的列宽拖拽入口——竖线在表头还是在正文都能拖，双击分隔线可自动适配列宽：
/// 命中竖线时接管鼠标事件，其余位置一律穿透给下层（表头排序、列表选中照常）。
private final class ColumnDividerLayer: NSView {

    weak var owner: FileListView?
    private var layout = FileListView.ColumnLayout()
    /// 分隔线命中容差（像素）。
    private let tolerance: CGFloat = 5
    var scrollOffsetX: CGFloat = 0
    private var isDraggingDivider: Bool = false
    private var activeDividerTarget: ResizableColumn?
    private var hoveredDividerTarget: ResizableColumn?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func apply(layout: FileListView.ColumnLayout) {
        self.layout = layout
        needsDisplay = true
    }

    /// 只有点在竖线附近才接管鼠标事件，其余穿透给下层视图。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let owner else { return nil }
        let local = convert(point, from: superview)
        let docX = local.x + owner.scrollOffsetX
        guard owner.divider(at: docX, tolerance: tolerance) != nil else { return nil }
        return super.hitTest(point)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let owner, !isDraggingDivider else { return }
        let point = convert(event.locationInWindow, from: nil)
        let docX = point.x + owner.scrollOffsetX
        let hit = owner.divider(at: docX, tolerance: tolerance)?.target
        if hoveredDividerTarget != hit {
            hoveredDividerTarget = hit
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredDividerTarget != nil {
            hoveredDividerTarget = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let owner else { return }
        let point = convert(event.locationInWindow, from: nil)
        let docX = point.x + owner.scrollOffsetX
        guard let divider = owner.divider(at: docX, tolerance: tolerance) else { return }
        if event.clickCount == 2 {
            owner.autoFitColumn(divider.target)
            return
        }
        isDraggingDivider = true
        activeDividerTarget = divider.target
        needsDisplay = true
        owner.beginColumnResize(divider.target, startWindowX: event.locationInWindow.x)
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.updateColumnResize(currentWindowX: event.locationInWindow.x)
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingDivider = false
        activeDividerTarget = nil
        needsDisplay = true
        owner?.endColumnResize()
    }

    /// 鼠标正好停在竖线上时的滚轮事件转发给列表，否则列表会滚不动。
    override func scrollWheel(with event: NSEvent) {
        owner?.listScrollView.scrollWheel(with: event)
    }

    /// 竖线上显示调整宽度的光标：双向可拖用系统箭头，到边界时换成单向箭头。
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let owner else { return }
        let offsetX = owner.scrollOffsetX
        for divider in owner.dividers() {
            let viewX = divider.x - offsetX
            let leftTol = tolerance
            let rightTol = divider.isRightmost ? tolerance + 8 : tolerance
            guard viewX + rightTol >= 0 && viewX - leftTol <= bounds.width else { continue }
            let range = owner.widthRange(for: divider.target)
            let cursor = ColumnResizeCursor.cursor(for: range.direction(for: owner.currentWidth(of: divider.target)))
            addCursorRect(NSRect(x: viewX - leftTol, y: 0,
                                 width: leftTol + rightTol, height: bounds.height),
                          cursor: cursor)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        // 设备像素级 1px 发丝线：整数设备像素对齐，任何屏幕都清晰不糊。
        let scale = (window?.screen?.backingScaleFactor) ?? 1
        let lineW = 1.0 / scale
        let offsetX = owner.scrollOffsetX

        NSGraphicsContext.current?.saveGraphicsState()
        // 排除可视区域内的所有分组标题行矩形，防止竖线切断分组标题
        if owner.hasGroupHeaders, let outline = owner.outlineView as NSOutlineView? {
            let visibleRect = outline.visibleRect
            let visibleRows = outline.rows(in: visibleRect)
            if visibleRows.length > 0 {
                let clipPath = NSBezierPath(rect: bounds)
                for row in visibleRows.location..<(visibleRows.location + visibleRows.length) {
                    if let item = outline.item(atRow: row), item is FileListView.GroupNode {
                        let rowRectInOutline = outline.rect(ofRow: row)
                        let rowRectInLayer = self.convert(rowRectInOutline, from: outline)
                        clipPath.appendRect(rowRectInLayer)
                    }
                }
                clipPath.windingRule = .evenOdd
                clipPath.addClip()
            }
        }

        for div in owner.dividers() {
            let viewX = div.x - offsetX
            guard viewX >= -4 && viewX <= bounds.width + 4 else { continue }
            let x = (viewX * scale).rounded() / scale
            let isActive = (isDraggingDivider && activeDividerTarget == div.target)
            let isHovered = (!isDraggingDivider && hoveredDividerTarget == div.target)

            if isActive {
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSRect(x: x - 0.5, y: 0, width: max(1.5, lineW * 2), height: bounds.height).fill()
            } else if isHovered {
                NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
                NSRect(x: x - 0.5, y: 0, width: max(1.5, lineW * 2), height: bounds.height).fill()
            } else {
                NSColor.separatorColor.setFill()
                NSRect(x: x, y: 0, width: lineW, height: bounds.height).fill()
            }
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - 调整宽度的光标

/// 列宽拖拽用的光标：
/// - 双向可拖 → 系统标准的左右箭头
/// - 已到最小宽度 → 只能往右拖（变宽），显示「右侧箭头 + 左侧挡板」
/// - 已到最大宽度 → 只能往左拖（变窄），显示「左侧箭头 + 右侧挡板」
enum ColumnResizeCursor {

    private static var cache: [Int: NSCursor] = [:]

    /// direction：1 = 只能往右，-1 = 只能往左，0 = 双向
    static func cursor(for direction: Int) -> NSCursor {
        if direction == 0 { return .resizeLeftRight }
        if let cached = cache[direction] { return cached }
        let cursor = NSCursor(image: image(for: direction), hotSpot: NSPoint(x: 8, y: 8))
        cache[direction] = cursor
        return cursor
    }

    private static func image(for direction: Int) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let shape = NSBezierPath()
            let midY: CGFloat = 8
            if direction > 0 {
                // 只能往右：左侧挡板 + 右箭头
                shape.appendRect(NSRect(x: 3, y: 4, width: 1.5, height: 8))
                shape.appendRect(NSRect(x: 4.5, y: 7, width: 5.5, height: 2))
                shape.move(to: NSPoint(x: 12.5, y: midY))
                shape.line(to: NSPoint(x: 8.5, y: midY + 3.2))
                shape.line(to: NSPoint(x: 8.5, y: midY - 3.2))
                shape.close()
            } else {
                // 只能往左：右侧挡板 + 左箭头
                shape.appendRect(NSRect(x: 11.5, y: 4, width: 1.5, height: 8))
                shape.appendRect(NSRect(x: 6, y: 7, width: 5.5, height: 2))
                shape.move(to: NSPoint(x: 3.5, y: midY))
                shape.line(to: NSPoint(x: 7.5, y: midY + 3.2))
                shape.line(to: NSPoint(x: 7.5, y: midY - 3.2))
                shape.close()
            }
            // 白色描边 + 黑色填充：任何底色上都看得清
            shape.lineWidth = 3
            shape.lineJoinStyle = .round
            NSColor.white.setStroke()
            shape.stroke()
            NSColor.black.setFill()
            shape.fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - 行单元格

/// 文件行：图标 + 名称 + 若干属性列（列的组合由用户设置决定）。
private final class FileRowCell: NSTableCellView, NSTextFieldDelegate {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let tagDotsView = TagDotsView()
    /// 每种列一个标签，按需创建。
    private var valueLabels: [ListColumn: NSTextField] = [:]
    /// 列布局的来源：始终取列表里的最新布局，列宽变化后行内列位置不会停留在旧值。
    weak var owner: FileListView?
    /// 当前显示的文件（补建列标签时要按它填值）。
    private var item: FileItem?

    private(set) var isInlineEditing: Bool = false
    private var isStartingEditing = false
    var onCommitRename: ((String) -> Void)?
    var onCancelRename: (() -> Void)?

    /// 斑马线条纹底色。nil = 不画底色（透出下层的行背景与蓝色选中高亮）。
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        for field in [icon, title, tagDotsView] as [NSView] {
            field.translatesAutoresizingMaskIntoConstraints = true
            field.autoresizingMask = []
        }
        icon.imageScaling = .scaleProportionallyDown

        title.font = .systemFont(ofSize: 12.5)
        title.lineBreakMode = .byTruncatingMiddle

        for field in [icon, title, tagDotsView] as [NSView] { addSubview(field) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        tagDotsView.setColors([])
        tagDotsView.isHidden = true
        if isInlineEditing {
            isInlineEditing = false
            isStartingEditing = false
            title.isEditable = false
            title.isSelectable = false
            title.drawsBackground = false
            title.isBordered = false
            title.layer?.borderWidth = 0
            title.delegate = nil
        }
    }

    // MARK: - 就地重命名

    func isPointInName(_ pointInOutline: NSPoint, in outline: NSOutlineView) -> Bool {
        guard !isInlineEditing else { return false }
        let local = convert(pointInOutline, from: outline)
        guard local.y >= 0 && local.y <= bounds.height else { return false }
        // 严格匹配文件名文字实际渲染的区域（与访达一致：仅点击文件名文字本身才触发重命名，点击图标、同行空白处或其他列均不触发）
        let font = title.font ?? .systemFont(ofSize: 12.5)
        let rawTextW = ceil((title.stringValue as NSString).size(withAttributes: [.font: font]).width) + 4
        let actualTextW = title.frame.width > 0 ? min(title.frame.width, rawTextW) : rawTextW
        let textMinX = title.frame.minX
        let textMaxX = textMinX + actualTextW
        return local.x >= textMinX && local.x <= textMaxX
    }

    func startInlineEditing() {
        guard !isInlineEditing else { return }
        isInlineEditing = true
        isStartingEditing = true

        title.isEditable = true
        title.isSelectable = true
        title.drawsBackground = true
        title.backgroundColor = .textBackgroundColor
        title.textColor = .labelColor
        title.isBordered = true
        title.lineBreakMode = .byClipping
        title.cell?.isScrollable = true

        title.wantsLayer = true
        title.layer?.cornerRadius = 3
        title.layer?.masksToBounds = true
        title.layer?.borderWidth = 1
        title.layer?.borderColor = NSColor.separatorColor.cgColor

        updateFrames()
        window?.makeFirstResponder(title)
        title.delegate = self

        if let editor = title.currentEditor() as? NSTextView {
            editor.allowsUndo = true
            editor.textColor = .labelColor
            editor.insertionPointColor = .labelColor
            editor.drawsBackground = false
            var attrs = editor.typingAttributes
            attrs[.foregroundColor] = NSColor.labelColor
            editor.typingAttributes = attrs
            let fullText = title.stringValue
            let isDir = item?.isNavigable ?? false
            let ext = (fullText as NSString).pathExtension
            let length: Int
            if isDir || ext.isEmpty || fullText.hasPrefix(".") {
                length = fullText.count
            } else {
                length = (fullText as NSString).deletingPathExtension.count
            }
            editor.selectedRange = NSRange(location: 0, length: length)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isStartingEditing = false
            self.title.textColor = .labelColor
            if let editor = self.title.currentEditor() as? NSTextView {
                editor.allowsUndo = true
                editor.textColor = .labelColor
                editor.insertionPointColor = .labelColor
                var attrs = editor.typingAttributes
                attrs[.foregroundColor] = NSColor.labelColor
                editor.typingAttributes = attrs
            }
        }
    }

    func endInlineEditing(commit: Bool) {
        guard isInlineEditing else { return }
        InlineRenameTracker.markEditingEnded()
        isInlineEditing = false
        isStartingEditing = false
        title.isEditable = false
        title.isSelectable = false
        title.drawsBackground = false
        title.isBordered = false
        title.layer?.borderWidth = 0
        title.lineBreakMode = .byTruncatingMiddle
        title.cell?.isScrollable = false
        title.delegate = nil
        updateColors()
        updateFrames()

        let original = item?.name ?? ""
        if commit {
            let newName = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if newName.isEmpty || newName == original {
                title.stringValue = original
            } else {
                onCommitRename?(newName)
            }
        } else {
            title.stringValue = original
            onCancelRename?()
        }
        if let doc = owner?.listScrollView.documentView {
            window?.makeFirstResponder(doc)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            endInlineEditing(commit: true)
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endInlineEditing(commit: false)
            return true
        } else if commandSelector == Selector(("undo:")) {
            textView.undoManager?.undo()
            return true
        } else if commandSelector == Selector(("redo:")) {
            textView.undoManager?.redo()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        if isInlineEditing {
            updateFrames()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isStartingEditing, isInlineEditing else { return }
        endInlineEditing(commit: true)
    }

    /// 按列表当前的列布局摆放图标、文件名与各列内容。
    ///
    /// 列矩形是「列表坐标」（列表左沿为 0），表头与列分隔线都画在这个坐标系上。
    /// NSOutlineView 会把单元格整体按层级右移 `dx`（缩进）。因此在单元格局部坐标里：
    /// - 名称列的图标/文件名要保持常量 `nameIconX`/`nameTextX`，这样单元格右移 dx 后，
    ///   它们在列表坐标里自然落在 `nameIconX + dx`，即随层级右移、与展开三角保持固定间距；
    /// - 其余列（大小/种类/修改日期）要在固定列位、不随层级缩进，所以减掉 dx。
    func updateFrames() {
        // 只有真正挂在列表里（同一个窗口）时，单元格与列表之间的坐标偏移才可测量。
        guard let owner, bounds.height > 0, let window, window === owner.window else { return }
        let rowHeight = bounds.height
        let layout = owner.columnLayout
        let dx = convert(NSPoint.zero, to: owner.outlineView).x

        let iconSize = owner.iconSize
        let nameIconX: CGFloat = FileListView.nameIconX
        let nameTextX: CGFloat = nameIconX + iconSize + 6

        icon.frame = NSRect(x: nameIconX,
                            y: (rowHeight - iconSize) / 2,
                            width: iconSize, height: iconSize)
        let nameRight = layout.nameRect.maxX - 8
        let textHeight: CGFloat = isInlineEditing ? max(21, iconSize + 4) : 17
        let nameX = nameTextX - (isInlineEditing ? 3 : 0)
        let localNameRight = nameRight - dx
        let maxAvailableWidth = max(50, localNameRight - nameX + (isInlineEditing ? 3 : 0))

        let titleWidth: CGFloat
        if isInlineEditing {
            let font = title.font ?? .systemFont(ofSize: 12.5)
            let textW = (title.stringValue as NSString).size(withAttributes: [.font: font]).width
            // 访达同款：紧凑自适应文本宽度 + 内边距光标缓冲，且不超过列右边界
            titleWidth = min(maxAvailableWidth, max(50, ceil(textW) + 18))
            tagDotsView.isHidden = true
        } else {
            let tagCount = item?.tags.count ?? 0
            if tagCount > 0 {
                let dotsW = TagDotsView.preferredWidth(count: tagCount)
                let tagX = localNameRight - dotsW
                tagDotsView.isHidden = false
                tagDotsView.frame = NSRect(x: tagX,
                                           y: (rowHeight - 12) / 2,
                                           width: dotsW, height: 12)
                let titleRight = tagX - 6
                titleWidth = max(20, titleRight - nameX)
            } else {
                titleWidth = max(0, localNameRight - nameX)
                tagDotsView.isHidden = true
            }
        }

        title.frame = NSRect(x: nameX,
                             y: (rowHeight - textHeight) / 2,
                             width: titleWidth,
                             height: textHeight)

        let shown = Set(layout.entries.map { $0.column })
        for entry in layout.entries {
            let label = valueLabels[entry.column] ?? makeValueLabel(for: entry.column, item: item)
            label.isHidden = false
            let rect = entry.rect.offsetBy(dx: -dx, dy: 0)
            if entry.column == .size {
                label.alignment = .right
                label.frame = NSRect(x: rect.minX, y: (rowHeight - 15) / 2,
                                     width: max(0, rect.width - 6), height: 15)
            } else {
                label.alignment = .left
                label.frame = NSRect(x: rect.minX + 6, y: (rowHeight - 15) / 2,
                                     width: max(0, rect.width - 10), height: 15)
            }
        }
        for (column, label) in valueLabels where !shown.contains(column) {
            label.isHidden = true
        }
    }

    /// frame 变化（新行、复用行、列宽变化）时立即摆好内容。
    ///
    /// 不能只依赖 `layout()`：单元格先 `configure`、后由 AppKit 赋予真实行高，
    /// 那一轮 `layout()` 里 `bounds.height` 还是 0（`updateFrames` 会提前返回），
    /// 之后不会再回调，于是整行空白，直到下一次点击触发布局才恢复正常。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateFrames()
    }

    override func layout() {
        super.layout()
        updateFrames()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFrames()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateColors()
        }
    }

    private func updateColors() {
        if isInlineEditing {
            title.textColor = .labelColor
            if let editor = title.currentEditor() as? NSTextView {
                editor.textColor = .labelColor
                editor.insertionPointColor = .labelColor
                var attrs = editor.typingAttributes
                attrs[.foregroundColor] = NSColor.labelColor
                editor.typingAttributes = attrs
            }
            return
        }
        if backgroundStyle == .emphasized {
            title.textColor = .white
            for (_, label) in valueLabels {
                label.textColor = NSColor.white.withAlphaComponent(0.85)
            }
        } else {
            title.textColor = item?.isHidden == true ? .secondaryLabelColor : .labelColor
            for (_, label) in valueLabels {
                label.textColor = .secondaryLabelColor
            }
        }
    }

    func configure(with item: FileItem) {
        self.item = item
        icon.image = IconCache.shared.icon(for: item)
        title.stringValue = item.name
        tagDotsView.setColors(item.tagColors)
        for (column, label) in valueLabels {
            configureLabel(label, for: column, item: item)
        }
        updateColors()
        updateFrames()
    }

    private func configureLabel(_ label: NSTextField, for column: ListColumn, item: FileItem) {
        if column == .size {
            if item.isPackage {
                if let cached = BundleSizeCache.shared.size(for: item.url) {
                    label.stringValue = Format.bytes(cached)
                } else {
                    label.stringValue = "--"
                    BundleSizeCache.shared.requestSize(for: item.url) { [weak self, weak label] size in
                        guard let self, let label, self.item?.url == item.url else { return }
                        label.stringValue = Format.bytes(size)
                    }
                }
                return
            } else if item.isNavigable {
                if AppSettings.calculateFolderSizes {
                    if let cached = BundleSizeCache.shared.size(for: item.url) {
                        label.stringValue = Format.bytes(cached)
                    } else {
                        label.stringValue = "--"
                        BundleSizeCache.shared.requestSize(for: item.url) { [weak self, weak label] size in
                            guard let self, let label, self.item?.url == item.url else { return }
                            label.stringValue = Format.bytes(size)
                        }
                    }
                    return
                } else {
                    label.stringValue = "--"
                    return
                }
            }
        }
        label.stringValue = column.value(for: item)
    }

    /// 按需创建某一列的标签（列显示设置随时可变，缺哪列补哪列）。
    private func makeValueLabel(for column: ListColumn, item: FileItem?) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        if let item {
            configureLabel(label, for: column, item: item)
        }
        label.translatesAutoresizingMaskIntoConstraints = true
        label.autoresizingMask = []
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = (backgroundStyle == .emphasized) ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        valueLabels[column] = label
        return label
    }
}

private final class GroupRowCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    var isFirstGroup: Bool = false
    override var isFlipped: Bool { true }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        label.translatesAutoresizingMaskIntoConstraints = true
        label.autoresizingMask = []
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)

        countLabel.translatesAutoresizingMaskIntoConstraints = true
        countLabel.autoresizingMask = []
        countLabel.font = .systemFont(ofSize: 10.5)
        countLabel.textColor = .tertiaryLabelColor
        addSubview(countLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let textH: CGFloat = 14
        let y = isFirstGroup ? (bounds.height - textH) / 2 : bounds.height - textH - 4
        label.frame = NSRect(x: 12, y: y, width: 220, height: textH)
        countLabel.frame = NSRect(x: 12 + label.intrinsicContentSize.width + 6, y: y, width: 60, height: textH)
    }

    func configure(title: String, count: Int, isFirst: Bool) {
        self.isFirstGroup = isFirst
        label.stringValue = title.uppercased()
        countLabel.stringValue = "\(count)"
        needsLayout = true
    }
}
