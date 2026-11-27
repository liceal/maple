import AppKit

/// 设置与权限管理窗口控制器（匹配 原生设置界面布局，支持分类侧边栏与多面板切换）。
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    var onSettingsChanged: (() -> Void)?
    var onIconSizeChanged: ((CGFloat) -> Void)?
    var onRowHeightChanged: ((CGFloat) -> Void)?

    private let window: NSWindow
    private var sidebarTable: NSTableView!
    private var rightContainer: NSView!
    private var categoryViews: [String: NSView] = [:]

    // MARK: - 常规设置控件
    private var appearanceRadios: [NSButton] = []
    private var languageRadios: [NSButton] = []
    private var sidebarIconRadios: [NSButton] = []
    private var sidebarIconStyleRadios: [NSButton] = []
    private var cornerSchemeRadios: [NSButton] = []
    private let showPaneBorderCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let highlightPaneAddressBarCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let keepPaneCornerRadiusCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let showItemInfoCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let hideBottomStatusBarCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let showSelectedSizeCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let calculateFolderSizesCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let hiddenCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let zebraCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let iconSizeSlider = NSSlider()
    private let iconSizeValueLabel = NSTextField(labelWithString: "")
    private let rowHeightSlider = NSSlider()
    private let rowHeightValueLabel = NSTextField(labelWithString: "")
    private var terminalPopUpButton: NSPopUpButton?
    private var defaultManagerStatusLabel = NSTextField(labelWithString: "")
    private var setDefaultManagerBtn = NSButton()
    private var restoreFinderBtn = NSButton()
    private var externalOpenRadios: [NSButton] = []

    // MARK: - 权限管理控件
    private var permissionRows: [PermissionItemRow] = []
    private let statusBanner = NSTextField(labelWithString: "")

    // MARK: - 搜索管理控件
    private let indexStatusLabel = NSTextField(labelWithString: "")
    private let indexSizeLabel = NSTextField(labelWithString: "")
    private let rebuildIndexButton = NSButton()
    private let revealCacheButton = NSButton()

    // MARK: - 分类列表定义
    struct CategoryItem {
        let id: String
        let title: String
        let iconName: String
        let iconColor: NSColor
    }

    private var categories: [CategoryItem] {
        [
            CategoryItem(id: "general", title: "常规".localized, iconName: "macwindow.on.rectangle", iconColor: .systemBlue),
            CategoryItem(id: "habits", title: "使用习惯".localized, iconName: "gearshape", iconColor: .systemGray),
            CategoryItem(id: "permissions", title: "权限".localized, iconName: "checkmark.shield.fill", iconColor: .systemGreen),
            CategoryItem(id: "search", title: "搜索".localized, iconName: "magnifyingglass", iconColor: .systemOrange),
            CategoryItem(id: "contextMenu", title: "右键菜单".localized, iconName: "filemenu.and.selection", iconColor: .systemIndigo),
            CategoryItem(id: "newFile", title: "新建文件".localized, iconName: "doc.badge.plus", iconColor: .systemGreen),
            CategoryItem(id: "shortcuts", title: "快捷键".localized, iconName: "command", iconColor: .systemPurple),
            CategoryItem(id: "about", title: "版本".localized, iconName: "info.circle.fill", iconColor: .systemPurple)
        ]
    }

    struct PermissionTarget {
        let id: String
        let title: String
        let subtitle: String
        let url: URL
        let tccService: String
        let isFullDisk: Bool
    }

    private var targets: [PermissionTarget] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            PermissionTarget(
                id: "desktop",
                title: "桌面文件夹 (Desktop)".localized,
                subtitle: "~/Desktop",
                url: home.appendingPathComponent("Desktop"),
                tccService: "SystemPolicyDesktopFolder",
                isFullDisk: false
            ),
            PermissionTarget(
                id: "documents",
                title: "文稿文件夹 (Documents)".localized,
                subtitle: "~/Documents",
                url: home.appendingPathComponent("Documents"),
                tccService: "SystemPolicyDocumentsFolder",
                isFullDisk: false
            ),
            PermissionTarget(
                id: "downloads",
                title: "下载文件夹 (Downloads)".localized,
                subtitle: "~/Downloads",
                url: home.appendingPathComponent("Downloads"),
                tccService: "SystemPolicyDownloadsFolder",
                isFullDisk: false
            ),
            PermissionTarget(
                id: "fulldisk",
                title: "完全磁盘访问权限 (Full Disk Access)".localized,
                subtitle: "用于完整同步访达标签、访问废纸篓及全局搜索受保护目录（可选）".localized,
                url: home.appendingPathComponent("Library/Safari"),
                tccService: "SystemPolicyAllFiles",
                isFullDisk: true
            )
        ]
    }

    override init() {
        let rect = NSRect(x: 0, y: 0, width: 760, height: 570)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "设置".localized
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildUI()
        NotificationCenter.default.addObserver(forName: .sidebarIconStyleDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.syncDisplayControls()
        }
        NotificationCenter.default.addObserver(forName: .sidebarIconSizeDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.syncDisplayControls()
        }
        NotificationCenter.default.addObserver(forName: .languageDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.handleLanguageDidChange()
        }
        NotificationCenter.default.addObserver(forName: .defaultFileManagerDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateDefaultManagerStatus()
        }
    }

    private func handleLanguageDidChange() {
        window.title = "设置".localized
        let selectedRow = sidebarTable.selectedRow
        let currentId = (selectedRow >= 0 && selectedRow < categories.count) ? categories[selectedRow].id : "general"
        categoryViews.removeAll()
        sidebarTable.reloadData()
        if selectedRow >= 0 && selectedRow < categories.count {
            sidebarTable.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        }
        showCategory(id: currentId)
        syncDisplayControls()
    }

    func show(relativeTo parentWindow: NSWindow?, categoryId: String? = nil) {
        window.appearance = NSApp.appearance
        refreshPermissionStatuses()
        refreshIndexCount()
        syncDisplayControls()
        populateTerminalPopUp()

        if let categoryId, let idx = categories.firstIndex(where: { $0.id == categoryId }) {
            sidebarTable.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            showCategory(id: categoryId)
        }

        if let parent = parentWindow {
            let pf = parent.frame
            let wf = window.frame
            let x = pf.midX - wf.width / 2
            let y = pf.midY - wf.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshPermissionStatuses()
        refreshIndexCount()
    }

    // MARK: - 布局构建

    private func buildUI() {
        let root = NSView()
        root.wantsLayer = true
        window.contentView = root

        // 左侧分类列表容器（带有半透明背景与右分隔线）
        let sidebarContainer = NSView()
        sidebarContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.wantsLayer = true
        root.addSubview(sidebarContainer)

        let sidebarScroll = NSScrollView()
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.backgroundColor = .clear
        sidebarScroll.scrollerStyle = .overlay
        sidebarScroll.verticalScroller = SubtleScroller()
        sidebarContainer.addSubview(sidebarScroll)

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .none
        table.target = self
        table.action = #selector(tableRowClicked)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CategoryColumn"))
        col.isEditable = false
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        self.sidebarTable = table
        sidebarScroll.documentView = table

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        root.addSubview(separator)

        // 右侧内容区容器
        let right = NSView()
        right.translatesAutoresizingMaskIntoConstraints = false
        right.wantsLayer = true
        root.addSubview(right)
        self.rightContainer = right

        NSLayoutConstraint.activate([
            sidebarContainer.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarContainer.widthAnchor.constraint(equalToConstant: 175),

            sidebarScroll.topAnchor.constraint(equalTo: sidebarContainer.topAnchor, constant: 12),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 8),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -8),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor, constant: -12),

            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            right.topAnchor.constraint(equalTo: root.topAnchor),
            right.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            right.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        // 默认选中第一项「常规」
        sidebarTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showCategory(id: categories[0].id)
    }

    // MARK: - NSTableView 代理与数据源

    func numberOfRows(in tableView: NSTableView) -> Int {
        categories.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("CategoryRowView")
        let rowView = (tableView.makeView(withIdentifier: identifier, owner: self) as? CategoryRowView)
            ?? CategoryRowView()
        rowView.identifier = identifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = categories[row]
        let identifier = NSUserInterfaceItemIdentifier("CategoryCellView")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? CategoryCellView)
            ?? CategoryCellView(item: item)
        cell.identifier = identifier
        cell.configure(with: item)
        return cell
    }

    @objc private func tableRowClicked() {
        let row = sidebarTable.clickedRow
        guard row >= 0 && row < categories.count else { return }
        sidebarTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        showCategory(id: categories[row].id)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarTable.selectedRow
        guard row >= 0 && row < categories.count else { return }
        showCategory(id: categories[row].id)
    }

    private func showCategory(id: String) {
        let targetView: NSView
        if let existing = categoryViews[id] {
            targetView = existing
        } else {
            let created = createCategoryView(id: id)
            categoryViews[id] = created
            targetView = created
        }

        rightContainer.subviews.forEach { $0.removeFromSuperview() }
        targetView.translatesAutoresizingMaskIntoConstraints = false
        rightContainer.addSubview(targetView)

        NSLayoutConstraint.activate([
            targetView.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            targetView.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            targetView.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            targetView.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor)
        ])
    }

    // MARK: - 右侧面板工厂

    private func createCategoryView(id: String) -> NSView {
        switch id {
        case "general":
            return buildGeneralPanelView()
        case "habits":
            return buildHabitsPanelView()
        case "permissions":
            return buildPermissionsPanelView()
        case "search":
            return buildSearchPanelView()
        case "contextMenu":
            return buildContextMenuPanelView()
        case "newFile":
            return buildNewFilePanelView()
        case "shortcuts":
            return buildShortcutsPanelView()
        case "about":
            return buildAboutPanelView()
        default:
            return buildPlaceholderPanelView(category: categories.first { $0.id == id }?.title ?? id)
        }
    }

    // MARK: - 1. 常规设置面板 (完全匹配 原生设置界面)

    private func buildGeneralPanelView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        content.addSubview(stack)

        let labelWidth: CGFloat = 100

        // 外观：跟随系统 / 浅色 / 深色（单选按钮组）
        let radioSys = NSButton(radioButtonWithTitle: "跟随系统".localized, target: self, action: #selector(appearanceRadioSelected(_:)))
        let radioLight = NSButton(radioButtonWithTitle: "浅色".localized, target: self, action: #selector(appearanceRadioSelected(_:)))
        let radioDark = NSButton(radioButtonWithTitle: "深色".localized, target: self, action: #selector(appearanceRadioSelected(_:)))
        appearanceRadios = [radioSys, radioLight, radioDark]
        let appearanceGroup = makeControlRow(label: "外观：".localized, labelWidth: labelWidth, views: appearanceRadios)
        stack.addArrangedSubview(appearanceGroup)

        // 界面语言：跟随系统 / 简体中文 / English / 繁體中文 / 日本語
        let langSys = NSButton(radioButtonWithTitle: "跟随系统".localized, target: self, action: #selector(languageRadioSelected(_:)))
        let langZh = NSButton(radioButtonWithTitle: "简体中文", target: self, action: #selector(languageRadioSelected(_:)))
        let langEn = NSButton(radioButtonWithTitle: "English", target: self, action: #selector(languageRadioSelected(_:)))
        let langZht = NSButton(radioButtonWithTitle: "繁體中文", target: self, action: #selector(languageRadioSelected(_:)))
        let langJa = NSButton(radioButtonWithTitle: "日本語", target: self, action: #selector(languageRadioSelected(_:)))
        languageRadios = [langSys, langZh, langEn, langZht, langJa]
        let languageGroup = makeControlRow(label: "语言：".localized, labelWidth: labelWidth, views: languageRadios)
        stack.addArrangedSubview(languageGroup)

        // 默认终端工具：[Popup: Warp / 终端 (系统内置)...]
        let terminalPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        terminalPopUp.translatesAutoresizingMaskIntoConstraints = false
        terminalPopUp.target = self
        terminalPopUp.action = #selector(terminalPopUpChanged(_:))
        terminalPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        terminalPopUp.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        self.terminalPopUpButton = terminalPopUp
        populateTerminalPopUp()

        let terminalRow = makeControlRow(label: "默认终端：".localized, labelWidth: labelWidth, views: [terminalPopUp])
        stack.addArrangedSubview(terminalRow)

        // 默认文件管理器：[设为默认] [恢复访达] ● 已设为默认 [?]
        let setDefBtn = NSButton(title: "设为默认".localized, target: self, action: #selector(setDefaultManagerClicked))
        setDefBtn.bezelStyle = .rounded
        self.setDefaultManagerBtn = setDefBtn

        let restoreBtn = NSButton(title: "恢复访达".localized, target: self, action: #selector(restoreFinderClicked))
        restoreBtn.bezelStyle = .rounded
        self.restoreFinderBtn = restoreBtn

        defaultManagerStatusLabel.font = .systemFont(ofSize: 11.5)
        updateDefaultManagerStatus()

        let helpBtn = NSButton()
        helpBtn.bezelStyle = .helpButton
        helpBtn.title = ""
        helpBtn.target = self
        helpBtn.action = #selector(showDefaultManagerHelp(_:))
        helpBtn.toolTip = "点击查看默认文件管理器生效说明".localized

        let defManagerRow = makeControlRow(label: "默认管理器：".localized, labelWidth: labelWidth, views: [setDefBtn, restoreBtn, defaultManagerStatusLabel, helpBtn])
        stack.addArrangedSubview(defManagerRow)

        // 外部打开时：在新标签页打开 / 在新独立窗口打开
        let radioExtTab = NSButton(radioButtonWithTitle: "在新标签页打开".localized, target: self, action: #selector(externalOpenRadioSelected(_:)))
        let radioExtWindow = NSButton(radioButtonWithTitle: "在新独立窗口打开".localized, target: self, action: #selector(externalOpenRadioSelected(_:)))
        externalOpenRadios = [radioExtTab, radioExtWindow]
        let externalOpenRow = makeControlRow(label: "外部打开时：".localized, labelWidth: labelWidth, views: externalOpenRadios)
        stack.addArrangedSubview(externalOpenRow)

        // 边栏图标大小：小 / 中 / 大
        let iconSmall = NSButton(radioButtonWithTitle: "小".localized, target: self, action: #selector(sidebarIconRadioSelected(_:)))
        let iconMedium = NSButton(radioButtonWithTitle: "中".localized, target: self, action: #selector(sidebarIconRadioSelected(_:)))
        let iconLarge = NSButton(radioButtonWithTitle: "大".localized, target: self, action: #selector(sidebarIconRadioSelected(_:)))
        sidebarIconRadios = [iconSmall, iconMedium, iconLarge]
        let sidebarIconGroup = makeControlRow(label: "边栏图标大小：".localized, labelWidth: labelWidth, views: sidebarIconRadios)
        stack.addArrangedSubview(sidebarIconGroup)

        // 边栏图标风格：彩色图标 / 分区彩色 / 简约图标
        let styleColorful = NSButton(radioButtonWithTitle: "彩色图标".localized, target: self, action: #selector(sidebarIconStyleRadioSelected(_:)))
        let styleCategory = NSButton(radioButtonWithTitle: "分区彩色".localized, target: self, action: #selector(sidebarIconStyleRadioSelected(_:)))
        let styleMinimalist = NSButton(radioButtonWithTitle: "简约图标".localized, target: self, action: #selector(sidebarIconStyleRadioSelected(_:)))
        sidebarIconStyleRadios = [styleColorful, styleCategory, styleMinimalist]
        let sidebarStyleGroup = makeControlRow(label: "边栏图标风格：".localized, labelWidth: labelWidth, views: sidebarIconStyleRadios)
        stack.addArrangedSubview(sidebarStyleGroup)

        // 当前窗格：[x] 显示边框   [x] 高亮地址栏   [x] 圆角
        showPaneBorderCheckbox.title = "显示边框".localized
        showPaneBorderCheckbox.target = self
        showPaneBorderCheckbox.action = #selector(paneOptionToggled)
        highlightPaneAddressBarCheckbox.title = "高亮地址栏".localized
        highlightPaneAddressBarCheckbox.target = self
        highlightPaneAddressBarCheckbox.action = #selector(paneOptionToggled)
        keepPaneCornerRadiusCheckbox.title = "圆角".localized
        keepPaneCornerRadiusCheckbox.target = self
        keepPaneCornerRadiusCheckbox.action = #selector(paneOptionToggled)
        let paneRow = makeControlRow(label: "当前窗格：".localized, labelWidth: labelWidth, views: [
            showPaneBorderCheckbox, highlightPaneAddressBarCheckbox, keepPaneCornerRadiusCheckbox
        ])
        stack.addArrangedSubview(paneRow)

        // 圆角方案：( ) 顶栏高亮   ( ) 间距分块   (•) 无缝贴边
        let schemeNative = NSButton(radioButtonWithTitle: "顶栏高亮".localized, target: self, action: #selector(cornerSchemeRadioSelected(_:)))
        let schemeCards = NSButton(radioButtonWithTitle: "间距分块".localized, target: self, action: #selector(cornerSchemeRadioSelected(_:)))
        let schemeSmart = NSButton(radioButtonWithTitle: "无缝贴边".localized, target: self, action: #selector(cornerSchemeRadioSelected(_:)))
        cornerSchemeRadios = [schemeNative, schemeCards, schemeSmart]
        let schemeRow = makeControlRow(label: "圆角方案：".localized, labelWidth: labelWidth, views: cornerSchemeRadios)
        stack.addArrangedSubview(schemeRow)

        // 侧边预览：[x] 显示项目信息
        showItemInfoCheckbox.title = "显示项目信息".localized
        showItemInfoCheckbox.target = self
        showItemInfoCheckbox.action = #selector(itemInfoToggled)
        let previewRow = makeControlRow(label: "侧边预览：".localized, labelWidth: labelWidth, views: [showItemInfoCheckbox])
        stack.addArrangedSubview(previewRow)

        // 底部状态栏：[ ] 默认隐藏
        hideBottomStatusBarCheckbox.title = "默认隐藏".localized
        hideBottomStatusBarCheckbox.target = self
        hideBottomStatusBarCheckbox.action = #selector(bottomStatusBarToggled)
        let statusRow = makeControlRow(label: "底部状态栏：".localized, labelWidth: labelWidth, views: [hideBottomStatusBarCheckbox])
        stack.addArrangedSubview(statusRow)

        // 计算所有大小：[ ] 计算并显示文件夹大小
        calculateFolderSizesCheckbox.title = "计算并显示文件夹大小".localized
        calculateFolderSizesCheckbox.target = self
        calculateFolderSizesCheckbox.action = #selector(calcSizeToggled)
        let calcRow = makeControlRow(label: "计算所有大小：".localized, labelWidth: labelWidth, views: [calculateFolderSizesCheckbox])
        stack.addArrangedSubview(calcRow)

        // 隐藏文件：[x] 显示以点开头的隐藏文件
        hiddenCheckbox.title = "显示以点（.）开头的隐藏文件（快捷键 ⌘⇧.）".localized
        hiddenCheckbox.target = self
        hiddenCheckbox.action = #selector(hiddenToggled)
        let hiddenRow = makeControlRow(label: "隐藏文件：".localized, labelWidth: labelWidth, views: [hiddenCheckbox])
        stack.addArrangedSubview(hiddenRow)

        // 斑马线底色：[x] 在列表视图中显示交替行底色
        zebraCheckbox.title = "在列表视图中显示交替行底色（斑马线）".localized
        zebraCheckbox.target = self
        zebraCheckbox.action = #selector(zebraToggled)
        let zebraRow = makeControlRow(label: "斑马线底色：".localized, labelWidth: labelWidth, views: [zebraCheckbox])
        stack.addArrangedSubview(zebraRow)

        // 分隔线
        let div = NSBox()
        div.boxType = .separator
        div.translatesAutoresizingMaskIntoConstraints = false
        div.widthAnchor.constraint(equalToConstant: 490).isActive = true
        stack.addArrangedSubview(div)

        // 图标视图尺寸
        let iconSliderRow = makeSliderRow(
            label: "网格图标尺寸：".localized,
            labelWidth: labelWidth,
            slider: iconSizeSlider,
            valueLabel: iconSizeValueLabel,
            min: 32,
            max: 128,
            action: #selector(iconSliderChanged)
        )
        stack.addArrangedSubview(iconSliderRow)

        // 列表视图行高
        let listSliderRow = makeSliderRow(
            label: "列表视图行高：".localized,
            labelWidth: labelWidth,
            slider: rowHeightSlider,
            valueLabel: rowHeightValueLabel,
            min: 20,
            max: 38,
            action: #selector(rowHeightSliderChanged)
        )
        stack.addArrangedSubview(listSliderRow)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])

        return scroll
    }

    // MARK: - 2. 权限面板

    private func buildPermissionsPanelView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        content.addSubview(stack)

        let permSection = makeCardSection(
            title: "文件夹与搜索权限管理".localized,
            subtitle: "若您在系统权限弹窗中误点了「不允许」，点击下方「重置并重新请求权限」即可清除拒绝记录并立即重新弹出系统授权框。".localized
        )

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        permissionRows.removeAll()
        for target in targets {
            let row = PermissionItemRow(target: target)
            row.onAction = { [weak self] t in
                self?.requestSinglePermission(t)
            }
            permissionRows.append(row)
            rowsStack.addArrangedSubview(row)
        }
        permSection.contentStack.addArrangedSubview(rowsStack)

        let actionBar = NSStackView()
        actionBar.orientation = .horizontal
        actionBar.alignment = .centerY
        actionBar.spacing = 8

        let resetAllBtn = NSButton(title: "重置并重新弹出授权框".localized, target: self, action: #selector(resetAndRepromptAllPermissions))
        resetAllBtn.bezelStyle = .rounded
        resetAllBtn.keyEquivalent = "\r"

        let openFilesPrivacyBtn = NSButton(title: "系统设置：文件与文件夹".localized, target: self, action: #selector(openFilesAndFoldersPrivacy))
        openFilesPrivacyBtn.bezelStyle = .rounded

        let openFullDiskBtn = NSButton(title: "系统设置：完全磁盘访问".localized, target: self, action: #selector(openFullDiskAccessPrivacy))
        openFullDiskBtn.bezelStyle = .rounded

        actionBar.addArrangedSubview(resetAllBtn)
        actionBar.addArrangedSubview(openFilesPrivacyBtn)
        actionBar.addArrangedSubview(openFullDiskBtn)
        permSection.contentStack.addArrangedSubview(actionBar)

        statusBanner.font = .systemFont(ofSize: 11.5)
        statusBanner.textColor = .secondaryLabelColor
        statusBanner.stringValue = "提示：重置权限后，系统会依次弹出“桌面”、“文稿”、“下载”访问请求，请点击「允许」。".localized
        permSection.contentStack.addArrangedSubview(statusBanner)

        stack.addArrangedSubview(permSection.container)

        let explainSection = makeCardSection(
            title: "权限影响与取舍说明".localized,
            subtitle: "Maple 严格遵循 macOS 隐私机制，所有权限均按需开启，您可以根据需要自行决定是否授权。".localized
        )
        let explainText = NSTextField(wrappingLabelWithString: "• 桌面 / 文稿 / 下载权限：仅用于浏览与搜索对应个人文件夹；不授予时仅无法读取对应目录，不影响其他路径。\n• 完全磁盘访问权限（可选，不强制开启）：\n  - 开启后：可与访达侧栏 1:1 完整同步自定义标签（名称、颜色、顺序与显示状态），支持直接浏览和清倒废纸篓，以及全局搜索受保护目录。\n  - 不开启：所有核心文件管理功能均可正常使用；受 macOS 系统隐私限制（第三方应用无法读取访达的标签列表文件），侧栏将仅显示访达基础 7 色常用标签与磁盘上已给文件打过的标签。".localized)
        explainText.font = .systemFont(ofSize: 11.5)
        explainText.textColor = .secondaryLabelColor
        explainSection.contentStack.addArrangedSubview(explainText)
        stack.addArrangedSubview(explainSection.container)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            permSection.container.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explainSection.container.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        refreshPermissionStatuses()
        return scroll
    }

    // MARK: - 3. 搜索面板

    private func buildSearchPanelView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        content.addSubview(stack)

        let searchSection = makeCardSection(
            title: "全局搜索引擎".localized,
            subtitle: "Maple 内置高并发常驻内存索引，支持秒级全盘文件名模糊匹配。在重新授予文件夹权限后，点击右侧按钮即可立即更新索引。".localized
        )

        let searchRow = NSStackView()
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 10

        let indexInfoStack = NSStackView()
        indexInfoStack.orientation = .vertical
        indexInfoStack.alignment = .leading
        indexInfoStack.spacing = 4
        indexInfoStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        indexStatusLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        indexStatusLabel.textColor = .labelColor

        indexSizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        indexSizeLabel.textColor = .secondaryLabelColor

        indexInfoStack.addArrangedSubview(indexStatusLabel)
        indexInfoStack.addArrangedSubview(indexSizeLabel)

        revealCacheButton.title = "在访达中显示".localized
        revealCacheButton.bezelStyle = .rounded
        revealCacheButton.target = self
        revealCacheButton.action = #selector(revealCacheFileAction)

        rebuildIndexButton.title = "立即重建搜索索引".localized
        rebuildIndexButton.bezelStyle = .rounded
        rebuildIndexButton.target = self
        rebuildIndexButton.action = #selector(rebuildSearchIndexAction)

        searchRow.addArrangedSubview(indexInfoStack)
        searchRow.addArrangedSubview(revealCacheButton)
        searchRow.addArrangedSubview(rebuildIndexButton)
        searchSection.contentStack.addArrangedSubview(searchRow)

        let tipsField = NSTextField(wrappingLabelWithString: "搜索显示与快捷键：\n• 快捷键 ⇧⌘F：全局搜索（范围为「此 Mac」）\n• 快捷键 ⌘F：在当前位置搜索（范围限定在当前所在文件夹内）\n• 搜索结果默认以扁平列表展示直接命中项，右下角提供统一尺寸调节滑块".localized)
        tipsField.font = .systemFont(ofSize: 12)
        tipsField.textColor = .secondaryLabelColor
        searchSection.contentStack.addArrangedSubview(tipsField)

        stack.addArrangedSubview(searchSection.container)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            searchSection.container.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        refreshIndexCount()
        return scroll
    }

    // MARK: - 4. 使用习惯面板

    private func buildHabitsPanelView() -> NSView {
        let content = NSView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        content.addSubview(stack)

        let section = makeCardSection(title: "操作与交互习惯".localized, subtitle: "定制符合您日常工作流的文件管理习惯。".localized)

        let soundCheck = NSButton(checkboxWithTitle: "移到废纸篓时播放碎纸音效（与系统访达一致）".localized, target: nil, action: nil)
        soundCheck.state = .on
        soundCheck.isEnabled = false
        section.contentStack.addArrangedSubview(soundCheck)

        let undoCheck = NSButton(checkboxWithTitle: "支持 Windows 习惯的 Ctrl+Z / Ctrl+Shift+Z 文本撤销与重做".localized, target: nil, action: nil)
        undoCheck.state = .on
        undoCheck.isEnabled = false
        section.contentStack.addArrangedSubview(undoCheck)

        let closeWindowCheck = NSButton(checkboxWithTitle: "⌘W 仅关闭当前窗口，应用在后台与 Dock 栏继续运行".localized, target: nil, action: nil)
        closeWindowCheck.state = .on
        closeWindowCheck.isEnabled = false
        section.contentStack.addArrangedSubview(closeWindowCheck)

        stack.addArrangedSubview(section.container)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            section.container.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return content
    }

    // MARK: - 5. 快捷键面板

    private func buildShortcutsPanelView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        content.addSubview(stack)

        let section = makeCardSection(title: "Maple 核心快捷键一览".localized, subtitle: "支持标准 macOS 快捷键及 Windows 习惯键位。".localized)

        let shortcuts: [(key: String, desc: String)] = [
            ("⌘N", "新建主窗口".localized),
            ("⌘W", "关闭当前窗口（后台保持运行）".localized),
            ("⌘Q", "彻底退出 Maple".localized),
            ("⌘F", "打开全局秒级搜索".localized),
            ("⌘[ / ⌘← / 鼠标侧键", "后退至上一级历史".localized),
            ("⌘] / ⌘→ / 鼠标侧键", "前进至下一级历史".localized),
            ("⌘1 / ⌘2 / ⌘3", "切换 列表 / 图标 / 分栏 视图".localized),
            ("⌘⇧.", "显示 / 隐藏隐藏文件".localized),
            ("⌘⌫", "将选中项移至废纸篓".localized),
            ("⌥⌘C", "拷贝选中文件完整路径".localized),
            ("⌥⌘T", "在终端中打开当前目录".localized),
            ("⇧⌘R", "在系统访达中定位并显示".localized),
            ("Ctrl+Z", "文本撤销（Windows 习惯）".localized),
            ("Ctrl+⇧+Z", "文本重做（Windows 习惯）".localized)
        ]

        for s in shortcuts {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 16

            let kLabel = NSTextField(labelWithString: s.key)
            kLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
            kLabel.textColor = .controlAccentColor
            kLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true

            let dLabel = NSTextField(labelWithString: s.desc.localized)
            dLabel.font = .systemFont(ofSize: 12.5)
            dLabel.textColor = .labelColor

            row.addArrangedSubview(kLabel)
            row.addArrangedSubview(dLabel)
            section.contentStack.addArrangedSubview(row)
        }

        stack.addArrangedSubview(section.container)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            section.container.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return scroll
    }

    // MARK: - 6. 右键菜单面板

    private func buildContextMenuPanelView() -> NSView {
        let content = NSView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        content.addSubview(stack)

        let section = makeCardSection(title: "右键菜单定制".localized, subtitle: "配置在文件与目录上右键时弹出的常用快捷操作。".localized)

        let items = ["拷贝路径 (⌥⌘C)".localized, "在终端中打开 (⌥⌘T)".localized, "在 Finder 中显示 (⇧⌘R)".localized, "重命名".localized, "移到废纸篓 (⌘⌫)".localized]
        for item in items {
            let check = NSButton(checkboxWithTitle: item, target: nil, action: nil)
            check.state = .on
            section.contentStack.addArrangedSubview(check)
        }

        stack.addArrangedSubview(section.container)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            section.container.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return content
    }

    // MARK: - 7. 新建文件面板

    private func buildNewFilePanelView() -> NSView {
        let content = NSView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        content.addSubview(stack)

        let section = makeCardSection(title: "新建文件模板".localized, subtitle: "快速在空白区域创建各种类型的新文件。".localized)

        let templates = ["新建文件夹（快捷键 ⇧⌘N）".localized, "新建文本文档 (.txt)".localized, "新建 Markdown 笔记 (.md)".localized, "新建空白代码文件".localized]
        for t in templates {
            let check = NSButton(checkboxWithTitle: t, target: nil, action: nil)
            check.state = .on
            section.contentStack.addArrangedSubview(check)
        }

        stack.addArrangedSubview(section.container)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            section.container.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return content
    }

    // MARK: - 8. 版本面板

    private func buildAboutPanelView() -> NSView {
        let content = NSView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        content.addSubview(stack)

        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage ?? NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 96).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 96).isActive = true
        stack.addArrangedSubview(iconView)

        let nameLabel = NSTextField(labelWithString: "Maple 枫叶文件管理器".localized)
        nameLabel.font = .systemFont(ofSize: 18, weight: .bold)
        stack.addArrangedSubview(nameLabel)

        let ver = UpdateChecker.currentVersion
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "2026.11"
        let verLabel = NSTextField(labelWithString: "\("版本".localized) \(ver) (Build \(build))")
        verLabel.font = .systemFont(ofSize: 12.5)
        verLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(verLabel)

        #if arch(arm64)
        let archText = "Apple Silicon (arm64) 原生架构".localized
        #else
        let archText = "Intel (x86_64) 原生架构".localized
        #endif
        let archLabel = NSTextField(labelWithString: "\("系统架构：".localized)\(archText)")
        archLabel.font = .systemFont(ofSize: 11.5)
        archLabel.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(archLabel)

        let descLabel = NSTextField(wrappingLabelWithString: "Maple 是一款专为 macOS 设计的极速、轻量、多窗格文件管理器。\n纯原生 Swift + AppKit 开发，极致性能，丝滑流畅。".localized)
        descLabel.alignment = .center
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(descLabel)

        let updateButton = NSButton(title: "检查更新…".localized, target: self, action: #selector(checkForUpdatesClicked(_:)))
        updateButton.bezelStyle = .rounded
        updateButton.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(updateButton)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -30)
        ])
        return content
    }

    @objc private func checkForUpdatesClicked(_ sender: NSButton) {
        sender.isEnabled = false
        sender.title = "正在检查更新…".localized
        UpdateChecker.shared.checkForUpdates(isUserInitiated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in
            sender?.isEnabled = true
            sender?.title = "检查更新…".localized
        }
    }

    // MARK: - 9. 占位面板

    private func buildPlaceholderPanelView(category: String) -> NSView {
        let content = NSView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        content.addSubview(stack)

        let title = NSTextField(labelWithString: "\(category)")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = .labelColor

        let subtitle = NSTextField(labelWithString: "该分类功能已在默认最佳配置下运行。".localized)
        subtitle.font = .systemFont(ofSize: 12.5)
        subtitle.textColor = .secondaryLabelColor

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        return content
    }

    // MARK: - 辅助组件生成

    private func makeControlRow(label: String, labelWidth: CGFloat, views: [NSView]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.font = .systemFont(ofSize: 12.5)
        labelField.textColor = .labelColor
        labelField.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        row.addArrangedSubview(labelField)

        let subStack = NSStackView(views: views)
        subStack.orientation = .horizontal
        subStack.alignment = .centerY
        subStack.spacing = 16
        row.addArrangedSubview(subStack)

        return row
    }

    private func makeSliderRow(label: String,
                               labelWidth: CGFloat,
                               slider: NSSlider,
                               valueLabel: NSTextField,
                               min: Double,
                               max: Double,
                               action: Selector) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let nameField = NSTextField(labelWithString: label)
        nameField.alignment = .right
        nameField.font = .systemFont(ofSize: 12.5)
        nameField.textColor = .labelColor
        nameField.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        slider.minValue = min
        slider.maxValue = max
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .left
        valueLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true

        row.addArrangedSubview(nameField)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(valueLabel)
        return row
    }

    private func makeCardSection(title: String, subtitle: String?) -> (container: NSView, contentStack: NSStackView) {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        box.addSubview(stack)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleField.textColor = .labelColor
        stack.addArrangedSubview(titleField)

        if let subtitle, !subtitle.isEmpty {
            let subField = NSTextField(wrappingLabelWithString: subtitle)
            subField.font = .systemFont(ofSize: 11.5)
            subField.textColor = .secondaryLabelColor
            stack.addArrangedSubview(subField)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])

        return (box, stack)
    }

    // MARK: - 权限检测与一键重置

    private func checkAccess(for target: PermissionTarget) -> Bool {
        let path = target.url.path
        if target.isFullDisk {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let probes = [
                "\(home)/Library/Safari",
                "\(home)/Library/Mail",
                "/Library/Application Support/com.apple.TCC"
            ]
            for probe in probes where FileManager.default.fileExists(atPath: probe) {
                if (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil {
                    return true
                }
            }
            return false
        }
        guard FileManager.default.fileExists(atPath: path) else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    func refreshPermissionStatuses() {
        for (idx, target) in targets.enumerated() where idx < permissionRows.count {
            let granted = checkAccess(for: target)
            permissionRows[idx].updateStatus(granted: granted)
        }
    }

    private func requestSinglePermission(_ target: PermissionTarget) {
        if target.isFullDisk {
            openFullDiskAccessPrivacy()
            return
        }

        resetTCC(service: target.tccService)
        resetTCC(service: "All")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = try? FileManager.default.contentsOfDirectory(atPath: target.url.path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let self else { return }
                self.refreshPermissionStatuses()
                self.onSettingsChanged?()
                let granted = self.checkAccess(for: target)
                if granted {
                    self.statusBanner.textColor = .systemGreen
                    self.statusBanner.stringValue = "\("✓ 已成功开启！正在更新搜索索引…".localized)"
                    self.rebuildSearchIndexAction()
                } else {
                    self.statusBanner.textColor = .systemOrange
                    self.statusBanner.stringValue = "若系统未弹出询问框，请点击「系统设置：文件与文件夹」手动勾选开启。".localized
                }
            }
        }
    }

    @objc private func resetAndRepromptAllPermissions() {
        statusBanner.textColor = .controlAccentColor
        statusBanner.stringValue = "正在重置权限记录并请求系统重新弹窗…".localized

        resetTCC(service: "All")
        resetTCC(service: "SystemPolicyDesktopFolder")
        resetTCC(service: "SystemPolicyDocumentsFolder")
        resetTCC(service: "SystemPolicyDownloadsFolder")

        let folderTargets = targets.filter { !$0.isFullDisk }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for t in folderTargets {
                _ = try? FileManager.default.contentsOfDirectory(atPath: t.url.path)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let self else { return }
                self.refreshPermissionStatuses()
                self.onSettingsChanged?()
                self.rebuildSearchIndexAction()
                self.statusBanner.textColor = .systemGreen
                self.statusBanner.stringValue = "✓ 已重置权限并重新请求授权！如果已在弹窗中点击允许，全局搜索将自动更新。".localized
            }
        }
    }

    private func resetTCC(service: String) {
        var bundleIDs: Set<String> = [
            "com.maple.app",
            "com.workbuddy.maple",
            "com.workbuddy.qspacelite",
            "com.qspacelite.app"
        ]
        if let mainID = Bundle.main.bundleIdentifier, !mainID.isEmpty {
            bundleIDs.insert(mainID)
        }
        for bid in bundleIDs {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            proc.arguments = ["reset", service, bid]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    @objc private func openFilesAndFoldersPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openFullDiskAccessPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 搜索索引管理

    private func refreshIndexCount() {
        let count = FileSearchEngine.shared.indexedCount
        let sizeStr = FileSearchEngine.shared.formattedIndexSize
        let formattedCount = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        indexStatusLabel.stringValue = "\("当前常驻索引：".localized)\(formattedCount) \("个项目".localized)"
        indexSizeLabel.stringValue = "\("当前索引大小：".localized)\(sizeStr)\("（高速磁盘缓存）".localized)"
    }

    @objc private func rebuildSearchIndexAction() {
        rebuildIndexButton.isEnabled = false
        rebuildIndexButton.title = "正在重建索引…".localized
        indexStatusLabel.stringValue = "正在扫描已授权目录并重建常驻索引…".localized
        indexSizeLabel.stringValue = "正在生成并压缩索引文件…".localized

        FileSearchEngine.shared.rebuildIndexNow { [weak self] newCount in
            guard let self else { return }
            self.rebuildIndexButton.isEnabled = true
            self.rebuildIndexButton.title = "立即重建搜索索引".localized
            let sizeStr = FileSearchEngine.shared.formattedIndexSize
            let formattedCount = NumberFormatter.localizedString(from: NSNumber(value: newCount), number: .decimal)
            self.indexStatusLabel.stringValue = "\("当前常驻索引：".localized)\(formattedCount) \("个项目（已更新）".localized)"
            self.indexSizeLabel.stringValue = "\("当前索引大小：".localized)\(sizeStr)\("（高速磁盘缓存）".localized)"
        }
    }

    @objc private func revealCacheFileAction() {
        let url = FileSearchEngine.cacheURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    // MARK: - 状态同步与事件处理

    private func syncDisplayControls() {
        // 外观单选按钮
        let currentApp = AppSettings.appearance
        for (idx, r) in appearanceRadios.enumerated() {
            if idx == 0 && currentApp == .system { r.state = .on }
            else if idx == 1 && currentApp == .light { r.state = .on }
            else if idx == 2 && currentApp == .dark { r.state = .on }
            else { r.state = .off }
        }

        // 语言单选按钮
        let currentLang = AppSettings.language
        for (idx, r) in languageRadios.enumerated() {
            if idx == 0 && currentLang == .system { r.state = .on }
            else if idx == 1 && currentLang == .zhHans { r.state = .on }
            else if idx == 2 && currentLang == .en { r.state = .on }
            else if idx == 3 && currentLang == .zhHant { r.state = .on }
            else if idx == 4 && currentLang == .ja { r.state = .on }
            else { r.state = .off }
        }

        // 边栏图标尺寸单选按钮
        let currentIconSize = AppSettings.sidebarIconSize
        for (idx, r) in sidebarIconRadios.enumerated() {
            if idx == 0 && currentIconSize == .small { r.state = .on }
            else if idx == 1 && currentIconSize == .medium { r.state = .on }
            else if idx == 2 && currentIconSize == .large { r.state = .on }
            else { r.state = .off }
        }

        // 边栏图标风格单选按钮
        let currentIconStyle = AppSettings.sidebarIconStyle
        for (idx, r) in sidebarIconStyleRadios.enumerated() {
            if idx == 0 && currentIconStyle == .colorful { r.state = .on }
            else if idx == 1 && currentIconStyle == .category { r.state = .on }
            else if idx == 2 && currentIconStyle == .minimalist { r.state = .on }
            else { r.state = .off }
        }

        showPaneBorderCheckbox.state = AppSettings.showPaneBorder ? .on : .off
        highlightPaneAddressBarCheckbox.state = AppSettings.highlightPaneAddressBar ? .on : .off
        keepPaneCornerRadiusCheckbox.state = AppSettings.keepPaneCornerRadius ? .on : .off
        let schemeVal = AppSettings.cornerScheme.rawValue
        for (idx, r) in cornerSchemeRadios.enumerated() {
            r.state = (idx + 1 == schemeVal) ? .on : .off
        }
        showItemInfoCheckbox.state = AppSettings.showItemInfo ? .on : .off
        hideBottomStatusBarCheckbox.state = AppSettings.hideBottomStatusBar ? .on : .off
        calculateFolderSizesCheckbox.state = AppSettings.calculateFolderSizes ? .on : .off
        hiddenCheckbox.state = AppSettings.showHidden ? .on : .off
        zebraCheckbox.state = AppSettings.showZebraStripes ? .on : .off

        iconSizeSlider.doubleValue = Double(AppSettings.gridIconSize)
        iconSizeValueLabel.stringValue = "\(Int(AppSettings.gridIconSize)) pt"
        rowHeightSlider.doubleValue = Double(AppSettings.listRowHeight)
        rowHeightValueLabel.stringValue = "\(Int(AppSettings.listRowHeight)) pt"
        populateTerminalPopUp()
        updateDefaultManagerStatus()

        let extMode = AppSettings.externalFolderOpenMode
        for (idx, r) in externalOpenRadios.enumerated() {
            if idx == 0 && extMode == "tab" { r.state = .on }
            else if idx == 1 && extMode == "window" { r.state = .on }
            else { r.state = .off }
        }
    }

    // MARK: - 终端应用设置交互

    private func populateTerminalPopUp() {
        guard let popUp = terminalPopUpButton else { return }
        popUp.removeAllItems()

        let current = TerminalManager.shared.currentTerminal()
        let installed = TerminalManager.shared.scanInstalledTerminals()

        for term in installed {
            let item = NSMenuItem(title: term.displayName, action: nil, keyEquivalent: "")
            item.image = term.icon
            item.representedObject = term.id
            popUp.menu?.addItem(item)
            if term.id == current.id || term.bundleIdentifier == AppSettings.defaultTerminalBundleId {
                popUp.select(item)
            }
        }

        popUp.menu?.addItem(.separator())
        let customItem = NSMenuItem(title: "浏览其他应用…".localized, action: nil, keyEquivalent: "")
        customItem.representedObject = "custom_browse"
        popUp.menu?.addItem(customItem)

        if popUp.selectedItem == nil {
            if let first = popUp.itemArray.first(where: { ($0.representedObject as? String) != "custom_browse" }) {
                popUp.select(first)
            }
        }
    }

    @objc private func terminalPopUpChanged(_ sender: NSPopUpButton) {
        guard let selected = sender.selectedItem,
              let id = selected.representedObject as? String else { return }

        if id == "custom_browse" {
            let panel = NSOpenPanel()
            panel.title = "选择终端应用程序".localized
            panel.prompt = "选择".localized
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedFileTypes = ["app"]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self = self else { return }
                if response == .OK, let appURL = panel.url {
                    AppSettings.customTerminalAppPath = appURL.path
                    AppSettings.defaultTerminalBundleId = appURL.path
                    self.populateTerminalPopUp()
                } else {
                    self.populateTerminalPopUp()
                }
            }
            return
        }

        AppSettings.defaultTerminalBundleId = id
    }

    // MARK: - 默认文件管理器与外部打开模式交互

    @objc private func setDefaultManagerClicked() {
        DefaultFileManager.setAsDefault()
        updateDefaultManagerStatus()
    }

    @objc private func restoreFinderClicked() {
        DefaultFileManager.restoreFinder()
        updateDefaultManagerStatus()
    }

    @objc private func showDefaultManagerHelp(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "默认文件管理器生效说明".localized
        alert.informativeText = "• 支持直接接管打开的场景：\n  1. 终端命令行运行 open 命令（例如 open . 或 open ~/Downloads）；\n  2. Spotlight（聚焦搜索）或 Raycast 等启动器搜索文件夹后回车打开；\n  3. 系统任意文件/文件夹上右键「打开方式」选择 Maple。\n\n• 受 macOS 系统机制限制的场景：\n  1. 桌面双击文件夹图标：桌面是访达的私有画布，由访达硬编码直接打开；\n  2. Chrome、微信等软件内点击“在访达中显示”：调用了系统硬绑定访达的专用接口，仍由原生访达打开。".localized
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好".localized)
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func updateDefaultManagerStatus() {
        let isMaple = DefaultFileManager.isMapleDefault
        if isMaple {
            defaultManagerStatusLabel.stringValue = "● 已设为默认".localized
            defaultManagerStatusLabel.textColor = .systemGreen
            setDefaultManagerBtn.isEnabled = false
            restoreFinderBtn.isEnabled = true
        } else {
            defaultManagerStatusLabel.stringValue = "○ 默认是系统访达".localized
            defaultManagerStatusLabel.textColor = .secondaryLabelColor
            setDefaultManagerBtn.isEnabled = true
            restoreFinderBtn.isEnabled = false
        }
    }

    @objc private func externalOpenRadioSelected(_ sender: NSButton) {
        externalOpenRadios.forEach { $0.state = ($0 == sender) ? .on : .off }
        if sender == externalOpenRadios.first {
            AppSettings.externalFolderOpenMode = "tab"
        } else {
            AppSettings.externalFolderOpenMode = "window"
        }
    }

    @objc private func appearanceRadioSelected(_ sender: NSButton) {
        appearanceRadios.forEach { $0.state = ($0 == sender) ? .on : .off }
        if sender == appearanceRadios.first {
            AppSettings.appearance = .system
        } else if sender == appearanceRadios[1] {
            AppSettings.appearance = .light
        } else {
            AppSettings.appearance = .dark
        }
        window.appearance = NSApp.appearance
        onSettingsChanged?()
    }

    @objc private func languageRadioSelected(_ sender: NSButton) {
        languageRadios.forEach { $0.state = ($0 == sender) ? .on : .off }
        if sender == languageRadios.first {
            AppSettings.language = .system
        } else if sender == languageRadios[1] {
            AppSettings.language = .zhHans
        } else if sender == languageRadios[2] {
            AppSettings.language = .en
        } else if sender == languageRadios[3] {
            AppSettings.language = .zhHant
        } else {
            AppSettings.language = .ja
        }
        onSettingsChanged?()
    }

    @objc private func sidebarIconRadioSelected(_ sender: NSButton) {
        sidebarIconRadios.forEach { $0.state = ($0 == sender) ? .on : .off }
        if sender == sidebarIconRadios.first {
            AppSettings.sidebarIconSize = .small
        } else if sender == sidebarIconRadios[1] {
            AppSettings.sidebarIconSize = .medium
        } else {
            AppSettings.sidebarIconSize = .large
        }
    }

    @objc private func sidebarIconStyleRadioSelected(_ sender: NSButton) {
        sidebarIconStyleRadios.forEach { $0.state = ($0 == sender) ? .on : .off }
        if sender == sidebarIconStyleRadios.first {
            AppSettings.sidebarIconStyle = .colorful
        } else if sidebarIconStyleRadios.count > 1 && sender == sidebarIconStyleRadios[1] {
            AppSettings.sidebarIconStyle = .category
        } else {
            AppSettings.sidebarIconStyle = .minimalist
        }
    }

    @objc private func paneOptionToggled() {
        AppSettings.showPaneBorder = (showPaneBorderCheckbox.state == .on)
        AppSettings.highlightPaneAddressBar = (highlightPaneAddressBarCheckbox.state == .on)
        AppSettings.keepPaneCornerRadius = (keepPaneCornerRadiusCheckbox.state == .on)
    }

    @objc private func cornerSchemeRadioSelected(_ sender: NSButton) {
        cornerSchemeRadios.forEach { $0.state = ($0 == sender) ? .on : .off }
        if sender == cornerSchemeRadios.first {
            AppSettings.cornerScheme = .native
        } else if cornerSchemeRadios.count > 1 && sender == cornerSchemeRadios[1] {
            AppSettings.cornerScheme = .cards
        } else {
            AppSettings.cornerScheme = .smart
        }
    }

    @objc private func itemInfoToggled() {
        AppSettings.showItemInfo = (showItemInfoCheckbox.state == .on)
    }

    @objc private func bottomStatusBarToggled() {
        AppSettings.hideBottomStatusBar = (hideBottomStatusBarCheckbox.state == .on)
    }

    @objc private func calcSizeToggled() {
        AppSettings.calculateFolderSizes = (calculateFolderSizesCheckbox.state == .on)
    }

    @objc private func hiddenToggled() {
        AppSettings.showHidden = (hiddenCheckbox.state == .on)
        onSettingsChanged?()
    }

    @objc private func zebraToggled() {
        AppSettings.showZebraStripes = (zebraCheckbox.state == .on)
    }

    @objc private func iconSliderChanged() {
        let val = CGFloat(iconSizeSlider.doubleValue.rounded())
        AppSettings.gridIconSize = val
        iconSizeValueLabel.stringValue = "\(Int(val)) pt"
        onIconSizeChanged?(val)
    }

    @objc private func rowHeightSliderChanged() {
        let val = CGFloat(rowHeightSlider.doubleValue.rounded())
        AppSettings.listRowHeight = val
        rowHeightValueLabel.stringValue = "\(Int(val)) pt"
        onRowHeightChanged?(val)
    }
}

// MARK: - 透明滚动条

private final class SubtleScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool {
        true
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // 不绘制槽与轨道底色，实现融入背景
    }

    override func draw(_ dirtyRect: NSRect) {
        // 仅绘制滑块，不绘制任何背景
        drawKnob()
    }
}

// MARK: - 设置侧边栏行视图

private final class CategoryRowView: NSTableRowView {

    private var isHovered: Bool = false
    private var trackingArea: NSTrackingArea?

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        .normal
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        needsDisplay = true
    }

    override var isSelected: Bool {
        didSet {
            needsDisplay = true
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let rect = bounds.insetBy(dx: 4, dy: 1.5)
        if isSelected {
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            let color = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(white: 1.0, alpha: 0.16)
                    : NSColor(white: 0.0, alpha: 0.12)
            }
            color.setFill()
            path.fill()
        } else if isHovered {
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            let color = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(white: 1.0, alpha: 0.08)
                    : NSColor(white: 0.0, alpha: 0.05)
            }
            color.setFill()
            path.fill()
        }
    }
}

// MARK: - 侧边栏行 Cell 视图

private final class CategoryCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(item: SettingsWindowController.CategoryItem) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = .labelColor
        addSubview(titleLabel)

        configure(with: item)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with item: SettingsWindowController.CategoryItem) {
        titleLabel.stringValue = item.title
        if let img = NSImage(systemSymbolName: item.iconName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
            iconView.image = img.withSymbolConfiguration(config)
        }
        iconView.contentTintColor = item.iconColor
    }
}


// MARK: - 单项权限状态行视图

private final class PermissionItemRow: NSView {

    let target: SettingsWindowController.PermissionTarget
    var onAction: ((SettingsWindowController.PermissionTarget) -> Void)?

    private let dotView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let statusBadge = NSTextField(labelWithString: "")
    private let actionButton = NSButton()

    init(target: SettingsWindowController.PermissionTarget) {
        self.target = target
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 4.5
        addSubview(dotView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.stringValue = target.title

        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.font = .systemFont(ofSize: 11)
        subLabel.textColor = .tertiaryLabelColor
        subLabel.stringValue = target.subtitle
        subLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, subLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        addSubview(textStack)

        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.font = .systemFont(ofSize: 11.5, weight: .medium)
        addSubview(statusBadge)

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.bezelStyle = .inline
        actionButton.controlSize = .small
        actionButton.font = .systemFont(ofSize: 11)
        actionButton.target = self
        actionButton.action = #selector(buttonClicked)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),

            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 9),
            dotView.heightAnchor.constraint(equalToConstant: 9),

            textStack.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: statusBadge.leadingAnchor, constant: -12),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusBadge.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -10),
            statusBadge.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func updateStatus(granted: Bool) {
        if granted {
            dotView.layer?.backgroundColor = NSColor.systemGreen.cgColor
            statusBadge.stringValue = "已授权".localized
            statusBadge.textColor = .systemGreen
            actionButton.title = target.isFullDisk ? "查看设置".localized : "重新检测".localized
        } else {
            dotView.layer?.backgroundColor = NSColor.systemOrange.cgColor
            statusBadge.stringValue = target.isFullDisk ? "未开启（可选）".localized : "未授权 / 已拒绝".localized
            statusBadge.textColor = .systemOrange
            actionButton.title = target.isFullDisk ? "去开启…".localized : "重新请求授权".localized
        }
    }

    @objc private func buttonClicked() {
        onAction?(target)
    }
}
