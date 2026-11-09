import AppKit
import QuartzCore

/// 居中极简搜索浮窗控制器：
/// - 屏幕/窗口正中弹出（Spotlight / Raycast 风格极简设计）
/// - 在搜索框按下回车（`↩`）立即触发搜索并展示动态进度条，**不会关闭搜索框**
/// - 树状图列表模式下，搜索到的层级结构与命中文件夹**自动展开为目录树**
/// - 支持 **树状图列表 (`FileListView`)**、**图标网格 (`FileIconView`)**、**分栏预览 (`SearchColumnBrowserView`)** 三种查看方式自由切换
final class SearchPanelController: NSObject {

    /// 选中某个结果并点击「在窗格中定位」时回调。
    var onPick: ((URL) -> Void)?
    /// 获取当前焦点窗格的目录（用于「当前文件夹」范围搜索）。
    var currentFolderProvider: (() -> URL)?
    /// 点击搜索栏上的权限/设置按钮或按 ⌘, 时打开设置窗口。
    var onOpenSettings: (() -> Void)?

    private let panel = CenteredSearchPanel(
        contentRect: NSRect(x: 0, y: 0, width: 840, height: 540),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )

    private let searchIconView = NSImageView()
    private let searchSpinner = NSProgressIndicator()
    private let searchField = MinimalSearchTextField()
    private let searchNowButton = NSButton()
    private let clearButton = NSButton()
    private let scopeControl = SearchScopePillControl()
    private let viewModeBar = ToolbarViewModeView()
    private let settingsButton = SquareToolbarButton()
    private let closeButton = SquareToolbarButton()

    /// 顶部动态搜索进度条（让用户直观感受到搜索过程与完成反馈）。
    private let progressBar = SearchProgressBar()

    /// 当在图标模式下双击进入某个子文件夹浏览时显示的返回条。
    private let drilldownBar = NSView()
    private let drilldownBackButton = NSButton()
    private let drilldownTitleLabel = NSTextField(labelWithString: "")
    private var drilldownHeightConstraint: NSLayoutConstraint!
    private var drilldownFolderStack: [URL] = []
    private var drilldownForwardStack: [URL] = []

    private let contentContainer = NSView()
    private let listView = FileListView()
    private let iconView = FileIconView()
    private let columnView = SearchColumnBrowserView()
    private let emptyStateLabel = NSTextField(labelWithString: "")

    private let statusDot = NSView()
    private let statsLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let openDirectButton = NSButton()
    private let locateInPaneButton = NSButton()
    private let sizeSlider = DisplaySizeSliderControl()

    private var hits: [FileSearchEngine.Hit] = []
    private var fileItems: [FileItem] = []
    private var isDisplayingSearchResults: Bool = false

    private var currentViewMode: ViewMode = .list {
        didSet {
            guard oldValue != currentViewMode else { return }
            applyViewMode()
        }
    }
    private var sortField: SortField = .modified
    private var sortAscending: Bool = false

    private var localKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var debounceTimer: Timer?
    private var progressFinishTimer: Timer?
    private weak var hostWindow: NSWindow?
    private var lastElapsedMs: Double = 0

    override init() {
        super.init()
        buildUI()
        wireViewCallbacks()
    }

    deinit {
        cancelMonitors()
        debounceTimer?.invalidate()
        progressFinishTimer?.invalidate()
    }

    // MARK: - 界面构建

    private func buildUI() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.minSize = NSSize(width: 680, height: 420)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.showsResizeIndicator = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

        let rootEffect = NSVisualEffectView()
        rootEffect.material = .popover
        rootEffect.blendingMode = .behindWindow
        rootEffect.state = .active
        rootEffect.maskImage = Theme.roundedCornerMask(radius: 12)
        rootEffect.wantsLayer = true
        rootEffect.layer?.cornerRadius = 12
        rootEffect.layer?.masksToBounds = true

        // 1. 顶部搜索栏
        let topBar = NSView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        rootEffect.addSubview(topBar)

        searchIconView.translatesAutoresizingMaskIntoConstraints = false
        searchIconView.image = Theme.symbol("magnifyingglass", size: 16, weight: .medium)
        searchIconView.contentTintColor = .secondaryLabelColor
        topBar.addSubview(searchIconView)

        searchSpinner.translatesAutoresizingMaskIntoConstraints = false
        searchSpinner.style = .spinning
        searchSpinner.controlSize = .small
        searchSpinner.isDisplayedWhenStopped = false
        topBar.addSubview(searchSpinner)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "输入文件名或关键字，按回车（↩）立即搜索…"
        searchField.font = .systemFont(ofSize: 15.5, weight: .regular)
        searchField.textColor = .labelColor
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.maximumNumberOfLines = 1
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true
        searchField.delegate = self
        topBar.addSubview(searchField)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.image = Theme.symbol("xmark.circle.fill", size: 13, weight: .regular)
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearSearchText)
        clearButton.toolTip = "清空搜索内容".localized
        clearButton.isHidden = true
        topBar.addSubview(clearButton)

        searchNowButton.translatesAutoresizingMaskIntoConstraints = false
        searchNowButton.title = "搜索".localized
        searchNowButton.bezelStyle = .inline
        searchNowButton.font = .systemFont(ofSize: 11.5, weight: .medium)
        searchNowButton.target = self
        searchNowButton.action = #selector(triggerExplicitSearch)
        searchNowButton.toolTip = "立即执行搜索（↩）".localized
        topBar.addSubview(searchNowButton)

        scopeControl.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchNowButton.setContentHuggingPriority(.required, for: .horizontal)
        searchNowButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        scopeControl.setContentHuggingPriority(.required, for: .horizontal)
        scopeControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        viewModeBar.setContentHuggingPriority(.required, for: .horizontal)
        viewModeBar.setContentCompressionResistancePriority(.required, for: .horizontal)
        scopeControl.onScopeChanged = { [weak self] _ in
            guard let self else { return }
            self.exitDrilldownIfNeeded(reloadSearch: false)
            self.updatePlaceholder()
            self.executeSearchWithVisualFeedback(term: self.searchField.stringValue, explicit: true)
        }
        topBar.addSubview(scopeControl)

        viewModeBar.translatesAutoresizingMaskIntoConstraints = false
        viewModeBar.setSelected(currentViewMode)
        viewModeBar.onPick = { [weak self] mode in
            self?.currentViewMode = mode
        }
        topBar.addSubview(viewModeBar)

        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.image = Theme.symbol("gearshape", size: 14)
        settingsButton.toolTip = "权限与搜索设置（⌘,）".localized
        settingsButton.target = self
        settingsButton.action = #selector(openSettingsClicked)
        topBar.addSubview(settingsButton)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = Theme.symbol("xmark", size: 12, weight: .semibold)
        closeButton.toolTip = "关闭搜索窗（Esc）".localized
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        topBar.addSubview(closeButton)

        let topDivider = Theme.hairlineView()
        rootEffect.addSubview(topDivider)

        // 顶部动态进度条（覆盖在分割线位置，搜索时高亮流动）
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        rootEffect.addSubview(progressBar)

        // 2. 子文件夹深入浏览导航条（在搜索框内双击进入某文件夹时出现）
        drilldownBar.translatesAutoresizingMaskIntoConstraints = false
        drilldownBar.wantsLayer = true
        drilldownBar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        drilldownBar.isHidden = true
        rootEffect.addSubview(drilldownBar)

        drilldownBackButton.translatesAutoresizingMaskIntoConstraints = false
        drilldownBackButton.title = "← 返回搜索结果"
        drilldownBackButton.bezelStyle = .inline
        drilldownBackButton.font = .systemFont(ofSize: 11.5, weight: .medium)
        drilldownBackButton.target = self
        drilldownBackButton.action = #selector(popDrilldownFolder)
        drilldownBar.addSubview(drilldownBackButton)

        drilldownTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        drilldownTitleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        drilldownTitleLabel.textColor = .secondaryLabelColor
        drilldownTitleLabel.lineBreakMode = .byTruncatingMiddle
        drilldownBar.addSubview(drilldownTitleLabel)

        drilldownHeightConstraint = drilldownBar.heightAnchor.constraint(equalToConstant: 0)

        // 3. 中部多视图容器（树状列表 / 图标网格 / 分栏预览）
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        rootEffect.addSubview(contentContainer)

        listView.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        columnView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isPaneActive = true

        contentContainer.addSubview(listView)
        contentContainer.addSubview(iconView)
        contentContainer.addSubview(columnView)

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.font = .systemFont(ofSize: 13, weight: .regular)
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.isHidden = true
        contentContainer.addSubview(emptyStateLabel)

        for v in [listView, iconView, columnView] {
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor)
            ])
        }

        // 4. 底部状态与明确操作按钮栏
        let bottomDivider = Theme.hairlineView()
        rootEffect.addSubview(bottomDivider)

        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        rootEffect.addSubview(bottomBar)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        bottomBar.addSubview(statusDot)

        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        statsLabel.textColor = .labelColor
        statsLabel.setContentHuggingPriority(.required, for: .horizontal)
        bottomBar.addSubview(statsLabel)

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bottomBar.addSubview(pathLabel)

        openDirectButton.translatesAutoresizingMaskIntoConstraints = false
        openDirectButton.title = "直接打开".localized
        openDirectButton.bezelStyle = .rounded
        openDirectButton.controlSize = .small
        openDirectButton.font = .systemFont(ofSize: 11.5)
        openDirectButton.target = self
        openDirectButton.action = #selector(openSelectedDirectly)
        openDirectButton.toolTip = "直接打开选中的文件或文件夹（⌘↩）".localized
        bottomBar.addSubview(openDirectButton)

        locateInPaneButton.translatesAutoresizingMaskIntoConstraints = false
        locateInPaneButton.title = "在窗格中定位".localized
        locateInPaneButton.bezelStyle = .rounded
        locateInPaneButton.controlSize = .small
        locateInPaneButton.font = .systemFont(ofSize: 11.5, weight: .medium)
        locateInPaneButton.contentTintColor = .controlAccentColor
        locateInPaneButton.target = self
        locateInPaneButton.action = #selector(locateSelectedInMainPane)
        locateInPaneButton.toolTip = "在主窗口当前窗格中打开并高亮定位该项".localized
        bottomBar.addSubview(locateInPaneButton)

        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.onSizeChanged = { [weak self] mode, value in
            guard let self else { return }
            switch mode {
            case .icons:
                AppSettings.gridIconSize = CGFloat(value)
                self.iconView.applyIconSize(CGFloat(value))
            case .list:
                AppSettings.listIconSize = CGFloat(value)
                AppSettings.listRowHeight = max(20, CGFloat(value) + 6)
                self.listView.applyListSize(iconSize: CGFloat(value))
            case .columns:
                AppSettings.browserColumnWidth = CGFloat(value)
                self.columnView.applyColumnWidth(CGFloat(value))
            }
        }
        bottomBar.addSubview(sizeSlider)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: rootEffect.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: rootEffect.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: rootEffect.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52),

            searchIconView.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            searchIconView.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            searchIconView.widthAnchor.constraint(equalToConstant: 18),
            searchIconView.heightAnchor.constraint(equalToConstant: 18),

            searchSpinner.centerXAnchor.constraint(equalTo: searchIconView.centerXAnchor),
            searchSpinner.centerYAnchor.constraint(equalTo: searchIconView.centerYAnchor),

            searchField.leadingAnchor.constraint(equalTo: searchIconView.trailingAnchor, constant: 10),
            searchField.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -6),

            clearButton.trailingAnchor.constraint(equalTo: searchNowButton.leadingAnchor, constant: -6),
            clearButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 18),
            clearButton.heightAnchor.constraint(equalToConstant: 18),

            searchNowButton.trailingAnchor.constraint(equalTo: scopeControl.leadingAnchor, constant: -8),
            searchNowButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            scopeControl.trailingAnchor.constraint(equalTo: viewModeBar.leadingAnchor, constant: -8),
            scopeControl.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            scopeControl.heightAnchor.constraint(equalToConstant: 24),

            viewModeBar.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -6),
            viewModeBar.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            viewModeBar.heightAnchor.constraint(equalToConstant: 28),

            settingsButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            settingsButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            topDivider.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: rootEffect.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: rootEffect.trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),

            progressBar.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -1),
            progressBar.leadingAnchor.constraint(equalTo: rootEffect.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: rootEffect.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2.5),

            drilldownBar.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            drilldownBar.leadingAnchor.constraint(equalTo: rootEffect.leadingAnchor),
            drilldownBar.trailingAnchor.constraint(equalTo: rootEffect.trailingAnchor),
            drilldownHeightConstraint,

            drilldownBackButton.leadingAnchor.constraint(equalTo: drilldownBar.leadingAnchor, constant: 12),
            drilldownBackButton.centerYAnchor.constraint(equalTo: drilldownBar.centerYAnchor),

            drilldownTitleLabel.leadingAnchor.constraint(equalTo: drilldownBackButton.trailingAnchor, constant: 10),
            drilldownTitleLabel.centerYAnchor.constraint(equalTo: drilldownBar.centerYAnchor),
            drilldownTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: drilldownBar.trailingAnchor, constant: -12),

            contentContainer.topAnchor.constraint(equalTo: drilldownBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: rootEffect.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: rootEffect.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),

            bottomDivider.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomDivider.leadingAnchor.constraint(equalTo: rootEffect.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: rootEffect.trailingAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1),

            bottomBar.leadingAnchor.constraint(equalTo: rootEffect.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: rootEffect.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: rootEffect.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 36),

            statusDot.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 14),
            statusDot.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),

            statsLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 7),
            statsLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            pathLabel.leadingAnchor.constraint(equalTo: statsLabel.trailingAnchor, constant: 10),
            pathLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: openDirectButton.leadingAnchor, constant: -10),

            openDirectButton.trailingAnchor.constraint(equalTo: locateInPaneButton.leadingAnchor, constant: -8),
            openDirectButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            locateInPaneButton.trailingAnchor.constraint(equalTo: sizeSlider.leadingAnchor, constant: -12),
            locateInPaneButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            sizeSlider.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -14),
            sizeSlider.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor)
        ])

        panel.contentView = rootEffect
        applyViewMode()
    }

    private func wireViewCallbacks() {
        // 1. 树状列表视图回调：双击文件夹就地浏览/定位，双击文件定位
        listView.onOpen = { [weak self] item in self?.handleItemDoubleClick(item, inViewMode: .list) }
        listView.onSelectionChange = { [weak self] _ in self?.syncSelectedPathLabel() }
        listView.onSortChange = { [weak self] field in self?.toggleSort(field) }
        listView.keyHandler = { [weak self] event in self?.handleResultViewKey(event) ?? false }
        listView.menuProvider = { [weak self] item in self?.makeResultContextMenu(for: item) }
        listView.canSwipeBack = { [weak self] in !(self?.drilldownFolderStack.isEmpty ?? true) }
        listView.canSwipeForward = { [weak self] in !(self?.drilldownForwardStack.isEmpty ?? true) }
        listView.onSwipeBack = { [weak self] in self?.popDrilldownFolder() }
        listView.onSwipeForward = { [weak self] in self?.forwardDrilldownFolder() }

        // 2. 图标网格视图回调：双击文件夹直接在搜索窗内进入该文件夹（支持触摸板左右滑动返回搜索结果！）
        iconView.onOpen = { [weak self] item in self?.handleItemDoubleClick(item, inViewMode: .icons) }
        iconView.onSelectionChange = { [weak self] _ in self?.syncSelectedPathLabel() }
        iconView.keyHandler = { [weak self] event in self?.handleResultViewKey(event) ?? false }
        iconView.menuProvider = { [weak self] item in self?.makeResultContextMenu(for: item) }
        iconView.canSwipeBack = { [weak self] in !(self?.drilldownFolderStack.isEmpty ?? true) }
        iconView.canSwipeForward = { [weak self] in !(self?.drilldownForwardStack.isEmpty ?? true) }
        iconView.onSwipeBack = { [weak self] in self?.popDrilldownFolder() }
        iconView.onSwipeForward = { [weak self] in self?.forwardDrilldownFolder() }

        // 3. 分栏预览视图回调
        columnView.onOpen = { [weak self] item in self?.handleItemDoubleClick(item, inViewMode: .columns) }
        columnView.onSelectionChange = { [weak self] _ in self?.syncSelectedPathLabel() }
        columnView.keyHandler = { [weak self] event in self?.handleResultViewKey(event) ?? false }
        columnView.menuProvider = { [weak self] item in self?.makeResultContextMenu(for: item) }
    }

    // MARK: - 弹出与收起

    func show(anchoredTo anchor: NSView? = nil, in window: NSWindow) {
        hostWindow = window
        FileSearchEngine.shared.loadIndex()
        scopeControl.invalidateIntrinsicContentSize()
        scopeControl.needsDisplay = true
        updatePlaceholder()

        let winFrame = window.frame
        let screenVisible = (window.screen ?? NSScreen.main)?.visibleFrame ?? winFrame
        let size = panel.frame.size

        var x = winFrame.midX - size.width / 2
        var y = winFrame.midY - size.height / 2 + 20
        x = min(max(x, screenVisible.minX + 16), max(screenVisible.minX + 16, screenVisible.maxX - size.width - 16))
        y = min(max(y, screenVisible.minY + 16), max(screenVisible.minY + 16, screenVisible.maxY - size.height - 16))

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        installMonitors()

        // 保留上次关闭前的搜索状态（关键字、结果列表、视图模式、钻取层级与选中项）；
        // 仅当从未搜索且无内容时展示初始空白提示。
        let trimmed = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && hits.isEmpty && drilldownFolderStack.isEmpty {
            executeSearchWithVisualFeedback(term: "", explicit: false)
        } else {
            syncSelectedPathLabel()
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// 设置搜索范围（全局「此 Mac」还是「当前文件夹」）
    func setScope(isCurrentFolder: Bool) {
        scopeControl.setScope(isCurrentFolder: isCurrentFolder)
        updatePlaceholder()
        if isVisible {
            let trimmed = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                executeSearchWithVisualFeedback(term: trimmed, explicit: true)
            }
        }
    }

    @objc private func closeClicked() {
        close()
    }

    func close() {
        cancelMonitors()
        debounceTimer?.invalidate()
        debounceTimer = nil
        progressFinishTimer?.invalidate()
        progressFinishTimer = nil
        FileSearchEngine.shared.cancel()
        panel.orderOut(nil)
        hostWindow?.makeKey()
    }

    private func installMonitors() {
        cancelMonitors()
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel { return event }
            if let winClass = event.window.map({ NSStringFromClass(type(of: $0)) }),
               winClass.contains("Menu") || winClass.contains("Carbon") {
                return event
            }
            // 点击主窗口外部区域时收起搜索浮窗
            if event.window === self.hostWindow {
                self.close()
            }
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if self.interceptGlobalShortcut(event) { return nil }
            return event
        }
    }

    private func cancelMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 视图模式切换与树级自动展开

    private func applyViewMode() {
        viewModeBar.setSelected(currentViewMode)
        listView.isHidden = (currentViewMode != .list)
        iconView.isHidden = (currentViewMode != .icons)
        columnView.isHidden = (currentViewMode != .columns)
        sizeSlider.configure(for: currentViewMode)
        refreshActiveViewData(preserveSelection: true)
    }

    private func toggleSort(_ field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = (field == .name)
        }
        listView.sortField = sortField
        listView.ascending = sortAscending

        let sorted = FileOrganizer.sections(items: fileItems,
                                            sort: sortField,
                                            ascending: sortAscending,
                                            group: .none)
        fileItems = sorted.first?.items ?? fileItems
        refreshActiveViewData(preserveSelection: true)
    }

    private func refreshActiveViewData(preserveSelection: Bool) {
        let previousURL = currentSelectedItem()?.url

        let section = FileSection(title: "", rank: 0, items: fileItems)

        // 树状列表模式：纯粹展示当前搜索命中的条目，不显示父级别，且全部初始保持折叠（不展开），用户点击三角可手动展开
        if currentViewMode == .list {
            if isDisplayingSearchResults && drilldownFolderStack.isEmpty {
                listView.updateWithSearchResults(fileItems)
            } else {
                listView.update(sections: [section])
            }
        }

        iconView.update(sections: [section])
        columnView.updateSearchHits(fileItems)

        if let prev = previousURL, preserveSelection {
            selectURL(prev)
        } else if let first = fileItems.first {
            selectURL(first.url)
        }
        syncSelectedPathLabel()
    }

    private func selectURL(_ url: URL) {
        let set: Set<URL> = [url]
        listView.select(urls: set)
        iconView.select(urls: set)
        columnView.select(url: url)
    }

    private func currentSelectedItem() -> FileItem? {
        switch currentViewMode {
        case .list:
            return listView.selectedItems.first ?? fileItems.first
        case .icons:
            return iconView.selectedItems.first ?? fileItems.first
        case .columns:
            return columnView.selectedItem ?? fileItems.first
        }
    }

    private func syncSelectedPathLabel() {
        let item = currentSelectedItem()
        openDirectButton.isEnabled = (item != nil)
        locateInPaneButton.isEnabled = (item != nil)

        guard let item else {
            pathLabel.stringValue = ""
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var displayPath = item.url.path
        if displayPath.hasPrefix(home) {
            displayPath = "~" + displayPath.dropFirst(home.count)
        }
        pathLabel.stringValue = displayPath
    }

    // MARK: - 搜索窗内双击文件夹钻取浏览（不乱关窗口）

    private func handleItemDoubleClick(_ item: FileItem, inViewMode mode: ViewMode) {
        if item.isNavigable {
            // 双击文件夹：在搜索框内部直接进入该文件夹查看内容，顶部显示「← 返回搜索结果」（也可右滑回退）
            enterDrilldownFolder(item.url)
        } else {
            // 双击文件：定位到主窗口窗格并高亮该文件
            pickURL(item.url)
        }
    }

    private func enterDrilldownFolder(_ folderURL: URL, clearForward: Bool = true) {
        if clearForward {
            drilldownForwardStack.removeAll()
        }
        drilldownFolderStack.append(folderURL)
        drilldownBar.isHidden = false
        drilldownHeightConstraint.constant = 30
        drilldownBackButton.title = drilldownFolderStack.count > 1 ? "← 返回上一级" : "← 返回搜索结果"
        drilldownTitleLabel.stringValue = "当前浏览：\(folderURL.path)"

        let subItems = FileItem.contents(of: folderURL, showHidden: AppSettings.showHidden)
        fileItems = subItems
        emptyStateLabel.isHidden = !subItems.isEmpty
        emptyStateLabel.stringValue = "此文件夹为空"
        refreshActiveViewData(preserveSelection: false)
    }

    @objc private func popDrilldownFolder() {
        guard let departing = drilldownFolderStack.popLast() else {
            exitDrilldownIfNeeded(reloadSearch: true)
            return
        }
        drilldownForwardStack.append(departing)

        if let parentFolder = drilldownFolderStack.last {
            drilldownBackButton.title = drilldownFolderStack.count > 1 ? "← 返回上一级" : "← 返回搜索结果"
            drilldownTitleLabel.stringValue = "当前浏览：\(parentFolder.path)"
            let subItems = FileItem.contents(of: parentFolder, showHidden: AppSettings.showHidden)
            fileItems = subItems
            emptyStateLabel.isHidden = !subItems.isEmpty
            refreshActiveViewData(preserveSelection: false)
            selectURL(departing)
        } else {
            // 已经退回到顶层搜索结果：收起导航条并还原搜索命中列表
            drilldownBar.isHidden = true
            drilldownHeightConstraint.constant = 0
            fileItems = hits.map { $0.toFileItem() }
            emptyStateLabel.isHidden = !fileItems.isEmpty
            refreshActiveViewData(preserveSelection: false)
            selectURL(departing)
        }
    }

    private func forwardDrilldownFolder() {
        guard let next = drilldownForwardStack.popLast() else { return }
        enterDrilldownFolder(next, clearForward: false)
    }

    private func exitDrilldownIfNeeded(reloadSearch: Bool) {
        let wasInDrilldown = !drilldownFolderStack.isEmpty || !drilldownBar.isHidden
        drilldownFolderStack.removeAll()
        drilldownForwardStack.removeAll()
        drilldownBar.isHidden = true
        drilldownHeightConstraint.constant = 0
        if wasInDrilldown && reloadSearch {
            fileItems = hits.map { $0.toFileItem() }
            emptyStateLabel.isHidden = !fileItems.isEmpty
            refreshActiveViewData(preserveSelection: true)
        }
    }

    // MARK: - 搜索调度与动态进度反馈

    private func updatePlaceholder() {
        if scopeControl.isCurrentFolder {
            let folderName = currentFolderProvider?().lastPathComponent ?? "当前文件夹"
            searchField.placeholderString = "在「\(folderName)」中搜索（按 ↩ 立即搜索）…"
        } else {
            searchField.placeholderString = "搜索此 Mac 的文件、文件夹或应用（按 ↩ 立即搜索）…"
        }
    }

    @objc private func clearSearchText() {
        searchField.stringValue = ""
        clearButton.isHidden = true
        exitDrilldownIfNeeded(reloadSearch: false)
        panel.makeFirstResponder(searchField)
        executeSearchWithVisualFeedback(term: "", explicit: false)
    }

    @objc private func triggerExplicitSearch() {
        exitDrilldownIfNeeded(reloadSearch: false)
        executeSearchWithVisualFeedback(term: searchField.stringValue, explicit: true)
    }

    private func scheduleSearch() {
        let text = searchField.stringValue
        clearButton.isHidden = text.isEmpty
        exitDrilldownIfNeeded(reloadSearch: false)

        debounceTimer?.invalidate()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            beginSearchVisualProgress(query: trimmed)
        }

        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.executeSearchWithVisualFeedback(term: self.searchField.stringValue, explicit: false)
        }
    }

    private func beginSearchVisualProgress(query: String) {
        progressFinishTimer?.invalidate()
        searchIconView.isHidden = true
        searchSpinner.startAnimation(nil)
        progressBar.startProgress()
        statusDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        statsLabel.textColor = .controlAccentColor
        statsLabel.stringValue = "正在搜索「\(query)」…"
    }

    private func finishSearchVisualProgress(count: Int, elapsedMs: Double, query: String, isFinal: Bool) {
        let timeStr = String(format: "%.1f ms", max(0.2, elapsedMs))
        if !isFinal {
            progressBar.setProgress(0.72)
            statsLabel.stringValue = "正在深度检索… 已找到 \(count) 项"
            return
        }

        // 确保用户肉眼能清晰看到进度条推进到 100% 与完成状态切换
        progressBar.completeProgress()
        progressFinishTimer?.invalidate()
        progressFinishTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.searchSpinner.stopAnimation(nil)
            self.searchIconView.isHidden = false
            self.searchIconView.contentTintColor = query.isEmpty ? .secondaryLabelColor : .controlAccentColor

            if count == 0 {
                self.statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
                self.statsLabel.textColor = .secondaryLabelColor
                self.statsLabel.stringValue = "未找到「\(query)」· \(timeStr)"
            } else {
                self.statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
                self.statsLabel.textColor = .labelColor
                let suffix = count >= 350 ? "+" : ""
                self.statsLabel.stringValue = "找到 \(count)\(suffix) 项 · \(timeStr)"
            }
        }
    }

    private func executeSearchWithVisualFeedback(term: String, explicit: Bool) {
        debounceTimer?.invalidate()
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        clearButton.isHidden = term.isEmpty

        guard !trimmed.isEmpty else {
            FileSearchEngine.shared.cancel()
            progressFinishTimer?.invalidate()
            searchSpinner.stopAnimation(nil)
            searchIconView.isHidden = false
            searchIconView.contentTintColor = .secondaryLabelColor
            progressBar.reset()

            isDisplayingSearchResults = false
            self.hits = []
            self.fileItems = []
            self.emptyStateLabel.isHidden = false
            self.emptyStateLabel.stringValue = "输入文件名或关键字开始搜索（按 ↩ 立即搜索）"
            self.statusDot.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
            self.statsLabel.textColor = .secondaryLabelColor
            self.statsLabel.stringValue = "准备就绪 · 支持列表 / 图标 / 分栏查看方式"
            self.refreshActiveViewData(preserveSelection: false)
            return
        }

        isDisplayingSearchResults = true
        beginSearchVisualProgress(query: trimmed)

        let scope: FileSearchEngine.Scope
        if scopeControl.isCurrentFolder, let folder = currentFolderProvider?() {
            scope = .folder(folder)
        } else {
            scope = .everywhere
        }

        FileSearchEngine.shared.search(term: trimmed, scope: scope, limit: 350) { [weak self] results, elapsedMs, isFinal in
            guard let self else { return }
            self.hits = results
            self.fileItems = results.map { $0.toFileItem() }
            self.lastElapsedMs = elapsedMs

            if results.isEmpty {
                if isFinal {
                    self.emptyStateLabel.stringValue = "没有找到与「\(trimmed)」匹配的项目"
                    self.emptyStateLabel.isHidden = false
                } else {
                    self.emptyStateLabel.isHidden = true
                }
            } else {
                self.emptyStateLabel.isHidden = true
            }

            self.finishSearchVisualProgress(count: results.count,
                                            elapsedMs: elapsedMs,
                                            query: trimmed,
                                            isFinal: isFinal)
            self.refreshActiveViewData(preserveSelection: !isFinal && !explicit)

            // 如果用户显式按了回车搜索，给结果容器加一个轻盈的刷新呼吸动效
            if explicit && isFinal {
                self.animateResultPulse()
            }
        }
    }

    private func animateResultPulse() {
        contentContainer.wantsLayer = true
        guard let layer = contentContainer.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.65
        fade.toValue = 1.0
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "searchResultPulse")
    }

    // MARK: - 键盘快捷键与动作

    private func interceptGlobalShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if flags == .command {
            switch chars {
            case "q":
                NSApp.terminate(nil)
                return true
            case "1":
                currentViewMode = .list
                return true
            case "2":
                currentViewMode = .icons
                return true
            case "3":
                currentViewMode = .columns
                return true
            case "f":
                panel.makeFirstResponder(searchField)
                searchField.selectText(nil)
                return true
            case ",":
                openSettingsClicked()
                return true
            default:
                switch event.keyCode {
                case 18:
                    currentViewMode = .list
                    return true
                case 19:
                    currentViewMode = .icons
                    return true
                case 20:
                    currentViewMode = .columns
                    return true
                case 36, 76: // ⌘Return：在主窗格定位或直接打开
                    locateSelectedInMainPane()
                    return true
                default:
                    break
                }
            }
        }
        return false
    }

    private func handleResultViewKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc
            if !drilldownFolderStack.isEmpty {
                popDrilldownFolder()
            } else {
                close()
            }
            return true
        case 36, 76: // 在结果视图里按 Return：定位到主窗格
            if event.modifierFlags.contains(.command) {
                openSelectedDirectly()
            } else {
                locateSelectedInMainPane()
            }
            return true
        case 48: // Tab 切换「此 Mac / 当前文件夹」
            scopeControl.toggleScope()
            return true
        default:
            return false
        }
    }

    private func moveSelectionInActiveView(by delta: Int) {
        switch currentViewMode {
        case .list:
            listView.moveSelection(by: delta)
        case .icons:
            iconView.moveSelection(by: delta)
        case .columns:
            columnView.moveSelection(by: delta)
        }
        syncSelectedPathLabel()
    }

    @objc private func locateSelectedInMainPane() {
        guard let item = currentSelectedItem() else { return }
        pickURL(item.url)
    }

    @objc private func openSelectedDirectly() {
        guard let item = currentSelectedItem() else { return }
        if item.isNavigable {
            enterDrilldownFolder(item.url)
        } else {
            let url = item.url
            close()
            NSWorkspace.shared.open(url)
        }
    }

    private func pickURL(_ url: URL) {
        let callback = onPick
        close()
        callback?(url)
    }

    @objc private func openSettingsClicked() {
        let callback = onOpenSettings
        close()
        callback?()
    }

    // MARK: - 右键上下文菜单

    private func makeResultContextMenu(for clickedItem: FileItem?) -> NSMenu? {
        guard let target = clickedItem ?? currentSelectedItem() else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let revealInPane = NSMenuItem(title: "在主窗口当前窗格中定位".localized, action: #selector(ctxRevealInPane(_:)), keyEquivalent: "")
        revealInPane.target = self
        revealInPane.representedObject = target.url
        menu.addItem(revealInPane)

        let openOtherPane = NSMenuItem(title: "在新窗格中打开".localized, action: #selector(ctxOpenInOtherPane(_:)), keyEquivalent: "")
        openOtherPane.target = self
        openOtherPane.representedObject = target.url
        menu.addItem(openOtherPane)

        let openDirect = NSMenuItem(title: "直接打开".localized, action: #selector(ctxOpenDirectly(_:)), keyEquivalent: "")
        openDirect.target = self
        openDirect.representedObject = target.url
        menu.addItem(openDirect)

        menu.addItem(.separator())

        let revealFinder = NSMenuItem(title: "在访达中显示".localized, action: #selector(ctxRevealInFinder(_:)), keyEquivalent: "")
        revealFinder.target = self
        revealFinder.representedObject = target.url
        menu.addItem(revealFinder)

        let copyPath = NSMenuItem(title: "拷贝路径".localized, action: #selector(ctxCopyPath(_:)), keyEquivalent: "")
        copyPath.target = self
        copyPath.representedObject = target.url
        menu.addItem(copyPath)

        menu.addItem(.separator())

        let trashItem = NSMenuItem(title: "移到废纸篓".localized, action: #selector(ctxTrashItem(_:)), keyEquivalent: "")
        trashItem.target = self
        trashItem.representedObject = target.url
        menu.addItem(trashItem)

        return menu
    }

    @objc private func ctxTrashItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        FileOperations.playTrashSound()
        var resulting: NSURL?
        try? FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
        triggerExplicitSearch()
    }

    @objc private func ctxRevealInPane(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        pickURL(url)
    }

    @objc private func ctxOpenInOtherPane(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        close()
        NotificationCenter.default.post(name: .openInOtherPane, object: url)
    }

    @objc private func ctxOpenDirectly(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        close()
        NSWorkspace.shared.open(url)
    }

    @objc private func ctxRevealInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        close()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func ctxCopyPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}

// MARK: - 搜索输入框代理（回车触发搜索并保持窗口不收起！）

extension SearchPanelController: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !drilldownFolderStack.isEmpty {
                popDrilldownFolder()
            } else if !searchField.stringValue.isEmpty {
                clearSearchText()
            } else {
                close()
            }
            return true
        }
        // 在搜索框内按下回车（↩）：立即执行搜索并展示进度条，绝不关闭搜索窗口！
        // 若按住 ⌘ + 回车（⌘↩）：直接将当前选中的结果定位到主窗口窗格
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                locateSelectedInMainPane()
            } else {
                triggerExplicitSearch()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveSelectionInActiveView(by: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveSelectionInActiveView(by: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            scopeControl.toggleScope()
            return true
        }
        return false
    }
}

// MARK: - 搜索进度条

private final class SearchProgressBar: NSView {

    private let fillLayer = CALayer()
    private var fraction: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        fillLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        fillLayer.cornerRadius = 1.25
        fillLayer.opacity = 0
        layer?.addSublayer(fillLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        CATransaction.commit()
    }

    func startProgress() {
        fraction = 0.45
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        fillLayer.opacity = 1.0
        fillLayer.frame = NSRect(x: 0, y: 0, width: max(60, bounds.width * 0.45), height: bounds.height)
        CATransaction.commit()
    }

    func setProgress(_ value: CGFloat) {
        fraction = min(max(0, value), 1)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        fillLayer.opacity = 1.0
        fillLayer.frame = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        CATransaction.commit()
    }

    func completeProgress() {
        fraction = 1.0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        fillLayer.opacity = 1.0
        fillLayer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.fraction >= 0.99 else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.28)
            self.fillLayer.opacity = 0.0
            CATransaction.commit()
        }
    }

    func reset() {
        fraction = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.opacity = 0
        fillLayer.frame = NSRect(x: 0, y: 0, width: 0, height: bounds.height)
        CATransaction.commit()
    }
}

// MARK: - 搜索范围切换控件

private final class SearchScopePillControl: NSView {

    var onScopeChanged: ((Bool) -> Void)?
    private(set) var isCurrentFolder: Bool = false {
        didSet {
            guard oldValue != isCurrentFolder else { return }
            needsDisplay = true
            onScopeChanged?(isCurrentFolder)
        }
    }

    private var titles: [String] {
        ["此 Mac".localized, "当前文件夹".localized]
    }

    private let horizontalPadding: CGFloat = 11
    private let inset: CGFloat = 2

    private func segmentNaturalWidths() -> [CGFloat] {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        return titles.map { title in
            let textWidth = ceil(NSAttributedString(string: title, attributes: [.font: font]).size().width)
            return textWidth + horizontalPadding * 2
        }
    }

    override var intrinsicContentSize: NSSize {
        let total = segmentNaturalWidths().reduce(0, +) + inset * 2
        return NSSize(width: total, height: 24)
    }

    func toggleScope() {
        isCurrentFolder.toggle()
    }

    func setScope(isCurrentFolder: Bool) {
        guard self.isCurrentFolder != isCurrentFolder else { return }
        self.isCurrentFolder = isCurrentFolder
    }

    /// 精准计算每个 segment 在当前 bounds 下的 CGRect（两端边距绝对对称等于 inset=2pt）
    private func segmentRects() -> [NSRect] {
        let innerRect = bounds.insetBy(dx: inset, dy: inset)
        guard innerRect.width > 0, innerRect.height > 0 else { return [] }

        let measured = segmentNaturalWidths()
        let totalMeasured = max(1, measured.reduce(0, +))

        var rects: [NSRect] = []
        var curX = innerRect.minX
        for (i, w) in measured.enumerated() {
            let segW: CGFloat
            if i == measured.count - 1 {
                // 最后一个 segment 精准吃满剩余宽度，确保右边缘与 bounds 边框距离严格为 2pt
                segW = max(0, innerRect.maxX - curX)
            } else {
                let ratio = w / totalMeasured
                segW = floor(innerRect.width * ratio)
            }
            rects.append(NSRect(x: curX, y: innerRect.minY, width: segW, height: innerRect.height))
            curX += segW
        }
        return rects
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let rects = segmentRects()
        if rects.count >= 2 {
            if rects[0].contains(p) {
                isCurrentFolder = false
            } else if rects[1].contains(p) {
                isCurrentFolder = true
            } else {
                isCurrentFolder = (p.x >= rects[0].maxX)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // 1. 外部胶囊底色
        let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        bgPath.fill()

        let rects = segmentRects()
        guard rects.count == titles.count else { return }

        // 2. 选中项胶囊高亮（完美贴合当前 segment，左右上下间距均为严格的 inset=2pt）
        let activeIndex = isCurrentFolder ? 1 : 0
        let activeRect = rects[activeIndex]
        let pillPath = NSBezierPath(roundedRect: activeRect, xRadius: 5, yRadius: 5)
        NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
        pillPath.fill()

        // 3. 绘制文字（精准居中）
        for (i, title) in titles.enumerated() {
            let segRect = rects[i]
            let isSelected = (i == activeIndex)
            let font = NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular)
            let color: NSColor = isSelected ? .controlAccentColor : .secondaryLabelColor
            let attr = NSAttributedString(string: title, attributes: [
                .font: font,
                .foregroundColor: color
            ])
            let size = attr.size()
            let drawRect = NSRect(
                x: segRect.minX + (segRect.width - size.width) / 2,
                y: segRect.minY + (segRect.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            attr.draw(in: drawRect)
        }
    }
}

// MARK: - 搜索分栏浏览器（第 0 列为搜索结果，点文件夹向右展开子目录列，点文件展示右侧访达详情预览列）

final class SearchColumnBrowserView: NSView {

    var onOpen: ((FileItem) -> Void)?
    var onSelectionChange: ((Set<URL>) -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((FileItem?) -> NSMenu?)?

    private let scroll = NSScrollView()
    private let board = SearchColumnBoard()
    private let hitsColumn = SearchHitsListColumn()
    private let hitsDivider = ColumnDividerView()
    private var subColumns: [BrowserColumn] = []
    private var dividers: [ColumnDividerView] = []
    private let preview = FilePreviewColumn()
    private let previewDivider = ColumnDividerView()

    private(set) var selectedItem: FileItem?
    private var dragStartHitsWidth: CGFloat = 270
    private var dragStartColumnWidth: CGFloat = 0
    private var dragStartPreviewWidth: CGFloat = 230

    func applyColumnWidth(_ width: CGFloat) {
        let clamped = min(max(width, 160), 650)
        hitsColumn.columnWidth = clamped
        for col in subColumns { col.columnWidth = clamped }
        preview.columnWidth = clamped
        tileColumns()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.documentView = board
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        hitsColumn.horizontalScrollTarget = scroll
        hitsColumn.onSelect = { [weak self] item in
            self?.handleSelectInHitsColumn(item)
        }
        hitsColumn.onOpen = { [weak self] item in
            self?.onOpen?(item)
        }
        hitsColumn.keyHandler = { [weak self] event in
            self?.handleColumnKey(event, columnIndex: -1) ?? false
        }
        hitsColumn.menuProvider = { [weak self] item in
            self?.menuProvider?(item)
        }
        board.addSubview(hitsColumn)

        hitsDivider.onDragBegan = { [weak self] in
            guard let self else { return }
            self.dragStartHitsWidth = self.hitsColumn.columnWidth
        }
        hitsDivider.onDrag = { [weak self] delta, isOption in
            guard let self else { return }
            let newW = min(max(self.dragStartHitsWidth + delta, 160), 650)
            self.hitsColumn.columnWidth = newW
            if isOption {
                for col in self.subColumns { col.columnWidth = newW }
            }
            self.tileColumns()
        }
        hitsDivider.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.hitsColumn.autoSizeColumn()
            self.tileColumns()
        }
        board.addSubview(hitsDivider)

        preview.isHidden = true
        board.addSubview(preview)

        previewDivider.isHidden = true
        previewDivider.isPreview = true
        previewDivider.onDragBegan = { [weak self] in
            guard let self else { return }
            self.dragStartPreviewWidth = self.preview.columnWidth
        }
        previewDivider.onDrag = { [weak self] delta, _ in
            guard let self else { return }
            let newW = min(max(self.dragStartPreviewWidth + delta, 160), 650)
            self.preview.columnWidth = newW
            self.tileColumns()
        }
        previewDivider.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.preview.columnWidth = 230
            self.tileColumns()
        }
        board.addSubview(previewDivider)
    }

    override func layout() {
        super.layout()
        tileColumns()
    }

    func updateSearchHits(_ items: [FileItem]) {
        removeSubColumns(from: 0)
        hitsColumn.update(items: items)
        if let first = items.first {
            hitsColumn.select(url: first.url)
            handleSelectInHitsColumn(first)
        } else {
            selectedItem = nil
            preview.isHidden = true
            previewDivider.isHidden = true
            tileColumns()
        }
    }

    func select(url: URL) {
        if hitsColumn.select(url: url), let item = hitsColumn.selectedItem {
            handleSelectInHitsColumn(item)
        }
    }

    func moveSelection(by delta: Int) {
        hitsColumn.moveSelection(by: delta)
    }

    private func handleSelectInHitsColumn(_ item: FileItem?) {
        removeSubColumns(from: 0)
        let selected = hitsColumn.selectedItems
        selectedItem = selected.last ?? item
        if selected.count > 1 {
            preview.isHidden = true
            previewDivider.isHidden = true
            onSelectionChange?(Set(selected.map { $0.url }))
            tileColumns()
            return
        }
        if let item {
            if item.isNavigable {
                preview.isHidden = true
                previewDivider.isHidden = true
                appendSubColumn(for: item.url)
            } else {
                preview.configure(with: item)
                preview.isHidden = false
                previewDivider.isHidden = false
            }
            onSelectionChange?([item.url])
        } else {
            preview.isHidden = true
            previewDivider.isHidden = true
            onSelectionChange?([])
        }
        tileColumns()
    }

    private func appendSubColumn(for url: URL) {
        let index = subColumns.count
        let col = BrowserColumn(url: url)
        col.columnWidth = max(190, AppSettings.browserColumnWidth)
        col.horizontalScrollTarget = scroll
        col.reload(showHidden: AppSettings.showHidden, sort: .name, ascending: true)

        col.onSelect = { [weak self] item in
            guard let self else { return }
            self.removeSubColumns(from: index + 1)
            let selected = col.selectedItems
            self.selectedItem = selected.last ?? item
            if selected.count > 1 {
                self.preview.isHidden = true
                self.previewDivider.isHidden = true
                self.onSelectionChange?(Set(selected.map { $0.url }))
                self.tileColumns()
                self.scrollToRightEnd()
                return
            }
            if let item {
                if item.isNavigable {
                    self.preview.isHidden = true
                    self.previewDivider.isHidden = true
                    self.appendSubColumn(for: item.url)
                } else {
                    self.preview.configure(with: item)
                    self.preview.isHidden = false
                    self.previewDivider.isHidden = false
                }
                self.onSelectionChange?([item.url])
            }
            self.tileColumns()
            self.scrollToRightEnd()
        }
        col.onOpen = { [weak self] item in self?.onOpen?(item) }
        col.keyHandler = { [weak self] event in self?.handleColumnKey(event, columnIndex: index) ?? false }
        col.menuProvider = { [weak self] item in self?.menuProvider?(item) }

        board.addSubview(col)
        subColumns.append(col)

        let divider = ColumnDividerView()
        divider.columnIndex = index
        divider.onDragBegan = { [weak self, weak col] in
            guard let self, let col else { return }
            self.dragStartColumnWidth = col.columnWidth
        }
        divider.onDrag = { [weak self, weak col] delta, isOption in
            guard let self, let col else { return }
            let newW = min(max(self.dragStartColumnWidth + delta, 150), 650)
            col.columnWidth = newW
            if isOption {
                self.hitsColumn.columnWidth = newW
                for c in self.subColumns { c.columnWidth = newW }
            }
            self.tileColumns()
        }
        divider.onDoubleClick = { [weak self, weak col] in
            guard let self, let col else { return }
            let font = NSFont.systemFont(ofSize: 12.5)
            var maxWidth: CGFloat = 0
            for item in col.items {
                let w = (item.name as NSString).size(withAttributes: [.font: font]).width
                if w > maxWidth { maxWidth = w }
            }
            let ideal = min(max(maxWidth + 65, 150), 600)
            col.columnWidth = (abs(col.columnWidth - ideal) < 2) ? AppSettings.browserColumnWidth : ideal
            self.tileColumns()
        }
        board.addSubview(divider)
        dividers.append(divider)
    }

    private func removeSubColumns(from startIndex: Int) {
        guard startIndex < subColumns.count else { return }
        for i in startIndex..<subColumns.count {
            subColumns[i].removeFromSuperview()
            if i < dividers.count {
                dividers[i].removeFromSuperview()
            }
        }
        subColumns.removeSubrange(startIndex..<subColumns.count)
        if startIndex < dividers.count {
            dividers.removeSubrange(startIndex..<dividers.count)
        }
    }

    private func tileColumns() {
        let height = max(1, scroll.contentSize.height)
        let hitZone: CGFloat = 9
        var x: CGFloat = 0

        let firstW = hitsColumn.columnWidth
        hitsColumn.frame = NSRect(x: x, y: 0, width: firstW, height: height)
        x += firstW

        hitsDivider.frame = NSRect(x: x - hitZone / 2 - 0.5, y: 0, width: hitZone, height: height)
        board.addSubview(hitsDivider, positioned: .above, relativeTo: nil)

        for (i, col) in subColumns.enumerated() {
            let w = col.columnWidth
            col.frame = NSRect(x: x, y: 0, width: w, height: height)
            x += w
            if i < dividers.count {
                let div = dividers[i]
                div.frame = NSRect(x: x - hitZone / 2 - 0.5, y: 0, width: hitZone, height: height)
                board.addSubview(div, positioned: .above, relativeTo: nil)
            }
        }

        if !preview.isHidden {
            let pw = max(180, preview.columnWidth)
            preview.frame = NSRect(x: x, y: 0, width: pw, height: height)
            x += pw
            previewDivider.frame = NSRect(x: x - hitZone / 2 - 0.5, y: 0, width: hitZone, height: height)
            board.addSubview(previewDivider, positioned: .above, relativeTo: nil)
        }

        let totalWidth = max(bounds.width, x)
        board.frame = NSRect(x: 0, y: 0, width: totalWidth, height: height)
    }

    private func scrollToRightEnd() {
        var rightEdge = subColumns.last?.frame.maxX ?? hitsColumn.frame.maxX
        if !preview.isHidden { rightEdge = preview.frame.maxX }
        let visible = scroll.documentVisibleRect
        if rightEdge > visible.maxX {
            board.scroll(NSPoint(x: rightEdge - visible.width, y: 0))
        }
    }

    private func handleColumnKey(_ event: NSEvent, columnIndex: Int) -> Bool {
        if keyHandler?(event) == true { return true }
        return false
    }
}

private final class SearchColumnBoard: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
    }
}

/// 分栏模式下的第 0 列：展示搜索命中列表（含文件图标、名称、右侧浅灰父目录名与文件夹右箭头）。
private final class SearchHitsListColumn: NSView, NSTableViewDataSource, NSTableViewDelegate {

    var columnWidth: CGFloat = 270
    var onSelect: ((FileItem?) -> Void)?
    var onOpen: ((FileItem) -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((FileItem?) -> NSMenu?)?

    private var items: [FileItem] = []
    private let table = KeyTableView()
    private let scroll = NSScrollView()

    weak var horizontalScrollTarget: NSScrollView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hitCol"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .fullWidth
        table.rowHeight = 28
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = true
        table.backgroundColor = .controlBackgroundColor
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(handleDoubleClick)
        table.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
        table.menuProvider = { [weak self] _ in self?.menuProvider?(self?.selectedItem) }
        table.urlsForRows = { [weak self] rows in
            guard let self else { return [] }
            return rows.compactMap { r in
                guard r >= 0, r < self.items.count else { return nil }
                return self.items[r].url
            }
        }

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.scrollerStyle = .overlay
        addSubview(scroll)

        let verticalInset: CGFloat = 5.0
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: verticalInset),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalInset),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1)
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    func update(items: [FileItem]) {
        self.items = items
        table.reloadData()
    }

    func autoSizeColumn() {
        let font = NSFont.systemFont(ofSize: 12.5)
        var maxWidth: CGFloat = 0
        for item in items {
            let w = (item.name as NSString).size(withAttributes: [.font: font]).width
            if w > maxWidth { maxWidth = w }
        }
        let ideal = min(max(maxWidth + 90, 180), 600)
        columnWidth = (abs(columnWidth - ideal) < 2) ? 270 : ideal
    }

    var selectedItem: FileItem? {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    var selectedItems: [FileItem] {
        let rows = table.selectedRowIndexes
        return rows.compactMap { index in
            guard index >= 0, index < items.count else { return nil }
            return items[index]
        }
    }

    @discardableResult
    func select(url: URL) -> Bool {
        guard let idx = items.firstIndex(where: { $0.url == url }) else { return false }
        table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        table.scrollRowToVisible(idx)
        return true
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let cur = table.selectedRow
        let next = cur < 0 ? 0 : min(max(0, cur + delta), items.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
        onSelect?(selectedItem)
    }

    @objc private func handleDoubleClick() {
        let row = table.clickedRow
        guard row >= 0, row < items.count else { return }
        onOpen?(items[row])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 28 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("SearchColumnRowView")
        let rowView = (tableView.makeView(withIdentifier: id, owner: self) as? ColumnTableRowView)
            ?? ColumnTableRowView()
        rowView.identifier = id
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("SearchColumnHitCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SearchColumnHitCell)
            ?? SearchColumnHitCell(identifier: id)
        cell.configure(with: items[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
        onSelect?(selectedItem)
    }
}

private final class SearchColumnHitCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let folderHint = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var isHiddenItem: Bool = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        for v in [icon, title, folderHint, chevron] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = true
            v.autoresizingMask = []
            addSubview(v)
        }
        icon.imageScaling = .scaleProportionallyDown
        title.font = .systemFont(ofSize: 12.5)
        title.lineBreakMode = .byTruncatingMiddle
        folderHint.font = .systemFont(ofSize: 10.5)
        folderHint.textColor = .tertiaryLabelColor
        folderHint.lineBreakMode = .byTruncatingTail
        folderHint.alignment = .right
        chevron.imageScaling = .scaleProportionallyDown
        chevron.contentTintColor = .tertiaryLabelColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateColors()
        }
    }

    private func updateColors() {
        if backgroundStyle == .emphasized {
            title.textColor = .white
            folderHint.textColor = NSColor.white.withAlphaComponent(0.7)
            chevron.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        } else {
            title.textColor = isHiddenItem ? .secondaryLabelColor : .labelColor
            folderHint.textColor = .tertiaryLabelColor
            chevron.contentTintColor = .tertiaryLabelColor
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let iconSize = Theme.listIconSize
        icon.frame = NSRect(x: 9, y: (h - iconSize) / 2, width: iconSize, height: iconSize)

        let chevronW: CGFloat = chevron.isHidden ? 0 : 12
        chevron.frame = NSRect(x: bounds.width - 8 - chevronW, y: (h - 12) / 2, width: chevronW, height: 12)

        let rightLimit = chevron.isHidden ? bounds.width - 8 : chevron.frame.minX - 4
        let hintW = min(68, max(36, bounds.width * 0.26))
        folderHint.frame = NSRect(x: rightLimit - hintW, y: (h - 14) / 2, width: hintW, height: 14)

        let nameX = icon.frame.maxX + 7
        let nameW = max(0, folderHint.frame.minX - nameX - 6)
        title.frame = NSRect(x: nameX, y: (h - 17) / 2, width: nameW, height: 17)
    }

    func configure(with item: FileItem) {
        self.isHiddenItem = item.isHidden
        icon.image = IconCache.shared.icon(for: item)
        title.stringValue = item.name
        let parent = item.url.deletingLastPathComponent().lastPathComponent
        folderHint.stringValue = parent.isEmpty ? "/" : parent
        chevron.isHidden = !item.isNavigable
        chevron.image = Theme.symbol("chevron.right", size: 9, weight: .semibold)
        updateColors()
        needsLayout = true
    }
}

// MARK: - 输入框与面板

private final class MinimalSearchTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
}

private final class CenteredSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
