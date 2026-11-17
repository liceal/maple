import AppKit

/// 原生多级面包屑路径栏：
/// - 单个胶囊背景，内部按层级横向排列「图标 + 目录名 + 箭头」
/// - 点目录名：跳转到该级目录；点最后一级目录名：就地切换为可编辑路径
/// - 点箭头：弹出该级目录下的子文件夹列表
/// - 分栏模式下若选中文件，末段追加「文件图标 + 文件名」（点它打开文件）
/// - 点空白处 / 双击：切换为可编辑路径（回车跳转，Esc 取消）
final class PathBar: NSView {

    /// 追加在最后一级目录之后的条目（分栏模式下选中的文件）。
    struct Trailing {
        let name: String
        let url: URL
    }

    // MARK: - 对外回调

    /// 用户点了一个面包屑层级。`Bool` 为 true 表示双击（分栏模式下＝把该目录设为最左列）。
    var onNavigate: ((URL, Bool) -> Void)?
    /// 当前是否为分栏模式：决定面包屑单击/双击的语义。
    var isColumnMode: Bool = false
    /// 点击末段文件（打开它）。
    var onOpenItem: ((URL) -> Void)?
    /// 点击时激活所属窗格。
    var onActivate: (() -> Void)?
    /// 编辑结束（需要把键盘焦点交还文件列表）。
    var onEditingFinished: (() -> Void)?
    /// 点了收藏星标（加入 / 移出个人收藏）。
    var onToggleFavorite: ((URL) -> Void)?

    // MARK: - 状态

    private(set) var url: URL = URL(fileURLWithPath: NSHomeDirectory())
    /// 末段文件；为 nil 时只显示目录层级。
    private var trailing: Trailing?
    /// 标签视图的徽章（显示「圆点 + 标签名」，不参与路径导航）。
    private var badge: (title: String, color: NSColor)?

    /// 所属窗格是否为焦点窗格（非焦点窗格整体变暗，与原生规范一致）。
    var isActive: Bool = false {
        didSet { if isActive != oldValue { needsDisplay = true } }
    }

    private var isEditing = false {
        didSet { needsDisplay = true; updateSubviews() }
    }
    var isInlineEditingPath: Bool { isEditing }
    private var hoveredItem: Int? {
        didSet { if hoveredItem != oldValue { needsDisplay = true } }
    }

    // MARK: - 横向滚动

    /// 内容总宽度（含左右内边距）。超过视图宽度时整条路径可横向滚动，不再折叠层级。
    private var contentWidth: CGFloat = 0
    /// 当前横向滚动偏移，0 表示从最左（卷根/主目录）开始显示。
    private var scrollOffset: CGFloat = 0
    /// 下次重建布局后自动滚到末端，保证当前所在层级始终可见。
    private var pinToEnd = true
    /// 上一次布局时的宽度，用于识别「宽度变了要重新贴末端」。
    private var lastLaidOutWidth: CGFloat = 0
    /// 正在展开下拉的层级（箭头朝下 + 强调色高亮）。
    private var openCrumbPath: String?
    /// 空白处按住拖动的起点（视图坐标）。
    private var dragOrigin: NSPoint?
    private var dragOriginOffset: CGFloat = 0
    private var isDraggingContent = false

    private var maxScrollOffset: CGFloat { max(0, contentWidth + Self.edgeInset - viewportWidth) }
    /// 右侧始终留白的区域宽度：路径再长也不占用，留作点击进入路径编辑。
    private static let trailingReserve: CGFloat = 40
    /// 最右侧收藏星标占用的宽度。
    private static let starWidth: CGFloat = 24
    private var viewportWidth: CGFloat { max(0, bounds.width - Self.trailingReserve - Self.starWidth) }
    /// 边缘渐隐蒙版缓存（尺寸或边缘状态变化时重建）。
    private var edgeMaskCache: (size: NSSize, leading: Bool, trailing: Bool, image: CGImage)?

    // MARK: - 布局缓存

    private struct Crumb {
        let url: URL
        let title: String
    }

    /// 目录内容检查结果（含检查时间，用于短时效缓存）。
    private struct FolderState {
        let hasChildren: Bool
        let checkedAt: Date
    }

    private struct BarItem {
        var title: String
        var url: URL?
        var icon: NSImage?
        var dotColor: NSColor?
        var isTrailing: Bool
        /// 该级目录下是否有可展开的子文件夹；没有时箭头置灰。
        var hasChildren: Bool = true
        var titleRect: NSRect = .zero
        var chevronRect: NSRect = .zero
        var iconRect: NSRect = .zero
        var hoverRect: NSRect = .zero
    }

    /// 参与布局的条目（多级路径 + 可能的省略号 + 可能的末段文件）。
    private var items: [BarItem] = []
    private var crumbs: [Crumb] = []
    private var iconCache: [String: NSImage] = [:]
    /// 目录是否有可展开的子文件夹（按路径缓存，避免每次布局都读磁盘）
    private var folderHasChildrenCache: [String: FolderState] = [:]
    /// 鼠标悬停 / 按下的箭头条目下标
    private var hoveredChevron: Int?
    private var pressedChevron: Int?
    /// 最左侧指向卷根目录的箭头。
    private var rootArrowRect: NSRect = .zero
    private var rootArrowHovered = false {
        didSet {
            guard oldValue != rootArrowHovered else { return }
            needsDisplay = true
        }
    }
    private var rootArrowPressed = false {
        didSet {
            guard oldValue != rootArrowPressed else { return }
            needsDisplay = true
        }
    }

    // MARK: - 子视图

    private let editor = NSTextField()
    private var trackingArea: NSTrackingArea?
    private var itemAreas: [NSTrackingArea] = []
    /// 编辑态下的本地鼠标监听：点到地址栏以外的地方就退出编辑。
    private var editingMonitor: Any?
    /// 最右侧的收藏星标（鼠标移到地址栏上时才出现）。
    private let starButton = FavoriteStarButton()

    // MARK: - 度量

    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let textHeight: CGFloat = 17
    private static let chevronWidth: CGFloat = 8
    /// 文字与箭头之间的空隙
    private static let chevronGap: CGFloat = 4
    /// 箭头与下一级文字之间的空隙（比前侧略大，避免粘连）
    private static let chevronTrailing: CGFloat = 6
    private static let iconSize: CGFloat = 16
    private static let iconGap: CGFloat = 5
    private static let edgeInset: CGFloat = 8
    /// 每一级目录名的最大宽度：太长就在中间截断，避免整条路径被撑得很长。
    private static let maxTitleWidth: CGFloat = 130

    private static let truncatingStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }()

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        installEditingMonitor()
        guard let window else { return }
        // 窗口失焦（切到别的 App / 别的窗口）时退出路径编辑，恢复面包屑外观
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowDidResignKey),
                                               name: NSWindow.didResignKeyNotification,
                                               object: window)
    }

    deinit {
        if let editingMonitor { NSEvent.removeMonitor(editingMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    /// 编辑态下点击地址栏以外的任何位置（应用内的文件列表、工具栏、侧栏……）
    /// 都立即退出编辑、恢复面包屑外观，不必切换到别的窗口才生效。
    private func installEditingMonitor() {
        if let editingMonitor {
            NSEvent.removeMonitor(editingMonitor)
            self.editingMonitor = nil
        }
        editingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, self.isEditing else { return event }
            let screenPoint = event.window.map {
                $0.convertPoint(toScreen: event.locationInWindow)
            } ?? NSEvent.mouseLocation
            guard let host = self.window else { return event }
            let local = self.convert(host.convertPoint(fromScreen: screenPoint), from: nil)
            // 点在编辑框里继续编辑；点其它任何位置都退出编辑
            if !self.editor.frame.contains(local) {
                self.finishEditing()
            }
            return event
        }
    }

    @objc private func windowDidResignKey() {
        if isEditing { finishEditing() }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.isBezeled = false
        editor.isBordered = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = .systemFont(ofSize: 13, weight: .regular)
        editor.textColor = .labelColor
        editor.lineBreakMode = .byTruncatingMiddle
        editor.isEditable = true
        editor.isHidden = true
        editor.delegate = self
        editor.target = self
        editor.action = #selector(commitEditing)
        addSubview(editor)

        // 收藏星标：常驻显示在地址栏右侧（原生高精风格）
        starButton.translatesAutoresizingMaskIntoConstraints = true
        starButton.isHidden = false
        starButton.onToggle = { [weak self] in
            guard let self else { return }
            self.onToggleFavorite?(self.url)
        }
        addSubview(starButton)

        NotificationCenter.default.addObserver(forName: .favoritesDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshFavoriteState()
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 23),

            editor.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            editor.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            editor.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            editor.heightAnchor.constraint(equalToConstant: 17)
        ])

        updateDisplay()
    }

    // MARK: - 数据

    /// 是否处于清空空白状态（删除标签等场景）
    private var isBlank = false

    /// 显示标签徽章（分栏/列表都可用），点它不进入路径编辑。
    func setBadge(title: String, color: NSColor) {
        isBlank = false
        badge = (title, color)
        trailing = nil
        updateDisplay()
        rebuildLayout()
    }

    /// 清空标签徽章
    func clearBadge() {
        badge = nil
        updateDisplay()
        rebuildLayout()
    }

    /// 设置为完全空白未选中状态
    func setBlank() {
        badge = nil
        isBlank = true
        crumbs = []
        trailing = nil
        items = []
        toolTip = nil
        editor.stringValue = ""
        starButton.isHidden = true
        needsDisplay = true
        rebuildLayout()
    }

    func setURL(_ newURL: URL, trailing newTrailing: Trailing? = nil) {
        isBlank = false
        // 一旦设置真实路径，标签徽章必须让位
        let hadBadge = badge != nil
        badge = nil
        guard hadBadge || newURL.path != url.path || newTrailing?.url.path != trailing?.url.path else { return }
        url = newURL
        trailing = newTrailing
        // 换目录后箭头下标全部失效，清掉悬停/按下状态
        hoveredChevron = nil
        pressedChevron = nil
        // 换目录后自动贴到末端，当前层级始终在可视区内
        pinToEnd = true
        updateDisplay()
        rebuildLayout()
    }

    private func updateDisplay() {
        if isBlank {
            crumbs = []
            toolTip = nil
            editor.stringValue = ""
            starButton.isOn = false
            starButton.isHidden = true
            needsDisplay = true
            return
        }
        if let badge {
            crumbs = []
            toolTip = "标签：".localized + badge.title
            editor.stringValue = ""
            starButton.isOn = false
            starButton.isHidden = true
            needsDisplay = true
            return
        }
        crumbs = makeCrumbs(for: url)
        if let trailing {
            toolTip = url.path + "/" + trailing.name
        } else {
            toolTip = url.path
        }
        editor.stringValue = url.path
        starButton.isOn = AppSettings.isFavorite(url)
        starButton.isHidden = false
        needsDisplay = true
    }

    /// 从卷根（或用户主目录）到当前目录的逐级路径。
    private func makeCrumbs(for url: URL) -> [Crumb] {
        let standardized = url.standardizedFileURL
        // 注意：URL.deletingLastPathComponent() 对 "/" 会返回 "/.."，用字符串路径计算
        var paths: [String] = []
        var current = standardized.path.isEmpty ? "/" : standardized.path
        while true {
            paths.append(current)
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        paths.reverse()

        // 位于 废纸篓、iCloud 云盘或主目录内时，从对应特殊根起点开始显示（不暴露冗长底层路径），与原生规范一致
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let iCloudPath = homePath + "/Library/Mobile Documents/com~apple~CloudDocs"
        let trashPath = homePath + "/.Trash"
        if standardized.path == trashPath || standardized.path.hasPrefix(trashPath + "/"),
           let start = paths.firstIndex(of: trashPath) {
            paths = Array(paths[start...])
        } else if standardized.path == iCloudPath || standardized.path.hasPrefix(iCloudPath + "/"),
           let start = paths.firstIndex(of: iCloudPath) {
            paths = Array(paths[start...])
        } else if standardized.path == homePath || standardized.path.hasPrefix(homePath + "/"),
                  let start = paths.firstIndex(of: homePath) {
            paths = Array(paths[start...])
        }

        return paths.map { Crumb(url: URL(fileURLWithPath: $0), title: displayName(forPath: $0)) }
    }

    private func displayName(forPath path: String) -> String {
        if path.hasSuffix("/com~apple~CloudDocs") {
            return "iCloud 云盘".localized
        }
        if path.hasSuffix("/.Trash") || path.hasSuffix("/Trash") {
            return "废纸篓".localized
        }
        let name = FileManager.default.displayName(atPath: path)
        if !name.isEmpty { return name }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? "/" : last
    }

    // MARK: - 图标

    private func icon(forPath path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let url = URL(fileURLWithPath: path)
        let image: NSImage
        if let special = Theme.specialFolderIcon(for: url, size: Self.iconSize) {
            image = special
        } else {
            image = NSWorkspace.shared.icon(forFile: path)
            image.size = NSSize(width: Self.iconSize, height: Self.iconSize)
        }
        iconCache[path] = image
        return image
    }

    // MARK: - 外观

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isBlank { return }

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)

        // 编辑态：无外框边线，使用明亮底色 + 内凹陷阴影质感，让黑色文字清晰突出
        if isEditing {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let brightBg = isDark ? NSColor(white: 0.22, alpha: 1.0) : NSColor.white
            brightBg.setFill()
            let bgPath = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            bgPath.fill()

            // 仅保留内凹陷阴影，完全去掉外边线
            InsetShadow.draw(in: rect, radius: 5, strength: 0.7)
            return
        }

        let titleColor = isActive ? NSColor.labelColor : NSColor.secondaryLabelColor
        /// 悬停时底变浅灰、字变淡：底色和字色一起变，才有「指到哪儿」的焦点感。
        let hoverTitleColor = NSColor.labelColor.withAlphaComponent(0.55)
        let defaultArrowColor = isActive
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.8)
            : NSColor.tertiaryLabelColor

        // 内容可横向滚动：裁剪到可视区内（右侧留出常驻空白区），溢出的一侧用渐变蒙版淡出
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: viewportWidth, height: bounds.height)).addClip()
        if let mask = edgeMask() {
            NSGraphicsContext.current?.cgContext.clip(
                to: NSRect(x: 0, y: 0, width: viewportWidth, height: bounds.height),
                mask: mask)
        }
        if scrollOffset != 0 {
            let transform = NSAffineTransform()
            transform.translateX(by: -scrollOffset, yBy: 0)
            transform.concat()
        }

        // 最左侧指向卷根目录的箭头
        if !rootArrowRect.isEmpty {
            // 卷根的下拉展开中：这一级（不属于任何面包屑）也要有焦点反馈
            let rootIsOpen = openCrumbPath != nil
                && !items.contains { $0.url?.path == openCrumbPath }
            let rootColor: NSColor
            if rootIsOpen {
                NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: rootArrowRect.insetBy(dx: -5, dy: -6),
                             xRadius: 4, yRadius: 4).fill()
                rootColor = NSColor.controlAccentColor
            } else if rootArrowHovered {
                NSColor.labelColor.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: rootArrowRect.insetBy(dx: -5, dy: -6),
                             xRadius: 4, yRadius: 4).fill()
                rootColor = NSColor.labelColor
            } else {
                rootColor = defaultArrowColor
            }
            drawArrow(in: rootArrowRect, pointingDown: rootIsOpen, color: rootColor)
        }

        for (index, item) in items.enumerated() {
            let isOpen = !item.isTrailing && openCrumbPath != nil && item.url?.path == openCrumbPath
            let isHovered = hoveredItem == index

            if isHovered || isOpen {
                let fill = isOpen
                    ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                    : NSColor.labelColor.withAlphaComponent(0.12)
                fill.setFill()
                NSBezierPath(roundedRect: item.hoverRect, xRadius: 5, yRadius: 5).fill()
            }

            if let dotColor = item.dotColor {
                let diameter: CGFloat = 10
                let rect = NSRect(x: item.iconRect.midX - diameter / 2,
                                  y: item.iconRect.midY - diameter / 2,
                                  width: diameter, height: diameter)
                dotColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else if let image = item.icon {
                image.draw(in: item.iconRect,
                           from: .zero,
                           operation: .sourceOver,
                           fraction: 1.0,
                           respectFlipped: true,
                           hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
            }

            let drawColor: NSColor
            if isOpen {
                // 下拉展开中：底色和文字一起变，形成明确的焦点
                drawColor = NSColor.controlAccentColor
            } else if isHovered {
                drawColor = hoverTitleColor
            } else {
                drawColor = titleColor
            }
            NSAttributedString(string: item.title, attributes: [
                .font: Self.font,
                .foregroundColor: drawColor,
                .paragraphStyle: Self.truncatingStyle
            ]).draw(in: item.titleRect)

            // 末段文件后面没有下拉箭头
            guard !item.isTrailing else { continue }

            // 箭头的悬停 / 按下反馈：浅色圆角底
            let isChevronHovered = hoveredChevron == index
            let isPressed = pressedChevron == index
            if isChevronHovered || isPressed {
                NSColor.labelColor.withAlphaComponent(isPressed ? 0.2 : 0.1).setFill()
                let feedback = item.chevronRect.insetBy(dx: -4, dy: -6)
                NSBezierPath(roundedRect: feedback, xRadius: 4, yRadius: 4).fill()
            }

            // 没有可展开内容时箭头置灰（灰＝不可用，悬停/按下也不加深）；
            // 有内容时悬停/按下变为高亮色
            let arrowColor: NSColor
            if isOpen {
                arrowColor = NSColor.controlAccentColor
            } else if !item.hasChildren {
                arrowColor = NSColor.labelColor.withAlphaComponent(0.26)
            } else if isChevronHovered || isPressed {
                arrowColor = NSColor.labelColor
            } else {
                arrowColor = defaultArrowColor
            }
            drawArrow(in: item.chevronRect,
                      pointingDown: isOpen,
                      color: arrowColor)
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    /// 路径溢出时，让被视口裁掉的一侧（左/右）渐隐，提示还有未显示的层级。
    private func edgeMask() -> CGImage? {
        guard maxScrollOffset > 0.5 else { return nil }
        let leading = scrollOffset > 0.5
        let trailing = scrollOffset < maxScrollOffset - 0.5
        guard leading || trailing else { return nil }
        if let cached = edgeMaskCache, cached.size == bounds.size,
           cached.leading == leading, cached.trailing == trailing {
            return cached.image
        }

        let scale: CGFloat = 2
        let width = Int(viewportWidth * scale)
        let height = Int(bounds.height * scale)
        let space = CGColorSpaceCreateDeviceGray()
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }

        // clip(to:mask:) 依据亮度取掩膜：白=保留，黑=裁掉
        let white = CGColor(gray: 1, alpha: 1)
        let black = CGColor(gray: 0, alpha: 1)
        context.setFillColor(white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let fade = 26 * scale
        if leading, let gradient = CGGradient(colorsSpace: space, colors: [black, white] as CFArray, locations: [0, 1]) {
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: 0, width: fade, height: CGFloat(height)))
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: fade, y: 0), options: [])
            context.restoreGState()
        }
        if trailing, let gradient = CGGradient(colorsSpace: space, colors: [white, black] as CFArray, locations: [0, 1]) {
            let startX = CGFloat(width) - fade
            context.saveGState()
            context.clip(to: CGRect(x: startX, y: 0, width: fade, height: CGFloat(height)))
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: startX, y: 0),
                                       end: CGPoint(x: CGFloat(width), y: 0),
                                       options: [])
            context.restoreGState()
        }

        guard let image = context.makeImage() else { return nil }
        edgeMaskCache = (bounds.size, leading, trailing, image)
        return image
    }

    /// QSpace 风格的实心箭头：默认朝右分隔层级，展开下拉时转为朝下。
    private func drawArrow(in rect: NSRect, pointingDown: Bool, color: NSColor) {
        guard rect.width > 0 else { return }
        let cx = rect.midX
        let cy = rect.midY
        let halfLong: CGFloat = 3.0   // 箭头方向的半长
        let halfWide: CGFloat = 2.7   // 垂直方向的半宽

        let path = NSBezierPath()
        if pointingDown {
            path.move(to: NSPoint(x: cx - halfWide, y: cy - halfLong + 0.9))
            path.line(to: NSPoint(x: cx + halfWide, y: cy - halfLong + 0.9))
            path.line(to: NSPoint(x: cx, y: cy + halfLong + 0.4))
        } else {
            path.move(to: NSPoint(x: cx - halfLong + 0.9, y: cy - halfWide))
            path.line(to: NSPoint(x: cx + halfLong + 0.4, y: cy))
            path.line(to: NSPoint(x: cx - halfLong + 0.9, y: cy + halfWide))
        }
        path.close()
        // 描边 + 填充同色，配合圆角转角得到饱满的实体箭头
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.lineWidth = 1.2
        color.setFill()
        color.setStroke()
        path.fill()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        // 收藏星标固定在最右侧
        starButton.frame = NSRect(x: max(0, bounds.width - Self.starWidth - 3),
                                  y: 0,
                                  width: Self.starWidth,
                                  height: bounds.height)
        rebuildLayout()
    }

    private func rebuildLayout() {
        items.removeAll()
        guard bounds.width > 8 else {
            contentWidth = 0
            scrollOffset = 0
            refreshItemTrackingAreas()
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font]

        func textWidth(_ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: attributes).width) + 2
        }

        let centerY = bounds.height / 2

        // 标签徽章：单个「圆点 + 标签名」，没有层级也没有箭头
        if let badge {
            let width = min(textWidth(badge.title) + Self.iconSize + Self.iconGap, bounds.width - 16)
            var item = BarItem(title: badge.title,
                               url: nil,
                               icon: nil,
                               dotColor: badge.color,
                               isTrailing: false)
            item.iconRect = NSRect(x: Self.edgeInset, y: centerY - Self.iconSize / 2,
                                   width: Self.iconSize, height: Self.iconSize)
            let titleX = Self.edgeInset + Self.iconSize + Self.iconGap
            item.titleRect = NSRect(x: titleX, y: centerY - Self.textHeight / 2,
                                    width: max(0, width - (titleX - Self.edgeInset)), height: Self.textHeight)
            item.chevronRect = .zero
            item.hoverRect = .zero
            items.append(item)
            rootArrowRect = .zero
            contentWidth = 0
            scrollOffset = 0
            refreshItemTrackingAreas()
            needsDisplay = true
            return
        }

        guard !crumbs.isEmpty else {
            rootArrowRect = .zero
            contentWidth = 0
            scrollOffset = 0
            refreshItemTrackingAreas()
            return
        }

        // 最左侧固定一个指向卷根目录的箭头
        rootArrowRect = NSRect(x: Self.edgeInset - 2,
                               y: centerY - Self.chevronWidth / 2,
                               width: Self.chevronWidth,
                               height: Self.chevronWidth)

        // 每一级都按名称排布；名字过长就在中间截断，总宽超出视图时靠横向滚动浏览
        var x: CGFloat = Self.edgeInset + Self.chevronWidth + 6
        /// 最后一个元素的可视右边界；内容宽度按它计算，保证滚到末端时右侧留白与左侧一致
        var contentRight: CGFloat = x

        for (index, crumb) in crumbs.enumerated() {
            // 第一级（卷根 / 主目录 / iCloud）以及所有特殊系统目录（桌面、文稿、下载、影片、音乐、图片、应用程序）
            // 均展示 QSpace 同款彩色图标，大小与磁盘图标保持一致。
            let isSpecial = Theme.specialFolderIcon(for: crumb.url, size: Self.iconSize) != nil
            let showIcon = (index == 0) || isSpecial
            let icon = showIcon ? self.icon(forPath: crumb.url.path) : nil
            var width = min(textWidth(crumb.title), Self.maxTitleWidth)
            if showIcon { width += Self.iconSize + Self.iconGap }

            var item = BarItem(title: crumb.title,
                               url: crumb.url,
                               icon: icon,
                               isTrailing: false,
                               hasChildren: crumbHasChildren(crumb.url))

            var titleX = x
            if showIcon {
                item.iconRect = NSRect(x: x, y: centerY - Self.iconSize / 2,
                                       width: Self.iconSize, height: Self.iconSize)
                titleX = x + Self.iconSize + Self.iconGap
            }
            item.titleRect = NSRect(x: titleX, y: centerY - Self.textHeight / 2,
                                    width: max(0, width - (titleX - x)), height: Self.textHeight)
            item.chevronRect = NSRect(x: x + width + Self.chevronGap,
                                      y: centerY - Self.chevronWidth / 2,
                                      width: Self.chevronWidth, height: Self.chevronWidth)
            item.hoverRect = NSRect(x: x - 2,
                                    y: centerY - Self.textHeight / 2 - 1,
                                    width: width + 4,
                                    height: Self.textHeight + 2)

            items.append(item)
            contentRight = item.chevronRect.maxX
            x += width + Self.chevronGap + Self.chevronWidth + Self.chevronTrailing
        }

        // 末段：分栏模式下选中的文件
        if let trailing {
            let width = min(textWidth(trailing.name), Self.maxTitleWidth) + Self.iconSize + Self.iconGap
            var item = BarItem(title: trailing.name,
                               url: trailing.url,
                               icon: icon(forPath: trailing.url.path),
                               isTrailing: true)
            item.iconRect = NSRect(x: x, y: centerY - Self.iconSize / 2,
                                   width: Self.iconSize, height: Self.iconSize)
            let titleX = x + Self.iconSize + Self.iconGap
            item.titleRect = NSRect(x: titleX, y: centerY - Self.textHeight / 2,
                                    width: max(0, width - (titleX - x)), height: Self.textHeight)
            item.chevronRect = .zero
            item.hoverRect = NSRect(x: x - 2,
                                    y: centerY - Self.textHeight / 2 - 1,
                                    width: width + 4,
                                    height: Self.textHeight + 2)
            items.append(item)
            contentRight = item.titleRect.maxX
            x += width
        }

        contentWidth = contentRight + Self.edgeInset
        // 宽度变化（窗口缩放、拖动分隔条）后重新贴到末端，避免当前层级被挤出去
        if abs(bounds.width - lastLaidOutWidth) > 0.5 {
            lastLaidOutWidth = bounds.width
            pinToEnd = true
        }
        if pinToEnd {
            // 切换目录后默认贴到末端，保证当前层级（以及末段文件）可见
            pinToEnd = false
            scrollOffset = maxScrollOffset
        } else {
            scrollOffset = min(max(0, scrollOffset), maxScrollOffset)
        }

        refreshItemTrackingAreas()
        needsDisplay = true
    }

    // MARK: - 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        refreshItemTrackingAreas()
    }

    private func refreshItemTrackingAreas() {
        itemAreas.forEach { removeTrackingArea($0) }
        itemAreas.removeAll()

        // 卷根箭头单独一个跟踪区域
        let rootRect = rootArrowHitRect.offsetBy(dx: -scrollOffset, dy: 0)
        if rootRect.intersects(bounds) {
            let area = NSTrackingArea(rect: rootRect,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                      owner: self,
                                      userInfo: ["root": true])
            addTrackingArea(area)
            itemAreas.append(area)
        }

        for (index, item) in items.enumerated() {
            // 直接用命中测试用的矩形，避免名称区与箭头区互相重叠导致高亮闪烁。
            // 矩形是内容坐标，减去滚动偏移才是视图坐标；否则滚动后悬停会错位。
            let nameRect = nameHitRect(for: index).offsetBy(dx: -scrollOffset, dy: 0)
            if nameRect.intersects(bounds) {
                let area = NSTrackingArea(rect: nameRect,
                                          options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                          owner: self,
                                          userInfo: ["index": index])
                addTrackingArea(area)
                itemAreas.append(area)
            }

            // 箭头单独一个跟踪区域，用于箭头的悬停 / 按下反馈
            guard !item.isTrailing else { continue }
            let chevronRect = chevronHitRect(for: index).offsetBy(dx: -scrollOffset, dy: 0)
            guard chevronRect.intersects(bounds) else { continue }
            let area = NSTrackingArea(rect: chevronRect,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                      owner: self,
                                      userInfo: ["chevron": index])
            addTrackingArea(area)
            itemAreas.append(area)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        let info = event.trackingArea?.userInfo
        if info?["root"] != nil {
            rootArrowHovered = true
            return
        }
        if let index = info?["chevron"] as? Int {
            if hoveredChevron != index {
                hoveredChevron = index
                needsDisplay = true
            }
            return
        }
        if let index = info?["index"] as? Int {
            hoveredItem = index
            return
        }
        // 鼠标进入地址栏整体：显示最右侧的收藏星标
        setStarVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        let info = event.trackingArea?.userInfo
        if info?["root"] != nil {
            rootArrowHovered = false
            return
        }
        if let index = info?["chevron"] as? Int, hoveredChevron == index {
            hoveredChevron = nil
            needsDisplay = true
            return
        }
        if let index = info?["index"] as? Int, hoveredItem == index {
            hoveredItem = nil
            return
        }
        // 鼠标离开地址栏：收藏星标淡出
        setStarVisible(false)
    }

    /// 收藏星标的显示 / 隐藏（编辑态与标签状态下不显示，常态保持显示）。
    private func setStarVisible(_ visible: Bool) {
        guard badge == nil, !isEditing else {
            starButton.isHidden = true
            return
        }
        starButton.isHidden = false
    }

    // MARK: - 交互

    /// 窗口未激活时的第一次点击也照常处理（点箭头、点条目都一步到位）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        guard !isEditing, badge == nil else { return }

        let point = convert(event.locationInWindow, from: nil)
        let contentPoint = NSPoint(x: point.x + scrollOffset, y: point.y)

        // 点在条目上（目录名 → 切换目录；箭头区域 → 展开子目录），绝不进入路径编辑
        if let hit = hitTest(at: contentPoint) {
            if hit.index == rootArrowIndex {
                rootArrowPressed = true
                showRootDropdown()
                return
            }
            if hit.isChevron {
                pressedChevron = hit.index
                needsDisplay = true
                showChildFolders(of: hit.index)
                return
            }
            // 面包屑目录名：即刻跳转到该目录（0 延迟原生手感）
            let isDouble = event.clickCount >= 2
            activate(itemAt: hit.index, isChevron: false, isDoubleClick: isDouble)
            return
        }

        // 面包屑内容右边缘（视图坐标）：在此坐标之后才是真正的「右侧空白区域」
        let contentEndX = (items.last.map { max($0.titleRect.maxX, $0.chevronRect.maxX, $0.hoverRect.maxX) } ?? 0) - scrollOffset

        // 只有点击在右侧空白区域，才进入路径编辑
        if point.x > contentEndX {
            beginEditingPath()
            return
        }

        // 内容溢出时按住可拖动横向浏览
        if maxScrollOffset > 0, event.clickCount < 2 {
            dragOrigin = point
            dragOriginOffset = scrollOffset
            isDraggingContent = false
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !isDraggingContent, abs(point.x - origin.x) > 3 { isDraggingContent = true }
        guard isDraggingContent else { return }
        setScrollOffset(dragOriginOffset - (point.x - origin.x))
    }

    override func mouseUp(with event: NSEvent) {
        if pressedChevron != nil {
            pressedChevron = nil
            needsDisplay = true
        }
        if rootArrowPressed {
            rootArrowPressed = false
        }
        // 仅在点击右侧空白区域且未发生拖拽时进入路径编辑
        if let origin = dragOrigin, !isDraggingContent {
            let contentEndX = (items.last.map { max($0.titleRect.maxX, $0.chevronRect.maxX, $0.hoverRect.maxX) } ?? 0) - dragOriginOffset
            if origin.x > contentEndX {
                beginEditingPath()
            }
        }
        dragOrigin = nil
        isDraggingContent = false
    }

    /// 触摸板双指横滑 / 鼠标滚轮：整条路径横向滚动。
    override func scrollWheel(with event: NSEvent) {
        guard maxScrollOffset > 0 else {
            super.scrollWheel(with: event)
            return
        }
        // 触摸板纵向滚动仍交给下方文件列表，只接管横向手势
        if event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) <= abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
            return
        }
        // 鼠标滚轮没有横向轴时，用纵向滚轮驱动横向浏览
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaX
            : (event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY) * 9
        guard abs(delta) > 0.01 else { return }
        setScrollOffset(scrollOffset - delta)
    }

    private func setScrollOffset(_ value: CGFloat) {
        let clamped = min(max(0, value), maxScrollOffset)
        guard abs(clamped - scrollOffset) > 0.01 else { return }
        scrollOffset = clamped
        refreshItemTrackingAreas()
        needsDisplay = true
    }

    /// 命中测试（传入内容坐标）。返回命中的条目以及命中的是「箭头」还是「目录名」。
    private func hitTest(at point: NSPoint) -> (index: Int, isChevron: Bool)? {
        // 最左侧的卷根箭头单独判定（它不属于任何一级目录名）
        if !rootArrowHitRect.isEmpty, rootArrowHitRect.contains(point) {
            return (rootArrowIndex, true)
        }
        for index in items.indices {
            // 箭头区域比图形本身大一圈，且纵向铺满整条地址栏
            let chevron = chevronHitRect(for: index)
            if !chevron.isEmpty, chevron.contains(point) { return (index, true) }
            if nameHitRect(for: index).contains(point) { return (index, false) }
        }
        return nil
    }

    /// 卷根箭头的可点区域（左右各放宽几像素，纵向铺满整条栏）。
    private var rootArrowHitRect: NSRect {
        guard !rootArrowRect.isEmpty else { return .zero }
        return NSRect(x: rootArrowRect.minX - 5,
                      y: 0,
                      width: rootArrowRect.width + 10,
                      height: bounds.height)
    }

    /// 命中卷根箭头时返回的特殊下标。
    private var rootArrowIndex: Int { items.count }

    /// 当前路径所在卷的根目录（外置磁盘则是「/Volumes/xxx」）。
    ///
    /// Swift 侧的 URLResourceValues 没有 volumeURL，只能从已挂载的卷里
    /// 找路径最长的那个前缀。
    private func volumeRoot(of url: URL) -> URL {
        let path = url.standardizedFileURL.path
        var best = URL(fileURLWithPath: "/")
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsBrowsableKey],
            options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            let volumePath = volume.standardizedFileURL.path
            let prefix = volumePath == "/" ? "/" : volumePath + "/"
            guard path == volumePath || path.hasPrefix(prefix) else { continue }
            if volumePath.count > best.path.count { best = volume }
        }
        return best
    }

    /// 箭头可点区域：箭头图形左右各放宽几像素，纵向铺满整条栏。
    /// 这样不用精确点到那个 8pt 的小三角，箭头周围留白也能展开。
    private func chevronHitRect(for index: Int) -> NSRect {
        guard items.indices.contains(index) else { return .zero }
        let item = items[index]
        guard !item.isTrailing, !item.chevronRect.isEmpty else { return .zero }
        return NSRect(x: item.chevronRect.minX - 5,
                      y: 0,
                      width: item.chevronRect.width + 10,
                      height: bounds.height)
    }

    /// 目录名可点区域：从「上一级箭头之后」一直延伸到「本级箭头之前」，铺满整条栏高。
    ///
    /// 名称段与箭头段严格相邻：既不重叠（否则点下一级文字会被上一级抢走，
    /// 表现为「点击跳到上一级」），也不留缝（否则点名称旁边的空隙会误进路径编辑态）。
    private func nameHitRect(for index: Int) -> NSRect {
        guard items.indices.contains(index) else { return .zero }
        let item = items[index]
        var left = item.hoverRect.minX
        if index == 0 {
            // 第一级前面是卷根箭头，名称段从箭头之后开始
            left = rootArrowHitRect.isEmpty ? left : rootArrowHitRect.maxX + 1
        } else {
            let previous = chevronHitRect(for: index - 1)
            left = previous.isEmpty ? items[index - 1].hoverRect.maxX + 2 : previous.maxX
        }
        let chevron = chevronHitRect(for: index)
        let right = chevron.isEmpty ? max(item.hoverRect.maxX, item.titleRect.maxX) + 4 : chevron.minX
        return NSRect(x: left, y: 0, width: max(0, right - left), height: bounds.height)
    }

    private func activate(itemAt index: Int, isChevron: Bool, isDoubleClick: Bool = false) {
        // 最左侧的卷根箭头只负责展开下拉：点它不会把当前目录切走
        if index == rootArrowIndex {
            showRootDropdown()
            return
        }
        guard items.indices.contains(index) else { return }
        let item = items[index]
        if isChevron {
            showChildFolders(of: index)
            return
        }
        guard let target = item.url else { return }
        if item.isTrailing {
            if isDoubleClick {
                onOpenItem?(target)
            } else {
                onNavigate?(target, false)
            }
        } else {
            onNavigate?(target, isDoubleClick)
        }
    }

    // MARK: - 下拉子目录

    /// 展开某一级目录下的子文件夹（也供测试调用）。
    func showChildFolders(of index: Int? = nil) {
        let fallback = items.lastIndex(where: { !$0.isTrailing }) ?? 0
        let targetIndex = index ?? fallback
        guard items.indices.contains(targetIndex), let base = items[targetIndex].url else { return }

        // 锚点覆盖「名称 + 箭头」整块可点区域：再点这里时由弹层的点外关闭逻辑吃掉这次点击，
        // 从而表现为「点一下展开、再点一下收起」，而不是关掉又重开。
        var anchor = nameHitRect(for: targetIndex)
        let chevron = chevronHitRect(for: targetIndex)
        if !chevron.isEmpty { anchor = anchor.union(chevron) }
        presentPopup(base: base, contentAnchor: anchor)
    }

    /// 卷根箭头的下拉：列出卷根目录自身、个人主目录以及卷根目录下的文件夹，
    /// 方便在主目录（🏠）与磁盘根目录（💿）之间一键切换。
    private func showRootDropdown() {
        let volRoot = volumeRoot(of: url)
        let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var entries: [URL] = [volRoot, homeURL]
        for child in childFolders(of: volRoot) {
            if !entries.contains(where: { $0.standardizedFileURL.path == child.standardizedFileURL.path }) {
                entries.append(child)
            }
        }
        presentPopup(base: volRoot, customFolders: entries, contentAnchor: rootArrowHitRect)
    }

    @objc private func handleCrumbMenuItem(_ sender: NSMenuItem) {
        guard let picked = sender.representedObject as? URL else { return }
        openCrumbPath = nil
        needsDisplay = true
        onNavigate?(picked, false)
        onEditingFinished?()
    }

    /// 在内容坐标的 `contentAnchor` 下方展开 `base` 的子文件夹列表（原生 NSMenu 款式，与点点点弹窗样式统一）。
    private func presentPopup(base: URL, customFolders: [URL]? = nil, contentAnchor: NSRect) {
        let folders = customFolders ?? childFolders(of: base)
        guard !folders.isEmpty else {
            NSSound.beep()
            return
        }

        // 展开期间该级箭头朝下并用强调色标示
        openCrumbPath = base.path
        needsDisplay = true

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        for folder in folders {
            let name = FileManager.default.displayName(atPath: folder.path)
            let item = NSMenuItem(title: name, action: #selector(handleCrumbMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = folder

            let icon = NSWorkspace.shared.icon(forFile: folder.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon

            menu.addItem(item)
        }

        let anchorX = contentAnchor.minX - scrollOffset
        let popPoint = NSPoint(x: max(4, anchorX), y: bounds.height + 2)
        menu.popUp(positioning: nil, at: popPoint, in: self)
    }

    /// 某一级目录下是否有可展开的子文件夹（没有则箭头置灰）。
    /// 带短时效缓存：目录内容变化后（如新建文件夹）很快能自动纠正。
    private func crumbHasChildren(_ url: URL) -> Bool {
        let now = Date()
        if let cached = folderHasChildrenCache[url.path],
           now.timeIntervalSince(cached.checkedAt) < 2 {
            return cached.hasChildren
        }
        let has = !childFolders(of: url).isEmpty
        folderHasChildrenCache[url.path] = FolderState(hasChildren: has, checkedAt: now)
        return has
    }

    /// 收藏状态变化后刷新星标（实心 / 空心）。
    func refreshFavoriteState() {
        starButton.isOn = AppSettings.isFavorite(url)
    }

    /// 目录内容变化后清缓存，让灰色箭头立刻恢复。
    func invalidateFolderCache() {
        folderHasChildrenCache.removeAll()
        needsDisplay = true
    }

    private func childFolders(of base: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: keys,
            options: AppSettings.showHidden ? [] : [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { candidate -> URL? in
            guard let values = try? candidate.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  values.isPackage != true else { return nil }
            return candidate
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - 路径编辑

    /// 切换为可编辑路径（也供测试调用）。
    func beginEditingPath() {
        guard !isEditing, badge == nil else { return }
        isEditing = true
        editor.stringValue = url.path
        window?.makeFirstResponder(editor)
        if let textEditor = editor.currentEditor() {
            textEditor.selectedRange = NSRange(location: 0, length: (editor.stringValue as NSString).length)
        }
    }

    private func updateSubviews() {
        editor.isHidden = !isEditing
        starButton.isHidden = isEditing || (badge != nil)
        if isEditing {
            hoveredItem = nil
            hoveredChevron = nil
            pressedChevron = nil
        }
    }

    @objc private func commitEditing() {
        let raw = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            cancelEditing()
            return
        }
        let target = resolve(raw)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            NSSound.beep()
            editor.currentEditor()?.selectedRange = NSRange(location: 0, length: (editor.stringValue as NSString).length)
            return
        }
        let destination = isDirectory.boolValue ? target : target.deletingLastPathComponent()
        finishEditing()
        if destination.standardizedFileURL.path != url.standardizedFileURL.path {
            onNavigate?(destination, false)
        }
    }

    @objc private func cancelEditing() {
        finishEditing()
    }

    private func finishEditing() {
        guard isEditing else { return }
        isEditing = false
        if window?.firstResponder === editor.currentEditor() {
            window?.makeFirstResponder(nil)
        }
        onEditingFinished?()
    }

    /// 支持 `~`、相对路径与尾部斜杠。
    private func resolve(_ raw: String) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return url.appendingPathComponent(expanded).standardizedFileURL
    }
}

// MARK: - 文本域代理

extension PathBar: NSTextFieldDelegate {

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitEditing()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // 点到别处结束编辑：不跳转，仅还原面包屑外观。
        if isEditing { finishEditing() }
    }
}

// MARK: - 收藏星标

/// 地址栏最右侧的五角星（Maple 内置资源图标）：
/// 点击将当前目录加入或移出个人收藏。
final class FavoriteStarButton: NSView {

    /// 是否已收藏（已收藏时显示 Maple 内置实心黄星）。
    var isOn = false {
        didSet {
            guard oldValue != isOn else { return }
            needsDisplay = true
        }
    }
    var onToggle: (() -> Void)?

    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            needsDisplay = true
        }
    }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let size: CGFloat = 16
        let rect = NSRect(x: (bounds.width - size) / 2,
                          y: (bounds.height - size) / 2,
                          width: size,
                          height: size)
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            let hoverRect = NSRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20)
            NSBezierPath(roundedRect: hoverRect, xRadius: 4, yRadius: 4).fill()
        }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard let image = Theme.favoriteStarIcon(isOn: isOn, isDark: isDark) else { return }

        if isOn {
            image.draw(in: rect)
        } else {
            // 未收藏：悬停时 1.0 完全饱和，未悬停时轻微柔和 (0.88)
            let fraction: CGFloat = isHovered ? 1.0 : 0.88
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - 原生菜单代理

extension PathBar: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        openCrumbPath = nil
        needsDisplay = true
    }
}
