import AppKit
import Quartz

// MARK: - 主窗口

/// 主窗口：点窗口内任意位置（文件行、空白处、状态栏、工具条都算）都让窗口获得焦点。
/// 系统默认只有「可接受首次点击」的控件才会顺带切换 key window，点空白处常常只激活
/// App 而不切窗口，所以这里在派发事件前先自己抢焦点。
final class MainWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if !isKeyWindow { makeKeyAndOrderFront(nil) }
            if let field = InlineRenameField.activeField, field.window === self {
                if !field.containsWindowPoint(event.locationInWindow) {
                    field.commitAndClose()
                }
            }
        case .leftMouseUp, .rightMouseUp:
            super.sendEvent(event)
            if InlineRenameField.activeField == nil {
                if let hit = contentView?.hitTest(event.locationInWindow) as? SplitterView {
                    (hit.axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            return
        case .keyDown:
            if let field = InlineRenameField.activeField, field.window === self {
                let hasMarked = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
                if !hasMarked {
                    if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 48 { // Return / Enter / Tab
                        field.commitAndClose()
                        return
                    } else if event.keyCode == 53 { // Escape
                        field.cancelAndClose()
                        return
                    }
                }
            }
        case .otherMouseDown:
            if event.buttonNumber == 3 || event.buttonNumber == 4 {
                (windowController as? MainWindowController)?.handleMouseNavigation(buttonNumber: event.buttonNumber, location: event.locationInWindow)
                return
            }
        case .otherMouseUp:
            if event.buttonNumber == 3 || event.buttonNumber == 4 {
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }
}

// MARK: - 工具栏里的自定义视图

/// 顶部左侧的导航区：后退 / 前进 + 当前文件夹名。
final class ToolbarNavView: NSView {

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?

    private let backButton = SquareToolbarButton()
    private let forwardButton = SquareToolbarButton()
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        backButton.image = Theme.symbol("chevron.left", size: 15, weight: .semibold)
        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.toolTip = "\("后退".localized) (⌘[ / ⌘←)"

        forwardButton.image = Theme.symbol("chevron.right", size: 15, weight: .semibold)
        forwardButton.target = self
        forwardButton.action = #selector(forwardTapped)
        forwardButton.toolTip = "\("前进".localized) (⌘] / ⌘→)"

        titleLabel.font = .systemFont(ofSize: 14.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [backButton, forwardButton, titleLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.setCustomSpacing(10, after: forwardButton)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 28),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 150)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    func setBackEnabled(_ enabled: Bool) {
        backButton.alphaValue = enabled ? 1 : 0.35
    }

    func setForwardEnabled(_ enabled: Bool) {
        forwardButton.alphaValue = enabled ? 1 : 0.35
    }

    @objc private func backTapped() { onBack?() }

    @objc private func forwardTapped() { onForward?() }
}

/// 工具栏里的显示方式切换：列表 / 图标 / 分栏（三个方形按钮）。
final class ToolbarViewModeView: NSView {

    var onPick: ((ViewMode) -> Void)?

    private let buttons: [(mode: ViewMode, button: SquareToolbarButton)] = [
        (.list, ToolbarViewModeView.makeButton("list.bullet", "列表".localized)),
        (.icons, ToolbarViewModeView.makeButton("square.grid.2x2", "图标".localized)),
        (.columns, ToolbarViewModeView.makeButton("rectangle.split.3x1", "分栏".localized))
    ]

    private static func makeButton(_ symbol: String, _ tooltip: String) -> SquareToolbarButton {
        let button = SquareToolbarButton()
        button.image = Theme.symbol(symbol, size: 15, weight: .regular)
        button.toolTip = tooltip
        return button
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView(views: buttons.map { $0.button })
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.heightAnchor.constraint(equalToConstant: 28)
        ])
        for entry in buttons {
            entry.button.target = self
            entry.button.action = #selector(picked(_:))
            entry.button.tag = ViewMode.allCases.firstIndex(of: entry.mode) ?? 0
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelected(_ mode: ViewMode) {
        for entry in buttons {
            entry.button.isOn = (entry.mode == mode)
        }
    }

    @objc private func picked(_ sender: NSButton) {
        let index = sender.tag
        guard ViewMode.allCases.indices.contains(index) else { return }
        onPick?(ViewMode.allCases[index])
    }
}

// MARK: - 主窗口控制器

final class MainWindowController: NSWindowController, NSWindowDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    let container: OpaqueBackgroundView
    let sidebar: SidebarView
    let workspace: WorkspaceArea

    private(set) var chromeBar: ChromeBar!
    private(set) var layoutButton: SquareToolbarButton!
    private(set) var moreButton: SquareToolbarButton?
    private(set) var searchButton: SquareToolbarButton!
    private(set) var navView: ToolbarNavView!
    private(set) var viewModeView: ToolbarViewModeView!

    private var displayOptionsPopover: NSPopover?
    private var layoutPicker: LayoutPickerController?
    private var searchController: SearchPanelController?
    private var previewItems: [URL] = []

    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarSplitterRef: SplitterView?
    private var sidebarWidthAtDragStart: CGFloat = 0
    private var workspaceTopConstraint: NSLayoutConstraint?

    // MARK: - 初始化

    init(initialURL: URL? = nil, frame: NSRect) {
        let win = MainWindow(contentRect: frame,
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered,
                             defer: false)
        win.appearance = NSApp.appearance
        win.title = "Maple"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = false
        win.minSize = NSSize(width: 760, height: 480)
        win.isReleasedWhenClosed = false
        win.isRestorable = false

        let sb = SidebarView()
        let ws = WorkspaceArea()
        self.sidebar = sb
        self.workspace = ws

        let cont = OpaqueBackgroundView(frame: frame)
        cont.autoresizingMask = [.width, .height]
        cont.color = Theme.paneBackground
        cont.wantsLayer = true
        cont.layer?.cornerRadius = 10.5
        cont.layer?.masksToBounds = true
        self.container = cont

        super.init(window: win)
        win.delegate = self
        win.windowController = self

        setupUI(in: cont, window: win)

        if let initialURL {
            ws.openInFocusedPane(initialURL)
            sb.select(url: initialURL)
            updateNavTitle()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 布局与装配

    private func setupUI(in container: OpaqueBackgroundView, window: MainWindow) {
        sidebar.currentURLProvider = { [weak self] in
            self?.workspace.focusedPane?.currentURL
        }

        sidebar.onSelect = { [weak self] url in
            self?.workspace.openInFocusedPane(url)
        }
        sidebar.onOpenInOtherPane = { [weak self] url in
            self?.workspace.openInOtherPane(url)
        }
        sidebar.onSelectTag = { [weak self] tag in
            self?.workspace.showTagInFocusedPane(tag)
            self?.updateNavTitle()
        }
        sidebar.onSelectAllTags = { [weak self] in
            self?.workspace.showAllTagsInFocusedPane()
            self?.updateNavTitle()
        }
        workspace.onRequestDeleteTag = { [weak self] tag in
            self?.sidebar.confirmAndDeleteTag(named: tag)
        }
        sidebar.onTagRemoved = { [weak self] tag in
            self?.workspace.handleTagRemoved(tag)
            self?.updateNavTitle()
        }
        sidebar.isShowingTag = { [weak self] tag in
            self?.workspace.isShowingTag(tag) ?? false
        }
        sidebar.getURLsForTagInPanes = { [weak self] tag in
            self?.workspace.getURLsForTagInPanes(tag) ?? []
        }
        sidebar.onRequestConnectServer = { entry in
            AppDelegate.shared?.showConnectServerWindow(initialEntry: entry)
        }
        sidebar.onOpenSettings = {
            AppDelegate.shared?.showSettings()
        }
        workspace.onQuickLook = { [weak self] pane in
            self?.toggleQuickLook(for: pane)
        }
        workspace.onNavigate = { [weak self] pane in
            self?.sidebar.select(url: pane.currentURL)
            self?.updateNavTitle()
        }
        workspace.onFocusChange = { [weak self] pane in
            if pane.isAllTagsMode {
                self?.sidebar.selectAllTagsRow(scrollToVisible: false)
            } else if let tag = pane.tagName, pane.isTagView {
                self?.sidebar.select(tag: tag)
            } else {
                self?.sidebar.select(url: pane.currentURL)
            }
            self?.syncToolbarViewMode()
            self?.updateNavTitle()
        }
        workspace.onViewModeChange = { [weak self] _ in
            self?.syncToolbarViewMode()
            self?.updateNavTitle()
        }
        workspace.onFavoritesChange = { [weak self] in
            self?.sidebar.reload()
        }

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        workspace.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sidebar)
        container.addSubview(workspace)

        let widthConstraint = sidebar.widthAnchor.constraint(equalToConstant: AppSettings.sidebarWidth)
        sidebarWidthConstraint = widthConstraint

        let sidebarSplitter = SplitterView()
        sidebarSplitter.axis = .vertical
        sidebarSplitter.translatesAutoresizingMaskIntoConstraints = false
        sidebarSplitter.onDragBegan = { [weak self] in
            guard let self, let constraint = self.sidebarWidthConstraint else { return }
            self.sidebarWidthAtDragStart = constraint.constant
        }
        sidebarSplitter.onDrag = { [weak self] delta in
            guard let self, let constraint = self.sidebarWidthConstraint else { return }
            constraint.constant = min(max(self.sidebarWidthAtDragStart + delta, 150), 420)
        }
        sidebarSplitter.onDragEnd = { [weak self] in
            guard let constraint = self?.sidebarWidthConstraint else { return }
            AppSettings.sidebarWidth = constraint.constant
        }
        container.addSubview(sidebarSplitter)
        sidebarSplitterRef = sidebarSplitter

        let topBand = Theme.chromeHeight
        let workspaceTop = workspace.topAnchor.constraint(equalTo: container.topAnchor,
                                                          constant: topBand)
        workspaceTopConstraint = workspaceTop
        sidebar.topInset = topBand

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            widthConstraint,

            workspaceTop,
            workspace.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            workspace.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 1),
            workspace.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            sidebarSplitter.centerXAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 0.5),
            sidebarSplitter.topAnchor.constraint(equalTo: container.topAnchor),
            sidebarSplitter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebarSplitter.widthAnchor.constraint(equalToConstant: 6)
        ])

        buildChrome(in: container)

        window.contentView = container

        if let pane = workspace.focusedPane {
            sidebar.select(url: pane.currentURL)
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleOpenInOtherPane(_:)),
                                               name: .openInOtherPane,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleLocateInOtherPane(_:)),
                                               name: .locateInOtherPane,
                                               object: nil)
    }

    private func buildChrome(in container: NSView) {
        let chrome = ChromeBar()
        chrome.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chrome)
        chromeBar = chrome

        chrome.onDragArea = { [weak self] event in
            self?.handleChromeDrag(event)
        }

        navView = chrome.navView
        viewModeView = chrome.viewModeView
        searchButton = chrome.searchButton
        moreButton = chrome.moreButton
        layoutButton = chrome.layoutButton

        navView.onBack = { [weak self] in self?.pane()?.goBack() }
        navView.onForward = { [weak self] in self?.pane()?.goForward() }

        chrome.newFolderButton.target = self
        chrome.newFolderButton.action = #selector(newFolderAction)

        chrome.terminalButton.target = self
        chrome.terminalButton.action = #selector(toolbarTerminalAction(_:))
        chrome.terminalButton.onRightMouseDown = { [weak self] event in
            self?.showToolbarTerminalMenu(for: self?.chromeBar.terminalButton, event: event)
        }

        chrome.searchButton.target = self
        chrome.searchButton.action = #selector(showSearchPanelClicked(_:))

        chrome.moreButton.target = self
        chrome.moreButton.action = #selector(showActionMenu(_:))

        chrome.layoutButton.target = self
        chrome.layoutButton.action = #selector(showLayoutMenu(_:))

        viewModeView.onPick = { [weak self] mode in
            self?.pane()?.viewMode = mode
            self?.syncToolbarViewMode()
        }

        let dragStrip = ChromeDragStrip()
        dragStrip.translatesAutoresizingMaskIntoConstraints = false
        dragStrip.onDragArea = { [weak self] event in
            self?.handleChromeDrag(event)
        }
        container.addSubview(dragStrip)

        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: container.topAnchor),
            chrome.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 1),
            chrome.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chrome.heightAnchor.constraint(equalToConstant: Theme.chromeHeight),

            dragStrip.topAnchor.constraint(equalTo: container.topAnchor),
            dragStrip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dragStrip.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            dragStrip.heightAnchor.constraint(equalToConstant: Theme.chromeHeight)
        ])

        syncToolbarViewMode()
        updateNavTitle()
        updateLayoutButton()
    }

    // MARK: - 窗口与交互

    /// 鼠标侧键前进 / 后退（Button 3 为后退，Button 4 为前进，与浏览器及系统标准一致）
    func handleMouseNavigation(buttonNumber: Int, location: NSPoint? = nil) {
        if let location, let win = window {
            if let hit = win.contentView?.hitTest(location) {
                for pane in workspace.panes {
                    if hit.isDescendant(of: pane) {
                        workspace.setFocused(pane)
                        break
                    }
                }
            }
        }
        if buttonNumber == 3 {
            goBackAction()
        } else if buttonNumber == 4 {
            goForwardAction()
        }
    }

    private func handleChromeDrag(_ event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
            return
        }
        window?.performDrag(with: event)
    }

    func pane() -> PaneView? { workspace.focusedPane }

    func syncToolbarViewMode() {
        guard let viewModeView, let mode = workspace.focusedPane?.viewMode else { return }
        viewModeView.setSelected(mode)
    }

    func updateNavTitle() {
        guard let navView else { return }
        guard let pane = workspace.focusedPane else {
            navView.setTitle("")
            return
        }
        let folder = pane.displayedFolderName
        navView.setTitle(folder)
        navView.setBackEnabled(pane.canGoBack)
        navView.setForwardEnabled(pane.canGoForward)
    }

    func updateLayoutButton() {
        let mode = workspace.mode
        layoutButton?.image = mode.icon
        layoutButton?.toolTip = "布局：\(mode.title)"
    }

    func toggleSidebar() {
        sidebar.isHidden.toggle()
        sidebarSplitterRef?.isHidden = sidebar.isHidden
    }

    func nextPane() {
        guard workspace.panes.count > 1 else { return }
        let panes = workspace.panes
        guard let current = workspace.focusedPane,
              let index = panes.firstIndex(where: { $0 === current }) else {
            workspace.setFocused(panes.first)
            return
        }
        workspace.setFocused(panes[(index + 1) % panes.count])
    }

    func setLayoutMode(_ mode: LayoutMode) {
        workspace.setMode(mode)
        updateLayoutButton()
    }

    func isSidebarFocused() -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: sidebar)
    }

    // MARK: - 跨窗格通知响应

    @objc private func handleOpenInOtherPane(_ note: Notification) {
        guard let win = self.window, win.isKeyWindow else { return }
        guard let url = note.object as? URL else { return }
        workspace.openInOtherPane(url)
    }

    @objc private func handleLocateInOtherPane(_ note: Notification) {
        guard let win = self.window, win.isKeyWindow else { return }
        guard let url = note.object as? URL else { return }
        workspace.locateInOtherPane(url)
    }

    // MARK: - 布局弹出菜单

    @objc func showLayoutMenu(_ sender: NSButton) {
        if let layoutPicker {
            layoutPicker.close()
            return
        }
        let picker = LayoutPickerController(selected: workspace.mode)
        picker.onPick = { [weak self] mode in
            guard let self else { return }
            self.workspace.setMode(mode)
            self.updateLayoutButton()
        }
        picker.onDismiss = { [weak self] in self?.layoutPicker = nil }
        layoutPicker = picker
        if let win = window {
            picker.show(anchoredTo: sender, in: win)
        }
    }

    // MARK: - 搜索浮层

    func openSearchPanel(isCurrentFolder: Bool) {
        guard let win = window else { return }
        if let controller = searchController {
            if controller.isVisible {
                controller.setScope(isCurrentFolder: isCurrentFolder)
                return
            }
            controller.setScope(isCurrentFolder: isCurrentFolder)
            controller.show(anchoredTo: searchButton, in: win)
            return
        }
        let controller = SearchPanelController()
        controller.currentFolderProvider = { [weak self] in
            self?.workspace.focusedPane?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        }
        controller.onPick = { [weak self] url in
            guard let self else { return }
            if let pane = self.workspace.focusedPane ?? self.workspace.panes.first {
                pane.activate()
                pane.reveal(url)
            }
        }
        controller.onOpenSettings = {
            AppDelegate.shared?.showSettings()
        }
        searchController = controller
        controller.setScope(isCurrentFolder: isCurrentFolder)
        controller.show(anchoredTo: searchButton, in: win)
    }

    @objc private func showSearchPanelClicked(_ sender: NSButton) {
        if let controller = searchController, controller.isVisible {
            controller.close()
            return
        }
        openSearchPanel(isCurrentFolder: false)
    }

    // MARK: - 显示选项 Popover

    func showDisplayOptions() {
        guard let win = window else { return }
        if let popover = displayOptionsPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let controller = DisplayOptionsViewController(iconSize: AppSettings.gridIconSize,
                                                     rowHeight: AppSettings.listRowHeight,
                                                     showHidden: AppSettings.showHidden)
        controller.onIconSize = { [weak self] size in
            AppSettings.gridIconSize = size
            self?.workspace.applyIconSize(size)
        }
        controller.onRowHeight = { [weak self] height in
            AppSettings.listRowHeight = height
            self?.workspace.applyRowHeight(height)
        }
        controller.onShowHidden = { [weak self] show in
            AppSettings.showHidden = show
            self?.workspace.reloadAll()
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 264, height: 226)
        if let anchor = moreButton {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let content = win.contentView {
            popover.show(relativeTo: content.bounds, of: content, preferredEdge: .minY)
        }
        displayOptionsPopover = popover
    }

    // MARK: - 工具栏终端按钮菜单

    @objc private func toolbarTerminalAction(_ sender: NSButton) {
        pane()?.openCurrentDirectoryInTerminal()
    }

    func showToolbarTerminalMenu(for button: NSButton?, event: NSEvent?) {
        guard let button, let win = button.window else { return }
        let current = TerminalManager.shared.currentTerminal()
        let installed = TerminalManager.shared.scanInstalledTerminals()

        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "快速打开终端".localized, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for term in installed {
            let isCurrent = term.id == current.id
            let item = NSMenuItem(
                title: String(format: "在“%@”中打开".localized, term.displayName) + (isCurrent ? " (默认)".localized : ""),
                action: #selector(toolbarTerminalPicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = term
            item.image = term.icon
            item.state = isCurrent ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let prefItem = NSMenuItem(title: "设置默认终端…".localized, action: #selector(openTerminalPreferencesAction), keyEquivalent: "")
        prefItem.target = self
        menu.addItem(prefItem)

        let onScreen = win.convertToScreen(button.convert(button.bounds, to: nil))
        menu.popUp(positioning: nil,
                   at: NSPoint(x: onScreen.minX, y: onScreen.minY - 6),
                   in: nil)
    }

    @objc private func toolbarTerminalPicked(_ sender: NSMenuItem) {
        guard let term = sender.representedObject as? InstalledTerminal else { return }
        pane()?.launchInTerminal(term)
    }

    @objc private func openTerminalPreferencesAction() {
        AppDelegate.shared?.showSettings(category: "general")
    }

    // MARK: - 顶部「更多」菜单

    @objc func showActionMenu(_ sender: NSButton) {
        guard let pane = workspace.focusedPane, let win = sender.window else { return }
        let menu = makeActionMenu(for: pane)
        let onScreen = win.convertToScreen(sender.convert(sender.bounds, to: nil))
        menu.popUp(positioning: nil,
                   at: NSPoint(x: onScreen.minX, y: onScreen.minY - 6),
                   in: nil)
    }

    private func makeActionMenu(for pane: PaneView) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let newFolder = NSMenuItem(title: "新建文件夹".localized, action: #selector(newFolderAction), keyEquivalent: "")
        newFolder.target = self
        newFolder.isEnabled = !pane.isTagView
        menu.addItem(newFolder)

        let openOther = NSMenuItem(title: "在新窗格中打开".localized, action: #selector(openSelectionInOtherPane), keyEquivalent: "")
        openOther.target = self
        openOther.isEnabled = workspace.panes.count > 1
        menu.addItem(openOther)

        menu.addItem(.separator())

        let info = NSMenuItem(title: "显示简介".localized, action: #selector(infoAction), keyEquivalent: "")
        info.target = self
        menu.addItem(info)

        let qlTitle = String(format: "快速查看“%@”".localized, pane.menuTargetName)
        let quickLook = NSMenuItem(title: qlTitle,
                                   action: #selector(quickLookAction),
                                   keyEquivalent: "")
        quickLook.target = self
        quickLook.isEnabled = !(pane.isTagView && pane.currentSelection().isEmpty)
        menu.addItem(quickLook)

        let currentTerm = TerminalManager.shared.currentTerminal()
        let termItem = NSMenuItem(title: String(format: "在“%@”中打开".localized, currentTerm.displayName),
                                  action: #selector(terminalAction),
                                  keyEquivalent: "")
        termItem.target = self
        menu.addItem(termItem)

        menu.addItem(.separator())

        let groupItem = NSMenuItem(title: "使用群组".localized, action: nil, keyEquivalent: "")
        let groupMenu = NSMenu()
        groupMenu.autoenablesItems = false
        for mode in GroupMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(groupPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == pane.groupMode ? .on : .off
            groupMenu.addItem(item)
        }
        groupItem.submenu = groupMenu
        menu.addItem(groupItem)

        let sortItem = NSMenuItem(title: "排序方式".localized, action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        sortMenu.autoenablesItems = false
        for field in SortField.allCases {
            let item = NSMenuItem(title: field.title, action: #selector(sortPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = field.rawValue
            item.state = field == pane.sortField ? .on : .off
            sortMenu.addItem(item)
        }
        sortMenu.addItem(.separator())
        let asc = NSMenuItem(title: "升序".localized, action: #selector(orderPicked(_:)), keyEquivalent: "")
        asc.target = self
        asc.representedObject = "asc"
        asc.state = pane.ascending ? .on : .off
        sortMenu.addItem(asc)
        let desc = NSMenuItem(title: "降序".localized, action: #selector(orderPicked(_:)), keyEquivalent: "")
        desc.target = self
        desc.representedObject = "desc"
        desc.state = pane.ascending ? .off : .on
        sortMenu.addItem(desc)
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)

        let options = NSMenuItem(title: "查看显示选项…".localized, action: #selector(showDisplayOptionsClicked), keyEquivalent: "")
        options.target = self
        menu.addItem(options)

        let settingsItem = NSMenuItem(title: "设置与权限管理…".localized, action: #selector(showSettingsClicked), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let connectServerItem = NSMenuItem(title: "连接服务器…".localized, action: #selector(connectServerClicked), keyEquivalent: "")
        connectServerItem.target = self
        menu.addItem(connectServerItem)

        let updateItem = NSMenuItem(title: "检查更新…".localized, action: #selector(checkForUpdatesClicked), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let hidden = NSMenuItem(title: AppSettings.showHidden ? "隐藏隐藏文件".localized : "显示隐藏文件".localized,
                                action: #selector(toggleHiddenClicked),
                                keyEquivalent: "")
        hidden.target = self
        menu.addItem(hidden)

        let refresh = NSMenuItem(title: "刷新".localized, action: #selector(refreshAction), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let layoutItem = NSMenuItem(title: "布局".localized, action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu()
        layoutMenu.autoenablesItems = false
        for mode in LayoutMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(layoutMenuItemPicked(_:)), keyEquivalent: "")
            item.target = self
            item.image = mode.icon
            item.representedObject = mode.rawValue
            item.state = mode == workspace.mode ? .on : .off
            layoutMenu.addItem(item)
        }
        layoutItem.submenu = layoutMenu
        menu.addItem(layoutItem)

        return menu
    }

    // MARK: - 菜单动作分派

    @objc func newFolderAction() { pane()?.createFolder() }
    @objc func renameAction() { pane()?.renameSelected() }
    @objc func trashAction() { pane()?.trashSelected() }
    @objc func duplicateAction() { pane()?.contextDuplicate() }
    @objc func infoAction() { pane()?.showInfo() }
    @objc func refreshAction() { pane()?.reload() }
    @objc func terminalAction() { pane()?.openInTerminal() }
    @objc func quickLookAction() { pane()?.requestQuickLook() }
    @objc func copyPathAction() { pane()?.copyPath() }
    @objc func revealAction() { pane()?.revealInFinder() }
    @objc func goUpAction() { pane()?.goUp() }
    @objc func goBackAction() { pane()?.goBack() }
    @objc func goForwardAction() { pane()?.goForward() }
    @objc func editPathAction() { pane()?.beginEditingPath() }
    @objc func listModeAction() { pane()?.viewMode = .list }
    @objc func iconModeAction() { pane()?.viewMode = .icons }
    @objc func columnModeAction() { pane()?.viewMode = .columns }

    @objc func openSelectionInOtherPane() {
        guard let pane = pane() else { return }
        let url = pane.currentSelection().first?.url ?? pane.currentURL
        workspace.openInOtherPane(url)
    }

    @objc private func showDisplayOptionsClicked() {
        showDisplayOptions()
    }

    @objc private func showSettingsClicked() {
        AppDelegate.shared?.showSettings()
    }

    @objc private func connectServerClicked() {
        AppDelegate.shared?.showConnectServerWindow(initialEntry: nil)
    }

    @objc private func checkForUpdatesClicked() {
        UpdateChecker.shared.checkForUpdates(isUserInitiated: true)
    }

    @objc private func toggleHiddenClicked() {
        AppSettings.showHidden.toggle()
        workspace.reloadAll()
    }

    @objc private func layoutMenuItemPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = LayoutMode(rawValue: raw) else { return }
        setLayoutMode(mode)
    }

    @objc func sortPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let field = SortField(rawValue: raw) else { return }
        pane()?.applySort(field)
    }

    @objc func orderPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        pane()?.applyAscending(raw == "asc")
    }

    @objc func groupPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = GroupMode(rawValue: raw) else { return }
        pane()?.applyGroup(mode)
    }

    // MARK: - Quick Look

    func toggleQuickLook(for pane: PaneView) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let selection = pane.currentSelection().map { $0.url }
        let urls = selection.isEmpty ? [pane.currentURL] : selection
        previewItems = urls
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index < previewItems.count else { return nil }
        return previewItems[index] as NSURL
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        workspace.saveState()
        if let frame = window?.frame {
            AppSettings.windowFrame = NSStringFromRect(frame)
        }
        NotificationCenter.default.removeObserver(self)
        AppDelegate.shared?.removeWindowController(self)
    }

    func windowDidResize(_ notification: Notification) {
        if let frame = window?.frame {
            AppSettings.windowFrame = NSStringFromRect(frame)
        }
    }

    func windowDidMove(_ notification: Notification) {
        if let frame = window?.frame {
            AppSettings.windowFrame = NSStringFromRect(frame)
        }
    }
}
