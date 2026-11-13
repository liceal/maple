import AppKit

enum AppAppearance: String, CaseIterable {
    case system = "system"
    case dark   = "dark"
    case light  = "light"

    var title: String {
        switch self {
        case .system: return "跟随系统".localized
        case .dark:   return "深色".localized
        case .light:  return "浅色".localized
        }
    }
}

enum SidebarIconSize: String, CaseIterable {
    case small  = "small"
    case medium = "medium"
    case large  = "large"

    var title: String {
        switch self {
        case .small:  return "小"
        case .medium: return "中"
        case .large:  return "大"
        }
    }

    var dimension: CGFloat {
        switch self {
        case .small:  return 15
        case .medium: return 18
        case .large:  return 22
        }
    }
}

enum SidebarIconStyle: String, CaseIterable {
    case colorful   = "colorful"
    case category   = "category"
    case minimalist = "minimalist"

    var title: String {
        switch self {
        case .colorful:   return "彩色图标"
        case .category:   return "分区彩色"
        case .minimalist: return "简约图标"
        }
    }
}

enum ViewMode: String, CaseIterable {
    case list    = "list"
    case icons   = "icons"
    case columns = "columns"

    var title: String {
        switch self {
        case .list: return "列表".localized
        case .icons: return "图标".localized
        case .columns: return "分栏".localized
        }
    }
 
    var symbolName: String {
        switch self {
        case .list: return "list.bullet"
        case .icons: return "square.grid.2x2"
        case .columns: return "rectangle.split.3x1"
        }
    }
}

/// 侧栏可展示的分类枚举。
enum SidebarCategory: String, CaseIterable {
    case favorites = "favorites"
    case icloud    = "icloud"
    case locations = "locations"
    case servers   = "servers"
    case tags      = "tags"

    var title: String {
        switch self {
        case .favorites: return "个人收藏".localized
        case .icloud:    return "iCloud"
        case .locations: return "位置".localized
        case .servers:   return "服务器".localized
        case .tags:      return "标签".localized
        }
    }

    /// 分区彩色图标风格下，每个大模块对应的专属图标着色（对齐访达并按大模块区分）
    var iconTintColor: NSColor {
        switch self {
        case .favorites:
            return .systemBlue
        case .icloud:
            return NSColor(calibratedRed: 0.0, green: 0.62, blue: 0.73, alpha: 1.0)
        case .locations:
            return .systemIndigo
        case .servers:
            return .systemOrange
        case .tags:
            return .secondaryLabelColor
        }
    }
}

/// 用户保存的远程服务器条目（如 SMB / AFP / NFS / FTP / WebDAV / VNC）。
struct ServerEntry: Codable, Equatable {
    var id: String
    var name: String
    var urlString: String

    init(id: String = UUID().uuidString, name: String, urlString: String) {
        self.id = id
        self.name = name
        self.urlString = urlString
    }

    /// 归一化后的 URL（若未写协议头则默认补全 smb://）。
    var normalizedURLString: String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") { return trimmed }
        return "smb://\(trimmed)"
    }

    var url: URL? {
        let raw = normalizedURLString
        if let u = URL(string: raw), u.host != nil {
            return u
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "/:#[]@!$&'()*+,;=%")
        if let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed),
           let u = URL(string: encoded), u.host != nil {
            return u
        }
        return nil
    }

    var hostDisplay: String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if let u = url, let host = u.host, !host.isEmpty {
            if !u.path.isEmpty && u.path != "/" {
                return "\(host)\(u.path)"
            }
            return host
        }
        return urlString
    }
}

/// 轻量偏好存储。全部落在 UserDefaults，启动时恢复上次状态。
enum AppSettings {
    private static let store: UserDefaults = {
        let s = UserDefaults.standard
        let migrationKey = "__migrated_from_qspacelite_v1"
        if !s.bool(forKey: migrationKey) {
            s.set(true, forKey: migrationKey)
            if let legacy = UserDefaults(suiteName: "com.workbuddy.qspacelite") {
                let dict = legacy.dictionaryRepresentation()
                for (key, val) in dict {
                    if s.object(forKey: key) == nil {
                        s.set(val, forKey: key)
                    }
                }
                s.synchronize()
            }
        }
        return s
    }()

    private static var _appearance: AppAppearance = {
        guard let val = store.string(forKey: "appAppearance"),
              let mode = AppAppearance(rawValue: val) else {
            return .system
        }
        return mode
    }()

    /// 外观模式（跟随系统 / 黑色 / 亮色）
    static var appearance: AppAppearance {
        get { _appearance }
        set {
            _appearance = newValue
            store.set(newValue.rawValue, forKey: "appAppearance")
            applyAppearance()
            NotificationCenter.default.post(name: .appearanceDidChange, object: nil)
        }
    }

    private static var _language: AppLanguage = {
        guard let val = store.string(forKey: "appLanguage"),
              let lang = AppLanguage(rawValue: val) else {
            return .system
        }
        return lang
    }()

    /// 界面语言设置（跟随系统 / 简体中文 / English / 繁體中文 / 日本語）
    static var language: AppLanguage {
        get { _language }
        set {
            _language = newValue
            store.set(newValue.rawValue, forKey: "appLanguage")
            NotificationCenter.default.post(name: .languageDidChange, object: nil)
        }
    }

    /// 将当前设置的外观模式应用到全局及所有已打开窗口
    static func applyAppearance() {
        let appearanceObject: NSAppearance?
        switch appearance {
        case .system:
            appearanceObject = nil
        case .dark:
            appearanceObject = NSAppearance(named: .darkAqua)
        case .light:
            appearanceObject = NSAppearance(named: .aqua)
        }

        NSApp?.appearance = appearanceObject
        for window in NSApp?.windows ?? [] {
            window.appearance = appearanceObject
            window.contentView?.needsDisplay = true
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    static var showHidden: Bool {
        get { store.bool(forKey: "showHidden") }
        set {
            store.set(newValue, forKey: "showHidden")
            NotificationCenter.default.post(name: .showHiddenFilesDidChange, object: nil)
        }
    }

    /// 是否在列表视图中显示斑马线交替底色（默认关闭，整行显示纯净底色）
    private static var _showZebraStripes: Bool = (store.object(forKey: "showZebraStripes") as? Bool) ?? false
    static var showZebraStripes: Bool {
        get { _showZebraStripes }
        set {
            _showZebraStripes = newValue
            store.set(newValue, forKey: "showZebraStripes")
            NotificationCenter.default.post(name: .zebraStripesDidChange, object: nil)
        }
    }

    /// 边栏图标尺寸（小 / 中 / 大）
    private static var _sidebarIconSize: SidebarIconSize = {
        guard let val = store.string(forKey: "sidebarIconSize"),
              let size = SidebarIconSize(rawValue: val) else {
            return .medium
        }
        return size
    }()
    static var sidebarIconSize: SidebarIconSize {
        get { _sidebarIconSize }
        set {
            _sidebarIconSize = newValue
            store.set(newValue.rawValue, forKey: "sidebarIconSize")
            NotificationCenter.default.post(name: .sidebarIconSizeDidChange, object: nil)
        }
    }

    /// 边栏图标风格（彩色图标 / 分区彩色 / 简约图标）
    private static var _sidebarIconStyle: SidebarIconStyle = {
        let migrationKey = "__migrated_sidebar_category_style_v1"
        if !store.bool(forKey: migrationKey) {
            store.set(true, forKey: migrationKey)
            store.set(SidebarIconStyle.category.rawValue, forKey: "sidebarIconStyle")
            return .category
        }
        guard let val = store.string(forKey: "sidebarIconStyle"),
              let style = SidebarIconStyle(rawValue: val) else {
            return .category
        }
        return style
    }()
    static var sidebarIconStyle: SidebarIconStyle {
        get { _sidebarIconStyle }
        set {
            _sidebarIconStyle = newValue
            store.set(newValue.rawValue, forKey: "sidebarIconStyle")
            NotificationCenter.default.post(name: .sidebarIconStyleDidChange, object: nil)
        }
    }

    /// 窗格圆角与焦点设计方案
    public enum CornerScheme: Int, CaseIterable, Codable {
        /// 方案 1：顶栏高亮（顶栏微底色 + 顶栏分隔线高亮，取消全包围外圈，零外切）
        case native = 1
        /// 方案 2：间距分块（6px呼吸边距 + R10独立分块 + 悬浮外框）
        case cards = 2
        /// 方案 3：无缝贴边（满铺贴合 + 右下角 R10.5 同心大圆角 + 预览按钮避让）
        case smart = 3

        public var title: String {
            switch self {
            case .native: return "顶栏高亮".localized
            case .cards:  return "间距分块".localized
            case .smart:  return "无缝贴边".localized
            }
        }
    }

    private static var _cornerScheme: CornerScheme = {
        if let env = ProcessInfo.processInfo.environment["MAPLE_CORNER_SCHEME"], let val = Int(env), let s = CornerScheme(rawValue: val) {
            return s
        }
        if let plistVal = Bundle.main.object(forInfoDictionaryKey: "MapleCornerScheme") as? Int, let s = CornerScheme(rawValue: plistVal) {
            return s
        }
        if let raw = store.object(forKey: "cornerScheme") as? Int, let s = CornerScheme(rawValue: raw) {
            return s
        }
        return .smart
    }()
    public static var cornerScheme: CornerScheme {
        get { _cornerScheme }
        set {
            _cornerScheme = newValue
            store.set(newValue.rawValue, forKey: "cornerScheme")
            NotificationCenter.default.post(name: .paneAppearanceDidChange, object: nil)
        }
    }

    /// 当前激活窗格是否显示边框
    private static var _showPaneBorder: Bool = (store.object(forKey: "showPaneBorder") as? Bool) ?? true
    static var showPaneBorder: Bool {
        get { _showPaneBorder }
        set {
            _showPaneBorder = newValue
            store.set(newValue, forKey: "showPaneBorder")
            NotificationCenter.default.post(name: .paneAppearanceDidChange, object: nil)
        }
    }

    /// 当前激活窗格是否高亮地址栏
    private static var _highlightPaneAddressBar: Bool = (store.object(forKey: "highlightPaneAddressBar") as? Bool) ?? true
    static var highlightPaneAddressBar: Bool {
        get { _highlightPaneAddressBar }
        set {
            _highlightPaneAddressBar = newValue
            store.set(newValue, forKey: "highlightPaneAddressBar")
            NotificationCenter.default.post(name: .paneAppearanceDidChange, object: nil)
        }
    }

    /// 当前窗格是否保持圆角
    private static var _keepPaneCornerRadius: Bool = (store.object(forKey: "keepPaneCornerRadius") as? Bool) ?? true
    static var keepPaneCornerRadius: Bool {
        get { _keepPaneCornerRadius }
        set {
            _keepPaneCornerRadius = newValue
            store.set(newValue, forKey: "keepPaneCornerRadius")
            NotificationCenter.default.post(name: .paneAppearanceDidChange, object: nil)
        }
    }

    /// 侧边预览 / 是否显示项目详细信息
    private static var _showItemInfo: Bool = (store.object(forKey: "showItemInfo") as? Bool) ?? true
    static var showItemInfo: Bool {
        get { _showItemInfo }
        set {
            _showItemInfo = newValue
            store.set(newValue, forKey: "showItemInfo")
            NotificationCenter.default.post(name: .itemInfoDidChange, object: nil)
        }
    }

    /// 底部状态栏是否默认隐藏
    private static var _hideBottomStatusBar: Bool = (store.object(forKey: "hideBottomStatusBar") as? Bool) ?? false
    static var hideBottomStatusBar: Bool {
        get { _hideBottomStatusBar }
        set {
            _hideBottomStatusBar = newValue
            store.set(newValue, forKey: "hideBottomStatusBar")
            NotificationCenter.default.post(name: .bottomStatusBarDidChange, object: nil)
        }
    }

    /// 计算所有文件夹大小
    private static var _calculateFolderSizes: Bool = (store.object(forKey: "calculateFolderSizes") as? Bool) ?? false
    static var calculateFolderSizes: Bool {
        get { _calculateFolderSizes }
        set {
            _calculateFolderSizes = newValue
            store.set(newValue, forKey: "calculateFolderSizes")
        }
    }

    static var layout: String {
        get { store.string(forKey: "layout") ?? "single" }
        set { store.set(newValue, forKey: "layout") }
    }

    static var viewMode: String {
        get { store.string(forKey: "viewMode") ?? ViewMode.list.rawValue }
        set { store.set(newValue, forKey: "viewMode") }
    }

    // MARK: - 预览窗格设置

    /// 各种显示模式下是否开启右侧预览栏
    /// 分栏模式默认开启 (true)，列表模式和图标模式默认关闭 (false)
    static func isPreviewPaneVisible(for mode: ViewMode) -> Bool {
        let key = "previewPane.\(mode.rawValue)"
        if let val = store.object(forKey: key) as? Bool {
            return val
        }
        return mode == .columns
    }

    static func setPreviewPaneVisible(_ visible: Bool, for mode: ViewMode) {
        store.set(visible, forKey: "previewPane.\(mode.rawValue)")
    }

    /// 列表/图标模式下右侧预览栏的宽度（默认 260，最小 180，最大 600）
    static var previewPaneWidth: CGFloat {
        get {
            let val = store.double(forKey: "previewPaneWidth")
            return val >= 180 ? CGFloat(val) : 260
        }
        set {
            store.set(Double(newValue), forKey: "previewPaneWidth")
        }
    }

    static var sortField: String {
        get { store.string(forKey: "sortField") ?? SortField.name.rawValue }
        set { store.set(newValue, forKey: "sortField") }
    }

    static var sortAscending: Bool {
        get { store.object(forKey: "sortAscending") as? Bool ?? true }
        set { store.set(newValue, forKey: "sortAscending") }
    }

    static var groupMode: String {
        get { store.string(forKey: "groupMode") ?? GroupMode.none.rawValue }
        set { store.set(newValue, forKey: "groupMode") }
    }

    /// 各窗格上次所在目录（按窗格序号）。
    static var panePaths: [String] {
        get { store.stringArray(forKey: "panePaths") ?? [] }
        set { store.set(newValue, forKey: "panePaths") }
    }

    /// 各窗格上次的显示方式（list / icons / columns），按窗格序号。
    static var paneViewModes: [String] {
        get { store.stringArray(forKey: "paneViewModes") ?? [] }
        set { store.set(newValue, forKey: "paneViewModes") }
    }

    /// 焦点窗格序号（下次启动时恢复）。
    static var focusedPaneIndex: Int {
        get { store.integer(forKey: "focusedPaneIndex") }
        set { store.set(newValue, forKey: "focusedPaneIndex") }
    }

    /// 窗口位置与大小（NSStringFromRect）。
    static var windowFrame: String? {
        get { store.string(forKey: "windowFrame") }
        set { store.set(newValue, forKey: "windowFrame") }
    }

    // MARK: - 个人收藏

    /// 个人收藏系统预设目录
    static let defaultFavoriteDirectories: [FileManager.SearchPathDirectory] = [
        .desktopDirectory,
        .documentDirectory,
        .downloadsDirectory,
        .moviesDirectory,
        .musicDirectory,
        .picturesDirectory
    ]

    private static let cachedDefaultFavoriteURLs: [URL] = {
        var urls: [URL] = []
        for dir in defaultFavoriteDirectories {
            if let u = FileManager.default.urls(for: dir, in: .userDomainMask).first {
                urls.append(u)
            }
        }
        urls.append(FileManager.default.homeDirectoryForCurrentUser)
        urls.append(URL(fileURLWithPath: "/Applications"))
        return urls
    }()

    private static let cachedDefaultFavoritePaths: Set<String> = {
        Set(cachedDefaultFavoriteURLs.map { $0.standardizedFileURL.path })
    }()

    static func defaultFavoriteURLs() -> [URL] {
        cachedDefaultFavoriteURLs
    }

    static func defaultFavoritePaths() -> Set<String> {
        cachedDefaultFavoritePaths
    }

    /// 用户显式从预设收藏中取消收藏的路径黑名单（避免取消后又被当做默认收藏）
    private static var removedDefaultFavorites: Set<String> {
        get { Set(store.stringArray(forKey: "removedDefaultFavorites") ?? []) }
        set { store.set(Array(newValue), forKey: "removedDefaultFavorites") }
    }

    /// 用户添加到「个人收藏」的路径。
    static var favorites: [String] {
        get { store.stringArray(forKey: "favorites") ?? [] }
        set {
            store.set(newValue, forKey: "favorites")
            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
        }
    }

    /// 检查指定 URL 是否在个人收藏中（包含系统默认预设收藏与用户自定义收藏）
    static func isFavorite(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        if favorites.contains(where: { ($0 as NSString).standardizingPath == target }) {
            return true
        }
        if removedDefaultFavorites.contains(target) {
            return false
        }
        return defaultFavoritePaths().contains(target)
    }

    /// 加入 / 移出个人收藏，返回切换后的状态（true = 已收藏）。
    @discardableResult
    static func toggleFavorite(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        let isDefault = defaultFavoritePaths().contains(target)
        let isCurrentlyFav = isFavorite(url)

        if isCurrentlyFav {
            // 移出收藏
            var list = favorites
            list.removeAll { ($0 as NSString).standardizingPath == target }
            favorites = list
            if isDefault {
                var removed = removedDefaultFavorites
                removed.insert(target)
                removedDefaultFavorites = removed
            }
            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
            return false
        } else {
            // 加入收藏
            if isDefault {
                var removed = removedDefaultFavorites
                removed.remove(target)
                removedDefaultFavorites = removed
            }
            var list = favorites
            if !list.contains(where: { ($0 as NSString).standardizingPath == target }) {
                list.append(target)
                favorites = list
            }
            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
            return true
        }
    }

    static func removeFavorite(_ url: URL) {
        let target = url.standardizedFileURL.path
        var list = favorites
        list.removeAll { ($0 as NSString).standardizingPath == target }
        favorites = list
        if defaultFavoritePaths().contains(target) {
            var removed = removedDefaultFavorites
            removed.insert(target)
            removedDefaultFavorites = removed
        }
        NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
    }

    // MARK: - 列表列显示

    /// 当前显示的列（名称列恒显，不在其中）。
    static var visibleColumns: [String] {
        get { store.stringArray(forKey: "visibleColumns") ?? defaultColumns }
        set { store.set(newValue, forKey: "visibleColumns") }
    }

    /// 「恢复到默认」用的一套列。
    static var defaultColumns: [String] {
        get { store.stringArray(forKey: "defaultColumns") ?? ListColumn.builtInDefaults }
        set { store.set(newValue, forKey: "defaultColumns") }
    }

    /// 各列的用户自定义宽度（key 为 ListColumn.rawValue）。缺省时不写，回落到内置默认宽。
    private static var _columnWidths: [String: Double] = store.dictionary(forKey: "columnWidths") as? [String: Double] ?? [:]
    static var columnWidths: [String: Double] {
        get { _columnWidths }
        set {
            _columnWidths = newValue
            store.set(newValue, forKey: "columnWidths")
        }
    }

    /// 名称列的固定宽度（左对齐布局下名称列在左、各列向右排，最后一列自适应填满）。
    private static var _nameColumnWidth: CGFloat = {
        let value = store.double(forKey: "nameColumnWidth")
        return value >= Double(FileListView.minNameWidth) ? CGFloat(value) : 220
    }()
    static var nameColumnWidth: CGFloat {
        get { _nameColumnWidth }
        set {
            _nameColumnWidth = newValue
            store.set(Double(newValue), forKey: "nameColumnWidth")
        }
    }

    /// 分栏视图列宽（可通过拖动列分隔线实时调节并记住）。
    static var browserColumnWidth: CGFloat {
        get {
            let val = store.double(forKey: "browserColumnWidth")
            return val >= 140 ? CGFloat(val) : 214
        }
        set { store.set(Double(newValue), forKey: "browserColumnWidth") }
    }

    /// 恢复默认列时一并清除自定义宽度与名称列宽。
    static func resetColumnWidths() {
        _columnWidths = [:]
        _nameColumnWidth = 220
        store.removeObject(forKey: "columnWidths")
        store.removeObject(forKey: "nameColumnWidth")
    }

    static var sidebarWidth: CGFloat {
        get {
            let value = store.double(forKey: "sidebarWidth")
            return value > 100 ? value : Theme.sidebarWidth
        }
        set { store.set(Double(newValue), forKey: "sidebarWidth") }
    }

    /// 「查看显示选项」：图标视图的图标尺寸。
    static var gridIconSize: CGFloat {
        get {
            guard let val = store.object(forKey: "gridIconSize") as? Double, val >= 32 else {
                return Theme.gridIconSize
            }
            if val == 56.0 || val == 68.0 {
                return Theme.gridIconSize
            }
            return CGFloat(val)
        }
        set {
            store.set(Double(newValue), forKey: "gridIconSize")
            NotificationCenter.default.post(name: .gridIconSizeDidChange, object: nil)
        }
    }

    /// 列表/详细列表的图标尺寸（16~32pt）。
    static var listIconSize: CGFloat {
        get {
            let val = store.double(forKey: "listIconSize")
            return val >= 16 ? CGFloat(val) : 16
        }
        set {
            store.set(Double(newValue), forKey: "listIconSize")
            store.set(Double(newValue + 8), forKey: "listRowHeight")
        }
    }

    /// 「查看显示选项」：列表视图的行高。
    static var listRowHeight: CGFloat {
        get {
            let value = store.double(forKey: "listRowHeight")
            return value >= 18 ? value : Theme.rowHeight
        }
        set { store.set(Double(newValue), forKey: "listRowHeight") }
    }

    /// 窗格分隔条位置：按布局分别保存「竖向分界」「横向分界」的比例数组。
    static func splits(for mode: LayoutMode) -> (vertical: [CGFloat], horizontal: [CGFloat]) {
        let v = (store.array(forKey: "splits.v.\(mode.rawValue)") as? [Double] ?? []).map { CGFloat($0) }
        let h = (store.array(forKey: "splits.h.\(mode.rawValue)") as? [Double] ?? []).map { CGFloat($0) }
        return (v, h)
    }

    static func setSplits(vertical: [CGFloat], horizontal: [CGFloat], for mode: LayoutMode) {
        store.set(vertical.map { Double($0) }, forKey: "splits.v.\(mode.rawValue)")
        store.set(horizontal.map { Double($0) }, forKey: "splits.h.\(mode.rawValue)")
    }

    // MARK: - 侧栏分类显示控制

    /// 当前在侧栏中显示的分类（默认全部显示）。
    static var visibleSidebarCategories: [String] {
        get {
            store.stringArray(forKey: "visibleSidebarCategories")
                ?? SidebarCategory.allCases.map { $0.rawValue }
        }
        set {
            store.set(newValue, forKey: "visibleSidebarCategories")
        }
    }

    static func isSidebarCategoryVisible(_ category: SidebarCategory) -> Bool {
        visibleSidebarCategories.contains(category.rawValue)
    }

    static func toggleSidebarCategory(_ category: SidebarCategory) {
        var current = visibleSidebarCategories
        if let idx = current.firstIndex(of: category.rawValue) {
            current.remove(at: idx)
        } else {
            current.append(category.rawValue)
        }
        visibleSidebarCategories = current
    }

    static func showAllSidebarCategories() {
        visibleSidebarCategories = SidebarCategory.allCases.map { $0.rawValue }
    }

    /// 获取侧栏某个大模块内子项的自定义拖拽排序（按标识符存储）
    static func sidebarSectionOrder(for category: SidebarCategory) -> [String] {
        store.stringArray(forKey: "sidebarSectionOrder.\(category.rawValue)") ?? []
    }

    /// 保存侧栏某个大模块内子项的自定义拖拽排序
    static func setSidebarSectionOrder(_ identifiers: [String], for category: SidebarCategory) {
        store.set(identifiers, forKey: "sidebarSectionOrder.\(category.rawValue)")
    }

    // MARK: - 已保存的远程服务器

    static var savedServers: [ServerEntry] {
        get {
            guard let data = store.data(forKey: "savedServers"),
                  let entries = try? JSONDecoder().decode([ServerEntry].self, from: data) else {
                return []
            }
            return entries
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                store.set(data, forKey: "savedServers")
            }
        }
    }

    @discardableResult
    static func addOrUpdateServer(id editingId: String? = nil, name: String, urlString: String) -> ServerEntry {
        var list = savedServers
        let entry = ServerEntry(id: editingId ?? UUID().uuidString, name: name, urlString: urlString)
        let norm = entry.normalizedURLString.lowercased()

        if let editingId, let idx = list.firstIndex(where: { $0.id == editingId }) {
            list[idx].name = name
            list[idx].urlString = entry.normalizedURLString
            for i in list.indices.reversed() where i != idx && list[i].normalizedURLString.lowercased() == norm {
                list.remove(at: i)
            }
            savedServers = list
            return list.first(where: { $0.id == editingId }) ?? entry
        }

        if let idx = list.firstIndex(where: { $0.normalizedURLString.lowercased() == norm }) {
            if !name.isEmpty {
                list[idx].name = name
            }
            list[idx].urlString = entry.normalizedURLString
            savedServers = list
            return list[idx]
        }
        var newEntry = entry
        newEntry.urlString = entry.normalizedURLString
        list.append(newEntry)
        savedServers = list
        return newEntry
    }

    static func removeServer(id: String) {
        savedServers = savedServers.filter { $0.id != id }
    }
}

extension Notification.Name {
    static let languageDidChange = Notification.Name("AppSettingsLanguageDidChange")
    static let appearanceDidChange = Notification.Name("AppSettingsAppearanceDidChange")
    static let zebraStripesDidChange = Notification.Name("AppSettingsZebraStripesDidChange")
    static let favoritesDidChange = Notification.Name("AppSettingsFavoritesDidChange")
    static let gridIconSizeDidChange = Notification.Name("AppSettingsGridIconSizeDidChange")
    static let sidebarIconSizeDidChange = Notification.Name("AppSettingsSidebarIconSizeDidChange")
    static let sidebarIconStyleDidChange = Notification.Name("AppSettingsSidebarIconStyleDidChange")
    static let paneAppearanceDidChange = Notification.Name("AppSettingsPaneAppearanceDidChange")
    static let itemInfoDidChange = Notification.Name("AppSettingsItemInfoDidChange")
    static let bottomStatusBarDidChange = Notification.Name("AppSettingsBottomStatusBarDidChange")
}
