import AppKit
import Quartz

// MARK: - 窗口

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
        default:
            break
        }
        super.sendEvent(event)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var window: MainWindow!
    private var container: OpaqueBackgroundView!
    private var sidebar: SidebarView!
    private var workspace: WorkspaceArea!
    private var chromeBar: ChromeBar!
    private var layoutButton: SquareToolbarButton!
    private var moreButton: SquareToolbarButton?
    private var searchButton: SquareToolbarButton!
    private var navView: ToolbarNavView!
    private var viewModeView: ToolbarViewModeView!
    private var displayOptionsPopover: NSPopover?
    private var layoutPicker: LayoutPickerController?
    private var searchController: SearchPanelController?
    private var settingsController: SettingsWindowController?
    private var previewItems: [URL] = []
    /// 侧栏宽度约束与分隔条（拖动调整侧栏宽度）。
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarSplitterRef: SplitterView?
    private var sidebarWidthAtDragStart: CGFloat = 0
    /// 窗格区顶部让出的高度（顶部工具条所在的那一条）
    private var workspaceTopConstraint: NSLayoutConstraint?

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.applyAppearance()
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }
        NotificationCenter.default.addObserver(self, selector: #selector(handleLanguageDidChange), name: .languageDidChange, object: nil)
        buildMenu()
        buildWindow()
        reopenMainWindowAction()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        // 启动 3 秒后后台静默检查一次新版本（仅当有新版时温和提示）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            UpdateChecker.shared.checkForUpdates(isUserInitiated: false)
        }
        FileSearchEngine.shared.loadIndex()

        // 确保在主运行循环完成启动阶段后，主窗口必定处于前台并可见
        DispatchQueue.main.async { [weak self] in
            self?.reopenMainWindowAction()
        }

        // 全局键盘监听：支持 ⌘Q 立即退出，以及 Windows 习惯的 Ctrl+Z / Ctrl+Shift+Z 文本与文件撤销与重做
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers ?? ""
            if flags == [.command] && (chars.lowercased() == "q" || event.keyCode == 12) {
                NSApp.terminate(nil)
                return nil
            }
            let isUndoKey = ((flags == [.control] || flags == [.command]) && chars == "z")
            if isUndoKey {
                if let responder = NSApp.keyWindow?.firstResponder,
                   (responder is NSTextView || responder is NSTextField) {
                    if NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) {
                        return nil
                    }
                }
                if self?.isSidebarFocused() == true {
                    if self?.sidebar?.undoTagDeletion() == true {
                        return nil
                    }
                }
                if flags == [.control] {
                    self?.workspace?.undoAction()
                    return nil
                }
            } else if flags == [.control, .shift] && chars == "z" {
                if let responder = NSApp.keyWindow?.firstResponder,
                   (responder is NSTextView || responder is NSTextField) {
                    if NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) {
                        return nil
                    }
                }
                self?.workspace?.redoAction()
                return nil
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        reopenMainWindowAction()
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenMainWindowAction()
        return true
    }

    @objc private func reopenMainWindowAction() {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspace?.saveState()
        saveWindowFrame()
    }

    func windowDidResize(_ notification: Notification) { saveWindowFrame() }
    func windowDidMove(_ notification: Notification) { saveWindowFrame() }

    private func saveWindowFrame() {
        guard let window else { return }
        AppSettings.windowFrame = NSStringFromRect(window.frame)
    }

    /// 恢复上次窗口的位置与大小；窗口必须落在某个屏幕的可见范围内，否则用默认位置。
    private func restoreWindowFrame(_ window: NSWindow, fallback: NSRect) {
        guard let saved = AppSettings.windowFrame else {
            window.setFrame(fallback, display: true)
            return
        }
        let rect = NSRectFromString(saved)
        guard rect.width >= 700, rect.height >= 420 else {
            window.setFrame(fallback, display: true)
            return
        }
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
        window.setFrame(onScreen ? rect : fallback, display: true)
    }

    // MARK: 窗口

    private func buildWindow() {
        guard window == nil else { return }
        // 不使用 setFrameAutosaveName：它会连窗口所属 Space 一起保存/恢复，
        // 导致窗口被还原到不可见的桌面。这里每次按当前主屏可见区定位。
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(1320, max(760, visible.width - 80))
        let height = min(860, max(480, visible.height - 80))
        let frame = NSRect(x: visible.minX + (visible.width - width) / 2,
                           y: visible.minY + (visible.height - height) / 2,
                           width: width,
                           height: height)

        window = MainWindow(contentRect: frame,
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            backing: .buffered,
                            defer: false)
        window.appearance = NSApp.appearance
        window.title = "Maple"
        // 与原生规范一致的「无标题栏」外观：不显示窗口标题，标题栏透明，
        // 侧栏与窗格一直画到窗口顶端，交通灯直接落在侧栏上，视觉上连成一体。
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 760, height: 480)
        window.delegate = self
        window.isReleasedWhenClosed = false
        // 关掉窗口状态恢复：一旦系统存下过异常尺寸（例如 0×0），下次启动会被还原成空白窗口
        window.isRestorable = false
        restoreWindowFrame(window, fallback: frame)

        let sidebar = SidebarView()
        let workspace = WorkspaceArea()
        self.sidebar = sidebar
        self.workspace = workspace

        sidebar.currentURLProvider = { [weak self] in
            self?.workspace?.focusedPane?.currentURL
        }

        sidebar.onSelect = { [weak self] url in
            self?.workspace?.openInFocusedPane(url)
        }
        sidebar.onOpenInOtherPane = { [weak self] url in
            self?.workspace?.openInOtherPane(url)
        }
        sidebar.onSelectTag = { [weak self] tag in
            self?.workspace?.showTagInFocusedPane(tag)
            self?.updateNavTitle()
        }
        sidebar.onSelectAllTags = { [weak self] in
            self?.workspace?.showAllTagsInFocusedPane()
            self?.updateNavTitle()
        }
        workspace.onRequestDeleteTag = { [weak self] tag in
            self?.sidebar?.confirmAndDeleteTag(named: tag)
        }
        sidebar.onTagRemoved = { [weak self] tag in
            self?.workspace?.handleTagRemoved(tag)
            self?.updateNavTitle()
        }
        sidebar.isShowingTag = { [weak self] tag in
            self?.workspace?.isShowingTag(tag) ?? false
        }
        sidebar.getURLsForTagInPanes = { [weak self] tag in
            self?.workspace?.getURLsForTagInPanes(tag) ?? []
        }
        sidebar.onRequestConnectServer = { [weak self] entry in
            self?.showConnectServerWindow(initialEntry: entry)
        }
        sidebar.onOpenSettings = { [weak self] in
            self?.showSettingsAction()
        }
        ServerConnectWindowController.shared.onServersChanged = { [weak self] in
            self?.sidebar?.reload()
        }
        ServerConnectWindowController.shared.onOpenDirectory = { [weak self] url in
            self?.workspace?.openInFocusedPane(url)
        }
        workspace.onQuickLook = { [weak self] pane in
            self?.toggleQuickLook(for: pane)
        }
        workspace.onNavigate = { [weak self] pane in
            self?.sidebar?.select(url: pane.currentURL)
            self?.updateNavTitle()
        }
        workspace.onFocusChange = { [weak self] pane in
            if pane.isAllTagsMode {
                self?.sidebar?.selectAllTagsRow(scrollToVisible: false)
            } else if let tag = pane.tagName, pane.isTagView {
                self?.sidebar?.select(tag: tag)
            } else {
                self?.sidebar?.select(url: pane.currentURL)
            }
            self?.syncToolbarViewMode()
            self?.updateNavTitle()
        }
        workspace.onViewModeChange = { [weak self] _ in
            self?.syncToolbarViewMode()
            self?.updateNavTitle()
        }
        workspace.onFavoritesChange = { [weak self] in
            self?.sidebar?.reload()
        }

        // 显式约束布局（不用 NSSplitView，避免左侧视图按固有宽度挤压工作区）
        // 容器用不透明垫底，避免窗口材质把桌面透进来（表现为窗口逐渐发白）
        let container = OpaqueBackgroundView(frame: frame)
        container.autoresizingMask = [.width, .height]
        container.color = Theme.paneBackground
        container.wantsLayer = true
        container.layer?.cornerRadius = 10.5
        container.layer?.masksToBounds = true
        self.container = container
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        workspace.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sidebar)
        container.addSubview(workspace)

        // 侧栏与工作区之间可左右拖动
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

        // 窗格区顶部让出顶部工具条那一条：侧栏与工具条背景一直画到窗口顶端，
        // 窗格内容从工具条下沿开始，整体看起来是一整块。
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

        // 自绘顶部工具条：横向从侧栏右沿开始，与窗格对齐；背景与窗格同色，无分隔线。
        buildChrome(in: container, sidebar: sidebar)

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // 兜底：万一窗口被系统还原成异常尺寸，重新按当前屏幕摆正
        if window.frame.width < 400 || window.frame.height < 300 {
            window.setFrame(frame, display: true)
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        // 首屏选中当前目录对应的侧栏条目
        if let pane = workspace.focusedPane {
            sidebar.select(url: pane.currentURL)
        }
        // 处理"在新窗格中打开"与"在新窗口定位"的跨组件通知
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleOpenInOtherPane(_:)),
                                               name: .openInOtherPane,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleLocateInOtherPane(_:)),
                                               name: .locateInOtherPane,
                                               object: nil)
    }

    @objc private func handleOpenInOtherPane(_ note: Notification) {
        guard let url = note.object as? URL else { return }
        workspace?.openInOtherPane(url)
    }

    @objc private func handleLocateInOtherPane(_ note: Notification) {
        guard let url = note.object as? URL else { return }
        workspace?.locateInOtherPane(url)
    }

    // MARK: 顶部工具条

    /// 自绘顶部工具条：没有系统标题栏、没有系统工具栏，
    /// 工具条从侧栏右沿开始，垂直方向与交通灯同一行，背景和窗格同色，
    /// 视觉上就是窗格顶部的延伸（QSpace 那种一体感）。
    private func buildChrome(in container: NSView, sidebar: SidebarView) {
        let chrome = ChromeBar()
        chrome.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chrome)
        chromeBar = chrome

        // 空白处按住可拖动窗口，双击缩放
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

        chrome.searchButton.target = self
        chrome.searchButton.action = #selector(showSearchPanel(_:))

        chrome.moreButton.target = self
        chrome.moreButton.action = #selector(showActionMenu(_:))

        chrome.layoutButton.target = self
        chrome.layoutButton.action = #selector(showLayoutMenu(_:))

        viewModeView.onPick = { [weak self] mode in
            self?.pane()?.viewMode = mode
            self?.syncToolbarViewMode()
        }

        // 侧栏顶部那一条（交通灯所在的空白区）也能拖窗口
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

    /// 按住工具条空白处拖窗口，双击缩放（替代系统标题栏的默认行为）。
    private func handleChromeDrag(_ event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
            return
        }
        window?.performDrag(with: event)
    }

    /// 顶部工具栏的显示方式控件始终反映「焦点窗格」的类型。
    private func syncToolbarViewMode() {
        guard let viewModeView, let mode = workspace?.focusedPane?.viewMode else { return }
        viewModeView.setSelected(mode)
    }

    /// 顶部左侧的标题始终显示焦点窗格当前所在的文件夹。
    private func updateNavTitle() {
        guard let navView else { return }
        guard let pane = workspace?.focusedPane else {
            navView.setTitle("")
            return
        }
        let folder = pane.displayedFolderName
        navView.setTitle(folder)
        navView.setBackEnabled(pane.canGoBack)
        navView.setForwardEnabled(pane.canGoForward)
    }

    @objc private func showLayoutMenu(_ sender: NSButton) {
        // 已经展开：再点一次收起
        if let layoutPicker {
            layoutPicker.close()
            return
        }
        let picker = LayoutPickerController(selected: workspace?.mode ?? .single)
        picker.onPick = { [weak self] mode in
            guard let self else { return }
            self.workspace?.setMode(mode)
            self.updateLayoutButton()
        }
        picker.onDismiss = { [weak self] in self?.layoutPicker = nil }
        layoutPicker = picker
        picker.show(anchoredTo: sender, in: window)
    }

    @objc private func layoutPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = LayoutMode(rawValue: raw) else { return }
        workspace?.setMode(mode)
        updateLayoutButton()
    }

    private func updateLayoutButton() {
        guard let mode = workspace?.mode else { return }
        layoutButton?.image = mode.icon
        layoutButton?.toolTip = "布局：\(mode.title)"
    }

    // MARK: 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 Maple".localized,
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        let updateMenuItem = appMenu.addItem(withTitle: "检查更新…".localized,
                                             action: #selector(checkForUpdatesAction),
                                             keyEquivalent: "")
        updateMenuItem.target = self
        appMenu.addItem(.separator())
        add(appMenu, "设置与权限管理…", #selector(showSettingsAction), ",", [.command])
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Maple".localized, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他".localized,
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: "退出 Maple".localized, action: #selector(quitAppAction), keyEquivalent: "q")
        quitItem.target = self

        // 文件
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件".localized)
        fileItem.submenu = fileMenu
        add(fileMenu, "新建窗口", #selector(reopenMainWindowAction), "n", [.command])
        add(fileMenu, "新建文件夹", #selector(newFolderAction), "n", [.command, .shift])
        add(fileMenu, "重命名", #selector(renameAction), "", [])
        add(fileMenu, "移到废纸篓", #selector(trashAction), "\u{8}", [.command])
        fileMenu.addItem(.separator())
        add(fileMenu, "拷贝路径", #selector(copyPathAction), "c", [.command, .option])
        add(fileMenu, "在终端中打开", #selector(terminalAction), "t", [.command, .option])
        add(fileMenu, "在 Finder 中显示", #selector(revealAction), "r", [.command, .shift])
        fileMenu.addItem(.separator())
        add(fileMenu, "刷新", #selector(refreshAction), "r", [.command])
        fileMenu.addItem(.separator())
        add(fileMenu, "显示简介", #selector(infoAction), "i", [.command])
        fileMenu.addItem(.separator())
        add(fileMenu, "关闭窗口", #selector(NSWindow.performClose(_:)), "w", [.command])

        // 编辑（走响应链，保证文本框里仍能正常撤销/重做/拷贝粘贴）
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑".localized)
        editItem.submenu = editMenu
        let undoItem = editMenu.addItem(withTitle: "撤销".localized, action: #selector(undoMenuAction), keyEquivalent: "z")
        undoItem.target = self
        let redoItem = editMenu.addItem(withTitle: "重做".localized, action: #selector(redoMenuAction), keyEquivalent: "z")
        redoItem.target = self
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切".localized, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝".localized, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴".localized, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选".localized, action: #selector(NSStandardKeyBindingResponding.selectAll(_:)), keyEquivalent: "a")

        // 显示
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示".localized)
        viewItem.submenu = viewMenu
        add(viewMenu, "在当前位置搜索…", #selector(searchCurrentLocationAction), "f", [.command])
        add(viewMenu, "全局搜索…", #selector(searchGlobalAction), "f", [.command, .shift])
        viewMenu.addItem(.separator())
        add(viewMenu, "以列表显示", #selector(listModeAction), "1", [.command])
        add(viewMenu, "以图标显示", #selector(iconModeAction), "2", [.command])
        add(viewMenu, "以分栏显示", #selector(columnModeAction), "3", [.command])
        viewMenu.addItem(.separator())
        add(viewMenu, "查看显示选项…", #selector(showDisplayOptionsAction), "j", [.command])
        add(viewMenu, "显示隐藏文件", #selector(toggleHiddenAction), ".", [.command, .shift])
        add(viewMenu, "切换侧栏", #selector(toggleSidebarAction), "s", [.command, .option])

        // 前往
        let goItem = NSMenuItem()
        mainMenu.addItem(goItem)
        let goMenu = NSMenu(title: "前往".localized)
        goItem.submenu = goMenu
        add(goMenu, "上一层", #selector(goUpAction), "\u{1e}", [.command])
        add(goMenu, "后退", #selector(goBackAction), "[", [.command])
        add(goMenu, "前进", #selector(goForwardAction), "]", [.command])
        add(goMenu, "编辑路径", #selector(editPathAction), "l", [.command])
        goMenu.addItem(.separator())
        for (title, key) in [("主目录", "h"), ("桌面", "d"), ("下载", "l"), ("应用程序", "a")] {
            let item = NSMenuItem(title: title.localized, action: #selector(goToStandardFolder(_:)), keyEquivalent: key)
            item.target = self
            item.keyEquivalentModifierMask = [.command, .shift]
            item.representedObject = key
            goMenu.addItem(item)
        }
        goMenu.addItem(.separator())
        add(goMenu, "连接服务器…", #selector(connectServerAction), "k", [.command])

        // 窗格
        let paneItem = NSMenuItem()
        mainMenu.addItem(paneItem)
        let paneMenu = NSMenu(title: "窗格".localized)
        paneItem.submenu = paneMenu
        add(paneMenu, "下一个窗格", #selector(nextPaneAction), "\u{9}", [.command])
        paneMenu.addItem(.separator())
        for mode in LayoutMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(layoutPicked(_:)), keyEquivalent: "")
            item.target = self
            item.image = mode.icon
            item.representedObject = mode.rawValue
            if let key = Self.layoutShortcut(for: mode) {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = [.command, .option]
            }
            paneMenu.addItem(item)
        }

        // 窗口
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口".localized)
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化".localized, action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放".localized, action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "关闭窗口".localized, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func handleLanguageDidChange() {
        buildMenu()
        updateLayoutButton()
    }

    /// ⌥⌘1–4 给最常用的四种布局，其余布局只能从菜单或工具条图标条里选。
    private static func layoutShortcut(for mode: LayoutMode) -> String? {
        switch mode {
        case .single: return "1"
        case .dualV: return "2"
        case .dualH: return "3"
        case .quad: return "4"
        default: return nil
        }
    }

    @discardableResult
    private func add(_ menu: NSMenu,
                     _ title: String,
                     _ action: Selector,
                     _ key: String,
                     _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title.localized, action: action, keyEquivalent: key)
        item.target = self
        if !modifiers.isEmpty { item.keyEquivalentModifierMask = modifiers }
        menu.addItem(item)
        return item
    }

    // MARK: 动作

    @objc private func quitAppAction() {
        NSApp.terminate(nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(quitAppAction) || menuItem.action == #selector(NSApplication.terminate(_:)) {
            return true
        }
        return true
    }

    private func pane() -> PaneView? { workspace?.focusedPane }

    @objc private func newFolderAction() { pane()?.createFolder() }
    @objc private func renameAction() { pane()?.renameSelected() }
    @objc private func trashAction() { pane()?.trashSelected() }

    @objc private func undoMenuAction() {
        if let responder = NSApp.keyWindow?.firstResponder,
           (responder is NSTextView || responder is NSTextField) {
            if NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) {
                return
            }
        }
        if isSidebarFocused() {
            if sidebar?.undoTagDeletion() == true {
                return
            }
        }
        workspace?.undoAction()
    }

    private func isSidebarFocused() -> Bool {
        guard let sidebar else { return false }
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: sidebar)
    }

    @objc private func redoMenuAction() {
        if let responder = NSApp.keyWindow?.firstResponder,
           (responder is NSTextView || responder is NSTextField) {
            if NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) {
                return
            }
        }
        workspace?.redoAction()
    }
    @objc private func copyPathAction() { pane()?.copyPath() }
    @objc private func terminalAction() { pane()?.openInTerminal() }
    @objc private func revealAction() { pane()?.revealInFinder() }
    @objc private func refreshAction() { pane()?.reload() }
    @objc private func infoAction() { pane()?.showInfo() }
    @objc private func goUpAction() { pane()?.goUp() }
    @objc private func goBackAction() { pane()?.goBack() }
    @objc private func goForwardAction() { pane()?.goForward() }
    @objc private func editPathAction() { pane()?.beginEditingPath() }
    @objc private func searchGlobalAction() {
        guard let window else { return }
        openSearchPanel(in: window, isCurrentFolder: false)
    }

    @objc private func searchCurrentLocationAction() {
        guard let window else { return }
        openSearchPanel(in: window, isCurrentFolder: true)
    }

    @objc private func searchAction() {
        searchGlobalAction()
    }

    @objc private func listModeAction() { pane()?.viewMode = .list }
    @objc private func iconModeAction() { pane()?.viewMode = .icons }
    @objc private func columnModeAction() { pane()?.viewMode = .columns }

    @objc private func sortPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let field = SortField(rawValue: raw) else { return }
        pane()?.applySort(field)
    }

    @objc private func orderPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        pane()?.applyAscending(raw == "asc")
    }

    @objc private func groupPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = GroupMode(rawValue: raw) else { return }
        pane()?.applyGroup(mode)
    }

    @objc private func quickLookAction() {
        pane()?.requestQuickLook()
    }

    /// 把选中的项目（没有选中就用当前目录）在另一个窗格里打开。
    @objc private func openSelectionInOtherPane() {
        guard let pane = pane() else { return }
        let url = pane.currentSelection().first?.url ?? pane.currentURL
        workspace?.openInOtherPane(url)
    }

    @objc private func showDisplayOptionsAction() {
        showDisplayOptions(anchoredTo: moreButton)
    }

    /// 统一打开搜索浮层，并设定搜索范围（保留上一次搜索状态，不重置）。
    private func openSearchPanel(in window: NSWindow, isCurrentFolder: Bool) {
        if let controller = searchController {
            if controller.isVisible {
                controller.setScope(isCurrentFolder: isCurrentFolder)
                return
            }
            controller.setScope(isCurrentFolder: isCurrentFolder)
            controller.show(anchoredTo: searchButton, in: window)
            return
        }
        let controller = SearchPanelController()
        controller.currentFolderProvider = { [weak self] in
            self?.workspace?.focusedPane?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        }
        controller.onPick = { [weak self] url in
            guard let self else { return }
            if let pane = self.workspace?.focusedPane ?? self.workspace?.panes.first {
                pane.activate()
                pane.reveal(url)
            }
        }
        controller.onOpenSettings = { [weak self] in
            self?.showSettingsAction()
        }
        searchController = controller
        controller.setScope(isCurrentFolder: isCurrentFolder)
        controller.show(anchoredTo: searchButton, in: window)
    }

    /// 顶部放大镜按钮点击
    @objc private func showSearchPanel(_ sender: NSButton) {
        guard let window else { return }
        if let controller = searchController, controller.isVisible {
            controller.close()
            return
        }
        openSearchPanel(in: window, isCurrentFolder: false)
    }

    /// 打开设置与权限管理窗口（支持重置被误拒的系统文件夹权限并立即重新触发授权弹窗）。
    @objc private func showSettingsAction() {
        if settingsController == nil {
            let ctrl = SettingsWindowController()
            ctrl.onSettingsChanged = { [weak self] in
                self?.workspace?.reloadAll()
            }
            ctrl.onIconSizeChanged = { [weak self] size in
                self?.workspace?.applyIconSize(size)
            }
            ctrl.onRowHeightChanged = { [weak self] height in
                self?.workspace?.applyRowHeight(height)
            }
            settingsController = ctrl
        }
        settingsController?.show(relativeTo: window)
    }

    /// 检查应用更新
    @objc private func checkForUpdatesAction() {
        UpdateChecker.shared.checkForUpdates(isUserInitiated: true)
    }

    @objc private func connectServerAction() {
        showConnectServerWindow(initialEntry: nil)
    }

    private func showConnectServerWindow(initialEntry: ServerEntry?) {
        ServerConnectWindowController.shared.show(relativeTo: window, initialEntry: initialEntry)
    }

    private func showDisplayOptions(anchoredTo anchor: NSButton?) {
        if let popover = displayOptionsPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let controller = DisplayOptionsViewController(iconSize: AppSettings.gridIconSize,
                                                     rowHeight: AppSettings.listRowHeight,
                                                     showHidden: AppSettings.showHidden)
        controller.onIconSize = { [weak self] size in
            AppSettings.gridIconSize = size
            self?.workspace?.applyIconSize(size)
        }
        controller.onRowHeight = { [weak self] height in
            AppSettings.listRowHeight = height
            self?.workspace?.applyRowHeight(height)
        }
        controller.onShowHidden = { [weak self] show in
            AppSettings.showHidden = show
            self?.workspace?.reloadAll()
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 264, height: 210)
        if let anchor {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let content = window.contentView {
            popover.show(relativeTo: content.bounds, of: content, preferredEdge: .minY)
        }
        displayOptionsPopover = popover
    }

    // MARK: 顶部「更多」菜单

    @objc private func showActionMenu(_ sender: NSButton) {
        guard let pane = workspace?.focusedPane, let window = sender.window else { return }
        let menu = makeActionMenu(for: pane)
        // 用屏幕坐标锚定按钮下沿，避免菜单盖住工具栏
        let onScreen = window.convertToScreen(sender.convert(sender.bounds, to: nil))
        menu.popUp(positioning: nil,
                   at: NSPoint(x: onScreen.minX, y: onScreen.minY - 6),
                   in: nil)
    }

    /// 与访达顶部省略号菜单一致：常用操作 + 分组 / 排序 / 显示选项。
    private func makeActionMenu(for pane: PaneView) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let newFolder = NSMenuItem(title: "新建文件夹".localized, action: #selector(newFolderAction), keyEquivalent: "")
        newFolder.target = self
        newFolder.isEnabled = !pane.isTagView
        menu.addItem(newFolder)

        let openOther = NSMenuItem(title: "在新窗格中打开".localized, action: #selector(openSelectionInOtherPane), keyEquivalent: "")
        openOther.target = self
        openOther.isEnabled = (workspace?.panes.count ?? 1) > 1
        menu.addItem(openOther)

        menu.addItem(.separator())

        let info = NSMenuItem(title: "显示简介".localized, action: #selector(infoAction), keyEquivalent: "")
        info.target = self
        menu.addItem(info)

        let quickLook = NSMenuItem(title: "快速查看“\(pane.menuTargetName)”",
                                   action: #selector(quickLookAction),
                                   keyEquivalent: "")
        quickLook.target = self
        // 标签视图没有选中项时，快速查看没有明确对象
        quickLook.isEnabled = !(pane.isTagView && pane.currentSelection().isEmpty)
        menu.addItem(quickLook)

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

        let options = NSMenuItem(title: "查看显示选项…".localized, action: #selector(showDisplayOptionsAction), keyEquivalent: "")
        options.target = self
        menu.addItem(options)

        let settingsItem = NSMenuItem(title: "设置与权限管理…".localized, action: #selector(showSettingsAction), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let connectServerItem = NSMenuItem(title: "连接服务器…".localized, action: #selector(connectServerAction), keyEquivalent: "")
        connectServerItem.target = self
        menu.addItem(connectServerItem)

        let updateItem = NSMenuItem(title: "检查更新…".localized, action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let hidden = NSMenuItem(title: AppSettings.showHidden ? "隐藏隐藏文件".localized : "显示隐藏文件".localized,
                                action: #selector(toggleHiddenAction),
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
            let item = NSMenuItem(title: mode.title, action: #selector(layoutPicked(_:)), keyEquivalent: "")
            item.target = self
            item.image = mode.icon
            item.representedObject = mode.rawValue
            item.state = mode == workspace?.mode ? .on : .off
            layoutMenu.addItem(item)
        }
        layoutItem.submenu = layoutMenu
        menu.addItem(layoutItem)

        return menu
    }

    @objc private func toggleHiddenAction() {
        AppSettings.showHidden.toggle()
        workspace?.reloadAll()
    }

    @objc private func toggleSidebarAction() {
        sidebar.isHidden.toggle()
        sidebarSplitterRef?.isHidden = sidebar.isHidden
    }

    @objc private func nextPaneAction() {
        guard let workspace, workspace.panes.count > 1 else { return }
        let panes = workspace.panes
        guard let current = workspace.focusedPane,
              let index = panes.firstIndex(where: { $0 === current }) else {
            workspace.setFocused(panes.first)
            return
        }
        workspace.setFocused(panes[(index + 1) % panes.count])
    }

    @objc private func goToStandardFolder(_ sender: NSMenuItem) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let mapping: [String: URL] = [
            "h": home,
            "d": home.appendingPathComponent("Desktop"),
            "l": home.appendingPathComponent("Downloads"),
            "a": URL(fileURLWithPath: "/Applications")
        ]
        guard let key = sender.representedObject as? String, let url = mapping[key] else { return }
        workspace?.openInFocusedPane(url)
    }

    // MARK: Quick Look

    private func toggleQuickLook(for pane: PaneView) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let selection = pane.currentSelection().map { $0.url }
        // 与访达一致：没有选中项时快速查看当前文件夹
        let urls = selection.isEmpty ? [pane.currentURL] : selection
        previewItems = urls
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
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
        backButton.toolTip = "后退".localized

        forwardButton.image = Theme.symbol("chevron.right", size: 15, weight: .semibold)
        forwardButton.target = self
        forwardButton.action = #selector(forwardTapped)
        forwardButton.toolTip = "前进".localized

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
        (.list, ToolbarViewModeView.makeButton("list.bullet", "列表")),
        (.icons, ToolbarViewModeView.makeButton("square.grid.2x2", "图标")),
        (.columns, ToolbarViewModeView.makeButton("rectangle.split.3x1", "分栏"))
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

// MARK: - Quick Look 数据源

extension AppDelegate: QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index < previewItems.count else { return nil }
        return previewItems[index] as NSURL
    }
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
