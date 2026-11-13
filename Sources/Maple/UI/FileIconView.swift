import AppKit
import QuartzCore

/// 图标视图：NSCollectionView 网格，支持分组标题、访达风格胶囊高亮、框选与快速双击响应，
/// 以及浏览器级丝滑的触摸板双指左右滑动前进/回退手势。
final class FileIconView: NSView {

    var onOpen: ((FileItem) -> Void)?
    var onSelectionChange: ((Set<URL>) -> Void)?
    var onActivate: (() -> Void)?
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

    /// 当前所属窗格是否处于焦点状态（多窗格管理用）。
    var isPaneActive: Bool = false {
        didSet {
            guard oldValue != isPaneActive else { return }
            updateVisibleSelectionStates()
        }
    }

    private let scroll = IconScrollView()
    private let flowLayout = NSCollectionViewFlowLayout()
    private let collection = KeyCollectionView()
    private let swipeBadge = SwipeIndicatorBadge()
    private var sections: [FileSection] = []

    /// 触发回退/前进所需的有效手指水平位移阈值（pt，对标 Chrome 浏览器阻尼手感）。
    private let swipeTriggerThreshold: CGFloat = 128
    private var badgeLeadingConstraint: NSLayoutConstraint!
    private var badgeCenterYConstraint: NSLayoutConstraint!

    /// 当前图标尺寸（自适应计算）。
    var iconSize: CGFloat = Theme.gridIconSize
    private var lastAdaptiveWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true

        let initialFrame = NSRect(x: 0, y: 0, width: 800, height: 600)
        scroll.frame = initialFrame
        collection.frame = initialFrame

        FileIconItem.iconSize = iconSize
        flowLayout.itemSize = Self.itemSize(for: iconSize)
        flowLayout.minimumInteritemSpacing = 8
        flowLayout.minimumLineSpacing = 10
        flowLayout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 16, right: 10)
        flowLayout.headerReferenceSize = .zero

        collection.wantsLayer = true
        collection.collectionViewLayout = flowLayout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.controlBackgroundColor]
        collection.registerForDraggedTypes([.fileURL])
        collection.dataSource = self
        collection.delegate = self
        collection.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.identifier)
        collection.register(IconSectionHeader.self,
                            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: IconSectionHeader.identifier)
        collection.menuProvider = { [weak self] item in self?.menuProvider?(item) }
        collection.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }

        // 事件回调注入：双击即刻打开、空白处点击/框选通知、窗格激活
        collection.onActivate = { [weak self] in self?.onActivate?() }
        collection.itemProvider = { [weak self] indexPath in self?.item(at: indexPath) }
        collection.onOpenItem = { [weak self] item in self?.onOpen?(item) }
        collection.onTriggerRename = { [weak self] indexPath in self?.startRename(at: indexPath) }
        collection.isPointInName = { [weak self] indexPath, point in
            guard let self, let item = self.collection.item(at: indexPath) as? FileIconItem else { return false }
            return item.isPointInName(point, in: self.collection)
        }
        collection.onSelectionChanged = { [weak self] in
            guard let self else { return }
            self.onSelectionChange?(self.selectedURLs())
            self.updateVisibleSelectionStates()
        }
        collection.onFirstResponderChanged = { [weak self] in
            self?.updateVisibleSelectionStates()
        }

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
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

        swipeBadge.translatesAutoresizingMaskIntoConstraints = false
        swipeBadge.alphaValue = 0
        swipeBadge.isHidden = true
        addSubview(swipeBadge)

        badgeLeadingConstraint = swipeBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -44)
        badgeCenterYConstraint = swipeBadge.centerYAnchor.constraint(equalTo: centerYAnchor)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            badgeLeadingConstraint,
            badgeCenterYConstraint,
            swipeBadge.widthAnchor.constraint(equalToConstant: SwipeIndicatorBadge.diameter),
            swipeBadge.heightAnchor.constraint(equalToConstant: SwipeIndicatorBadge.diameter)
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        collection.backgroundColors = [.controlBackgroundColor]
        scroll.backgroundColor = .controlBackgroundColor
        collection.reloadData()
        needsDisplay = true
    }

    // MARK: - 触摸板丝滑左右滑动手势（右滑回退 / 左滑前进，Chrome 级阻尼与触发阈值）

    private func handleSwipeBegin() {
        collection.layer?.removeAllAnimations()
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

        // 1. 视图层跟随手指产生细腻的阻尼平移，提供浏览器级沉稳跟手反馈
        let maxVisualShift: CGFloat = allowed ? 44 : 10
        let damping: CGFloat = allowed ? 0.30 : 0.08
        let rawShift = absDX * damping
        let dampedShift = maxVisualShift * (1 - exp(-rawShift / max(1, maxVisualShift)))
        let signedShift = isRightSlide ? dampedShift : -dampedShift

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        collection.layer?.transform = CATransform3DMakeTranslation(signedShift, 0, 0)
        collection.layer?.opacity = allowed ? Float(max(0.88, 1.0 - (absDX / swipeTriggerThreshold) * 0.08)) : 1.0
        CATransaction.commit()

        // 2. 浏览器同款边缘圆形回退/前进指示器（从小变大，透明度从浅变深）
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

        // 位移达标，或较大行程快速轻拂方可触发（对标 Chrome 浏览器防误触手感）
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

    /// 触发导航后：新目录内容从对应方向丝滑滑入归位，边缘指示器轻盈消散
    private func animateTransitionAfterTrigger(isBack: Bool) {
        let entryOffset: CGFloat = isBack ? -36 : 36

        if let layer = collection.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DIdentity
            layer.opacity = 1.0
            CATransaction.commit()

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

    /// 未达阈值松手：网格与指示器平滑回弹归位
    private func animateCancelReset() {
        if let layer = collection.layer {
            let currentX = (layer.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
            let currentOpacity = layer.opacity

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DIdentity
            layer.opacity = 1.0
            CATransaction.commit()

            if abs(currentX) > 0.5 {
                let spring = CABasicAnimation(keyPath: "transform.translation.x")
                spring.fromValue = currentX
                spring.toValue = 0
                spring.duration = 0.18
                spring.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                layer.add(spring, forKey: "swipeCancelResetX")
            }
            if currentOpacity < 0.99 {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = currentOpacity
                fade.toValue = 1.0
                fade.duration = 0.15
                layer.add(fade, forKey: "swipeCancelOpacity")
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let win = window {
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(windowKeyChanged(_:)),
                                                   name: NSWindow.didBecomeKeyNotification,
                                                   object: win)
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(windowKeyChanged(_:)),
                                                   name: NSWindow.didResignKeyNotification,
                                                   object: win)
        }
    }

    @objc private func windowKeyChanged(_ note: Notification) {
        guard let win = window, let sender = note.object as? NSWindow, win === sender else { return }
        updateVisibleSelectionStates()
    }

    /// 点击当前未激活的窗口或窗格，首击立即响应
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        focus()
        onActivate?()
        collection.deselectAll(nil)
        onSelectionChange?(Set())
        super.mouseDown(with: event)
    }

    // MARK: - 数据与布局（原生紧凑流式布局，硬件加速 120 帧）

    static func itemSize(for iconSize: CGFloat) -> NSSize {
        NSSize(width: max(72, iconSize + 28), height: iconSize + 44)
    }

    /// 应用由显示选项调节的图标尺寸，仅在设置改变时刷新
    func applyIconSize(_ size: CGFloat) {
        let clamped = max(36, min(96, size))
        iconSize = clamped
        FileIconItem.iconSize = clamped
        flowLayout.itemSize = Self.itemSize(for: clamped)
        flowLayout.invalidateLayout()
        collection.reloadData()
    }

    func update(sections: [FileSection]) {
        let previous = selectedURLs()
        self.sections = sections
        collection.reloadData()
        restoreSelection(previous)
        updateVisibleSelectionStates()
    }

    var items: [FileItem] { sections.flatMap { $0.items } }

    var selectedItems: [FileItem] {
        collection.selectionIndexPaths.compactMap { item(at: $0) }
    }

    private func item(at indexPath: IndexPath) -> FileItem? {
        guard indexPath.section < sections.count,
              indexPath.item < sections[indexPath.section].items.count else { return nil }
        return sections[indexPath.section].items[indexPath.item]
    }

    private func selectedURLs() -> Set<URL> {
        Set(selectedItems.map { $0.url })
    }

    private func restoreSelection(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        var indexPaths = Set<IndexPath>()
        for (sectionIndex, section) in sections.enumerated() {
            for (itemIndex, item) in section.items.enumerated() where paths.contains(item.url.standardizedFileURL.path) {
                indexPaths.insert(IndexPath(item: itemIndex, section: sectionIndex))
            }
        }
        collection.selectionIndexPaths = indexPaths
    }

    func select(urls: Set<URL>) {
        restoreSelection(urls)
        updateVisibleSelectionStates()
        if let first = collection.selectionIndexPaths.first {
            collection.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
        }
    }

    // MARK: - 就地重命名（访达同款）

    func startRenameSelected() {
        guard let path = collection.selectionIndexPaths.first, collection.selectionIndexPaths.count == 1 else { return }
        startRename(at: path)
    }

    func startRename(at indexPath: IndexPath) {
        collection.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
        collection.layoutSubtreeIfNeeded()
        guard let item = collection.item(at: indexPath) as? FileIconItem else { return }
        focus()
        item.startInlineEditing()
    }

    func performRename(item: FileItem, newName: String) {
        FileOperations.performRename(item: item, newName: newName, window: window) { [weak self] oldURL, newURL in
            self?.onFileRenamed?(oldURL, newURL)
        }
    }

    func selectAll() {
        var paths = Set<IndexPath>()
        for (sectionIndex, section) in sections.enumerated() {
            for itemIndex in section.items.indices {
                paths.insert(IndexPath(item: itemIndex, section: sectionIndex))
            }
        }
        collection.selectionIndexPaths = paths
        updateVisibleSelectionStates()
    }

    func focus() {
        window?.makeFirstResponder(collection)
        updateVisibleSelectionStates()
    }

    func deselectAll() {
        collection.deselectAll(nil)
    }

    func scrollToTop() { collection.scroll(.zero) }

    /// 键盘上下/左右移动选中项（供搜索面板在输入框焦点下也能快速切换选中项）。
    func moveSelection(by delta: Int) {
        guard !sections.isEmpty else { return }
        var flat: [IndexPath] = []
        for (sIdx, sec) in sections.enumerated() {
            for iIdx in sec.items.indices {
                flat.append(IndexPath(item: iIdx, section: sIdx))
            }
        }
        guard !flat.isEmpty else { return }
        let current = collection.selectionIndexPaths.first
        let nextIdx: Int
        if let current, let pos = flat.firstIndex(of: current) {
            nextIdx = min(max(0, pos + delta), flat.count - 1)
        } else {
            nextIdx = delta >= 0 ? 0 : flat.count - 1
        }
        let target = flat[nextIdx]
        collection.selectionIndexPaths = [target]
        collection.scrollToItems(at: [target], scrollPosition: .nearestHorizontalEdge)
        onSelectionChange?(selectedURLs())
        updateVisibleSelectionStates()
    }

    /// 统一刷新当前可见项的选中高亮颜色（随窗口 key / 窗格 focus 动态适配）。
    func updateVisibleSelectionStates() {
        let active = isPaneActive && (window?.isKeyWindow ?? false)
        for item in collection.visibleItems() {
            if let iconItem = item as? FileIconItem {
                iconItem.isPaneActive = active
            }
        }
    }
}

// MARK: - 数据源 / 代理

extension FileIconView: NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: NSCollectionView,
                        layout collectionViewLayout: NSCollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> NSSize {
        guard section < sections.count else { return .zero }
        let s = sections[section]
        if s.title.isEmpty {
            return .zero
        }
        let w = max(collectionView.bounds.width - 20, 100)
        return NSSize(width: w, height: 24)
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: FileIconItem.identifier, for: indexPath)
        if let iconItem = cell as? FileIconItem, let model = item(at: indexPath) {
            let active = isPaneActive && (window?.isKeyWindow ?? false)
            iconItem.configure(with: model, isPaneActive: active)
            iconItem.onCommitRename = { [weak self] newName in
                guard let self, let current = self.item(at: indexPath) else { return }
                self.performRename(item: current, newName: newName)
            }
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView,
                        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(
            ofKind: kind,
            withIdentifier: IconSectionHeader.identifier,
            for: indexPath
        )
        if let header = view as? IconSectionHeader {
            let section = sections[indexPath.section]
            header.configure(title: section.title, hidden: section.title.isEmpty)
        }
        return view
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        onActivate?()
        onSelectionChange?(selectedURLs())
        updateVisibleSelectionStates()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChange?(selectedURLs())
        updateVisibleSelectionStates()
    }

    // MARK: 拖拽数据源与接收

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard let item = item(at: indexPath) else { return nil }
        return item.url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let urls = FileOperations.readURLs(from: draggingInfo)
        guard !urls.isEmpty else { return [] }
        let ip = proposedDropIndexPath.pointee as IndexPath
        let destURL: URL
        if let targetItem = item(at: ip), targetItem.isDirectory {
            destURL = targetItem.url
            proposedDropOperation.pointee = .on
        } else {
            guard let current = currentFolderURL else { return [] }
            destURL = current
            proposedDropOperation.pointee = .before
        }
        return FileOperations.shouldCopy(for: draggingInfo, destination: destURL) ? .copy : .move
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let urls = FileOperations.readURLs(from: draggingInfo)
        guard !urls.isEmpty else { return false }
        let destURL: URL
        if dropOperation == .on, let targetItem = item(at: indexPath), targetItem.isDirectory {
            destURL = targetItem.url
        } else {
            guard let current = currentFolderURL else { return false }
            destURL = current
        }
        let isCopy = FileOperations.shouldCopy(for: draggingInfo, destination: destURL)
        onDropFiles?(urls, destURL, isCopy)
        return true
    }
}

// MARK: - 集合视图子类

final class KeyCollectionView: NSCollectionView {
    var keyHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((FileItem?) -> NSMenu?)?
    var onActivate: (() -> Void)?
    var itemProvider: ((IndexPath) -> FileItem?)?
    var onOpenItem: ((FileItem) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onFirstResponderChanged: (() -> Void)?
    var onTriggerRename: ((IndexPath) -> Void)?
    var isPointInName: ((IndexPath, NSPoint) -> Bool)?

    private var potentialRenamePath: IndexPath?
    private var pendingRenameWorkItem: DispatchWorkItem?
    private var mouseDidDrag = false
    private var dragStartPoint: NSPoint?
    private var dragStartWindowPoint: NSPoint?
    private var dragInitialSelection: Set<IndexPath> = []
    private var isRubberBandDragging = false
    private var didClickOnMultiSelection = false

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFirstResponderChanged?() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFirstResponderChanged?() }
        return result
    }

    /// 保证网格在内容较少时也能铺满滚动区域，使用户点击底部空白处也能正确激活窗格并取消选中或拉框选。
    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let clip = enclosingScrollView?.contentView {
            let visibleSize = clip.bounds.size
            if size.width < visibleSize.width { size.width = visibleSize.width }
            if size.height < visibleSize.height { size.height = visibleSize.height }
        }
        super.setFrameSize(size)
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

    override func mouseDown(with event: NSEvent) {
        pendingRenameWorkItem?.cancel()
        pendingRenameWorkItem = nil
        mouseDidDrag = false
        potentialRenamePath = nil
        dragStartWindowPoint = event.locationInWindow

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

        window?.makeFirstResponder(self)
        let didEndEditingOnThisClick = wasEditingBeforeClick || InlineRenameTracker.didEndDuring(event: event)
        onActivate?()

        let point = convert(event.locationInWindow, from: nil)
        let clickedPath = indexPathForItem(at: point)
        dragStartPoint = point
        dragInitialSelection = selectionIndexPaths
        isRubberBandDragging = (clickedPath == nil)

        // 双击：立即打开对应项目（0 延迟原生手感）
        if event.clickCount >= 2 {
            didClickOnMultiSelection = false
            if let path = clickedPath, let item = itemProvider?(path) {
                if !selectionIndexPaths.contains(path) {
                    selectionIndexPaths = [path]
                    onSelectionChanged?()
                }
                onOpenItem?(item)
                return
            }
        }

        // 判断该项在点击前是否已被单独选中，且点在文件名文字区域
        let wasAlreadySingleSelected = (clickedPath != nil && selectionIndexPaths.count == 1 && selectionIndexPaths.contains(clickedPath!))
        let hitName: Bool
        if let path = clickedPath {
            hitName = isPointInName?(path, point) ?? false
        } else {
            hitName = false
        }

        // 单击空白处且未按 ⌘ / ⇧：与访达一致清空选中
        if clickedPath == nil && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
            if !selectionIndexPaths.isEmpty {
                deselectAll(nil)
                onSelectionChanged?()
            }
        }

        if !didEndEditingOnThisClick, let path = clickedPath, wasAlreadySingleSelected, hitName, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift) {
            potentialRenamePath = path
        }

        // 如果用户在已多选的项目中点击了其中某一项，且未按 ⌘ / ⇧：
        // 延迟至鼠标抬起时再单选它，以便在拖拽时能完整带出所有选中的文件
        if let path = clickedPath, selectionIndexPaths.contains(path), selectionIndexPaths.count > 1, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift) {
            didClickOnMultiSelection = true
        } else if wasAlreadySingleSelected {
            // 已被单独选中的项再次单击：保留选中，使后续 mouseUp 能准确收到事件并触发重命名
            window?.makeFirstResponder(self)
        } else {
            didClickOnMultiSelection = false
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let curWindow = event.locationInWindow
        let startWindow = dragStartWindowPoint ?? curWindow
        let dist = hypot(curWindow.x - startWindow.x, curWindow.y - startWindow.y)

        // 仅当位移达到系统拖拽阈值（>= 3pt）时才视为拖拽
        // 触摸板微小晃动（< 3pt）保留重命名状态，不触发拖动
        if dist >= 3.0 {
            mouseDidDrag = true
            potentialRenamePath = nil
            pendingRenameWorkItem?.cancel()
            pendingRenameWorkItem = nil
        }

        guard mouseDidDrag else { return }

        // 1. 若拖拽起始于某一个文件图标且位移超过 3pt：启动文件拖拽！
        if !isRubberBandDragging, let start = dragStartPoint {
            let pathsToDrag: Set<IndexPath>
            if let clicked = indexPathForItem(at: start) {
                if selectionIndexPaths.contains(clicked) {
                    pathsToDrag = selectionIndexPaths
                } else {
                    selectionIndexPaths = [clicked]
                    onSelectionChanged?()
                    pathsToDrag = [clicked]
                }
                let urls = pathsToDrag.compactMap { itemProvider?($0)?.url }
                if !urls.isEmpty {
                    let items = FileDragHelper.createDraggingItems(for: urls, at: start)
                    let session = beginDraggingSession(with: items, event: event, source: self)
                    session.animatesToStartingPositionsOnCancelOrFail = true
                    dragStartPoint = nil
                    didClickOnMultiSelection = false
                    dragStartWindowPoint = nil
                    return
                }
            }
        }

        super.mouseDragged(with: event)

        // 框选模式：实时计算相交项并立即更新选中高亮，与访达一致
        if isRubberBandDragging, let start = dragStartPoint {
            let current = convert(event.locationInWindow, from: nil)
            let rect = NSRect(x: min(start.x, current.x),
                              y: min(start.y, current.y),
                              width: max(1, abs(current.x - start.x)),
                              height: max(1, abs(current.y - start.y)))

            let totalItems = numberOfItems(inSection: 0)
            var touched = Set<IndexPath>()
            for i in 0..<totalItems {
                let ip = IndexPath(item: i, section: 0)
                if let layoutAttrs = layoutAttributesForItem(at: ip) {
                    if layoutAttrs.frame.intersects(rect) {
                        touched.insert(ip)
                    }
                }
            }

            let newSelection: Set<IndexPath>
            if event.modifierFlags.contains(.command) {
                newSelection = dragInitialSelection.symmetricDifference(touched)
            } else if event.modifierFlags.contains(.shift) {
                newSelection = dragInitialSelection.union(touched)
            } else {
                newSelection = touched
            }

            if selectionIndexPaths != newSelection {
                selectionIndexPaths = newSelection
                onSelectionChanged?()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let didDrag = mouseDidDrag
        let targetPath = potentialRenamePath
        potentialRenamePath = nil

        if didClickOnMultiSelection && !didDrag {
            if let start = dragStartPoint, let clicked = indexPathForItem(at: start) {
                selectionIndexPaths = [clicked]
            }
        }
        didClickOnMultiSelection = false
        isRubberBandDragging = false
        dragStartPoint = nil
        dragStartWindowPoint = nil
        mouseDidDrag = false
        super.mouseUp(with: event)
        onSelectionChanged?()

        // 访达同款：未拖拽、单选状态、单次单击且在同一个有效项上抬起时，延迟双击间隔触发就地重命名
        if !didDrag, let p = targetPath, selectionIndexPaths.count == 1, selectionIndexPaths.contains(p), event.clickCount == 1 {
            let delay = NSEvent.doubleClickInterval
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.mouseDidDrag, self.selectionIndexPaths.count == 1, self.selectionIndexPaths.contains(p) else { return }
                self.onTriggerRename?(p)
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
        potentialRenamePath = nil
        pendingRenameWorkItem?.cancel()
        pendingRenameWorkItem = nil
        dragStartPoint = nil
        dragStartWindowPoint = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        pendingRenameWorkItem?.cancel()
        pendingRenameWorkItem = nil
        potentialRenamePath = nil

        window?.makeFirstResponder(self)
        onActivate?()

        let point = convert(event.locationInWindow, from: nil)
        let clickedItem: FileItem?
        if let indexPath = indexPathForItem(at: point) {
            // 右键未选中的项目时单选该项目；若已在多选集合中则保持多选
            if !selectionIndexPaths.contains(indexPath) {
                selectionIndexPaths = [indexPath]
                onSelectionChanged?()
            }
            clickedItem = itemProvider?(indexPath)
        } else {
            // 右键空白处：与访达一致清空选中，展示文件夹级菜单
            if !selectionIndexPaths.isEmpty {
                deselectAll(nil)
                onSelectionChanged?()
            }
            clickedItem = nil
        }
        return menuProvider?(clickedItem) ?? super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        if event.keyCode == 36, let path = selectionIndexPaths.first, selectionIndexPaths.count == 1 {
            pendingRenameWorkItem?.cancel()
            pendingRenameWorkItem = nil
            onTriggerRename?(path)
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - 单元格（访达风格）

final class FileIconItem: NSCollectionViewItem, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("FileIconItem")
    /// 由 FileIconView 统一注入，保证所有单元格的图标尺寸一致。
    static var iconSize: CGFloat = Theme.gridIconSize

    /// 窗格激活状态：激活显示系统主强调色（蓝），未激活或窗口失焦显示柔和中性灰
    var isPaneActive: Bool = false {
        didSet { updateSelectionVisuals() }
    }

    private let iconContainer = NSView()
    private let iconView = NSImageView()
    private let iconHighlight = NSView()

    /// 访达风格文本胶囊：仅在文件名周围紧凑包裹圆角高亮背景，而非染整个单元格
    private let textBubble = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var model: FileItem?

    private(set) var isInlineEditing: Bool = false
    private var isStartingEditing = false
    var onCommitRename: ((String) -> Void)?
    var onCancelRename: (() -> Void)?

    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: FileIconView.itemSize(for: Self.iconSize)))
        view.wantsLayer = true

        // 1. 选中时图标背景光晕（与访达一致：尺寸适度超出图标，左右留出呼吸边距）
        iconHighlight.translatesAutoresizingMaskIntoConstraints = false
        iconHighlight.wantsLayer = true
        iconHighlight.layer?.cornerRadius = 10
        iconHighlight.isHidden = true
        view.addSubview(iconHighlight)

        // 2. 图标容器
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.wantsLayer = true
        view.addSubview(iconContainer)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconContainer.addSubview(iconView)

        // 3. 文本高亮胶囊（在 label 下层，跟随 label 尺寸紧贴包裹）
        textBubble.translatesAutoresizingMaskIntoConstraints = false
        textBubble.wantsLayer = true
        textBubble.layer?.cornerRadius = 4.5
        textBubble.layer?.masksToBounds = true
        textBubble.isHidden = true
        view.addSubview(textBubble)

        // 4. 文件名文本
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.isBordered = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.addSubview(label)

        iconWidthConstraint = iconContainer.widthAnchor.constraint(equalToConstant: Self.iconSize)
        iconHeightConstraint = iconContainer.heightAnchor.constraint(equalToConstant: Self.iconSize)

        NSLayoutConstraint.activate([
            // 图标居中与尺寸
            iconContainer.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            iconContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconWidthConstraint,
            iconHeightConstraint,

            iconView.topAnchor.constraint(equalTo: iconContainer.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor),
            iconView.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),

            // 图标背后的选中圆角背景
            iconHighlight.topAnchor.constraint(equalTo: iconContainer.topAnchor, constant: -4),
            iconHighlight.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 4),
            iconHighlight.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor, constant: -8),
            iconHighlight.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 8),

            // 文本水平居中，两端留出安全内边距
            label.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 5),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -2),

            // 文本胶囊紧密环绕文本，形成访达同款标签效果
            textBubble.topAnchor.constraint(equalTo: label.topAnchor, constant: -2),
            textBubble.bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            textBubble.leadingAnchor.constraint(equalTo: label.leadingAnchor, constant: -6),
            textBubble.trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6)
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if isInlineEditing {
            isInlineEditing = false
            isStartingEditing = false
            label.isEditable = false
            label.isSelectable = false
            label.drawsBackground = false
            label.isBordered = false
            label.layer?.borderWidth = 0
            label.delegate = nil
        }
        model = nil
        iconView.image = nil
        label.stringValue = ""
        isSelected = false
        updateSelectionVisuals()
    }

    // MARK: - 就地重命名（访达同款）

    func isPointInName(_ pointInCollection: NSPoint, in collection: NSCollectionView) -> Bool {
        guard !isInlineEditing else { return false }
        let local = view.convert(pointInCollection, from: collection)
        // 图标模式：仅点在下方文件名文字区域或胶囊上才视为点击文件名（就地重命名），点击图标或四周空白均不触发
        let hitRect = textBubble.isHidden ? label.frame.insetBy(dx: -4, dy: -2) : textBubble.frame.insetBy(dx: -2, dy: -2)
        return hitRect.contains(local)
    }

    func startInlineEditing() {
        guard !isInlineEditing else { return }
        isInlineEditing = true
        isStartingEditing = true
        textBubble.isHidden = true
        label.isEditable = true
        label.isSelectable = true
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.textColor = .labelColor
        label.isBordered = true
        label.lineBreakMode = .byClipping
        label.cell?.isScrollable = true

        label.wantsLayer = true
        label.layer?.cornerRadius = 3
        label.layer?.masksToBounds = true
        label.layer?.borderWidth = 1
        label.layer?.borderColor = NSColor.separatorColor.cgColor

        view.window?.makeFirstResponder(label)
        label.delegate = self

        if let editor = label.currentEditor() as? NSTextView {
            editor.allowsUndo = true
            editor.textColor = .labelColor
            editor.insertionPointColor = .labelColor
            editor.drawsBackground = false
            var attrs = editor.typingAttributes
            attrs[.foregroundColor] = NSColor.labelColor
            editor.typingAttributes = attrs
            let fullText = label.stringValue
            let isDir = model?.isNavigable ?? false
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
            self.label.textColor = .labelColor
            if let editor = self.label.currentEditor() as? NSTextView {
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
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        label.layer?.borderWidth = 0
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.isScrollable = false
        label.delegate = nil
        updateSelectionVisuals()

        let original = model?.name ?? ""
        if commit {
            let newName = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if newName.isEmpty || newName == original {
                label.stringValue = original
            } else {
                onCommitRename?(newName)
            }
        } else {
            label.stringValue = original
            onCancelRename?()
        }
        if let collectionView = view.superview as? NSCollectionView {
            view.window?.makeFirstResponder(collectionView)
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

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isStartingEditing, isInlineEditing else { return }
        endInlineEditing(commit: true)
    }

    func configure(with item: FileItem, isPaneActive: Bool) {
        self.model = item
        self.isPaneActive = isPaneActive

        if iconWidthConstraint.constant != Self.iconSize {
            iconWidthConstraint.constant = Self.iconSize
            iconHeightConstraint.constant = Self.iconSize
        }

        iconView.image = IconCache.shared.icon(for: item)
        label.stringValue = item.name
        updateSelectionVisuals()
    }

    override var isSelected: Bool {
        didSet { updateSelectionVisuals() }
    }

    private func updateSelectionVisuals() {
        if isInlineEditing {
            textBubble.isHidden = true
            return
        }

        let windowActive = view.window?.isKeyWindow ?? false
        let effectiveActive = isPaneActive && windowActive

        if isSelected {
            iconHighlight.isHidden = false
            iconHighlight.layer?.backgroundColor = effectiveActive
                ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                : NSColor.labelColor.withAlphaComponent(0.08).cgColor

            textBubble.isHidden = false
            textBubble.layer?.backgroundColor = effectiveActive
                ? NSColor.controlAccentColor.cgColor
                : NSColor(white: 0.5, alpha: 0.28).cgColor

            label.textColor = effectiveActive
                ? .white
                : .labelColor
        } else {
            iconHighlight.isHidden = true
            textBubble.isHidden = true
            textBubble.layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = (model?.isHidden ?? false) ? .secondaryLabelColor : .labelColor
        }
    }
}

// MARK: - 分组头视图

final class IconSectionHeader: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("IconSectionHeader")
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, hidden: Bool) {
        label.stringValue = title.uppercased()
        label.isHidden = hidden
    }
}

// MARK: - 支持双指横向滑动手势的滚动容器

final class IconScrollView: NSScrollView {

    var canSwipe: (() -> Bool)?
    var canSwipeDirection: ((_ isBack: Bool) -> Bool)?
    var onSwipeBegin: (() -> Void)?
    var onSwipeChange: ((CGFloat) -> Void)?
    var onSwipeEnd: ((_ totalFingerDX: CGFloat, _ velocityX: CGFloat, _ cancelled: Bool) -> Void)?

    private enum GestureMode {
        case undecided
        case nativeScroll
        case horizontalSwipe
    }

    /// 起手防误触死区（pt）：手指明确横向滑过该距离且角度纯粹才进入前进/后退手势
    private static let swipeActivationDeadzone: CGFloat = 22

    private var mode: GestureMode = .undecided
    private var accumulatedFingerDX: CGFloat = 0
    private var accumulatedFingerDY: CGFloat = 0
    private var swipeStartOffsetX: CGFloat = 0
    private var lastVelocityX: CGFloat = 0
    private var suppressMomentum: Bool = false
    private var atLeftEdgeAtStart: Bool = true
    private var atRightEdgeAtStart: Bool = true

    override func scrollWheel(with event: NSEvent) {
        // 若当前视图禁止左右滑动前进/后退（如标签视图、「所有标签…」等），直接走原生滚动
        if let canSwipe, !canSwipe() {
            mode = .undecided
            suppressMomentum = false
            super.scrollWheel(with: event)
            return
        }
        // 仅对触摸板 / Magic Mouse 高精度连续手势启用丝滑横向滑动导航
        guard event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }

        // 若刚刚结束一次横向滑动，吞掉余留的惯性滚动事件，防止误触发二次导航或抖动
        if event.momentumPhase != [] {
            if suppressMomentum { return }
            super.scrollWheel(with: event)
            return
        }

        if event.phase == .began || event.phase == .mayBegin {
            mode = .undecided
            accumulatedFingerDX = 0
            accumulatedFingerDY = 0
            swipeStartOffsetX = 0
            lastVelocityX = 0
            suppressMomentum = false
            updateHorizontalEdgeStateAtStart()
        }

        // 将滚动增量还原为物理手指在触摸板上的真实位移方向：
        // fingerDX > 0 始终代表「双指向右滑动」（回退上一级），fingerDX < 0 代表「双指向左滑动」（前进）
        let fingerDX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let fingerDY = event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY

        if event.phase == .changed {
            accumulatedFingerDX += fingerDX
            accumulatedFingerDY += fingerDY
            lastVelocityX = fingerDX

            if mode == .undecided {
                let absX = abs(accumulatedFingerDX)
                let absY = abs(accumulatedFingerDY)

                // 1. 若存在可水平滚动的内容（如宽列表），且当前手势方向是在正常滚动内容，则立即交由原生滚动
                if hasHorizontallyScrollableContent {
                    if accumulatedFingerDX > 3 && !atLeftEdgeAtStart {
                        mode = .nativeScroll
                    } else if accumulatedFingerDX < -3 && !atRightEdgeAtStart {
                        mode = .nativeScroll
                    }
                }

                // 2. 起手一旦出现明显纵向分量，立即锁定为原生滚动，绝不抢占上下浏览
                if mode == .undecided {
                    if absY > 8 && absY > absX * 0.75 {
                        mode = .nativeScroll
                    } else if absX >= Self.swipeActivationDeadzone {
                        if absX > absY * 2.0 {
                            let isBack = (accumulatedFingerDX >= 0)
                            let edgeAllows = !hasHorizontallyScrollableContent
                                || (isBack ? atLeftEdgeAtStart : atRightEdgeAtStart)
                            if edgeAllows {
                                mode = .horizontalSwipe
                                swipeStartOffsetX = accumulatedFingerDX
                                suppressMomentum = true
                                onSwipeBegin?()
                            } else {
                                mode = .nativeScroll
                            }
                        } else {
                            mode = .nativeScroll
                        }
                    }
                }
            }

            if mode == .horizontalSwipe {
                let effectiveDX = accumulatedFingerDX - swipeStartOffsetX
                onSwipeChange?(effectiveDX)
                return
            }
        }

        if event.phase == .ended || event.phase == .cancelled {
            if mode == .horizontalSwipe {
                let cancelled = (event.phase == .cancelled)
                let effectiveDX = accumulatedFingerDX - swipeStartOffsetX
                onSwipeEnd?(effectiveDX, lastVelocityX, cancelled)
                mode = .undecided
                return
            }
            mode = .undecided
        }

        super.scrollWheel(with: event)
    }

    private var hasHorizontallyScrollableContent: Bool {
        guard hasHorizontalScroller, let doc = documentView else { return false }
        return doc.frame.width > contentView.bounds.width + 1.0
    }

    private func updateHorizontalEdgeStateAtStart() {
        guard hasHorizontallyScrollableContent, let doc = documentView else {
            atLeftEdgeAtStart = true
            atRightEdgeAtStart = true
            return
        }
        let clipBounds = contentView.bounds
        atLeftEdgeAtStart = clipBounds.minX <= 1.0
        atRightEdgeAtStart = clipBounds.maxX >= doc.frame.width - 1.0
    }
}

// MARK: - 浏览器风格边缘滑动指示器（圆形箭头徽标）

final class SwipeIndicatorBadge: NSView {
    static let diameter: CGFloat = 40

    private let circleLayer = CAShapeLayer()
    private let arrowView = NSImageView()
    private var isBackDirection: Bool = true
    private var isArmedState: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        circleLayer.frame = NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        circleLayer.path = CGPath(ellipseIn: circleLayer.bounds, transform: nil)
        circleLayer.lineWidth = 1
        circleLayer.shadowColor = NSColor.black.cgColor
        circleLayer.shadowOpacity = 0.22
        circleLayer.shadowRadius = 6
        circleLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(circleLayer)

        arrowView.translatesAutoresizingMaskIntoConstraints = false
        arrowView.imageScaling = .scaleProportionallyDown
        arrowView.wantsLayer = true
        addSubview(arrowView)

        NSLayoutConstraint.activate([
            arrowView.centerXAnchor.constraint(equalTo: centerXAnchor),
            arrowView.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrowView.widthAnchor.constraint(equalToConstant: 18),
            arrowView.heightAnchor.constraint(equalToConstant: 18)
        ])

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(isBack: Bool, progress: CGFloat, isArmed: Bool) {
        let directionChanged = (isBackDirection != isBack)
        let armedChanged = (isArmedState != isArmed)
        isBackDirection = isBack
        isArmedState = isArmed

        if directionChanged || arrowView.image == nil {
            let symbolName = isBack ? "chevron.left" : "chevron.right"
            arrowView.image = Theme.symbol(symbolName, size: 14, weight: .bold)
        }

        if armedChanged || directionChanged {
            updateAppearance()
        }

        // 从小变大：从 0.35 开始平滑放大至 1.0，达标超额时提供弹性质感 (至 1.08)
        let clamped = min(1.0, max(0.0, progress))
        let ease = sin(clamped * .pi / 2)
        let scale: CGFloat
        if isArmed {
            scale = 1.0 + min(0.08, max(0.0, progress - 1.0) * 0.22)
        } else {
            scale = 0.35 + 0.65 * ease
        }

        let center = CGPoint(x: Self.diameter * 0.5, y: Self.diameter * 0.5)
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, center.x, center.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -center.x, -center.y, 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layer?.transform = t
        CATransaction.commit()
    }

    func resetScale(animated: Bool) {
        let center = CGPoint(x: Self.diameter * 0.5, y: Self.diameter * 0.5)
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, center.x, center.y, 0)
        t = CATransform3DScale(t, 0.35, 0.35, 1)
        t = CATransform3DTranslate(t, -center.x, -center.y, 0)

        if animated {
            let anim = CABasicAnimation(keyPath: "transform")
            anim.fromValue = self.layer?.transform
            anim.toValue = t
            anim.duration = 0.16
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.layer?.add(anim, forKey: "swipeResetScale")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layer?.transform = t
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isArmedState {
            circleLayer.fillColor = NSColor.controlAccentColor.cgColor
            circleLayer.strokeColor = NSColor.white.withAlphaComponent(0.25).cgColor
            arrowView.contentTintColor = .white
        } else {
            circleLayer.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
            circleLayer.strokeColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
            arrowView.contentTintColor = .labelColor
        }
        CATransaction.commit()
    }
}
