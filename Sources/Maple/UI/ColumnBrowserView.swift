import AppKit

/// 分栏浏览（Finder / QSpace 的「分栏」模式）。
///
/// 最左一列是当前目录，点开其中一个文件夹，就在它右侧展开该文件夹的内容，
/// 逐级向右延伸；选中文件则收起右侧多余的列。列宽固定，整排可横向滚动。
final class ColumnBrowserView: NSView {

    var onOpen: ((FileItem) -> Void)?
    var onSelectionChange: ((Set<URL>) -> Void)?
    var onActivate: (() -> Void)?
    /// 当前显示位置变化：目录（面包屑末级）+ 选中的文件（若有）。
    var onLocationChange: ((URL, FileItem?) -> Void)?
    /// 其它按键（⌘C、空格、⌫ 等）交给窗格处理。
    var keyHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((FileItem?) -> NSMenu?)?
    var onFileRenamed: ((URL, URL) -> Void)?
    var onDropFiles: (([URL], URL, Bool) -> Void)?

    /// 单列宽度常量（支持自由拖拽分界线拉宽分栏与预览，彻底避免信息展示受限）
    static let minColumnWidth: CGFloat = 140
    static let maxColumnWidth: CGFloat = 1000
    static var defaultColumnWidth: CGFloat { AppSettings.browserColumnWidth }

    func applyColumnWidth(_ width: CGFloat) {
        let clamped = max(Self.minColumnWidth, min(Self.maxColumnWidth, width))
        for col in columns {
            col.columnWidth = clamped
        }
        previewColumn?.columnWidth = clamped
        layoutColumns()
    }

    /// 分栏模式下是否开启最右侧预览列（默认跟随 AppSettings，支持实时切换）
    var isPreviewEnabled: Bool = AppSettings.isPreviewPaneVisible(for: .columns) {
        didSet {
            AppSettings.setPreviewPaneVisible(isPreviewEnabled, for: .columns)
            if !isPreviewEnabled {
                clearPreview()
                layoutColumns()
            } else {
                syncPreview(items: selectedItems)
            }
        }
    }

    private let scroll = NSScrollView()
    private let board = ColumnBoard()
    fileprivate var columns: [BrowserColumn] = []
    fileprivate var dividers: [ColumnDividerView] = []
    /// 选中文件时，列链最右侧追加的一栏文件预览（仿访达分栏视图）。
    fileprivate var previewColumn: FilePreviewColumn?

    private var dragStartWidths: [CGFloat] = []
    private var dragStartPreviewWidth: CGFloat = 214

    private(set) var rootURL = URL(fileURLWithPath: NSHomeDirectory())
    private var customRootItems: [FileItem]?
    private var sortField: SortField = .name
    private var ascending = true

    /// 当前高亮的条目（最深一次选择）。
    private(set) var currentItem: FileItem?
    /// 顶栏面包屑应该显示的目录：选中文件夹时为该文件夹，选中文件时为它所在列，
    /// 什么都没选时为当前活动列。
    private(set) var displayURL = URL(fileURLWithPath: NSHomeDirectory())
    /// 选中文件的名称，追加在面包屑末段；选中文件夹或未选中时为 nil。
    private(set) var displayItem: FileItem?
    fileprivate var activeColumn = 0

    /// 当前活动列对应的目录 URL（右键新建文件、粘贴、打开终端等操作的实际目标目录）。
    var activeColumnURL: URL {
        if columns.indices.contains(activeColumn) {
            return columns[activeColumn].url
        }
        return rootURL
    }
    /// 程序化选中（新建/重命名后）不触发右侧展开。
    private var suppressExpansion = false

    // MARK: - 生命周期

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.scrollerStyle = .overlay
        board.owner = self
        scroll.documentView = board
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    override func layout() {
        super.layout()
        layoutColumns()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        scroll.backgroundColor = .controlBackgroundColor
        board.needsDisplay = true
        for col in columns {
            col.needsDisplay = true
        }
        previewColumn?.needsDisplay = true
        needsDisplay = true
    }

    private func layoutColumns() {
        let height = max(0, scroll.contentSize.height)
        var currentX: CGFloat = 0

        for column in columns {
            let width = column.columnWidth
            column.frame = NSRect(x: currentX, y: 0, width: width, height: height)
            currentX += width
        }

        if let preview = previewColumn {
            let width = preview.columnWidth
            preview.frame = NSRect(x: currentX, y: 0, width: width, height: height)
            currentX += width
        }

        board.frame = NSRect(x: 0, y: 0,
                             width: max(currentX, scroll.contentSize.width),
                             height: height)

        updateDividers(height: height)
    }

    private func updateDividers(height: CGFloat) {
        let totalTargets = columns.count + (previewColumn != nil ? 1 : 0)
        while dividers.count < totalTargets {
            let div = ColumnDividerView()
            board.addSubview(div)
            dividers.append(div)
        }
        while dividers.count > totalTargets {
            let div = dividers.removeLast()
            div.removeFromSuperview()
        }

        for (index, col) in columns.enumerated() {
            let div = dividers[index]
            div.columnIndex = index
            div.isPreview = false
            div.frame = NSRect(x: col.frame.maxX - 4, y: 0, width: 8, height: height)
            board.addSubview(div)
            wireDivider(div)
        }

        if let preview = previewColumn {
            let div = dividers[columns.count]
            div.columnIndex = columns.count
            div.isPreview = true
            div.frame = NSRect(x: preview.frame.maxX - 4, y: 0, width: 8, height: height)
            board.addSubview(div)
            wireDivider(div)
        }
    }

    private func wireDivider(_ div: ColumnDividerView) {
        div.onDragBegan = { [weak self] in
            guard let self else { return }
            self.dragStartWidths = self.columns.map { $0.columnWidth }
            self.dragStartPreviewWidth = self.previewColumn?.columnWidth ?? AppSettings.browserColumnWidth
        }
        div.onDrag = { [weak self, weak div] dx, isOption in
            guard let self, let div else { return }
            let index = div.columnIndex
            if div.isPreview {
                let startW = self.dragStartPreviewWidth
                let newW = max(Self.minColumnWidth, min(Self.maxColumnWidth, startW + dx))
                if isOption {
                    for col in self.columns { col.columnWidth = newW }
                    self.previewColumn?.columnWidth = newW
                    AppSettings.browserColumnWidth = newW
                } else {
                    self.previewColumn?.columnWidth = newW
                }
            } else if index < self.columns.count {
                let startW = index < self.dragStartWidths.count ? self.dragStartWidths[index] : self.columns[index].columnWidth
                let newW = max(Self.minColumnWidth, min(Self.maxColumnWidth, startW + dx))
                if isOption {
                    for col in self.columns { col.columnWidth = newW }
                    self.previewColumn?.columnWidth = newW
                    AppSettings.browserColumnWidth = newW
                } else {
                    self.columns[index].columnWidth = newW
                }
            }
            self.layoutColumns()
        }
        div.onDragEnded = { [weak self] in
            guard let self else { return }
            if let first = self.columns.first {
                AppSettings.browserColumnWidth = first.columnWidth
            }
        }
        div.onDoubleClick = { [weak self, weak div] in
            guard let self, let div else { return }
            if div.isPreview {
                self.previewColumn?.columnWidth = max(280, AppSettings.browserColumnWidth)
                self.layoutColumns()
            } else {
                self.autoSizeColumn(at: div.columnIndex)
            }
        }
    }

    private func autoSizeColumn(at index: Int) {
        guard index < columns.count else { return }
        let col = columns[index]
        let font = NSFont.systemFont(ofSize: 12.5)
        var maxWidth: CGFloat = 0
        for item in col.items {
            let width = (item.name as NSString).size(withAttributes: [.font: font]).width
            if width > maxWidth { maxWidth = width }
        }
        let ideal = max(Self.minColumnWidth, min(Self.maxColumnWidth, maxWidth + 65))
        if abs(col.columnWidth - ideal) < 2 {
            col.columnWidth = AppSettings.browserColumnWidth
        } else {
            col.columnWidth = ideal
        }
        layoutColumns()
    }

    // MARK: - 数据

    /// 由窗格调用：根目录或排序发生变化时刷新。
    func refresh(root: URL, sort: SortField, ascending: Bool) {
        let wasCustom = (customRootItems != nil)
        customRootItems = nil
        let rootChanged = wasCustom || (root.standardizedFileURL != rootURL.standardizedFileURL)
        rootURL = root
        sortField = sort
        self.ascending = ascending

        if rootChanged || columns.isEmpty {
            rebuild()
        } else {
            reloadKeepingChain()
        }
    }

    /// 标签视图下按指定文件列表展示分栏（首列直接展示标签下的项目，若无项目则为空，不读取 rootURL 磁盘目录）
    func refreshWithCustomItems(_ items: [FileItem], sort: SortField, ascending: Bool) {
        customRootItems = items
        sortField = sort
        self.ascending = ascending
        removeColumns(from: 0)
        clearPreview()
        if !items.isEmpty {
            let first = makeColumn(url: rootURL, index: 0)
            first.customItems = items
            first.reload(showHidden: AppSettings.showHidden, sort: sortField, ascending: ascending)
            columns = [first]
            board.addSubview(first)
        } else {
            columns = []
        }
        activeColumn = 0
        currentItem = nil
        if isPreviewEnabled {
            syncPreview(items: [], scrollToVisible: false)
        }
        layoutColumns()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// 重置为「只有一列」的状态，并选中 url（若在根目录内）。
    func setRoot(_ url: URL, selecting target: URL? = nil) {
        customRootItems = nil
        rootURL = url
        rebuild()
        if let target { select(urls: [target]) }
    }

    private func rebuild() {
        removeColumns(from: 0)
        clearPreview()
        let first = makeColumn(url: rootURL, index: 0)
        first.reload(showHidden: AppSettings.showHidden, sort: sortField, ascending: ascending)
        columns = [first]
        board.addSubview(first)
        activeColumn = 0
        currentItem = nil
        if isPreviewEnabled {
            syncPreview(items: [], scrollToVisible: false)
        }
        layoutColumns()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        updateLocation()
    }

    /// 排序/显示隐藏变化或文件变动时，保留已展开的列链，只重新读取内容。
    private func reloadKeepingChain() {
        guard !columns.isEmpty else { return rebuild() }
        suppressExpansion = true
        defer { suppressExpansion = false }

        let previousActive = activeColumn
        for column in columns {
            column.reload(showHidden: AppSettings.showHidden,
                          sort: sortField,
                          ascending: ascending,
                          restoring: column.selectedItem?.url)
        }
        // 链上某一列选中的目录已经不存在（被删除/改名）时，收掉后面的列
        for index in 0..<max(0, columns.count - 1) {
            guard let item = columns[index].selectedItem, item.isNavigable else {
                removeColumns(from: index + 1)
                break
            }
        }
        // 维持当前活动列焦点（防跳回首列）
        activeColumn = min(previousActive, max(0, columns.count - 1))

        if columns.indices.contains(activeColumn) {
            currentItem = columns[activeColumn].selectedItem
        } else {
            currentItem = nil
        }

        // 若当前选中的文件已不存在（被删除），及时清空 currentItem 并收起预览
        if let current = currentItem {
            let stillExists = columns.contains { col in
                col.items.contains { $0.url.path == current.url.path }
            }
            if !stillExists {
                currentItem = nil
                clearPreview()
            }
        }
        layoutColumns()
        let activeItems = columns.indices.contains(activeColumn) ? columns[activeColumn].selectedItems : []
        syncPreview(items: activeItems, scrollToVisible: false)
        updateLocation()
    }

    private func makeColumn(url: URL, index: Int) -> BrowserColumn {
        let column = BrowserColumn(url: url)
        column.columnWidth = AppSettings.browserColumnWidth
        column.horizontalScrollTarget = scroll
        column.onDropFiles = { [weak self] urls, dest, isCopy in
            self?.onDropFiles?(urls, dest, isCopy)
        }
        column.onSelect = { [weak self, weak column] item in
            guard let self, let column,
                  let index = self.columns.firstIndex(where: { $0 === column }) else { return }
            self.activeColumn = index
            let items = column.selectedItems
            if self.suppressExpansion {
                self.currentItem = items.last ?? item
                let urls = Set(items.map { $0.url })
                self.onSelectionChange?(urls.isEmpty ? Set([item?.url].compactMap { $0 }) : urls)
                self.updateLocation()
                return
            }
            self.expand(after: index, item: item, selectedItems: items)
        }
        column.onOpen = { [weak self] item in self?.onOpen?(item) }
        column.onActivate = { [weak self] in self?.onActivate?() }
        column.keyHandler = { [weak self, weak column] event in
            guard let self, let column,
                  let index = self.columns.firstIndex(where: { $0 === column }) else { return false }
            return self.handleKey(event, columnIndex: index)
        }
        column.menuProvider = { [weak self, weak column] item in
            guard let self, let column else { return nil }
            if let index = self.columns.firstIndex(where: { $0 === column }) {
                self.activeColumn = index
            }
            return self.menuProvider?(item)
        }
        column.onFileRenamed = { [weak self] oldURL, newURL in
            self?.onFileRenamed?(oldURL, newURL)
        }
        return column
    }

    func startRenameOnActiveColumn() {
        if activeColumn >= 0, activeColumn < columns.count, columns[activeColumn].hasSingleSelection {
            columns[activeColumn].startRenameSelected()
            return
        }
        for col in columns.reversed() {
            if col.hasSingleSelection {
                col.startRenameSelected()
                return
            }
        }
        if let last = columns.last {
            last.startRenameSelected()
        }
    }

    // MARK: - 展开与收起

    private func expand(after index: Int, item: FileItem?, selectedItems: [FileItem] = []) {
        removeColumns(from: index + 1)
        currentItem = selectedItems.last ?? item

        if selectedItems.count > 1 {
            // 多选状态：在最右侧展示多选汇总预览（仿访达分栏视图）
            syncPreview(items: selectedItems, scrollToVisible: true)
            activeColumn = index
            let urls = Set(selectedItems.map { $0.url })
            onSelectionChange?(urls)
            updateLocation()
            onActivate?()
            return
        }

        if let item, item.isNavigable {
            let next = makeColumn(url: item.url, index: index + 1)
            next.reload(showHidden: AppSettings.showHidden, sort: sortField, ascending: ascending)
            columns.append(next)
            board.addSubview(next)
            activeColumn = index + 1
            if isPreviewEnabled {
                syncPreview(items: [], scrollToVisible: false)
            }
            layoutColumns()
            next.scrollToVisible(next.bounds)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else if let item, !item.isNavigable {
            // 选中单文件：在列链最右侧追加一栏文件预览（仿访达分栏视图）。
            syncPreview(items: [item], scrollToVisible: true)
            activeColumn = index
        } else {
            currentItem = nil
            if isPreviewEnabled {
                syncPreview(items: [], scrollToVisible: false)
            } else {
                clearPreview()
                layoutColumns()
            }
        }

        let urls = Set(selectedItems.isEmpty ? [item?.url].compactMap { $0 } : selectedItems.map { $0.url })
        onSelectionChange?(urls)
        updateLocation()
        onActivate?()
    }

    /// 定位到指定地址：逐级展开父目录，最后选中目标并展开它。
    ///
    /// 后退 / 前进以及点地址栏上的某一级都走这里 —— 分栏模式下地址栏显示的
    /// 就是「当前选中的文件夹」，所以回到某个历史地址 = 把整条展开链恢复回去。
    func locate(at url: URL) {
        let target = url.standardizedFileURL
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir)
        let isDirectory = exists && isDir.boolValue
        let targetFolder = isDirectory ? target : target.deletingLastPathComponent().standardizedFileURL

        let root = rootURL.standardizedFileURL
        if !targetFolder.path.hasPrefix(root.path + "/") && targetFolder.path != root.path {
            // target 不在当前 root 内：寻找合适的祖先根目录（优先使用用户主目录或常用目录）
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            let desktop = home.appendingPathComponent("Desktop").standardizedFileURL
            let documents = home.appendingPathComponent("Documents").standardizedFileURL
            let downloads = home.appendingPathComponent("Downloads").standardizedFileURL

            let chosenRoot: URL
            if targetFolder.path == desktop.path || targetFolder.path.hasPrefix(desktop.path + "/") {
                chosenRoot = desktop
            } else if targetFolder.path == documents.path || targetFolder.path.hasPrefix(documents.path + "/") {
                chosenRoot = documents
            } else if targetFolder.path == downloads.path || targetFolder.path.hasPrefix(downloads.path + "/") {
                chosenRoot = downloads
            } else if targetFolder.path == home.path || targetFolder.path.hasPrefix(home.path + "/") {
                chosenRoot = home
            } else {
                chosenRoot = (targetFolder.pathComponents.count > 2)
                    ? URL(fileURLWithPath: (targetFolder.path as NSString).deletingLastPathComponent).standardizedFileURL
                    : targetFolder
            }
            rootURL = chosenRoot
        }

        let effectiveRoot = rootURL.standardizedFileURL
        if target.path == effectiveRoot.path {
            rebuild()
            return
        }

        // 从根到目标的每一级目录/文件
        var chain: [URL] = []
        var current = effectiveRoot
        for component in target.pathComponents.dropFirst(effectiveRoot.pathComponents.count) {
            current = current.appendingPathComponent(component)
            chain.append(current.standardizedFileURL)
        }

        rebuild()
        for level in chain {
            guard let column = columns.last else { break }
            guard let item = column.item(withURL: level) else { break }
            expand(after: columns.count - 1, item: item)
        }
    }

    /// 当前展开链的最深一列（可能就是根）。
    var deepestURL: URL { columns.last?.url ?? rootURL }

    /// 地址栏点某一级：只在链内「退到」这一级 —— 收掉它右侧的列、把焦点移回来，
    /// 不改根、不重新读盘。目标不在链上时返回 false，交给调用方决定怎么导航。
    @discardableResult
    func rewind(to url: URL) -> Bool {
        let target = url.standardizedFileURL
        guard let index = columns.firstIndex(where: { $0.url.standardizedFileURL.path == target.path }) else {
            return false
        }

        removeColumns(from: index + 1)
        activeColumn = index
        if index > 0 {
            suppressExpansion = true
            columns[index - 1].select(url: target)
            suppressExpansion = false
            currentItem = columns[index - 1].selectedItem
        } else {
            // 回退到根列（index == 0）：收掉右侧所有列，取消根列内的子项展开
            currentItem = nil
            columns[0].deselect()
        }
        syncPreview()
        columns[index].scrollToVisible(columns[index].bounds)
        scroll.reflectScrolledClipView(scroll.contentView)
        updateLocation()
        onSelectionChange?(Set([currentItem?.url].compactMap { $0 }))
        onActivate?()
        return true
    }

    /// 重新计算顶栏应显示的目录并通知窗格。
    private func updateLocation() {
        let columnURL: URL = columns.indices.contains(activeColumn) ? columns[activeColumn].url : rootURL
        let newURL: URL
        let newItem: FileItem?

        let selected = columns.indices.contains(activeColumn) ? columns[activeColumn].selectedItems : []
        if selected.count > 1 {
            newURL = columnURL
            newItem = nil
            currentItem = selected.last
        } else if let first = selected.first {
            currentItem = first
            if first.isNavigable {
                // 选中文件夹：它自己就是当前地址（右侧同时展开它的内容）
                newURL = first.url
                newItem = nil
            } else {
                // 选中文件：地址停在它所在的一列，文件名追加为末段
                newURL = columnURL
                newItem = first
            }
        } else {
            // 没有选中任何项（例如刚删除文件、或点击了空白处）
            currentItem = nil
            newURL = columnURL
            newItem = nil
        }

        guard newURL.standardizedFileURL.path != displayURL.standardizedFileURL.path
                || newItem?.url != displayItem?.url else { return }
        displayURL = newURL
        displayItem = newItem
        onLocationChange?(newURL, newItem)
    }

    private func removeColumns(from index: Int) {
        guard index < columns.count else { return }
        for column in columns[index...] {
            column.removeFromSuperview()
        }
        columns.removeSubrange(index...)
        activeColumn = min(activeColumn, max(0, columns.count - 1))
    }

    private func clearPreview() {
        guard let preview = previewColumn else { return }
        preview.removeFromSuperview()
        previewColumn = nil
    }

    /// 当前选中单项或多项时，在最右侧展示文件预览；为空选或未展开文件夹时展示空白占位列（仿访达保持宽度稳定，避免画面跳动）。
    private func syncPreview(items: [FileItem] = [], scrollToVisible: Bool = false) {
        guard isPreviewEnabled else {
            clearPreview()
            layoutColumns()
            return
        }

        let hadPreview = (previewColumn != nil)
        let preview: FilePreviewColumn
        if let existing = previewColumn {
            preview = existing
        } else {
            let col = FilePreviewColumn()
            col.horizontalScrollTarget = scroll
            board.addSubview(col)
            previewColumn = col
            preview = col
        }

        if items.count > 1 {
            preview.configure(with: items)
        } else if let item = items.first, !item.isNavigable {
            preview.configure(with: item)
        } else {
            // 没有选中文件（空选或选中了文件夹）：清空内容保留空白占位，彻底避免宽度收缩偏移
            preview.configureEmpty()
        }

        layoutColumns()

        // 仅在首次展示有效文件预览时才自动平滑滚入
        if scrollToVisible && !hadPreview, items.contains(where: { !$0.isNavigable }) {
            let maxX = board.frame.width
            let visible = scroll.contentSize.width
            if maxX > visible {
                scroll.contentView.scroll(to: NSPoint(x: max(0, maxX - visible), y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }

    // MARK: - 键盘

    private func handleKey(_ event: NSEvent, columnIndex: Int) -> Bool {
        switch event.keyCode {
        case 124:  // →
            if let item = columns[columnIndex].selectedItem, item.isNavigable,
               columnIndex + 1 < columns.count {
                activeColumn = columnIndex + 1
                columns[columnIndex + 1].focus()
                columns[columnIndex + 1].selectFirstRow()
                return true
            }
            return true
        case 123:  // ←
            if columnIndex > 0 {
                activeColumn = columnIndex - 1
                columns[columnIndex - 1].focus()
                currentItem = columns[columnIndex - 1].selectedItem
                updateLocation()
                return true
            }
            return true
        default:
            return keyHandler?(event) ?? false
        }
    }

    // MARK: - 对外接口（与列表/图标视图保持一致）

    var selectedItems: [FileItem] {
        guard columns.indices.contains(activeColumn) else { return [] }
        return columns[activeColumn].selectedItems
    }

    /// 当前活动列的项目数（状态栏用，避免一直显示根目录的项目数）。
    var activeColumnItemCount: Int {
        columns.indices.contains(activeColumn) ? columns[activeColumn].items.count : 0
    }

    func focus() {
        guard !columns.isEmpty else { return }
        activeColumn = min(activeColumn, columns.count - 1)
        columns[activeColumn].focus()
        columns[activeColumn].scrollToVisible(columns[activeColumn].bounds)
    }

    func selectAll() {
        guard !columns.isEmpty else { return }
        let index = min(activeColumn, columns.count - 1)
        columns[index].selectAll()
    }

    /// 程序化选中（新建文件夹、重命名之后）。只高亮，不自动展开——
    /// 展开是用户点选文件夹时的行为，否则新建完就会直接钻进去。
    func select(urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        suppressExpansion = true
        defer { suppressExpansion = false }
        for index in stride(from: columns.count - 1, through: 0, by: -1) {
            let col = columns[index]
            let matching = col.items.filter { paths.contains($0.url.standardizedFileURL.path) }
            if !matching.isEmpty {
                removeColumns(from: index + 1)
                activeColumn = index
                col.select(urls: urls)
                currentItem = col.selectedItems.last ?? col.selectedItem
                if col.selectedItems.count > 1 {
                    syncPreview(items: col.selectedItems)
                } else {
                    syncPreview()
                }
                updateLocation()
                onSelectionChange?(urls)
                return
            }
        }
        // 各列都没有：从根目录重新读一遍再试
        rebuild()
        if let first = columns.first {
            first.select(urls: urls)
            currentItem = first.selectedItems.last ?? first.selectedItem
            if first.selectedItems.count > 1 {
                syncPreview(items: first.selectedItems)
            } else {
                syncPreview()
            }
            updateLocation()
            onSelectionChange?(urls)
        }
    }

    func scrollToTop() {
        columns.first?.selectFirstRow()
    }

    func clearSelection() {
        handleBlankAreaClick()
    }

    /// 点击分栏右侧空白画布或列底部空白：清空选中并收起右侧预览（访达同款）
    func handleBlankAreaClick() {
        if activeColumn >= 0 && activeColumn < columns.count {
            columns[activeColumn].deselectAll()
        }
        currentItem = nil
        clearPreview()
        layoutColumns()
        onSelectionChange?(Set())
        updateLocation()
    }
}

// MARK: - 画布

/// 承载多列的翻转容器（作为横向滚动视图的 documentView）。
private final class ColumnBoard: NSView {
    override var isFlipped: Bool { true }
    weak var owner: ColumnBrowserView?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let owner = owner {
            // 关键修复 1：如果点击落在最右侧文件详情预览列上，坚决不触发空白收起！
            if let preview = owner.previewColumn, preview.frame.contains(point) {
                return
            }
            // 关键修复 2：如果点击落在任何已有分栏列内部，也不触发空白收起
            for col in owner.columns {
                if col.frame.contains(point) {
                    return
                }
            }
            // 关键修复 3：如果点击落在分栏列边框分割线上，也不收起
            for div in owner.dividers {
                if div.frame.contains(point) {
                    return
                }
            }
        }
        super.mouseDown(with: event)
        owner?.handleBlankAreaClick()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let owner = owner {
            if let preview = owner.previewColumn, preview.frame.contains(point) {
                let item = owner.currentItem ?? owner.selectedItems.first
                return owner.menuProvider?(item)
            }
            for (idx, col) in owner.columns.enumerated() {
                if col.frame.contains(point) {
                    owner.activeColumn = idx
                    return col.menu(for: event)
                }
            }
        }
        if let owner = owner, let last = owner.columns.indices.last {
            owner.activeColumn = last
        }
        owner?.handleBlankAreaClick()
        return owner?.menuProvider?(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - 单列

/// 一列文件列表：自带滚动视图与数据源。
final class BrowserColumn: NSView, NSTableViewDataSource, NSTableViewDelegate {

    let url: URL
    private(set) var items: [FileItem] = []
    var columnWidth: CGFloat = AppSettings.browserColumnWidth

    private let table = KeyTableView()
    private let scroll = ColumnScrollView()

    /// 外层横向滚动视图：列内的横向手势要交给它，否则点到某一列后整排就滚不动了。
    weak var horizontalScrollTarget: NSScrollView? {
        didSet { scroll.horizontalTarget = horizontalScrollTarget }
    }

    var onSelect: ((FileItem?) -> Void)?
    var onOpen: ((FileItem) -> Void)?
    var onActivate: (() -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((FileItem?) -> NSMenu?)?
    var onFileRenamed: ((URL, URL) -> Void)?
    var onDropFiles: (([URL], URL, Bool) -> Void)?

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        tableColumn.resizingMask = .autoresizingMask
        table.addTableColumn(tableColumn)
        table.headerView = nil
        table.style = .fullWidth
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = AppSettings.showZebraStripes
        table.backgroundColor = .controlBackgroundColor
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(handleDoubleClick)
        table.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
        table.menuProvider = { [weak self] event in
            guard let self else { return nil }
            if let event {
                let point = self.table.convert(event.locationInWindow, from: nil)
                let row = self.table.row(at: point)
                if row >= 0 && row < self.items.count {
                    if !self.table.selectedRowIndexes.contains(row) {
                        self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    }
                    return self.menuProvider?(self.items[row])
                } else {
                    return self.menuProvider?(nil)
                }
            } else {
                return self.menuProvider?(nil)
            }
        }
        table.onTriggerRename = { [weak self] row in self?.startRename(at: row) }
        table.isPointInName = { [weak self] row, point in
            guard let self, row >= 0, row < self.items.count else { return false }
            if let cell = self.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ColumnRowCell {
                return cell.isPointInName(point, in: self.table)
            }
            return false
        }
        table.registerForDraggedTypes([.fileURL])
        table.urlsForRows = { [weak self] rows in
            guard let self else { return [] }
            return rows.compactMap { r in
                guard r >= 0, r < self.items.count else { return nil }
                return self.items[r].url
            }
        }

        NotificationCenter.default.addObserver(forName: .zebraStripesDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.table.usesAlternatingRowBackgroundColors = AppSettings.showZebraStripes
            self.table.enumerateAvailableRowViews { rowView, _ in
                rowView.needsDisplay = true
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        table.backgroundColor = .controlBackgroundColor
        scroll.backgroundColor = .controlBackgroundColor
        table.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if let column = table.tableColumns.first {
            column.width = max(40, scroll.contentSize.width)
        }
    }

    func deselectAll() {
        table.deselectAll(nil)
    }

    override func mouseDown(with event: NSEvent) {
        deselectAll()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        deselectAll()
        return menuProvider?(nil)
    }

    // MARK: - 数据

    private var isReloading = false
    var customItems: [FileItem]?

    func reload(showHidden: Bool, sort: SortField, ascending: Bool, restoring keep: URL? = nil) {
        isReloading = true
        defer { isReloading = false }

        let oldSelectedRow = table.selectedRow
        let raw = customItems ?? FileItem.contents(of: url, showHidden: showHidden)
        items = FileOrganizer.sections(items: raw, sort: sort, ascending: ascending, group: .none)
            .flatMap { $0.items }
        table.reloadData()
        if let keep, let index = items.firstIndex(where: { $0.url == keep }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else if oldSelectedRow >= 0 && !items.isEmpty {
            // 被选中的条目已不存在（如被删除/移至废纸篓）：仿 Finder 自动选中邻近的相邻项，绝不丢失焦点
            let newIndex = min(oldSelectedRow, items.count - 1)
            table.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
            table.scrollRowToVisible(newIndex)
        } else {
            table.deselectAll(nil)
        }
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

    /// 批量选中指定 URLs
    func select(urls: Set<URL>) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        let indices = items.enumerated().compactMap { index, item in
            paths.contains(item.url.standardizedFileURL.path) ? index : nil
        }
        if !indices.isEmpty {
            let set = IndexSet(indices)
            table.selectRowIndexes(set, byExtendingSelection: false)
            if let first = indices.first {
                table.scrollRowToVisible(first)
            }
        } else {
            table.deselectAll(nil)
        }
    }

    /// 找到指定 URL 对应的条目（供程序化定位使用）。
    func item(withURL url: URL) -> FileItem? {
        let target = url.standardizedFileURL.path
        return items.first { $0.url.standardizedFileURL.path == target }
    }

    func focus() { window?.makeFirstResponder(table) }

    func selectFirstRow() {
        guard !items.isEmpty else { return }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.scrollRowToVisible(0)
    }

    /// 选中指定 URL，成功返回 true。
    @discardableResult
    func select(url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        guard let index = items.firstIndex(where: { $0.url.standardizedFileURL.path == target }) else { return false }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        return true
    }

    func selectAll() { table.selectAll(nil) }

    func deselect() {
        table.deselectAll(nil)
    }

    var hasSingleSelection: Bool {
        table.selectedRow >= 0 && table.selectedRowIndexes.count == 1
    }

    // MARK: - 就地重命名（访达同款）

    func startRenameSelected() {
        let row = table.selectedRow
        guard row >= 0, table.selectedRowIndexes.count == 1 else { return }
        startRename(at: row)
    }

    func startRename(at row: Int) {
        guard row >= 0, row < items.count else { return }
        table.scrollRowToVisible(row)
        table.layoutSubtreeIfNeeded()
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ColumnRowCell else { return }
        focus()
        cell.startInlineEditing()
    }

    func performRename(item: FileItem, newName: String) {
        FileOperations.performRename(item: item, newName: newName, window: window) { [weak self] oldURL, newURL in
            self?.onFileRenamed?(oldURL, newURL)
        }
    }

    @objc private func handleDoubleClick() {
        let row = table.clickedRow
        guard row >= 0, row < items.count else { return }
        onOpen?(items[row])
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 26 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("ColumnTableRowView")
        let rowView = (tableView.makeView(withIdentifier: identifier, owner: self) as? ColumnTableRowView)
            ?? ColumnTableRowView()
        rowView.identifier = identifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ColumnRowCell)
            ?? ColumnRowCell(identifier: identifier)
        cell.configure(with: items[row])
        cell.onCommitRename = { [weak self] newName in
            guard let self, row < self.items.count else { return }
            self.performRename(item: self.items[row], newName: newName)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
        guard !isReloading else { return }
        onActivate?()
        onSelect?(selectedItem)
    }

    // MARK: - 拖拽数据源与接收

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row >= 0, row < items.count else { return nil }
        return items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let urls = FileOperations.readURLs(from: info)
        guard !urls.isEmpty else { return [] }
        let destURL: URL
        if row >= 0, row < items.count, items[row].isDirectory {
            destURL = items[row].url
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            destURL = url
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return FileOperations.shouldCopy(for: info, destination: destURL) ? .copy : .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = FileOperations.readURLs(from: info)
        guard !urls.isEmpty else { return false }
        let destURL: URL
        if row >= 0, row < items.count, items[row].isDirectory {
            destURL = items[row].url
        } else {
            destURL = url
        }
        let isCopy = FileOperations.shouldCopy(for: info, destination: destURL)
        onDropFiles?(urls, destURL, isCopy)
        return true
    }
}

// MARK: - 访达风格圆角行视图

/// 分栏列表行视图：仿访达四边圆角高亮。
/// - 左右内缩 (5pt)，避免紧贴分栏边界
/// - 单项选中：四角全圆角 (radius 5.5)
/// - 连续多选：首行顶角圆角、末行底角圆角、中间行无缝平滑拼接
class ColumnTableRowView: NSTableRowView {

    override var isSelected: Bool {
        didSet {
            needsDisplay = true
        }
    }

    override var isEmphasized: Bool {
        didSet {
            needsDisplay = true
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let baseColor = NSColor.controlBackgroundColor
        guard AppSettings.showZebraStripes else {
            baseColor.setFill()
            bounds.fill()
            return
        }

        var candidateView: NSView? = superview
        var table: NSTableView?
        while let v = candidateView {
            if let t = v as? NSTableView {
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

        let stripeColor = NSColor.alternatingContentBackgroundColors.count > 1
            ? NSColor.alternatingContentBackgroundColors[1]
            : (baseColor.blended(withFraction: 0.04, of: .labelColor) ?? baseColor)
        let color = (row % 2 == 1) ? stripeColor : baseColor
        color.setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }

        let horizontalInset: CGFloat = 5.0
        let cornerRadius: CGFloat = 5.5

        guard let table = superview as? NSTableView else {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: horizontalInset, dy: 0),
                                    xRadius: cornerRadius, yRadius: cornerRadius)
            let color = isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor
            color.setFill()
            path.fill()
            return
        }

        let row = table.row(for: self)
        guard row >= 0 else { return }

        let prevSelected = row > 0 && table.isRowSelected(row - 1)
        let nextSelected = row < table.numberOfRows - 1 && table.isRowSelected(row + 1)

        let topY: CGFloat = prevSelected ? -0.5 : 0
        let bottomY: CGFloat = nextSelected ? bounds.height + 0.5 : bounds.height

        // 关键：在 fullWidth 样式或不同滚动容器下，table.bounds.width 往往会比可视区宽 12pt（导致右侧圆角被 Clip 裁切成直角）
        // 故必须取可视宽度与 bounds.width 的较小值，确保右侧同样留出 5pt 内边距并完整画出所有圆角！
        let visibleWidth: CGFloat
        if let clip = table.enclosingScrollView?.contentView, clip.bounds.width > 0 {
            visibleWidth = clip.bounds.width
        } else if table.visibleRect.width > 0 {
            visibleWidth = table.visibleRect.width
        } else {
            visibleWidth = bounds.width
        }
        let effectiveWidth = min(bounds.width, visibleWidth)

        let rect = NSRect(x: horizontalInset,
                          y: topY,
                          width: max(0, effectiveWidth - horizontalInset * 2),
                          height: max(0, bottomY - topY))

        let path = ColumnTableRowView.selectionPath(rect: rect,
                                                    roundTop: !prevSelected,
                                                    roundBottom: !nextSelected,
                                                    radius: cornerRadius)

        let color = isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        path.fill()
    }

    static func selectionPath(rect: NSRect, roundTop: Bool, roundBottom: Bool, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY
        let r = min(radius, rect.width / 2, rect.height / 2)

        path.move(to: NSPoint(x: minX + (roundTop ? r : 0), y: minY))

        if roundTop {
            path.line(to: NSPoint(x: maxX - r, y: minY))
            path.appendArc(from: NSPoint(x: maxX, y: minY), to: NSPoint(x: maxX, y: minY + r), radius: r)
        } else {
            path.line(to: NSPoint(x: maxX, y: minY))
        }

        if roundBottom {
            path.line(to: NSPoint(x: maxX, y: maxY - r))
            path.appendArc(from: NSPoint(x: maxX, y: maxY), to: NSPoint(x: maxX - r, y: maxY), radius: r)
        } else {
            path.line(to: NSPoint(x: maxX, y: maxY))
        }

        if roundBottom {
            path.line(to: NSPoint(x: minX + r, y: maxY))
            path.appendArc(from: NSPoint(x: minX, y: maxY), to: NSPoint(x: minX, y: maxY - r), radius: r)
        } else {
            path.line(to: NSPoint(x: minX, y: maxY))
        }

        if roundTop {
            path.line(to: NSPoint(x: minX, y: minY + r))
            path.appendArc(from: NSPoint(x: minX, y: minY), to: NSPoint(x: minX + r, y: minY), radius: r)
        } else {
            path.line(to: NSPoint(x: minX, y: minY))
        }

        path.close()
        return path
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - 单元格

private final class ColumnRowCell: NSTableCellView {

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let tagDotsView = TagDotsView()
    private let chevron = NSImageView()
    private var isHiddenItem: Bool = false
    private var currentItem: FileItem?

    private var renameField: InlineRenameField?
    var isInlineEditing: Bool { renameField != nil }
    var onCommitRename: ((String) -> Void)?
    var onCancelRename: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        for field in [icon, title, tagDotsView, chevron] as [NSView] {
            field.translatesAutoresizingMaskIntoConstraints = true
            field.autoresizingMask = []
        }
        icon.imageScaling = .scaleProportionallyDown
        title.font = .systemFont(ofSize: 12.5)
        title.lineBreakMode = .byTruncatingMiddle
        title.isEditable = false
        title.isSelectable = false
        chevron.imageScaling = .scaleProportionallyDown
        chevron.contentTintColor = .tertiaryLabelColor

        for field in [icon, title, tagDotsView, chevron] as [NSView] { addSubview(field) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil, let field = renameField {
            renameField = nil
            field.cancelSilently()
            title.isHidden = false
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tagDotsView.setColors([])
        tagDotsView.isHidden = true
        if let field = renameField {
            renameField = nil
            field.cancelSilently()
            title.isHidden = false
        }
    }

    // MARK: - 就地重命名

    func isPointInName(_ pointInTable: NSPoint, in table: NSTableView) -> Bool {
        guard !isInlineEditing else { return false }
        let local = convert(pointInTable, from: table)
        guard local.y >= 0 && local.y <= bounds.height else { return false }
        let font = title.font ?? .systemFont(ofSize: 12.5)
        let rawTextW = ceil((title.stringValue as NSString).size(withAttributes: [.font: font]).width) + 4
        let actualTextW = title.frame.width > 0 ? min(title.frame.width, rawTextW) : rawTextW
        let textMinX = title.frame.minX
        let textMaxX = textMinX + actualTextW
        return local.x >= textMinX && local.x <= textMaxX
    }

    func startInlineEditing() {
        guard renameField == nil else { return }
        let original = currentItem?.name ?? title.stringValue
        let isDir = currentItem?.isNavigable ?? false
        let font = title.font ?? .systemFont(ofSize: 12.5)

        let field = InlineRenameField(text: original, isDirectory: isDir, font: font, alignment: .left)
        self.renameField = field
        title.isHidden = true
        tagDotsView.isHidden = true
        addSubview(field)
        needsLayout = true
        layoutSubtreeIfNeeded()

        field.onTextChange = { [weak self] _ in
            self?.needsLayout = true
            self?.layoutSubtreeIfNeeded()
        }
        field.onEndEditing = { [weak self] rawText, commit in
            guard let self else { return }
            self.renameField = nil
            self.title.isHidden = false
            self.updateColors()
            self.needsLayout = true

            if let table = self.superview as? NSTableView ?? (self.superview?.superview as? NSTableView) {
                self.window?.makeFirstResponder(table)
            }
            NSCursor.arrow.set()

            let orig = self.currentItem?.name ?? ""
            if commit {
                let newName = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                if newName.isEmpty || newName == orig {
                    self.title.stringValue = orig
                } else {
                    self.title.stringValue = newName
                    self.onCommitRename?(newName)
                }
            } else {
                self.title.stringValue = orig
                self.onCancelRename?()
            }
        }

        if let win = window {
            field.beginEditing(in: win)
        }
    }

    func endInlineEditing(commit: Bool) {
        guard let field = renameField else { return }
        if commit {
            field.commitAndClose()
        } else {
            field.cancelAndClose()
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateColors()
        }
    }

    private func updateColors() {
        if backgroundStyle == .emphasized {
            title.textColor = .white
            chevron.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        } else {
            title.textColor = isHiddenItem ? .secondaryLabelColor : .labelColor
            chevron.contentTintColor = .tertiaryLabelColor
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let iconSize = Theme.listIconSize
        icon.frame = NSRect(x: 9, y: (height - iconSize) / 2, width: iconSize, height: iconSize)

        let visibleW: CGFloat
        if let clip = (superview as? NSTableRowView)?.superview?.enclosingScrollView?.contentView, clip.bounds.width > 0 {
            visibleW = clip.bounds.width
        } else {
            visibleW = bounds.width
        }
        let cellW = min(bounds.width, visibleW)

        let rightMargin: CGFloat = 14
        let chevronWidth: CGFloat = 13
        let chevronGap: CGFloat = 6

        // 箭头放置在最右侧（右边距 14）
        chevron.frame = NSRect(x: cellW - rightMargin - chevronWidth,
                               y: (height - 12) / 2,
                               width: chevronWidth,
                               height: 12)

        // 无论当前是文件夹还是文件，标签都以「箭头的左侧位置」为统一右边界基准
        // 从而保证普通文件右侧预留出箭头空间，在垂直视觉上与文件夹标签完全对齐
        let tagRightAnchor = cellW - rightMargin - chevronWidth - chevronGap

        if let field = renameField {
            let textHeight: CGFloat = 21
            let nameX = icon.frame.maxX + 4
            let maxRight = chevron.isHidden ? (cellW - rightMargin) : (chevron.frame.minX - 4)
            let maxAvailableW = max(50, maxRight - nameX)
            let font = field.font ?? .systemFont(ofSize: 12.5)
            let currentStr = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
            let textW = (currentStr as NSString).size(withAttributes: [.font: font]).width
            let fieldWidth = min(maxAvailableW, max(56, ceil(textW) + 20))
            field.frame = NSRect(x: nameX, y: round((height - textHeight) / 2), width: fieldWidth, height: textHeight)
            tagDotsView.isHidden = true
        } else {
            let textHeight: CGFloat = 17
            let nameX = icon.frame.maxX + 7
            let tagCount = currentItem?.tags.count ?? 0
            if tagCount > 0 {
                let dotsW = TagDotsView.preferredWidth(count: tagCount)
                let tagX = tagRightAnchor - dotsW
                tagDotsView.isHidden = false
                tagDotsView.frame = NSRect(x: tagX, y: (height - 12) / 2, width: dotsW, height: 12)

                let titleRight = tagX - 6
                let titleWidth = max(20, titleRight - nameX)
                title.frame = NSRect(x: nameX, y: (height - textHeight) / 2, width: titleWidth, height: textHeight)
            } else {
                tagDotsView.isHidden = true
                let titleRight = chevron.isHidden ? (cellW - rightMargin) : (chevron.frame.minX - 6)
                let titleWidth = max(20, titleRight - nameX)
                title.frame = NSRect(x: nameX, y: (height - textHeight) / 2, width: titleWidth, height: textHeight)
            }
        }
    }

    func configure(with item: FileItem) {
        self.currentItem = item
        self.isHiddenItem = item.isHidden
        icon.image = IconCache.shared.icon(for: item)
        title.stringValue = item.name
        tagDotsView.setColors(item.tagColors)
        chevron.isHidden = !item.isNavigable
        chevron.image = Theme.symbol("chevron.right", size: 9, weight: .semibold)
        updateColors()
        needsLayout = true
    }
}

// MARK: - 单列滚动视图

/// 分栏里每一列表格自己的滚动视图。
/// 竖向滚动留给自己，横向手势交给外层「整排」滚动视图，
/// 否则点开某一列后，横向滚动会被这一列吃掉，整排就滚不动了。
private final class ColumnScrollView: NSScrollView {

    weak var horizontalTarget: NSScrollView?

    override func mouseDown(with event: NSEvent) {
        if let browserColumn = superview as? BrowserColumn {
            browserColumn.deselectAll()
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let browserColumn = superview as? BrowserColumn {
            browserColumn.deselectAll()
            return browserColumn.menuProvider?(nil)
        }
        return super.menu(for: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let horizontalTarget else {
            super.scrollWheel(with: event)
            return
        }
        let dx = abs(event.scrollingDeltaX)
        let dy = abs(event.scrollingDeltaY)
        if dx > dy, dx > 0.01 {
            horizontalTarget.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - 文件预览列

/// 选中文件时追加在列链最右侧的一栏：大图标 / 缩略图 + 文件元信息
/// （种类、大小、创建与修改时间、上次打开时间、版本、尺寸、位置等），1:1 还原访达分栏预览列。
final class FilePreviewColumn: NSView {

    var columnWidth: CGFloat = max(280, AppSettings.browserColumnWidth)
    weak var horizontalScrollTarget: NSScrollView? {
        didSet {
            scroll.horizontalTarget = horizontalScrollTarget
        }
    }

    static var bundleSizeCache: NSCache<NSURL, NSNumber> { BundleSizeCache.shared.cache }
    private var currentURL: URL?
    private weak var sizeValueField: NSTextField?

    static func calculateDirectorySize(at url: URL) -> Int64 {
        BundleSizeCache.calculateDirectorySize(at: url)
    }

    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
        override func mouseDown(with event: NSEvent) {
            // 阻断点击冒泡，避免误触画布的空白处收起逻辑
        }
        override func scrollWheel(with event: NSEvent) {
            // 向上冒泡给 PreviewScrollView
            nextResponder?.scrollWheel(with: event)
        }
    }

    private final class PreviewScrollView: NSScrollView {
        weak var horizontalTarget: NSScrollView?

        override func mouseDown(with event: NSEvent) {
            // 阻断点击冒泡
        }

        override func scrollWheel(with event: NSEvent) {
            let dx = abs(event.scrollingDeltaX)
            let dy = abs(event.scrollingDeltaY)
            if dx > dy, dx > 0.01 {
                if let target = horizontalTarget ?? enclosingScrollView {
                    target.scrollWheel(with: event)
                    return
                }
            }
            super.scrollWheel(with: event)
        }
    }

    private let scroll = PreviewScrollView()
    private let documentView = FlippedDocumentView()
    private let iconView = NSImageView()
    private let textContainer = NSView()
    private let nameLabel = SelectableLabel(selectableText: "")
    private let subtitleLabel = SelectableLabel(selectableText: "")
    private let infoHeaderContainer = NSView()
    private let infoHeaderLabel = NSTextField(labelWithString: "信息".localized)
    private let toggleMoreButton = LinkButton()
    private let infoStack = NSStackView()
    private var isExpanded: Bool = false
    private var currentPrimaryCount: Int = 0
    private var allRowViews: [DetailRowView] = []

    private var iconLeadingConstraint: NSLayoutConstraint!
    private var iconTrailingConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        // 阻断点击冒泡至底层画布
    }

    override func scrollWheel(with event: NSEvent) {
        let dx = abs(event.scrollingDeltaX)
        let dy = abs(event.scrollingDeltaY)
        if dx > dy, dx > 0.01 {
            if let target = horizontalScrollTarget ?? enclosingScrollView {
                target.scrollWheel(with: event)
                return
            }
        }
        super.scrollWheel(with: event)
    }

    func configureEmpty() {
        currentURL = nil
        sizeValueField = nil
        iconView.image = nil
        nameLabel.stringValue = ""
        subtitleLabel.stringValue = ""
        toggleMoreButton.isHidden = true
        infoHeaderContainer.isHidden = true
        infoStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        allRowViews.removeAll()
        documentView.isHidden = true
    }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.scrollerStyle = .overlay
        addSubview(scroll)

        // documentView 与 clipView 等宽且原点为 (0,0)，防止 NSClipView 重置坐标导致内部文字贴边
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = documentView

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(iconView)

        // 下方文字区统一留出充足的左右内边距（18pt），彻底告别贴边拥挤感
        textContainer.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(textContainer)

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.maximumNumberOfLines = 3
        nameLabel.alignment = .left
        nameLabel.isSelectable = true
        nameLabel.focusRingType = .none
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.alignment = .left
        subtitleLabel.isSelectable = true
        subtitleLabel.focusRingType = .none
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        infoHeaderContainer.translatesAutoresizingMaskIntoConstraints = false

        infoHeaderLabel.font = .systemFont(ofSize: 12.5, weight: .bold)
        infoHeaderLabel.textColor = .labelColor
        infoHeaderLabel.alignment = .left
        infoHeaderLabel.isEditable = false
        infoHeaderLabel.isSelectable = false
        infoHeaderLabel.isBordered = false
        infoHeaderLabel.drawsBackground = false
        infoHeaderLabel.translatesAutoresizingMaskIntoConstraints = false

        toggleMoreButton.title = "更多".localized
        toggleMoreButton.font = .systemFont(ofSize: 12, weight: .regular)
        toggleMoreButton.contentTintColor = .controlAccentColor
        toggleMoreButton.isBordered = false
        toggleMoreButton.setButtonType(.momentaryPushIn)
        toggleMoreButton.target = self
        toggleMoreButton.action = #selector(toggleMoreAction)
        toggleMoreButton.translatesAutoresizingMaskIntoConstraints = false
        toggleMoreButton.isHidden = true

        infoHeaderContainer.addSubview(infoHeaderLabel)
        infoHeaderContainer.addSubview(toggleMoreButton)

        NSLayoutConstraint.activate([
            infoHeaderLabel.leadingAnchor.constraint(equalTo: infoHeaderContainer.leadingAnchor),
            infoHeaderLabel.centerYAnchor.constraint(equalTo: infoHeaderContainer.centerYAnchor),
            toggleMoreButton.trailingAnchor.constraint(equalTo: infoHeaderContainer.trailingAnchor),
            toggleMoreButton.centerYAnchor.constraint(equalTo: infoHeaderContainer.centerYAnchor),
            infoHeaderContainer.heightAnchor.constraint(equalToConstant: 22)
        ])

        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 0
        infoStack.translatesAutoresizingMaskIntoConstraints = false

        textContainer.addSubview(nameLabel)
        textContainer.addSubview(subtitleLabel)
        textContainer.addSubview(infoHeaderContainer)
        textContainer.addSubview(infoStack)

        iconLeadingConstraint = iconView.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor, constant: 18)
        iconTrailingConstraint = iconView.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -18)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 128)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),

            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            iconView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            iconView.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            iconLeadingConstraint,
            iconTrailingConstraint,
            iconHeightConstraint,

            // 文字容器：左右各留 18pt 安全边距（仿访达原生预览栏排版）
            textContainer.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 18),
            textContainer.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 18),
            textContainer.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -18),
            textContainer.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -20),

            nameLabel.topAnchor.constraint(equalTo: textContainer.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            subtitleLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            infoHeaderContainer.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            infoHeaderContainer.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            infoHeaderContainer.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            infoStack.topAnchor.constraint(equalTo: infoHeaderContainer.bottomAnchor, constant: 4),
            infoStack.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            infoStack.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            infoStack.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor)
        ])
    }

    func configure(with item: FileItem) {
        documentView.isHidden = false
        infoHeaderContainer.isHidden = false
        currentURL = item.url
        isExpanded = false

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .creationDateKey, .contentAccessDateKey,
            .localizedTypeDescriptionKey, .isSymbolicLinkKey
        ]
        let values = try? item.url.resourceValues(forKeys: keys)
        let isDirectory = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false

        // 1. 顶部图片/图标：图片文件可铺满左右边距展示大图，文件夹/包/普通文件展示 128pt 高清大图标
        if !isDirectory && !isPackage, let image = NSImage(contentsOfFile: item.url.path), image.size.width > 1 {
            iconView.image = image
            iconLeadingConstraint.constant = 0
            iconTrailingConstraint.constant = 0
            iconHeightConstraint.constant = 176
        } else {
            let icon = NSWorkspace.shared.icon(forFile: item.url.path)
            icon.size = NSSize(width: 128, height: 128)
            iconView.image = icon
            iconLeadingConstraint.constant = 18
            iconTrailingConstraint.constant = -18
            iconHeightConstraint.constant = 128
        }

        // 2. 标题与副标题（种类 - 大小，与访达一致）
        nameLabel.alignment = .left
        subtitleLabel.alignment = .left
        infoHeaderContainer.isHidden = false
        nameLabel.stringValue = item.name

        var initialSize: Int64?
        if !isDirectory {
            if let size = values?.fileSize ?? values?.totalFileAllocatedSize {
                initialSize = Int64(size)
            }
        } else if let cached = FilePreviewColumn.bundleSizeCache.object(forKey: item.url as NSURL) {
            initialSize = cached.int64Value
        }

        let kindText = values?.localizedTypeDescription ?? (isDirectory ? (isPackage ? "应用程序".localized : "文件夹".localized) : "文件".localized)
        if isDirectory && !isPackage {
            let itemCount = (try? FileManager.default.contentsOfDirectory(atPath: item.url.path).filter { !$0.hasPrefix(".") }.count) ?? 0
            if let initialSize {
                subtitleLabel.stringValue = "\(kindText) - \(itemCount) 项，\(Format.bytes(initialSize))"
            } else {
                subtitleLabel.stringValue = "\(kindText) - \(itemCount) 项"
            }
        } else if let initialSize {
            subtitleLabel.stringValue = "\(kindText) - \(Format.bytes(initialSize))"
        } else {
            subtitleLabel.stringValue = kindText
        }

        // 3. 「信息」键值表（1:1 还原访达信息展示引擎）
        let metaResult = FileMetadataEngine.extractMetadata(for: item.url, resourceValues: values)
        buildRows(primary: metaResult.primaryRows, extended: metaResult.extendedRows)

        // 异步计算包（.app）或文件夹真实大小，计算完毕后自动更新界面并写入缓存
        if (isPackage || isDirectory) && initialSize == nil {
            let targetURL = item.url
            BundleSizeCache.shared.requestSize(for: targetURL) { [weak self] total in
                guard let self, self.currentURL == targetURL else { return }
                let formatted = Format.bytes(total)
                if isDirectory && !isPackage {
                    let itemCount = (try? FileManager.default.contentsOfDirectory(atPath: targetURL.path).filter { !$0.hasPrefix(".") }.count) ?? 0
                    self.subtitleLabel.stringValue = "\(kindText) - \(itemCount) 项，\(formatted)"
                } else {
                    self.subtitleLabel.stringValue = "\(kindText) - \(formatted)"
                }
            }
        }
    }

    /// 多选状态下的概览预览（1:1 还原访达分栏多选预览效果）
    func configure(with items: [FileItem]) {
        guard !items.isEmpty else { return }
        if items.count == 1 {
            configure(with: items[0])
            return
        }
        documentView.isHidden = false
        infoHeaderContainer.isHidden = false
        isExpanded = false

        // 1. 顶部叠放复合预览图（双层文档/文件夹层叠外观）
        let stackWidth: CGFloat = 128
        let stackHeight: CGFloat = 128
        let stackedImage = NSImage(size: NSSize(width: stackWidth, height: stackHeight), flipped: false) { rect in
            let icon1 = NSWorkspace.shared.icon(forFile: items[0].url.path)
            let icon2 = NSWorkspace.shared.icon(forFile: items[min(1, items.count - 1)].url.path)

            let backRect = NSRect(x: 18, y: 16, width: 92, height: 92)
            icon2.draw(in: backRect, from: .zero, operation: .sourceOver, fraction: 0.85)

            let frontRect = NSRect(x: 6, y: 4, width: 98, height: 98)
            icon1.draw(in: frontRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }

        iconView.image = stackedImage
        iconLeadingConstraint.constant = 18
        iconTrailingConstraint.constant = -18
        iconHeightConstraint.constant = 128

        // 2. 标题（如 "2份文稿"、"3个文件夹"、"4个项目"）与副标题（"2 项 - 6 KB"）
        let allNavigable = items.allSatisfy { $0.isNavigable }
        let allFiles = items.allSatisfy { !$0.isNavigable }
        let title: String
        if allNavigable {
            title = "\(items.count)个文件夹"
        } else if allFiles {
            title = "\(items.count)份文稿"
        } else {
            title = "\(items.count)个项目"
        }

        nameLabel.alignment = .center
        nameLabel.stringValue = title

        var totalBytes: Int64 = 0
        var hasValidSize = false
        for it in items {
            if let vals = try? it.url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]),
               let s = vals.fileSize ?? vals.totalFileAllocatedSize {
                totalBytes += Int64(s)
                hasValidSize = true
            }
        }
        if hasValidSize {
            subtitleLabel.stringValue = "\(items.count) 项 - \(Format.bytes(totalBytes))"
        } else {
            subtitleLabel.stringValue = "\(items.count) 项"
        }
        subtitleLabel.alignment = .center

        // 3. 元数据：创建时间区间与修改时间区间
        var creationDates: [Date] = []
        var modificationDates: [Date] = []
        for it in items {
            if let vals = try? it.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
                if let c = vals.creationDate { creationDates.append(c) }
                if let m = vals.contentModificationDate { modificationDates.append(m) }
            }
        }

        func dateRangeString(_ dates: [Date]) -> String? {
            guard !dates.isEmpty else { return nil }
            let sorted = dates.sorted()
            guard let first = sorted.first, let last = sorted.last else { return nil }
            let fYear = Calendar.current.component(.year, from: first)
            let lYear = Calendar.current.component(.year, from: last)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy年M月d日"
            if Calendar.current.isDate(first, inSameDayAs: last) {
                return fmt.string(from: first)
            } else if fYear == lYear {
                let endFmt = DateFormatter()
                endFmt.dateFormat = "M月d日"
                return "\(fmt.string(from: first))～\(endFmt.string(from: last))"
            } else {
                return "\(fmt.string(from: first))～\(fmt.string(from: last))"
            }
        }

        var rows: [(String, String)] = []
        if let cr = dateRangeString(creationDates) {
            rows.append(("创建时间".localized, cr))
        }
        if let md = dateRangeString(modificationDates) {
            rows.append(("修改时间".localized, md))
        }

        infoHeaderContainer.isHidden = true
        buildRows(primary: rows, extended: [])
    }

    @objc private func toggleMoreAction() {
        isExpanded.toggle()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            self.updateRowVisibilities()
            self.layoutSubtreeIfNeeded()
        }
    }

    private func updateRowVisibilities() {
        let totalCount = allRowViews.count
        let hasExtended = (totalCount > currentPrimaryCount)

        if !hasExtended {
            toggleMoreButton.isHidden = true
            for (i, row) in allRowViews.enumerated() {
                row.isHidden = false
                row.showDivider = (i < totalCount - 1)
            }
        } else {
            toggleMoreButton.isHidden = false
            toggleMoreButton.title = isExpanded ? "更少".localized : "更多".localized

            for (i, row) in allRowViews.enumerated() {
                if i < currentPrimaryCount {
                    row.isHidden = false
                    row.showDivider = isExpanded ? true : (i < currentPrimaryCount - 1)
                } else {
                    row.isHidden = !isExpanded
                    row.showDivider = (i < totalCount - 1)
                }
            }
        }
    }

    private func buildRows(primary: [(String, String)], extended: [(String, String)]) {
        infoStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        allRowViews.removeAll()
        currentPrimaryCount = primary.count

        let combined = primary + extended

        for pair in combined {
            let rowView = DetailRowView(key: pair.0, value: pair.1)
            infoStack.addArrangedSubview(rowView)
            NSLayoutConstraint.activate([
                rowView.leadingAnchor.constraint(equalTo: infoStack.leadingAnchor),
                rowView.trailingAnchor.constraint(equalTo: infoStack.trailingAnchor)
            ])
            allRowViews.append(rowView)
        }

        updateRowVisibilities()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        scroll.backgroundColor = .controlBackgroundColor
        needsDisplay = true
    }
}

// MARK: - 可拖拽列分隔线

/// 分栏之间的竖向分割线：支持鼠标悬浮左右光标、拖拽改变列宽（按住 ⌥ 键等比例改变所有列宽）、
/// 双击自动根据最长文件名智能适应宽度（同 macOS 访达原生行为）。
final class ColumnDividerView: NSView {
    var columnIndex: Int = 0
    var isPreview: Bool = false

    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat, Bool) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private var dragStartOrigin: NSPoint = .zero
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        dragStartOrigin = event.locationInWindow
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        let dx = event.locationInWindow.x - dragStartOrigin.x
        let isOption = event.modifierFlags.contains(.option)
        onDrag?(dx, isOption)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}

