import AppKit
import Quartz

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    static weak var shared: AppDelegate?

    private(set) var windowControllers: [MainWindowController] = []

    var activeController: MainWindowController? {
        if let keyWin = NSApp.keyWindow, let ctrl = keyWin.windowController as? MainWindowController {
            return ctrl
        }
        if let mainWin = NSApp.mainWindow, let ctrl = mainWin.windowController as? MainWindowController {
            return ctrl
        }
        return windowControllers.last
    }

    private var settingsController: SettingsWindowController?

    override init() {
        super.init()
        Self.shared = self
    }

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.applyAppearance()
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }
        NotificationCenter.default.addObserver(self, selector: #selector(handleLanguageDidChange), name: .languageDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleOpenTerminalSettingsRequested), name: .openTerminalSettingsRequested, object: nil)
        
        ServerConnectWindowController.shared.onServersChanged = { [weak self] in
            self?.windowControllers.forEach { $0.sidebar.reload() }
        }
        ServerConnectWindowController.shared.onOpenDirectory = { [weak self] url in
            self?.activeController?.workspace.openInFocusedPane(url)
        }

        buildMenu()
        _ = createMainWindow(openURL: nil)

        // 启动 3 秒后后台静默检查一次新版本（仅当有新版时温和提示）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            UpdateChecker.shared.checkForUpdates(isUserInitiated: false)
        }
        FileSearchEngine.shared.loadIndex()

        // 确保在主运行循环完成启动阶段后，主窗口必定处于前台并可见
        DispatchQueue.main.async { [weak self] in
            self?.reopenMainWindowAction()
        }

        // 全局键盘与鼠标监听：支持 ⌘Q 立即退出、鼠标前进后退侧键、浏览器一致的前进后退快捷键，以及 Windows 习惯的 Ctrl+Z / Ctrl+Shift+Z
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown, .otherMouseUp]) { [weak self] event in
            if event.type == .otherMouseDown {
                if event.buttonNumber == 3 || event.buttonNumber == 4 {
                    let targetController = (event.window?.windowController as? MainWindowController) ?? self?.activeController
                    targetController?.handleMouseNavigation(buttonNumber: event.buttonNumber, location: event.locationInWindow)
                    return nil
                }
            } else if event.type == .otherMouseUp {
                if event.buttonNumber == 3 || event.buttonNumber == 4 {
                    return nil
                }
            } else if event.type == .keyDown {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let chars = event.charactersIgnoringModifiers ?? ""
                if flags == [.command] && (chars.lowercased() == "q" || event.keyCode == 12) {
                    NSApp.terminate(nil)
                    return nil
                }

                let isEditingText: Bool = {
                    if let responder = NSApp.keyWindow?.firstResponder,
                       (responder is NSTextView || responder is NSTextField) {
                        return true
                    }
                    if InlineRenameField.activeField != nil {
                        return true
                    }
                    return false
                }()

                let isUndoKey = ((flags == [.control] || flags == [.command]) && chars == "z")
                if isUndoKey {
                    if isEditingText {
                        if NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) {
                            return nil
                        }
                    }
                    if self?.activeController?.isSidebarFocused() == true {
                        if self?.activeController?.sidebar.undoTagDeletion() == true {
                            return nil
                        }
                    }
                    if flags == [.control] {
                        self?.activeController?.workspace.undoAction()
                        return nil
                    }
                } else if flags == [.control, .shift] && chars == "z" {
                    if isEditingText {
                        if NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) {
                            return nil
                        }
                    }
                    self?.activeController?.workspace.redoAction()
                    return nil
                }

                // 前进与后退快捷键（保持与浏览器一致）：
                // 后退：⌘[、⌘←（Cmd+左箭头）、⌥←（Option/Alt+左箭头）
                // 前进：⌘]、⌘→（Cmd+右箭头）、⌥→（Option/Alt+右箭头）
                if !isEditingText {
                    let isBackShortcut = (flags == [.command] && (chars == "[" || event.keyCode == 123))
                        || (flags == [.option] && event.keyCode == 123)
                    if isBackShortcut {
                        self?.activeController?.goBackAction()
                        return nil
                    }

                    let isForwardShortcut = (flags == [.command] && (chars == "]" || event.keyCode == 124))
                        || (flags == [.option] && event.keyCode == 124)
                    if isForwardShortcut {
                        self?.activeController?.goForwardAction()
                        return nil
                    }
                }
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

    // MARK: - 多窗口创建与管理

    @discardableResult
    func createMainWindow(openURL: URL? = nil) -> MainWindowController {
        let frame: NSRect
        if let activeWin = activeController?.window, activeWin.isVisible {
            var cascadeFrame = activeWin.frame.offsetBy(dx: 28, dy: -28)
            let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(cascadeFrame) }) ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                if cascadeFrame.minY < visible.minY || cascadeFrame.maxX > visible.maxX {
                    cascadeFrame.origin.x = visible.minX + 28
                    cascadeFrame.origin.y = visible.maxY - cascadeFrame.height - 28
                }
            }
            frame = cascadeFrame
        } else {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let width = min(1320, max(760, visible.width - 80))
            let height = min(860, max(480, visible.height - 80))
            let defaultFrame = NSRect(x: visible.minX + (visible.width - width) / 2,
                                      y: visible.minY + (visible.height - height) / 2,
                                      width: width,
                                      height: height)
            if let saved = AppSettings.windowFrame {
                let rect = NSRectFromString(saved)
                if rect.width >= 700, rect.height >= 420,
                   NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                    frame = rect
                } else {
                    frame = defaultFrame
                }
            } else {
                frame = defaultFrame
            }
        }

        let controller = MainWindowController(initialURL: openURL, frame: frame)
        windowControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        return controller
    }

    func removeWindowController(_ controller: MainWindowController) {
        windowControllers.removeAll { $0 === controller }
    }

    // MARK: - 程序坞菜单（Dock 右键菜单）

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newWindowItem = NSMenuItem(title: "打开新的窗口".localized, action: #selector(openNewWindowAction), keyEquivalent: "")
        newWindowItem.target = self
        menu.addItem(newWindowItem)
        return menu
    }

    @objc func openNewWindowAction() {
        createMainWindow(openURL: nil)
    }

    // MARK: - 外部打开文件/文件夹处理（作为默认文件管理器）

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        guard let first = filenames.first else { return }
        let url = URL(fileURLWithPath: first)
        handleExternalOpen(url: url)
        application.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        handleExternalOpen(url: first)
    }

    private func handleExternalOpen(url: URL) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let targetFolder: URL
        let selectTarget: URL?
        if exists {
            if isDir.boolValue {
                targetFolder = url
                selectTarget = nil
            } else {
                targetFolder = url.deletingLastPathComponent().standardizedFileURL
                selectTarget = url.standardizedFileURL
            }
        } else {
            targetFolder = url
            selectTarget = nil
        }

        let mode = AppSettings.externalFolderOpenMode
        if mode == "window" || windowControllers.isEmpty {
            let ctrl = createMainWindow(openURL: targetFolder)
            if let selectTarget {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    ctrl.workspace.focusedPane?.select(urls: [selectTarget])
                }
            }
        } else {
            guard let ctrl = activeController else {
                let newCtrl = createMainWindow(openURL: targetFolder)
                if let selectTarget {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        newCtrl.workspace.focusedPane?.select(urls: [selectTarget])
                    }
                }
                return
            }
            if ctrl.window?.isMiniaturized == true {
                ctrl.window?.deminiaturize(nil)
            }
            ctrl.window?.makeKeyAndOrderFront(nil)
            ctrl.window?.orderFrontRegardless()
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

            ctrl.workspace.openInFocusedPane(targetFolder)
            ctrl.sidebar.select(url: targetFolder)
            ctrl.updateNavTitle()
            if let selectTarget {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    ctrl.workspace.focusedPane?.select(urls: [selectTarget])
                }
            }
        }
    }

    @objc func reopenMainWindowAction() {
        if windowControllers.isEmpty {
            createMainWindow(openURL: nil)
            return
        }
        guard let window = activeController?.window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    func applicationWillTerminate(_ notification: Notification) {
        activeController?.workspace.saveState()
        if let frame = activeController?.window?.frame {
            AppSettings.windowFrame = NSStringFromRect(frame)
        }
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
        add(fileMenu, "新建窗口", #selector(openNewWindowAction), "n", [.command])
        add(fileMenu, "新建文件夹", #selector(newFolderAction), "n", [.command, .shift])
        add(fileMenu, "重命名", #selector(renameAction), "", [])
        add(fileMenu, "制作副本", #selector(duplicateAction), "d", [.command])
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
        editMenu.addItem(withTitle: "剪切".localized, action: #selector(cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝".localized, action: #selector(copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴".localized, action: #selector(paste(_:)), keyEquivalent: "v")
        let dupEditItem = editMenu.addItem(withTitle: "复制".localized, action: #selector(duplicateAction), keyEquivalent: "d")
        dupEditItem.target = self
        editMenu.addItem(withTitle: "全选".localized, action: #selector(selectAll(_:)), keyEquivalent: "a")

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
        windowControllers.forEach {
            $0.updateLayoutButton()
            $0.updateNavTitle()
            $0.sidebar.reload()
        }
    }

    @objc private func handleOpenTerminalSettingsRequested() {
        showSettings(category: "general")
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
        if menuItem.action == #selector(copy(_:)) || menuItem.action == #selector(cut(_:)) || menuItem.action == #selector(duplicateAction) {
            if let _ = NSApp.keyWindow?.firstResponder as? NSText { return true }
            return !(pane()?.currentSelection().isEmpty ?? true)
        }
        if menuItem.action == #selector(paste(_:)) {
            if let _ = NSApp.keyWindow?.firstResponder as? NSText { return true }
            return pane()?.hasPasteableFiles == true
        }
        return true
    }

    private func pane() -> PaneView? { activeController?.pane() }

    @objc func duplicateAction() { pane()?.contextDuplicate() }

    @objc func copy(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSText {
            editor.copy(sender)
        } else {
            pane()?.copySelection()
        }
    }

    @objc func cut(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSText {
            editor.cut(sender)
        } else {
            pane()?.cutSelection()
        }
    }

    @objc func paste(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSText {
            editor.paste(sender)
        } else {
            pane()?.paste()
        }
    }

    @objc func selectAll(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSText {
            editor.selectAll(sender)
        } else {
            pane()?.selectAll()
        }
    }

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
        if activeController?.isSidebarFocused() == true {
            if activeController?.sidebar.undoTagDeletion() == true {
                return
            }
        }
        activeController?.workspace.undoAction()
    }

    @objc private func redoMenuAction() {
        if let responder = NSApp.keyWindow?.firstResponder,
           (responder is NSTextView || responder is NSTextField) {
            if NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) {
                return
            }
        }
        activeController?.workspace.redoAction()
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
        activeController?.openSearchPanel(isCurrentFolder: false)
    }

    @objc private func searchCurrentLocationAction() {
        activeController?.openSearchPanel(isCurrentFolder: true)
    }

    @objc private func searchAction() {
        searchGlobalAction()
    }

    @objc private func listModeAction() {
        activeController?.listModeAction()
    }

    @objc private func iconModeAction() {
        activeController?.iconModeAction()
    }

    @objc private func columnModeAction() {
        activeController?.columnModeAction()
    }

    @objc private func layoutPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = LayoutMode(rawValue: raw) else { return }
        activeController?.setLayoutMode(mode)
    }

    @objc private func showDisplayOptionsAction() {
        activeController?.showDisplayOptions()
    }

    @objc private func showSettingsAction() {
        showSettings(category: nil)
    }

    func showSettings(category: String? = nil) {
        if settingsController == nil {
            let ctrl = SettingsWindowController()
            ctrl.onSettingsChanged = { [weak self] in
                self?.windowControllers.forEach { $0.workspace.reloadAll() }
            }
            ctrl.onIconSizeChanged = { [weak self] size in
                self?.windowControllers.forEach { $0.workspace.applyIconSize(size) }
            }
            ctrl.onRowHeightChanged = { [weak self] height in
                self?.windowControllers.forEach { $0.workspace.applyRowHeight(height) }
            }
            settingsController = ctrl
        }
        settingsController?.show(relativeTo: activeController?.window, categoryId: category)
    }

    @objc private func checkForUpdatesAction() {
        UpdateChecker.shared.checkForUpdates(isUserInitiated: true)
    }

    @objc private func connectServerAction() {
        showConnectServerWindow(initialEntry: nil)
    }

    func showConnectServerWindow(initialEntry: ServerEntry?) {
        ServerConnectWindowController.shared.show(relativeTo: activeController?.window, initialEntry: initialEntry)
    }

    @objc private func toggleHiddenAction() {
        AppSettings.showHidden.toggle()
        windowControllers.forEach { $0.workspace.reloadAll() }
    }

    @objc private func toggleSidebarAction() {
        activeController?.toggleSidebar()
    }

    @objc private func nextPaneAction() {
        activeController?.nextPane()
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
        activeController?.workspace.openInFocusedPane(url)
    }
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
