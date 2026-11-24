import AppKit

/// 侧栏数据节点：分组标题（.group）、文件夹（.folder）、远程服务器（.server）、连接服务器入口（.connectServer）或标签（.tag）。
final class SidebarNode: NSObject {

    enum Kind { case group, folder, server, connectServer, tag, allTags }

    let kind: Kind
    let title: String
    let url: URL?
    let tag: String?
    let symbol: String
    /// true 时用磁盘上的真实图标（文件夹、磁盘、应用程序、废纸篓更有辨识度）
    let usesSystemIcon: Bool
    let dotColor: NSColor?
    /// true 表示这是用户自己加入「个人收藏」的条目（可以移除）
    let isUserFavorite: Bool
    /// 关联的已保存服务器配置
    let serverEntry: ServerEntry?
    /// 是否是当前已挂载的网络卷（支持卸载/断开）
    let isMountedNetworkVolume: Bool
    /// 是否是可推出的本地磁盘/外置卷/DMG镜像
    let isEjectableVolume: Bool
    /// 是否是废纸篓
    let isTrash: Bool
    /// 所属侧栏大模块分类（用于按模块区分图标颜色及持久化模块内拖拽顺序）
    let category: SidebarCategory?
    var children: [SidebarNode] = []

    init(kind: Kind,
         title: String,
         url: URL? = nil,
         tag: String? = nil,
         symbol: String = "",
         usesSystemIcon: Bool = false,
         dotColor: NSColor? = nil,
         isUserFavorite: Bool = false,
         serverEntry: ServerEntry? = nil,
         isMountedNetworkVolume: Bool = false,
         isEjectableVolume: Bool = false,
         isTrash: Bool = false,
         category: SidebarCategory? = nil) {
        self.kind = kind
        self.title = title
        self.url = url
        self.tag = tag
        self.symbol = symbol
        self.usesSystemIcon = usesSystemIcon
        self.dotColor = dotColor
        self.isUserFavorite = isUserFavorite
        self.serverEntry = serverEntry
        self.isMountedNetworkVolume = isMountedNetworkVolume
        self.isEjectableVolume = isEjectableVolume
        self.isTrash = isTrash
        self.category = category
    }

    var isGroup: Bool { kind == .group }
    var isTag: Bool { kind == .tag }

    /// 是否支持在所属分组内按住拖拽调整位置
    var isReorderable: Bool {
        switch kind {
        case .folder, .server, .tag:
            return true
        case .group, .connectServer, .allTags:
            return false
        }
    }

    /// 分组内拖拽排序的稳定唯一标识
    var reorderIdentifier: String {
        if let url {
            return url.standardizedFileURL.path
        }
        if let entry = serverEntry {
            return entry.id
        }
        if let tag {
            return tag
        }
        return title
    }
}

/// 侧栏视图：个人收藏 / iCloud / 位置 / 服务器 / 标签 + 底部操作栏。
final class SidebarView: NSView {

    var onSelect: ((URL) -> Void)?
    /// 在另一个窗格打开
    var onOpenInOtherPane: ((URL) -> Void)?
    /// 点击某个标签。
    var onSelectTag: ((String) -> Void)?
    /// 点击「所有标签…」。
    var onSelectAllTags: (() -> Void)?
    /// 某个标签被移除，通知主窗格清空对应标签视图
    var onTagRemoved: ((String) -> Void)?
    /// 查询窗口是否正在显示某标签
    var isShowingTag: ((String) -> Bool)?
    /// 获取正在显示某标签的窗格中已加载的 URLs
    var getURLsForTagInPanes: ((String) -> [URL])?
    /// 点击「连接服务器…」或未挂载的已保存服务器条目。
    var onRequestConnectServer: ((ServerEntry?) -> Void)?
    /// 点击底栏设置齿轮按钮。
    var onOpenSettings: (() -> Void)?

    /// 删除标签撤销记录
    struct TagDeletionRecord {
        let tagDef: TagDefinition
        let originalIndex: Int
        let affectedURLs: [URL]
        let wasShowingInPane: Bool
    }
    private var tagUndoStack: [TagDeletionRecord] = []
    var hasUndoableTagDeletion: Bool { !tagUndoStack.isEmpty }

    /// 获取当前焦点窗格正在浏览的 URL，供刷新时安全恢复选中项，避免外置卷挂载时误选新卷
    var currentURLProvider: (() -> URL?)?

    /// 列表顶部让出的高度（隐藏标题栏后，交通灯与工具条浮在侧栏上方，
    /// 列表内容要整体下移，避免第一组标题被挡住）。
    var topInset: CGFloat = 38 {
        didSet {
            guard abs(scrollTop.constant - (topInset + 6)) > 0.5 else { return }
            scrollTop.constant = topInset + 6
        }
    }

    private let effect = NSVisualEffectView()
    private let outline = SidebarOutlineView()
    private let scroll = OverlayScrollView()
    private let footerBar = NSView()
    private let moreButton = SquareToolbarButton(size: 24)
    private let settingsButton = SquareToolbarButton(size: 24)
    private var scrollTop: NSLayoutConstraint!
    private var nodes: [SidebarNode] = []
    private var isRestoringSelection = false
    /// 最近一次右键命中的节点（菜单动作针对它，而不是选中行）。
    private var contextNode: SidebarNode?
    private var activeAllTagsSelection: String?
    private weak var draggedSidebarNode: SidebarNode?

    /// 仿访达侧栏实时拖拽重排上下文
    private final class InteractiveReorderState {
        let node: SidebarNode
        let group: SidebarNode
        let reorderableChildren: [SidebarNode]
        let sourceIndex: Int
        var currentTargetIndex: Int
        let startPointInOutline: NSPoint
        let initialRowRect: NSRect
        let baseRowRects: [NSRect]
        let floatingView: SidebarFloatingDragView
        let previousSelectedNode: SidebarNode?

        init(node: SidebarNode,
             group: SidebarNode,
             reorderableChildren: [SidebarNode],
             sourceIndex: Int,
             startPointInOutline: NSPoint,
             initialRowRect: NSRect,
             baseRowRects: [NSRect],
             floatingView: SidebarFloatingDragView,
             previousSelectedNode: SidebarNode?) {
            self.node = node
            self.group = group
            self.reorderableChildren = reorderableChildren
            self.sourceIndex = sourceIndex
            self.currentTargetIndex = sourceIndex
            self.startPointInOutline = startPointInOutline
            self.initialRowRect = initialRowRect
            self.baseRowRects = baseRowRects
            self.floatingView = floatingView
            self.previousSelectedNode = previousSelectedNode
        }
    }
    private var reorderState: InteractiveReorderState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
        reload()
        observeVolumes()
        NotificationCenter.default.addObserver(self, selector: #selector(handleLanguageDidChangeNotification), name: .languageDidChange, object: nil)
    }

    @objc private func handleLanguageDidChangeNotification() {
        moreButton.toolTip = "侧栏选项与操作".localized
        settingsButton.toolTip = "偏好设置与权限管理 (⌘,)".localized
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - 构建

    private func setup() {
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        addSubview(effect)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .none
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.registerForDraggedTypes([.fileURL])
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(handleClick)
        outline.menuProvider = { [weak self] node in self?.makeContextMenu(for: node) }
        outline.onUndo = { [weak self] in self?.undoTagDeletion() ?? false }

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        // 底部操作栏（带「⋯」按钮）
        footerBar.translatesAutoresizingMaskIntoConstraints = false
        footerBar.clipsToBounds = true
        let footerLine = Theme.hairlineView()
        footerBar.addSubview(footerLine)

        moreButton.image = Theme.symbol("ellipsis.circle", size: 14.5, weight: .medium)
        moreButton.toolTip = "侧栏选项与操作".localized
        moreButton.target = self
        moreButton.action = #selector(moreButtonClicked(_:))
        footerBar.addSubview(moreButton)

        settingsButton.image = Theme.symbol("gearshape", size: 13.5, weight: .regular)
        settingsButton.toolTip = "偏好设置与权限管理 (⌘,)".localized
        settingsButton.target = self
        settingsButton.action = #selector(settingsButtonClicked)
        footerBar.addSubview(settingsButton)

        effect.addSubview(scroll)
        effect.addSubview(footerBar)

        let top = scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: topInset + 6)
        scrollTop = top
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),

            top,
            scroll.bottomAnchor.constraint(equalTo: footerBar.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),

            footerBar.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            footerBar.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            footerBar.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            footerBar.heightAnchor.constraint(equalToConstant: 32),

            footerLine.topAnchor.constraint(equalTo: footerBar.topAnchor),
            footerLine.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor),
            footerLine.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor),
            footerLine.heightAnchor.constraint(equalToConstant: 1),

            moreButton.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor, constant: 8),
            moreButton.centerYAnchor.constraint(equalTo: footerBar.centerYAnchor, constant: 1),

            settingsButton.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor, constant: -8),
            settingsButton.centerYAnchor.constraint(equalTo: footerBar.centerYAnchor, constant: 1)
        ])
    }

    // MARK: - 菜单（底部「⋯」按钮 & 右键空白处 / 条目）

    override func menu(for event: NSEvent) -> NSMenu? {
        return makeSidebarAreaMenu()
    }

    @objc private func moreButtonClicked(_ sender: NSButton) {
        let menu = makeSidebarAreaMenu()
        let point = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    /// 构造「展示分类」子菜单。
    private func makeCategorySubmenu() -> NSMenu {
        let sub = NSMenu(title: "展示分类".localized)
        sub.autoenablesItems = false
        for category in SidebarCategory.allCases {
            let item = NSMenuItem(title: category.title,
                                  action: #selector(toggleCategoryClicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = category.rawValue
            item.state = AppSettings.isSidebarCategoryVisible(category) ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let showAll = NSMenuItem(title: "显示全部分类".localized,
                                 action: #selector(showAllCategoriesClicked),
                                 keyEquivalent: "")
        showAll.target = self
        let allVisible = SidebarCategory.allCases.allSatisfy { AppSettings.isSidebarCategoryVisible($0) }
        showAll.isEnabled = !allVisible
        sub.addItem(showAll)
        return sub
    }

    /// 侧栏空白处右键或点击底部「⋯」按钮弹出的菜单。
    private func makeSidebarAreaMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let categoryItem = NSMenuItem(title: "展示分类".localized, action: nil, keyEquivalent: "")
        categoryItem.submenu = makeCategorySubmenu()
        menu.addItem(categoryItem)

        menu.addItem(.separator())

        let iconStyleItem = NSMenuItem(title: "图标风格".localized, action: nil, keyEquivalent: "")
        let styleSub = NSMenu(title: "图标风格".localized)
        styleSub.autoenablesItems = false
        for style in SidebarIconStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(selectSidebarIconStyleClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = (AppSettings.sidebarIconStyle == style) ? .on : .off
            styleSub.addItem(item)
        }
        iconStyleItem.submenu = styleSub
        menu.addItem(iconStyleItem)

        menu.addItem(.separator())

        let expandAll = NSMenuItem(title: "展开全部分组".localized, action: #selector(expandAllGroupsClicked), keyEquivalent: "")
        expandAll.target = self
        menu.addItem(expandAll)

        let collapseAll = NSMenuItem(title: "收起全部分组".localized, action: #selector(collapseAllGroupsClicked), keyEquivalent: "")
        collapseAll.target = self
        menu.addItem(collapseAll)

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "刷新侧栏".localized, action: #selector(refreshClicked), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        return menu
    }

    @objc private func selectSidebarIconStyleClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = SidebarIconStyle(rawValue: raw) else { return }
        AppSettings.sidebarIconStyle = style
    }

    /// 右键菜单：空白处或分组标题唤起侧栏通用操作菜单；具体节点提供针对性操作 + 展示分类选项。
    private func makeContextMenu(for node: SidebarNode?) -> NSMenu? {
        guard let node, !node.isGroup else {
            return makeSidebarAreaMenu()
        }
        contextNode = node
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 1. 连接服务器入口
        if node.kind == .connectServer {
            let connect = NSMenuItem(title: "连接服务器…".localized, action: #selector(connectServerMenuClicked), keyEquivalent: "k")
            connect.keyEquivalentModifierMask = [.command]
            connect.target = self
            menu.addItem(connect)
            menu.addItem(.separator())
            let categoryItem = NSMenuItem(title: "展示分类".localized, action: nil, keyEquivalent: "")
            categoryItem.submenu = makeCategorySubmenu()
            menu.addItem(categoryItem)
            return menu
        }

        // 1b. 所有标签… 入口
        if node.kind == .allTags {
            let showAll = NSMenuItem(title: "显示所有标签…".localized, action: #selector(showAllTagsFromMenuClicked), keyEquivalent: "")
            showAll.target = self
            menu.addItem(showAll)
            let extraTags = Tags.allSystemTags
            if !extraTags.isEmpty {
                menu.addItem(.separator())
                for def in extraTags {
                    let item = NSMenuItem(title: def.name, action: #selector(openTagInOtherPaneClicked(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = def.name
                    item.image = def.colorKey == "none" ? Tags.paletteIcon(color: nil, diameter: 12) : Tags.dotImage(color: def.color, diameter: 12)
                    menu.addItem(item)
                }
            }
            return menu
        }

        // 2. 标签菜单
        if node.kind == .tag {
            let tagName = node.tag ?? node.title

            // 1. 在新标签页中打开
            let openItem = NSMenuItem(title: "在新标签页中打开".localized, action: #selector(openTagInOtherPaneClicked), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = tagName
            menu.addItem(openItem)

            menu.addItem(.separator())

            // 2. 从边栏中移除
            let hideItem = NSMenuItem(title: "从边栏中移除".localized, action: #selector(hideTagFromSidebarClicked), keyEquivalent: "")
            hideItem.target = self
            hideItem.representedObject = tagName
            menu.addItem(hideItem)

            // 3. 删除标签 “xxx”…
            let deleteItem = NSMenuItem(title: "删除标签 “\(tagName)”…", action: #selector(deleteTagClicked), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = tagName
            menu.addItem(deleteItem)

            menu.addItem(.separator())

            // 4. 给“xxx”重新命名
            let renameItem = NSMenuItem(title: "给“\(tagName)”重新命名", action: #selector(renameTagClicked), keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = tagName
            menu.addItem(renameItem)

            menu.addItem(.separator())

            // 5. 调色盘颜色选项（单选带勾选状态）
            let tagDef = Tags.all.first(where: { $0.name == tagName })
            let currentColorKey = tagDef?.colorKey ?? ""

            // 无颜色
            let noneItem = NSMenuItem(title: "无颜色".localized, action: #selector(colorPickedForTag(_:)), keyEquivalent: "")
            noneItem.target = self
            noneItem.representedObject = (tagName: tagName, colorKey: "none")
            noneItem.image = makePaletteIcon(color: nil)
            noneItem.state = (currentColorKey == "none" || tagDef?.xattrIndex == 0) ? .on : .off
            menu.addItem(noneItem)

            // 红色、橙色、黄色、绿色、蓝色、紫色、灰色
            let colorChoices: [(key: String, title: String, color: NSColor)] = [
                ("red", "红色", .systemRed),
                ("orange", "橙色", .systemOrange),
                ("yellow", "黄色", .systemYellow),
                ("green", "绿色", .systemGreen),
                ("blue", "蓝色", .systemBlue),
                ("purple", "紫色", .systemPurple),
                ("gray", "灰色", .systemGray)
            ]

            for choice in colorChoices {
                let item = NSMenuItem(title: choice.title, action: #selector(colorPickedForTag(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = (tagName: tagName, colorKey: choice.key)
                item.image = makePaletteIcon(color: choice.color)
                item.state = (currentColorKey == choice.key) ? .on : .off
                menu.addItem(item)
            }

            return menu
        }

        // 3. 服务器
        if node.kind == .server {
            let openOrConnect = NSMenuItem(
                title: node.url != nil ? "在新窗格中打开" : "连接服务器…",
                action: #selector(openOrConnectContextServerClicked),
                keyEquivalent: ""
            )
            openOrConnect.target = self
            menu.addItem(openOrConnect)

            // 如果是已挂载的网络卷：显示「推出」
            if node.isMountedNetworkVolume, let url = node.url {
                let unmount = NSMenuItem(title: "\("推出".localized)“\(node.title)”", action: #selector(ejectVolumeClicked(_:)), keyEquivalent: "E")
                unmount.keyEquivalentModifierMask = [.command]
                unmount.target = self
                unmount.representedObject = url
                menu.addItem(unmount)
            }

            menu.addItem(.separator())

            if let url = node.url {
                let reveal = NSMenuItem(title: "在 Finder 中显示".localized, action: #selector(revealClicked), keyEquivalent: "")
                reveal.target = self
                menu.addItem(reveal)

                let currentTerm = TerminalManager.shared.currentTerminal()
                let terminal = NSMenuItem(title: String(format: "在“%@”中打开".localized, currentTerm.displayName), action: #selector(openInTerminalClicked), keyEquivalent: "")
                terminal.target = self
                terminal.representedObject = url
                menu.addItem(terminal)
                appendSidebarOtherTerminalsMenu(to: menu, targetURL: url, currentTerm: currentTerm)

                let copyPath = NSMenuItem(title: "拷贝路径".localized, action: #selector(copyPathClicked), keyEquivalent: "C")
                copyPath.keyEquivalentModifierMask = [.command, .option]
                copyPath.target = self
                copyPath.representedObject = url
                menu.addItem(copyPath)
            }

            if let entry = node.serverEntry {
                if let serverURL = entry.url {
                    let copyServerURL = NSMenuItem(title: "拷贝服务器地址".localized, action: #selector(copyServerURLClicked), keyEquivalent: "")
                    copyServerURL.target = self
                    copyServerURL.representedObject = serverURL
                    menu.addItem(copyServerURL)
                }

                menu.addItem(.separator())

                let editItem = NSMenuItem(title: "编辑服务器连接…".localized, action: #selector(editContextServerClicked), keyEquivalent: "")
                editItem.target = self
                editItem.representedObject = entry
                menu.addItem(editItem)

                let remove = NSMenuItem(title: "从列表中移除".localized, action: #selector(removeSavedServerClicked(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = entry.id
                menu.addItem(remove)
            }

            menu.addItem(.separator())
            let refresh = NSMenuItem(title: "刷新".localized, action: #selector(refreshClicked), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)

            menu.addItem(.separator())
            let categoryItem = NSMenuItem(title: "展示分类".localized, action: nil, keyEquivalent: "")
            categoryItem.submenu = makeCategorySubmenu()
            menu.addItem(categoryItem)
            return menu
        }

        // 4. 废纸篓
        if node.isTrash {
            if let url = node.url {
                let openInOther = NSMenuItem(title: "在新窗格中打开".localized, action: #selector(openInOtherPaneClicked), keyEquivalent: "")
                openInOther.target = self
                openInOther.representedObject = url
                menu.addItem(openInOther)
            }

            let emptyTrash = NSMenuItem(title: "清倒废纸篓…".localized, action: #selector(emptyTrashClicked), keyEquivalent: "")
            emptyTrash.target = self
            menu.addItem(emptyTrash)

            menu.addItem(.separator())

            if let url = node.url {
                let reveal = NSMenuItem(title: "在 Finder 中显示".localized, action: #selector(revealClicked), keyEquivalent: "")
                reveal.target = self
                menu.addItem(reveal)

                let copyPath = NSMenuItem(title: "拷贝路径".localized, action: #selector(copyPathClicked), keyEquivalent: "")
                copyPath.target = self
                copyPath.representedObject = url
                menu.addItem(copyPath)
            }

            menu.addItem(.separator())
            let refresh = NSMenuItem(title: "刷新".localized, action: #selector(refreshClicked), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)

            menu.addItem(.separator())
            let categoryItem = NSMenuItem(title: "展示分类".localized, action: nil, keyEquivalent: "")
            categoryItem.submenu = makeCategorySubmenu()
            menu.addItem(categoryItem)
            return menu
        }

        // 5. 挂载的本地磁盘、DMG 镜像、外置磁盘或文件夹条目
        if let url = node.url {
            let openInOther = NSMenuItem(title: "在新窗格中打开".localized, action: #selector(openInOtherPaneClicked), keyEquivalent: "")
            openInOther.target = self
            openInOther.representedObject = url
            menu.addItem(openInOther)

            // 【核心推出功能】：若是可推出的挂载卷/外置磁盘/DMG，提供「推出“名称”」
            if node.isEjectableVolume || Self.isVolumeEjectable(url: url) {
                let eject = NSMenuItem(title: "\("推出".localized)“\(node.title)”", action: #selector(ejectVolumeClicked(_:)), keyEquivalent: "E")
                eject.keyEquivalentModifierMask = [.command]
                eject.target = self
                eject.representedObject = url
                menu.addItem(eject)
            }

            menu.addItem(.separator())

            // 针对个人收藏文件夹：新建文件夹
            if node.isUserFavorite || !node.isEjectableVolume {
                let newFolder = NSMenuItem(title: "新建文件夹…".localized, action: #selector(newFolderInContextClicked), keyEquivalent: "N")
                newFolder.keyEquivalentModifierMask = [.command, .shift]
                newFolder.target = self
                newFolder.representedObject = url
                menu.addItem(newFolder)
            }

            let reveal = NSMenuItem(title: "在 Finder 中显示".localized, action: #selector(revealClicked), keyEquivalent: "")
            reveal.target = self
            menu.addItem(reveal)

            let currentTerm = TerminalManager.shared.currentTerminal()
            let terminal = NSMenuItem(title: String(format: "在“%@”中打开".localized, currentTerm.displayName), action: #selector(openInTerminalClicked), keyEquivalent: "")
            terminal.target = self
            terminal.representedObject = url
            menu.addItem(terminal)
            appendSidebarOtherTerminalsMenu(to: menu, targetURL: url, currentTerm: currentTerm)

            let copyPath = NSMenuItem(title: "拷贝路径".localized, action: #selector(copyPathClicked), keyEquivalent: "C")
            copyPath.keyEquivalentModifierMask = [.command, .option]
            copyPath.target = self
            copyPath.representedObject = url
            menu.addItem(copyPath)

            let getInfo = NSMenuItem(title: "显示简介".localized, action: #selector(getInfoClicked), keyEquivalent: "i")
            getInfo.keyEquivalentModifierMask = [.command]
            getInfo.target = self
            getInfo.representedObject = url
            menu.addItem(getInfo)

            if node.isUserFavorite {
                menu.addItem(.separator())
                let remove = NSMenuItem(title: "从个人收藏中移除".localized, action: #selector(removeFavoriteClicked), keyEquivalent: "")
                remove.target = self
                remove.representedObject = url
                menu.addItem(remove)
            }

            menu.addItem(.separator())
            let refresh = NSMenuItem(title: "刷新".localized, action: #selector(refreshClicked), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)

            menu.addItem(.separator())
            let categoryItem = NSMenuItem(title: "展示分类".localized, action: nil, keyEquivalent: "")
            categoryItem.submenu = makeCategorySubmenu()
            menu.addItem(categoryItem)
            return menu
        }

        return makeSidebarAreaMenu()
    }

    // MARK: - 数据

    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .tagsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .favoritesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .sidebarIconSizeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .sidebarIconStyleDidChange, object: nil)
    }

    @objc private func volumesChanged() { reload() }

    func reload(preservingCurrentURL currentURL: URL? = nil) {
        // 保存当前视口的滚动位置，避免增删标签或刷新时滚动条跳回顶部
        let clipView = outline.enclosingScrollView?.contentView
        let savedScrollOrigin = clipView?.bounds.origin

        let previousURL = currentURL ?? currentURLProvider?() ?? selectedNode()?.url
        let previousTag = selectedNode()?.tag
        let previousWasAllTags = (selectedNode()?.kind == .allTags)

        let wasRestoring = isRestoringSelection
        isRestoringSelection = true
        defer { isRestoringSelection = wasRestoring }

        let home = FileManager.default.homeDirectoryForCurrentUser
        var list: [SidebarNode] = []

        // 1. 个人收藏
        if AppSettings.isSidebarCategoryVisible(.favorites) {
            let favorites = SidebarNode(kind: .group, title: SidebarCategory.favorites.title, category: .favorites)
            for (directory, title) in Self.favoriteEntries {
                guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else { continue }
                if AppSettings.isFavorite(url) {
                    favorites.children.append(SidebarNode(kind: .folder, title: title, url: url, usesSystemIcon: true, category: .favorites))
                }
            }
            if AppSettings.isFavorite(home) {
                favorites.children.append(SidebarNode(kind: .folder, title: "主目录".localized, url: home, symbol: "house.fill", category: .favorites))
            }
            let appURL = URL(fileURLWithPath: "/Applications")
            if AppSettings.isFavorite(appURL) {
                favorites.children.append(SidebarNode(kind: .folder,
                                                      title: "应用程序".localized,
                                                      url: appURL,
                                                      usesSystemIcon: true,
                                                      category: .favorites))
            }
            let defaultPaths = AppSettings.defaultFavoritePaths()
            for path in AppSettings.favorites {
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if defaultPaths.contains(url.standardizedFileURL.path) { continue }
                let name = FileManager.default.displayName(atPath: url.path)
                let title = name.isEmpty ? url.lastPathComponent : name
                favorites.children.append(SidebarNode(kind: .folder,
                                                      title: title,
                                                      url: url,
                                                      usesSystemIcon: true,
                                                      isUserFavorite: true,
                                                      category: .favorites))
            }
            applySavedOrder(to: favorites)
            list.append(favorites)
        }

        // 2. iCloud
        if AppSettings.isSidebarCategoryVisible(.icloud) {
            let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            if FileManager.default.fileExists(atPath: cloud.path) {
                let group = SidebarNode(kind: .group, title: SidebarCategory.icloud.title, category: .icloud)
                group.children.append(SidebarNode(kind: .folder, title: "iCloud 云盘".localized, url: cloud, symbol: "icloud", category: .icloud))
                applySavedOrder(to: group)
                list.append(group)
            }
        }

        // 3. 位置：本地根卷 + 已挂载的本地外置磁盘，最后是废纸篓
        if AppSettings.isSidebarCategoryVisible(.locations) {
            let locations = SidebarNode(kind: .group, title: SidebarCategory.locations.title, category: .locations)
            for volume in Self.localVolumeEntries() {
                locations.children.append(SidebarNode(kind: .folder,
                                                      title: volume.name,
                                                      url: volume.url,
                                                      usesSystemIcon: true,
                                                      isEjectableVolume: volume.isEjectable,
                                                      category: .locations))
            }
            if let trash = Self.trashURL() {
                locations.children.append(SidebarNode(kind: .folder,
                                                      title: "废纸篓".localized,
                                                      url: trash,
                                                      usesSystemIcon: true,
                                                      isTrash: true,
                                                      category: .locations))
            }
            applySavedOrder(to: locations)
            list.append(locations)
        }

        // 4. 服务器：已挂载的网络卷 + 已保存的常用服务器 + 「连接服务器…」快捷入口
        if AppSettings.isSidebarCategoryVisible(.servers) {
            let serversGroup = SidebarNode(kind: .group, title: SidebarCategory.servers.title, category: .servers)
            let mountedNets = ServerConnectWindowController.mountedNetworkVolumes()
            var handledMountPaths = Set<String>()

            // 先展示用户已保存的服务器（如果已挂载则关联其挂载路径）
            for entry in AppSettings.savedServers {
                let matchedMount = entry.url.flatMap { ServerConnectWindowController.findMountedVolume(matching: $0) }
                if let m = matchedMount {
                    handledMountPaths.insert(m.standardizedFileURL.path)
                }
                serversGroup.children.append(
                    SidebarNode(
                        kind: .server,
                        title: entry.hostDisplay,
                        url: matchedMount,
                        serverEntry: entry,
                        isMountedNetworkVolume: matchedMount != nil,
                        category: .servers
                    )
                )
            }

            // 再展示其它当前已挂载但未在收藏中的网络卷
            for net in mountedNets where !handledMountPaths.contains(net.url.standardizedFileURL.path) {
                let tempEntry = net.remountURL.map { ServerEntry(name: net.name, urlString: $0.absoluteString) }
                serversGroup.children.append(
                    SidebarNode(
                        kind: .server,
                        title: net.name,
                        url: net.url,
                        serverEntry: tempEntry,
                        isMountedNetworkVolume: true,
                        category: .servers
                    )
                )
            }

            // 始终提供「连接服务器…」入口
            serversGroup.children.append(
                SidebarNode(
                    kind: .connectServer,
                    title: "连接服务器…".localized,
                    symbol: "plus.circle",
                    category: .servers
                )
            )
            applySavedOrder(to: serversGroup)
            list.append(serversGroup)
        }

        // 5. 标签
        if AppSettings.isSidebarCategoryVisible(.tags) {
            let tags = SidebarNode(kind: .group, title: SidebarCategory.tags.title, category: .tags)
            for tag in Tags.all {
                tags.children.append(SidebarNode(kind: .tag,
                                                 title: tag.name,
                                                 tag: tag.name,
                                                 dotColor: tag.color,
                                                 category: .tags))
            }
            // 对齐访达侧栏底部「所有标签…」入口
            tags.children.append(SidebarNode(kind: .allTags, title: "所有标签…".localized, category: .tags))
            list.append(tags)
        }

        nodes = list
        outline.deselectAll(nil)
        outline.reloadData()
        for node in nodes { outline.expandItem(node) }

        if previousWasAllTags {
            selectAllTagsRow(scrollToVisible: false)
        } else if let tag = previousTag {
            select(tag: tag, scrollToVisible: false)
        } else if let url = previousURL {
            select(url: url, scrollToVisible: false)
        } else {
            outline.deselectAll(nil)
        }

        // 精准恢复原本的滚动位置
        if let savedScrollOrigin, let clipView = outline.enclosingScrollView?.contentView {
            clipView.scroll(to: savedScrollOrigin)
            outline.enclosingScrollView?.reflectScrolledClipView(clipView)

            // 再次在下一次 Runloop 校验确认，防止 NSOutlineView 布局重排后将滚动条重置
            DispatchQueue.main.async { [weak self] in
                guard let self, let clip = self.outline.enclosingScrollView?.contentView else { return }
                clip.scroll(to: savedScrollOrigin)
                self.outline.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
    }

    private static var favoriteEntries: [(FileManager.SearchPathDirectory, String)] {
        [
            (.desktopDirectory, "桌面".localized),
            (.documentDirectory, "文稿".localized),
            (.downloadsDirectory, "下载".localized),
            (.moviesDirectory, "影片".localized),
            (.musicDirectory, "音乐".localized),
            (.picturesDirectory, "图片".localized)
        ]
    }

    /// 按用户拖拽保存的顺序排列某个分组内的子项（底部固定入口如「连接服务器…」「所有标签…」保持在末尾）
    private func applySavedOrder(to group: SidebarNode) {
        guard let category = group.category else { return }
        let savedOrder = AppSettings.sidebarSectionOrder(for: category)
        guard !savedOrder.isEmpty else { return }

        let reorderable = group.children.filter { $0.isReorderable }
        let pinned = group.children.filter { !$0.isReorderable }

        var orderIndexMap: [String: Int] = [:]
        for (idx, id) in savedOrder.enumerated() where orderIndexMap[id] == nil {
            orderIndexMap[id] = idx
        }

        let enumerated = reorderable.enumerated().map { ($0.offset, $0.element) }
        let sorted = enumerated.sorted { lhs, rhs in
            let lOrder = orderIndexMap[lhs.1.reorderIdentifier] ?? (savedOrder.count + lhs.0)
            let rOrder = orderIndexMap[rhs.1.reorderIdentifier] ?? (savedOrder.count + rhs.0)
            if lOrder != rOrder {
                return lOrder < rOrder
            }
            return lhs.0 < rhs.0
        }.map { $0.1 }

        group.children = sorted + pinned
    }

    /// 查找某个子节点所属的顶层分组节点
    private func parentGroup(of child: SidebarNode) -> SidebarNode? {
        for group in nodes where group.isGroup {
            if group.children.contains(where: { $0 === child }) {
                return group
            }
        }
        return nil
    }

    /// 持久化某个分组内拖拽调整后的新顺序
    private func persistOrder(for group: SidebarNode) {
        guard let category = group.category else { return }
        if category == .tags {
            let names = group.children.compactMap { $0.tag }
            Tags.reorderSidebarTags(names: names)
            return
        }
        let ids = group.children.filter { $0.isReorderable }.map { $0.reorderIdentifier }
        AppSettings.setSidebarSectionOrder(ids, for: category)
        if category == .servers {
            let currentSaved = AppSettings.savedServers
            var map: [String: ServerEntry] = [:]
            for s in currentSaved { map[s.id] = s }
            var reorderedServers: [ServerEntry] = []
            var seen = Set<String>()
            for id in ids {
                if let s = map[id], seen.insert(id).inserted {
                    reorderedServers.append(s)
                }
            }
            for s in currentSaved where seen.insert(s.id).inserted {
                reorderedServers.append(s)
            }
            AppSettings.savedServers = reorderedServers
        }
    }

    /// 本地卷：根卷排在最前（名字取真实的卷名，如 Macintosh HD），随后是其它已挂载的本地可浏览卷（不含网络卷）。
    private static func localVolumeEntries() -> [(name: String, url: URL, isEjectable: Bool)] {
        var result: [(String, URL, Bool)] = []
        let root = URL(fileURLWithPath: "/")
        let rootName = (try? root.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        result.append((rootName?.isEmpty == false ? rootName! : "Macintosh HD", root, false))

        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        for url in urls {
            guard url.standardizedFileURL.path != "/" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]),
                  values.volumeIsBrowsable != false,
                  values.volumeIsLocal != false,
                  let name = values.volumeName, !name.isEmpty else { continue }
            let isEjectable = isVolumeEjectable(url: url)
            result.append((name, url, isEjectable))
        }
        return result
    }

    /// 判断某个路径是否是可推出的磁盘或挂载卷（外置驱动器、DMG镜像、USB驱动器等）
    static func isVolumeEjectable(url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path == "/" { return false }
        if let values = try? url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]) {
            if values.volumeIsRemovable == true || values.volumeIsEjectable == true || values.volumeIsInternal == false {
                return true
            }
        }
        if path.hasPrefix("/Volumes/") && !path.hasSuffix("/Macintosh HD") {
            return true
        }
        return false
    }

    private static func trashURL() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 选中同步

    func select(url: URL, scrollToVisible: Bool = true) {
        activeAllTagsSelection = nil
        let wasRestoring = isRestoringSelection
        isRestoringSelection = true
        defer { isRestoringSelection = wasRestoring }

        let target = url.standardizedFileURL.path

        for node in nodes {
            for child in node.children {
                guard let childURL = child.url else { continue }
                if childURL.standardizedFileURL.path == target {
                    let row = outline.row(forItem: child)
                    if row >= 0 {
                        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        if scrollToVisible {
                            outline.scrollRowToVisible(row)
                        }
                    }
                    return
                }
            }
        }
        outline.deselectAll(nil)
    }

    /// 让某个标签行成为选中项（切换窗格焦点时用）。若该标签不在边栏中（例如「123」），则高亮选中「所有标签…」行。
    func select(tag: String, scrollToVisible: Bool = true) {
        activeAllTagsSelection = tag
        let wasRestoring = isRestoringSelection
        isRestoringSelection = true
        defer { isRestoringSelection = wasRestoring }

        for node in nodes {
            for child in node.children where child.tag == tag {
                let row = outline.row(forItem: child)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    if scrollToVisible {
                        outline.scrollRowToVisible(row)
                    }
                }
                return
            }
        }

        // 若该标签属于「所有标签…」里的额外标签（如 "123"），高亮「所有标签…」行
        selectAllTagsRow(scrollToVisible: scrollToVisible)
    }

    /// 选中侧栏底部的「所有标签…」行
    func selectAllTagsRow(scrollToVisible: Bool = true) {
        let wasRestoring = isRestoringSelection
        isRestoringSelection = true
        defer { isRestoringSelection = wasRestoring }

        for node in nodes {
            for child in node.children where child.kind == .allTags {
                let row = outline.row(forItem: child)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    if scrollToVisible {
                        outline.scrollRowToVisible(row)
                    }
                }
                return
            }
        }
        outline.deselectAll(nil)
    }

    // MARK: - 动作

    @objc private func handleClick() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode else {
            outline.deselectAll(nil)
            return
        }
        if node.kind == .allTags {
            selectAllTagsRow(scrollToVisible: false)
            onSelectAllTags?()
            return
        }
        open(node)
    }

    private func open(_ node: SidebarNode) {
        switch node.kind {
        case .connectServer:
            outline.deselectAll(nil)
            onRequestConnectServer?(nil)
        case .server:
            if let mountedURL = node.url {
                onSelect?(mountedURL)
            } else if let entry = node.serverEntry {
                ServerConnectWindowController.shared.connect(entry: entry)
            } else {
                onRequestConnectServer?(nil)
            }
        case .tag:
            if let tag = node.tag {
                activeAllTagsSelection = tag
                onSelectTag?(tag)
            }
        case .allTags:
            selectAllTagsRow(scrollToVisible: false)
            onSelectAllTags?()
        case .folder:
            if let url = node.url { onSelect?(url) }
        case .group:
            break
        }
    }

    @objc private func showAllTagsFromMenuClicked() {
        selectAllTagsRow(scrollToVisible: true)
        onSelectAllTags?()
    }

    @objc private func toggleCategoryClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let category = SidebarCategory(rawValue: raw) else { return }
        AppSettings.toggleSidebarCategory(category)
        reload()
    }

    @objc private func showAllCategoriesClicked() {
        AppSettings.showAllSidebarCategories()
        reload()
    }

    @objc private func connectServerMenuClicked() {
        onRequestConnectServer?(nil)
    }

    @objc private func browseNetworkMenuClicked() {
        onSelect?(URL(fileURLWithPath: "/Network"))
    }

    @objc private func expandAllGroupsClicked() {
        for node in nodes { outline.expandItem(node) }
    }

    @objc private func collapseAllGroupsClicked() {
        for node in nodes { outline.collapseItem(node) }
    }

    @objc private func openOrConnectContextServerClicked() {
        guard let node = contextNode ?? selectedNode() else { return }
        open(node)
    }

    @objc private func editContextServerClicked(_ sender: NSMenuItem) {
        let entry = sender.representedObject as? ServerEntry
        onRequestConnectServer?(entry)
    }

    @objc private func unmountServerClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
        reload()
    }

    @objc private func removeSavedServerClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AppSettings.removeServer(id: id)
        reload()
    }

    @objc private func revealClicked() {
        let node = contextNode ?? selectedNode()
        guard let url = node?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func refreshClicked() { reload() }

    /// 从个人收藏里移除某个条目。
    @objc private func removeFavoriteClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        AppSettings.removeFavorite(url)
        reload()
    }

    /// 边栏右键将文件夹移到废纸篓
    @objc private func trashContextNodeClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == "/" || path == home || path == "/Applications" || path == "/System" {
            let alert = NSAlert()
            alert.messageText = "系统核心目录不能移到废纸篓"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        FileOperations.playTrashSound()
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            if AppSettings.isFavorite(url) {
                AppSettings.removeFavorite(url)
            }
            reload()
            NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// 边栏右键直接永久删除文件夹
    @objc private func deleteContextNodeImmediatelyClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == "/" || path == home || path == "/Applications" || path == "/System" {
            let alert = NSAlert()
            alert.messageText = "系统核心目录不能直接删除"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        FileOperations.deleteImmediately(urls: [url], window: window) { [weak self] success in
            if success {
                if AppSettings.isFavorite(url) {
                    AppSettings.removeFavorite(url)
                }
                self?.reload()
            }
        }
    }

    @objc private func settingsButtonClicked() {
        onOpenSettings?()
    }

    @objc private func openTagInOtherPaneClicked(_ sender: NSMenuItem) {
        guard let tagName = sender.representedObject as? String ?? contextNode?.tag ?? contextNode?.title else { return }
        onSelectTag?(tagName)
    }

    func addNewTag() {
        let newDef = Tags.addTag()
        reload()
        if let tagsGroup = nodes.first(where: { $0.title == SidebarCategory.tags.title }) {
            outline.expandItem(tagsGroup)
        }
        select(tag: newDef.name)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startRenamingSelectedTag()
        }
    }

    func startRenamingSelectedTag() {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode, node.kind == .tag else { return }
        let oldName = node.tag ?? node.title
        outline.scrollRowToVisible(row)
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarItemCell else { return }
        cell.startInlineEditing(oldName: oldName, onCommit: { [weak self] newName in
            Tags.renameTag(oldName: oldName, newName: newName)
            self?.reload()
            self?.select(tag: newName)
        }, onCancel: { [weak self] in
            self?.reload()
            self?.select(tag: oldName)
        })
    }

    @objc private func renameTagClicked(_ sender: NSMenuItem) {
        guard let tagName = sender.representedObject as? String ?? contextNode?.tag ?? contextNode?.title else { return }
        promptRenameTag(named: tagName)
    }

    private func promptRenameTag(named tagName: String) {
        if Tags.isTagInSidebar(named: tagName) {
            select(tag: tagName)
            startRenamingSelectedTag()
        } else {
            let alert = NSAlert()
            alert.messageText = "给“\(tagName)”重新命名"
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            input.stringValue = tagName
            alert.accessoryView = input
            alert.addButton(withTitle: "好")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !newName.isEmpty && newName != tagName {
                    let wasShowing = isShowingTag?(tagName) ?? false
                    Tags.renameTag(oldName: tagName, newName: newName)
                    reload()
                    if wasShowing {
                        onSelectTag?(newName)
                    }
                    select(tag: newName)
                }
            }
        }
    }

    @objc private func openInOtherPaneClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? URL) ?? contextNode?.url else { return }
        onOpenInOtherPane?(url)
    }

    @objc private func ejectVolumeClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? URL) ?? contextNode?.url else { return }
        let title = contextNode?.title ?? url.lastPathComponent
        eject(url: url, title: title)
    }

    func eject(url: URL, title: String) {
        let volName = title.isEmpty ? url.lastPathComponent : title
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var success = false
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                success = true
            } catch {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                p.arguments = ["unmount", url.path]
                try? p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    success = true
                } else {
                    let p2 = Process()
                    p2.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                    p2.arguments = ["unmount", "force", url.path]
                    try? p2.run()
                    p2.waitUntilExit()
                    if p2.terminationStatus == 0 {
                        success = true
                    } else {
                        let h = Process()
                        h.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                        h.arguments = ["detach", url.path, "-force"]
                        try? h.run()
                        h.waitUntilExit()
                        success = (h.terminationStatus == 0)
                    }
                }
            }

            DispatchQueue.main.async {
                if !success {
                    let alert = NSAlert()
                    alert.messageText = "无法推出“\(volName)”"
                    alert.informativeText = "该磁盘可能正被其它应用程序使用。请先关闭使用该磁盘的程序后再试。"
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
                self?.reload()
            }
        }
    }

    @objc private func openInTerminalClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? URL) ?? contextNode?.url else { return }
        TerminalManager.shared.open(directoryURL: url)
    }

    @objc private func openInSpecificTerminalClicked(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? (url: URL, term: InstalledTerminal) else { return }
        TerminalManager.shared.open(directoryURL: payload.url, using: payload.term)
    }

    @objc private func openTerminalPreferencesClicked() {
        NotificationCenter.default.post(name: .openTerminalSettingsRequested, object: nil)
    }

    private func appendSidebarOtherTerminalsMenu(to menu: NSMenu, targetURL: URL, currentTerm: InstalledTerminal) {
        let otherTerms = TerminalManager.shared.scanInstalledTerminals().filter { $0.id != currentTerm.id }
        guard !otherTerms.isEmpty else { return }
        let otherMenu = NSMenu()
        otherMenu.autoenablesItems = false
        for term in otherTerms {
            let item = NSMenuItem(title: term.displayName, action: #selector(openInSpecificTerminalClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (url: targetURL, term: term)
            item.image = term.icon
            otherMenu.addItem(item)
        }
        otherMenu.addItem(.separator())
        let prefItem = NSMenuItem(title: "设置默认终端…".localized, action: #selector(openTerminalPreferencesClicked), keyEquivalent: "")
        prefItem.target = self
        otherMenu.addItem(prefItem)

        let otherItem = NSMenuItem(title: "其他终端".localized, action: nil, keyEquivalent: "")
        otherItem.submenu = otherMenu
        menu.addItem(otherItem)
    }

    @objc private func copyPathClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? URL) ?? contextNode?.url else { return }
        let pboard = NSPasteboard.general
        pboard.clearContents()
        pboard.setString(url.path, forType: .string)
    }

    @objc private func copyServerURLClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? URL) ?? contextNode?.url else { return }
        let pboard = NSPasteboard.general
        pboard.clearContents()
        pboard.setString(url.absoluteString, forType: .string)
    }

    @objc private func getInfoClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? URL) ?? contextNode?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        let script = "tell application \"Finder\" to open information window of (POSIX file \"\(url.path)\" as alias)"
        if let appleScript = NSAppleScript(source: script) {
            var err: NSDictionary?
            appleScript.executeAndReturnError(&err)
        }
    }

    @objc private func newFolderInContextClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? URL) ?? contextNode?.url else { return }
        let folderName = contextNode?.title ?? url.lastPathComponent
        let alert = NSAlert()
        alert.messageText = "新建文件夹"
        alert.informativeText = "在“\(folderName)”中新建子文件夹："
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = "未命名文件夹"
        alert.accessoryView = input
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let folderToCreate = name.isEmpty ? "未命名文件夹" : name
            let newURL = url.appendingPathComponent(folderToCreate)
            try? FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: true)
            reload()
        }
    }

    @objc private func emptyTrashClicked(_ sender: NSMenuItem) {
        FileOperations.emptyTrash(window: window) { [weak self] in
            self?.reload()
        }
    }

    private func makePaletteIcon(color: NSColor?) -> NSImage {
        Tags.paletteIcon(color: color, diameter: 14)
    }

    @objc private func hideTagFromSidebarClicked(_ sender: NSMenuItem) {
        guard let tagName = (sender.representedObject as? String) ?? contextNode?.tag ?? contextNode?.title else { return }
        if selectedNode()?.tag == tagName {
            outline.deselectAll(nil)
        }
        Tags.hideTagFromSidebar(named: tagName)
        onTagRemoved?(tagName)
        reload()
    }

    @objc private func colorPickedForTag(_ sender: NSMenuItem) {
        guard let tuple = sender.representedObject as? (tagName: String, colorKey: String) else { return }
        Tags.updateTagColor(named: tuple.tagName, colorKey: tuple.colorKey)
        reload()
    }

    @objc private func deleteTagClicked(_ sender: NSMenuItem) {
        guard let tagName = (sender.representedObject as? String) ?? contextNode?.tag ?? contextNode?.title else { return }
        confirmAndDeleteTag(named: tagName)
    }

    func confirmAndDeleteTag(named tagName: String) {
        let paneURLs = getURLsForTagInPanes?(tagName) ?? []
        var affectedSet = Set(paneURLs)
        for url in Tags.findURLs(tagged: tagName) {
            affectedSet.insert(url)
        }
        let itemCount = affectedSet.count

        let executeDeletion = { [weak self] in
            guard let self else { return }
            let wasShowing = (self.isShowingTag?(tagName) ?? false)
                || (self.selectedNode()?.tag == tagName)
                || (self.activeAllTagsSelection == tagName)
            if self.activeAllTagsSelection == tagName {
                self.activeAllTagsSelection = nil
            }
            if self.selectedNode()?.tag == tagName {
                self.outline.deselectAll(nil)
            }
            if let result = Tags.removeTag(named: tagName, extraURLs: Array(affectedSet)) {
                let record = TagDeletionRecord(
                    tagDef: result.definition,
                    originalIndex: result.index,
                    affectedURLs: result.affectedURLs,
                    wasShowingInPane: wasShowing
                )
                self.tagUndoStack.append(record)
            }
            self.onTagRemoved?(tagName)
            NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
            self.reload()
        }

        if let win = self.window {
            FinderTagDeleteOverlay.present(
                in: win,
                tagName: tagName,
                itemCount: itemCount,
                onConfirm: executeDeletion
            )
        } else {
            executeDeletion()
        }
    }

    /// 撤销刚刚删除的标签并恢复所有被标记的文件/文件夹
    @discardableResult
    func undoTagDeletion() -> Bool {
        guard let record = tagUndoStack.popLast() else { return false }
        Tags.restoreTag(record.tagDef, at: record.originalIndex)
        for url in record.affectedURLs {
            Tags.addTag(tag: record.tagDef.name, to: url)
        }
        NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
        NotificationCenter.default.post(name: .tagsDidChange, object: nil)
        reload()
        select(tag: record.tagDef.name)
        if record.wasShowingInPane {
            onSelectTag?(record.tagDef.name)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isUndo = (flags == .control || flags == .command) && chars == "z"
        if isUndo {
            if undoTagDeletion() {
                return
            }
        }
        super.keyDown(with: event)
    }

    private func selectedNode() -> SidebarNode? {
        let row = outline.selectedRow
        guard row >= 0 else { return nil }
        return outline.item(atRow: row) as? SidebarNode
    }
}

// MARK: - 侧栏列表

/// 侧栏列表：右键时按被点中的节点动态生成菜单（点空白区域同样弹出侧栏操作菜单）。
final class SidebarOutlineView: NSOutlineView {
    var menuProvider: ((SidebarNode?) -> NSMenu?)?
    var onUndo: (() -> Bool)?
    private var trackingArea: NSTrackingArea?
    private weak var pendingDragNode: SidebarNode?
    private var pendingDragStartPoint: NSPoint = .zero
    private(set) var isInteractiveDragging: Bool = false

    var hoveredRow: Int = -1 {
        didSet {
            guard oldValue != hoveredRow else { return }
            enumerateAvailableRowViews { rowView, _ in
                rowView.needsDisplay = true
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 如果点击的是推出按钮、加号按钮、折叠箭头或正在内联编辑的文本框，交由系统原样处理
        if let hit = hitTest(superview?.convert(event.locationInWindow, from: nil) ?? point) {
            if hit is NSButton || hit is NSTextView || (hit as? NSTextField)?.isEditable == true {
                super.mouseDown(with: event)
                return
            }
        }

        let row = self.row(at: point)
        guard row >= 0,
              let node = item(atRow: row) as? SidebarNode,
              node.isReorderable else {
            super.mouseDown(with: event)
            return
        }

        pendingDragNode = node
        pendingDragStartPoint = point
        isInteractiveDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let node = pendingDragNode,
              let sidebar = delegate as? SidebarView else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if !isInteractiveDragging {
            let dy = abs(point.y - pendingDragStartPoint.y)
            let dist = hypot(point.x - pendingDragStartPoint.x, point.y - pendingDragStartPoint.y)
            guard dy >= 2.5 || dist >= 3.5 else { return }
            isInteractiveDragging = true
            hoveredRow = -1
            sidebar.beginInteractiveReorder(for: node, startPoint: pendingDragStartPoint, currentPoint: point)
        } else {
            sidebar.updateInteractiveReorder(currentPoint: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let node = pendingDragNode else {
            super.mouseUp(with: event)
            return
        }
        pendingDragNode = nil
        guard let sidebar = delegate as? SidebarView else { return }

        if isInteractiveDragging {
            isInteractiveDragging = false
            sidebar.endInteractiveReorder()
        } else {
            let point = convert(event.locationInWindow, from: nil)
            let row = self.row(at: point)
            if row >= 0, (item(atRow: row) as? SidebarNode) === node {
                sidebar.handleDirectRowClick(row: row, node: node)
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !isInteractiveDragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        if row >= 0, visibleRect.contains(p), let node = item(atRow: row) as? SidebarNode, !node.isGroup {
            hoveredRow = row
        } else {
            hoveredRow = -1
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredRow = -1
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard !isInteractiveDragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        if row >= 0, visibleRect.contains(p), let node = item(atRow: row) as? SidebarNode, !node.isGroup {
            hoveredRow = row
        } else {
            hoveredRow = -1
        }
        enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
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
        hoveredRow = -1
        super.reloadData()
        enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        hoveredRow = -1
        let node = row >= 0 ? (item(atRow: row) as? SidebarNode) : nil
        return menuProvider?(node) ?? super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isUndo = (flags == .control || flags == .command) && chars == "z"
        if isUndo {
            if onUndo?() == true {
                return
            }
        }
        if event.keyCode == 36 || event.characters == "\r" {
            if selectedRow >= 0, let node = item(atRow: selectedRow) as? SidebarNode, node.kind == .tag {
                if let sidebar = delegate as? SidebarView {
                    sidebar.startRenamingSelectedTag()
                    return
                }
            }
        }
        super.keyDown(with: event)
    }
}

// MARK: - 数据源 / 代理

extension SidebarView: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? SidebarNode { return node.children.count }
        return nodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? SidebarNode { return node.children[index] }
        return nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.isGroup == false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? SidebarNode)?.isGroup == true ? 26 : 24
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let node = item as? SidebarNode else { return nil }
        if node.isGroup {
            let identifier = NSUserInterfaceItemIdentifier("SidebarGroupRowView")
            let row = (outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarGroupRowView)
                ?? SidebarGroupRowView()
            row.identifier = identifier
            return row
        }
        let identifier = NSUserInterfaceItemIdentifier("SidebarRowView")
        let row = (outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarRowView)
            ?? SidebarRowView()
        row.identifier = identifier
        row.alphaValue = (node === draggedSidebarNode) ? 0.0 : 1.0
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        if node.isGroup {
            let identifier = NSUserInterfaceItemIdentifier("group")
            let view = (outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarGroupCell)
                ?? SidebarGroupCell(identifier: identifier)
            view.textField?.stringValue = node.title
            let isTags = (node.title == SidebarCategory.tags.title)
            view.plusButton.isHidden = !isTags
            view.onAddTag = { [weak self] in
                self?.addNewTag()
            }
            return view
        }
        let identifier = NSUserInterfaceItemIdentifier("item")
        let view = (outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarItemCell)
            ?? SidebarItemCell(identifier: identifier)
        view.configure(with: node)
        view.onEject = { [weak self] in
            if let url = node.url {
                self?.eject(url: url, title: node.title)
            }
        }
        return view
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection else { return }
        guard let node = selectedNode() else { return }
        if node.kind == .allTags { return }
        open(node)
    }

    // MARK: 拖拽排序与避让动画

    fileprivate func handleDirectRowClick(row: Int, node: SidebarNode) {
        isRestoringSelection = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isRestoringSelection = false
        if node.kind == .allTags {
            selectAllTagsRow(scrollToVisible: false)
            onSelectAllTags?()
            return
        }
        open(node)
    }

    fileprivate func beginInteractiveReorder(for node: SidebarNode, startPoint: NSPoint, currentPoint: NSPoint) {
        guard let group = parentGroup(of: node) else { return }
        let reorderableChildren = group.children.filter { $0.isReorderable }
        guard reorderableChildren.count > 1,
              let sourceIndex = reorderableChildren.firstIndex(where: { $0 === node }) else {
            return
        }

        let sourceRow = outline.row(forItem: node)
        guard sourceRow >= 0 else { return }
        let initialRowRect = outline.rect(ofRow: sourceRow)

        var baseRowRects: [NSRect] = []
        baseRowRects.reserveCapacity(reorderableChildren.count)
        for child in reorderableChildren {
            let r = outline.row(forItem: child)
            baseRowRects.append(r >= 0 ? outline.rect(ofRow: r) : initialRowRect)
        }

        let cellLeadingOffset: CGFloat
        if let cell = outline.view(atColumn: 0, row: sourceRow, makeIfNecessary: false) {
            cellLeadingOffset = outline.convert(cell.bounds.origin, from: cell).x - initialRowRect.minX
        } else {
            cellLeadingOffset = 16
        }

        let prevSelected = selectedNode()
        draggedSidebarNode = node

        // 隐藏原位置行（留出空白槽位）并刷新其余行的选中背景
        if let sourceRowView = outline.rowView(atRow: sourceRow, makeIfNecessary: false) {
            sourceRowView.alphaValue = 0.0
        }
        outline.enumerateAvailableRowViews { rv, _ in
            rv.needsDisplay = true
        }

        let floatingView = SidebarFloatingDragView(
            frame: convert(initialRowRect, from: outline),
            node: node,
            cellLeadingOffset: cellLeadingOffset
        )
        addSubview(floatingView)

        reorderState = InteractiveReorderState(
            node: node,
            group: group,
            reorderableChildren: reorderableChildren,
            sourceIndex: sourceIndex,
            startPointInOutline: startPoint,
            initialRowRect: initialRowRect,
            baseRowRects: baseRowRects,
            floatingView: floatingView,
            previousSelectedNode: prevSelected
        )

        updateInteractiveReorder(currentPoint: currentPoint)
    }

    fileprivate func updateInteractiveReorder(currentPoint: NSPoint) {
        guard let state = reorderState,
              let firstRect = state.baseRowRects.first,
              let lastRect = state.baseRowRects.last else {
            return
        }

        let dy = currentPoint.y - state.startPointInOutline.y
        let dx = min(max((currentPoint.x - state.startPointInOutline.x) * 0.14, -5), 5)
        let rawY = state.initialRowRect.minY + dy
        let minAllowedY = firstRect.minY - 5
        let maxAllowedY = lastRect.minY + 5
        let clampedY: CGFloat
        if rawY < minAllowedY {
            clampedY = minAllowedY - (minAllowedY - rawY) * 0.2
        } else if rawY > maxAllowedY {
            clampedY = maxAllowedY + (rawY - maxAllowedY) * 0.2
        } else {
            clampedY = rawY
        }

        let floatingRectInOutline = NSRect(
            x: state.initialRowRect.minX + dx,
            y: clampedY,
            width: state.initialRowRect.width,
            height: state.initialRowRect.height
        )
        state.floatingView.frame = convert(floatingRectInOutline, from: outline)

        let floatingMidY = floatingRectInOutline.midY
        var newTarget = state.currentTargetIndex
        for (k, rect) in state.baseRowRects.enumerated() {
            if k < state.currentTargetIndex {
                if floatingMidY < rect.midY - 1.5 {
                    newTarget = k
                    break
                }
            } else if k > state.currentTargetIndex {
                if floatingMidY > rect.midY + 1.5 {
                    newTarget = k
                }
            }
        }

        guard newTarget != state.currentTargetIndex else { return }
        state.currentTargetIndex = newTarget

        // 邻行像访达一样平滑上下滑动让出空位
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            for (i, child) in state.reorderableChildren.enumerated() where i != state.sourceIndex {
                let destSlot: Int
                if state.currentTargetIndex > state.sourceIndex {
                    destSlot = (i > state.sourceIndex && i <= state.currentTargetIndex) ? (i - 1) : i
                } else if state.currentTargetIndex < state.sourceIndex {
                    destSlot = (i >= state.currentTargetIndex && i < state.sourceIndex) ? (i + 1) : i
                } else {
                    destSlot = i
                }
                let r = outline.row(forItem: child)
                if r >= 0, let rv = outline.rowView(atRow: r, makeIfNecessary: false) as? SidebarRowView {
                    let targetRect = state.baseRowRects[destSlot]
                    rv.dragTargetFrame = targetRect
                    rv.animator().frame = targetRect
                }
            }
        }
    }

    fileprivate func endInteractiveReorder() {
        guard let state = reorderState else { return }
        reorderState = nil

        let finalSlotRectInSelf = convert(state.baseRowRects[state.currentTargetIndex], from: outline)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            state.floatingView.animator().frame = finalSlotRectInSelf
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.commitInteractiveReorder(state)
        })
    }

    private func commitInteractiveReorder(_ state: InteractiveReorderState) {
        state.floatingView.removeFromSuperview()
        draggedSidebarNode = nil

        outline.enumerateAvailableRowViews { rv, _ in
            rv.alphaValue = 1.0
            if let sRv = rv as? SidebarRowView {
                sRv.dragTargetFrame = nil
            }
            rv.needsDisplay = true
        }

        if state.currentTargetIndex != state.sourceIndex,
           let oldIdx = state.group.children.firstIndex(where: { $0 === state.node }) {
            state.group.children.remove(at: oldIdx)
            state.group.children.insert(state.node, at: state.currentTargetIndex)
            persistOrder(for: state.group)
        }

        isRestoringSelection = true
        outline.reloadData()
        for groupNode in nodes {
            outline.expandItem(groupNode)
        }
        if let prev = state.previousSelectedNode {
            let row = outline.row(forItem: prev)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        isRestoringSelection = false
    }

    // MARK: 外部文件/文件夹拖拽接收

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // 1. 从外部窗格拖拽文件夹到「个人收藏」行间以加入收藏
        if let group = item as? SidebarNode, group.isGroup, group.category == .favorites, index >= 0 {
            let urls = FileOperations.readURLs(from: info)
            let allDirs = !urls.isEmpty && urls.allSatisfy {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            if allDirs {
                return .link
            }
            return []
        }

        // 2. 从窗格拖拽文件到侧栏具体文件夹或废纸篓上
        guard let node = item as? SidebarNode,
              index == NSOutlineViewDropOnItemIndex,
              let dest = node.url,
              node.kind == .folder || node.isTrash else {
            return []
        }
        let urls = FileOperations.readURLs(from: info)
        guard !urls.isEmpty else { return [] }
        return FileOperations.shouldCopy(for: info, destination: dest) ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        // 1. 外部文件夹拖入「个人收藏」指定位置
        if let group = item as? SidebarNode, group.isGroup, group.category == .favorites, index >= 0 {
            let urls = FileOperations.readURLs(from: info).filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            guard !urls.isEmpty else { return false }
            var currentIds = group.children.filter { $0.isReorderable }.map { $0.reorderIdentifier }
            var insertAt = min(max(0, index), currentIds.count)
            for url in urls {
                let stdPath = url.standardizedFileURL.path
                if !AppSettings.isFavorite(url) {
                    AppSettings.toggleFavorite(url)
                }
                if let existingIdx = currentIds.firstIndex(of: stdPath) {
                    currentIds.remove(at: existingIdx)
                    if existingIdx < insertAt { insertAt -= 1 }
                }
                currentIds.insert(stdPath, at: min(insertAt, currentIds.count))
                insertAt += 1
            }
            AppSettings.setSidebarSectionOrder(currentIds, for: .favorites)
            reload()
            return true
        }

        // 2. 文件拖入侧栏目录或废纸篓
        guard let node = item as? SidebarNode, let dest = node.url, node.kind == .folder || node.isTrash else {
            return false
        }
        let urls = FileOperations.readURLs(from: info)
        guard !urls.isEmpty else { return false }
        if node.isTrash {
            FileOperations.playTrashSound()
            NSWorkspace.shared.recycle(urls) { _, _ in
                NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
            }
            return true
        }
        let isCopy = FileOperations.shouldCopy(for: info, destination: dest)
        FileOperations.transfer(urls: urls, to: dest, isCopy: isCopy)
        FileOperations.playFileAddedSound()
        NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
        return true
    }
}

// MARK: - 分组行（支持折叠箭头垂直居中优化）

private final class SidebarGroupRowView: NSTableRowView {

    override func layout() {
        super.layout()

        // 调整所有分组行（位置、iCloud、个人收藏、服务器、标签等）右侧折叠箭头的垂直居中位置
        for sv in subviews {
            if sv.identifier?.rawValue == "NSOutlineViewShowHideButtonKey" || sv is NSButton {
                var f = sv.frame
                // 系统默认 y=0 导致箭头位置偏上，将其下移使得箭头与左侧分组标题文字垂直光学居中
                f.origin.y = 2.5
                sv.frame = f
            }
        }
    }
}

// MARK: - 侧栏标签分组专用的「+」添加按钮（颜色与折叠箭头一致，纯净点击变深反馈）

private final class SidebarPlusButton: NSButton {

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        bezelStyle = .regularSquare
        isBordered = false
        title = ""
        image = Theme.symbol("plus", size: 9, weight: .medium)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        toolTip = "添加标签".localized
        updateAppearance()
    }

    private func updateAppearance() {
        // 与系统折叠箭头保持一致：平时颜色淡灰（.tertiaryLabelColor），按下时变深（.labelColor）
        contentTintColor = isHighlighted ? .labelColor : .tertiaryLabelColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - 单元格

private final class SidebarGroupCell: NSTableCellView {
    let plusButton = SidebarPlusButton()
    var onAddTag: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .secondaryLabelColor
        addSubview(field)
        textField = field

        plusButton.translatesAutoresizingMaskIntoConstraints = false
        plusButton.target = self
        plusButton.action = #selector(plusButtonClicked)
        plusButton.isHidden = true
        addSubview(plusButton)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),

            plusButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
            plusButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: 14),
            plusButton.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    @objc private func plusButtonClicked() {
        onAddTag?()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - 侧栏专用推出按钮（支持悬停深灰/高亮底色反馈、小手光标、默认浅灰）

private final class SidebarEjectButton: NSButton {

    private var trackingArea: NSTrackingArea?

    var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            updateAppearance()
        }
    }

    var isRowSelected = false {
        didSet {
            guard oldValue != isRowSelected else { return }
            updateAppearance()
        }
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        bezelStyle = .regularSquare
        isBordered = false
        title = ""
        image = Theme.symbol("eject.fill", size: 8.5, weight: .medium) ?? NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "推出")
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        layer?.cornerRadius = 3.5
        updateAppearance()
    }

    private func updateAppearance() {
        if isHighlighted {
            contentTintColor = .labelColor
            layer?.backgroundColor = NSColor.separatorColor.cgColor
        } else if isHovered {
            // 鼠标移上去：颜色变深，带精致的微灰背景反馈（完全包含在浅灰色行背景内）
            contentTintColor = .labelColor
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        } else {
            // 默认状态：颜色更浅更干净
            contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.6)
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func resetCursorRects() {
        // 鼠标放上去显示「小手」光标
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }
}

private final class SidebarItemCell: NSTableCellView, NSTextFieldDelegate {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let ejectButton = SidebarEjectButton()
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?

    var onEject: (() -> Void)?

    private(set) var isInlineEditing: Bool = false
    private var isStartingEditing = false
    var onCommitRename: ((String) -> Void)?
    var onCancelRename: (() -> Void)?
    private var originalName: String = ""

    override func prepareForReuse() {
        super.prepareForReuse()
        if isInlineEditing {
            endInlineEditing(commit: false)
        }
    }

    func startInlineEditing(oldName: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        guard !isInlineEditing else { return }
        isInlineEditing = true
        isStartingEditing = true
        self.originalName = oldName
        self.onCommitRename = onCommit
        self.onCancelRename = onCancel

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
        title.delegate = self

        window?.makeFirstResponder(title)
        title.selectText(nil)
        isStartingEditing = false
    }

    func endInlineEditing(commit: Bool) {
        guard isInlineEditing else { return }
        isInlineEditing = false
        title.isEditable = false
        title.isSelectable = false
        title.drawsBackground = false
        title.isBordered = false
        title.layer?.borderWidth = 0
        title.delegate = nil

        let newName = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if commit && !newName.isEmpty && newName != originalName {
            onCommitRename?(newName)
        } else {
            title.stringValue = originalName
            onCancelRename?()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isStartingEditing, isInlineEditing else { return }
        endInlineEditing(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            endInlineEditing(commit: true)
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endInlineEditing(commit: false)
            return true
        }
        return false
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            ejectButton.isRowSelected = (backgroundStyle == .emphasized)
        }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .controlAccentColor
        addSubview(icon)

        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        textField = title

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusDot.isHidden = true
        addSubview(statusDot)

        ejectButton.translatesAutoresizingMaskIntoConstraints = false
        ejectButton.target = self
        ejectButton.action = #selector(ejectButtonClicked)
        ejectButton.isHidden = true
        addSubview(ejectButton)

        let dim = AppSettings.sidebarIconSize.dimension
        let w = icon.widthAnchor.constraint(equalToConstant: dim)
        let h = icon.heightAnchor.constraint(equalToConstant: dim)
        iconWidthConstraint = w
        iconHeightConstraint = h

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            w,
            h,

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),

            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectButton.widthAnchor.constraint(equalToConstant: 16),
            ejectButton.heightAnchor.constraint(equalToConstant: 15),

            title.trailingAnchor.constraint(lessThanOrEqualTo: ejectButton.leadingAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func ejectButtonClicked() {
        onEject?()
    }

    func configure(with node: SidebarNode) {
        let dim = AppSettings.sidebarIconSize.dimension
        iconWidthConstraint?.constant = dim
        iconHeightConstraint?.constant = dim
        title.stringValue = node.title

        let canEject = node.isEjectableVolume || node.isMountedNetworkVolume
        ejectButton.isHidden = !canEject
        ejectButton.toolTip = canEject ? "\("推出".localized)“\(node.title)”" : nil

        statusDot.isHidden = canEject || !node.isMountedNetworkVolume

        if node.kind == .connectServer {
            icon.image = Theme.symbol("plus.circle", size: 13, weight: .medium)
            icon.contentTintColor = .secondaryLabelColor
            title.textColor = .secondaryLabelColor
            return
        }

        if node.kind == .allTags {
            icon.image = Tags.allTagsIcon()
            icon.contentTintColor = nil
            title.textColor = .labelColor
            return
        }

        title.textColor = .labelColor
        if let dotColor = node.dotColor {
            icon.image = Tags.dotImage(color: dotColor)
            icon.contentTintColor = nil
            return
        }

        if AppSettings.sidebarIconStyle == .minimalist {
            icon.image = Theme.minimalistSidebarIcon(for: node, size: dim)
            icon.contentTintColor = .secondaryLabelColor
            return
        }

        if AppSettings.sidebarIconStyle == .category {
            icon.image = Theme.minimalistSidebarIcon(for: node, size: dim)
            icon.contentTintColor = node.category?.iconTintColor ?? .controlAccentColor
            return
        }

        // 彩色图标模式：废纸篓显示原生彩色图标
        if node.isTrash {
            let trashURL = node.url ?? FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            if let trashURL, let special = Theme.specialFolderIcon(for: trashURL, size: dim) {
                icon.image = special
                icon.contentTintColor = nil
                return
            }
        }

        if node.kind == .server {
            icon.image = Theme.serverIcon(urlString: node.serverEntry?.urlString ?? "", size: dim)
            icon.contentTintColor = nil
            return
        }
        if let url = node.url, let special = Theme.specialFolderIcon(for: url, size: dim) {
            icon.image = special
            icon.contentTintColor = nil
            return
        }
        if node.usesSystemIcon, let url = node.url {
            icon.image = NSWorkspace.shared.icon(forFile: url.path)
            icon.contentTintColor = nil
            return
        }
        if node.symbol == "house.fill" {
            icon.image = Theme.colorfulHomeIcon(size: dim)
            icon.contentTintColor = nil
            return
        }
        icon.image = Theme.symbol(node.symbol, size: 13)
        icon.contentTintColor = .controlAccentColor
    }
}

// MARK: - 侧栏选中行与悬停效果

private final class SidebarRowView: NSTableRowView {

    var dragTargetFrame: NSRect?

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        // 返回 .normal，防止系统将选中行的文字强制反白，保持极简深色文字与浅灰底
        .normal
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        dragTargetFrame = nil
        alphaValue = 1.0
        needsDisplay = true
    }

    private var parentOutline: SidebarOutlineView? {
        (superview as? SidebarOutlineView) ?? (enclosingScrollView?.documentView as? SidebarOutlineView)
    }

    private var isHovered: Bool {
        guard let outline = parentOutline, !outline.isInteractiveDragging else {
            return false
        }
        let myRow = outline.row(for: self)
        return myRow >= 0 && outline.hoveredRow == myRow
    }

    override var isSelected: Bool {
        didSet {
            needsDisplay = true
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // selectionHighlightStyle 为 .none 时不调用；留空防止系统原生蓝色绘制
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        // 拖拽排序期间，仅由浮动拖拽块呈现灰色选中块，底层行隐藏静态选中框（与访达一致）
        if parentOutline?.isInteractiveDragging == true {
            return
        }
        let selectionRect = bounds.insetBy(dx: 5, dy: 1)
        if isSelected {
            let path = NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6)
            let fillColor = NSColor(name: nil) { appearance in
                if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                    return NSColor(white: 1.0, alpha: 0.18)
                } else {
                    return NSColor(white: 0.0, alpha: 0.12)
                }
            }
            fillColor.setFill()
            path.fill()
        } else if isHovered {
            let path = NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6)
            let fillColor = NSColor(name: nil) { appearance in
                if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                    return NSColor(white: 1.0, alpha: 0.09)
                } else {
                    return NSColor(white: 0.0, alpha: 0.05)
                }
            }
            fillColor.setFill()
            path.fill()
        }
    }
}

// MARK: - 侧栏拖拽浮动视图

private final class SidebarFloatingDragView: NSView {

    private let pillView = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(frame frameRect: NSRect, node: SidebarNode, cellLeadingOffset: CGFloat) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        // 柔和浮起灰色块状背景 + 访达式微阴影光晕
        pillView.frame = bounds.insetBy(dx: 5, dy: 1)
        pillView.autoresizingMask = [.width, .height]
        pillView.wantsLayer = true
        pillView.layer?.cornerRadius = 6
        pillView.layer?.masksToBounds = false
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 10
        pillView.shadow = shadow
        addSubview(pillView)

        let dim = AppSettings.sidebarIconSize.dimension
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        if let dotColor = node.dotColor {
            iconView.image = Tags.dotImage(color: dotColor)
            iconView.alphaValue = 0.65
        } else {
            iconView.image = Theme.minimalistSidebarIcon(for: node, size: dim)
            iconView.contentTintColor = .secondaryLabelColor
        }
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = node.title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: cellLeadingOffset + 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: dim),
            iconView.heightAnchor.constraint(equalToConstant: dim),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
        ])

        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        pillView.layer?.backgroundColor = (isDark
            ? NSColor(white: 1.0, alpha: 0.14)
            : NSColor(white: 0.0, alpha: 0.08)).cgColor
    }
}
