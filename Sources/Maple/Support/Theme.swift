import AppKit

/// 全局尺寸、颜色与常用控件工厂。
enum Theme {

    // MARK: - 尺寸

    static let sidebarWidth: CGFloat = 196
    /// 顶部工具条（自绘，与窗口内容连成一体）的高度
    static let chromeHeight: CGFloat = 36
    static let paneGap: CGFloat = 1
    static let headerHeight: CGFloat = 30
    static let statusHeight: CGFloat = 20
    static let rowHeight: CGFloat = 24
    static let groupRowHeight: CGFloat = 21
    static let listIconSize: CGFloat = 16
    static let gridIconSize: CGFloat = 48

    // MARK: - 颜色

    static let sidebarBackground = NSColor.windowBackgroundColor
    /// 内容区/工具栏背景：动态适配浅色与深色外观，
    /// 深色模式下为深灰 (0.13)，浅色模式下为原生浅灰 (0.96)，让窗格与顶部条视觉统一。
    static let paneBackground: NSColor = NSColor(name: "ThemePaneBackground") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            return NSColor(calibratedWhite: 0.13, alpha: 1.0)
        } else {
            return NSColor(calibratedWhite: 0.96, alpha: 1.0)
        }
    }
    static let hairline = NSColor.separatorColor
    static let focusRing = NSColor.controlAccentColor

    // MARK: - 控件工厂

    static func symbol(_ name: String,
                       size: CGFloat = 13,
                       weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// 工具栏「更多」按钮的图标：仅省略号（不再带下拉小箭头）。
    static func moreMenuImage() -> NSImage? {
        symbol("ellipsis", size: 15, weight: .semibold)
    }

    /// 缓存从 Bundle / Resources 加载的特殊目录彩色图标（含 24x24 @1x 与 48x48 @2x）及按尺寸缩放后的副本。
    private static var specialIconCache: [String: NSImage] = [:]
    private static var sizedIconCache: [String: NSImage] = [:]
    private static let devResourcesDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources", isDirectory: true)

    /// 预构建特殊目录标准路径到资源名的 O(1) 映射表，避免每次绘制行/单元格时拼接字符串。
    private static let specialFolderResourceMap: [String: String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return [
            home: "icon_sidebar_home_folder",
            home + "/Desktop": "icon_sidebar_desktop_folder",
            home + "/Documents": "icon_sidebar_documents_folder",
            home + "/Downloads": "icon_sidebar_downloads_folder",
            home + "/Movies": "icon_sidebar_movies_folder",
            home + "/Music": "icon_sidebar_music_folder",
            home + "/Pictures": "icon_sidebar_pictures_folder",
            "/Applications": "icon_sidebar_apps_folder",
            home + "/Applications": "icon_sidebar_apps_folder",
            "/System/Applications": "icon_sidebar_apps_folder",
            home + "/Library/Mobile Documents/com~apple~CloudDocs": "icon_icloud_small",
            "/Network": "icon_sidebar_net_host"
        ]
    }()

    private static func loadBundledTiffIcon(_ name: String, asTemplate: Bool = false) -> NSImage? {
        let key = asTemplate ? "\(name)_tpl" : name
        if let cached = specialIconCache[key] { return cached }
        let load = { () -> NSImage? in
            if let url = Bundle.main.url(forResource: name, withExtension: "tiff"),
               let img = NSImage(contentsOf: url) {
                return img
            }
            let devURL = devResourcesDir.appendingPathComponent("\(name).tiff")
            if let img = NSImage(contentsOf: devURL) {
                return img
            }
            return nil
        }
        guard let img = load() else { return nil }
        img.isTemplate = asTemplate
        specialIconCache[key] = img
        return img
    }

    static func sizedBundledIcon(_ name: String, size: CGFloat, asTemplate: Bool = false) -> NSImage? {
        let cacheKey = "\(name)_\(Int(size * 2))_\(asTemplate)"
        if let cached = sizedIconCache[cacheKey] { return cached }
        guard let base = loadBundledTiffIcon(name, asTemplate: asTemplate),
              let copy = base.copy() as? NSImage else {
            return nil
        }
        copy.size = NSSize(width: size, height: size)
        copy.isTemplate = asTemplate
        sizedIconCache[cacheKey] = copy
        return copy
    }

    /// 根据目录 URL 返回原生彩色特殊目录图标（主目录、桌面、文稿、下载、影片、音乐、图片、应用程序、iCloud 云盘、网络）；
    /// 普通目录返回 `nil`。所有图标均已去除多余透明边距，视觉尺寸与磁盘图标一致。
    static func specialFolderIcon(for url: URL, size: CGFloat = 16) -> NSImage? {
        let stdPath = url.standardizedFileURL.path
        let resourceName: String?
        if stdPath.hasSuffix("/.Trash") || url.lastPathComponent == ".Trash" || url.lastPathComponent == "Trash" || FileItem.isTrash(url: url) {
            let isEmpty: Bool = {
                guard let contents = try? FileManager.default.contentsOfDirectory(atPath: stdPath) else { return false }
                return contents.filter { !$0.hasPrefix(".") }.isEmpty
            }()
            resourceName = isEmpty ? "icon_trash_empty_small" : "icon_trash_full_small"
        } else if let mapped = specialFolderResourceMap[stdPath] {
            resourceName = mapped
        } else if stdPath.hasPrefix("/Volumes/"),
                  let vals = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
                  vals.volumeIsLocal == false {
            resourceName = "icon_sidebar_net_host"
        } else {
            resourceName = nil
        }

        guard let name = resourceName else { return nil }
        return sizedBundledIcon(name, size: size)
    }

    /// 远程服务器图标（根据协议返回网络主机或 VNC 图标）。
    static func serverIcon(urlString: String = "", size: CGFloat = 16) -> NSImage {
        let lower = urlString.lowercased()
        let name = lower.hasPrefix("vnc://") ? "icon_sidebar_vnc" : "icon_sidebar_net_host"
        if let icon = sizedBundledIcon(name, size: size) {
            return icon
        }
        return symbol("network", size: size - 3, weight: .regular) ?? NSImage()
    }

    /// 彩色小房子图标（🏠）：优先加载本地高精矢量资源 `icon_sidebar_home_folder.tiff`。
    static func colorfulHomeIcon(size: CGFloat = 16) -> NSImage {
        if let icon = sizedBundledIcon("icon_sidebar_home_folder", size: size) {
            return icon
        }
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let fallback = NSWorkspace.shared.icon(forFile: homeURL.path)
        fallback.size = NSSize(width: size, height: size)
        return fallback
    }

    /// 简约风边栏图标（极简单色线条图标）
    static func minimalistSidebarIcon(for node: SidebarNode, size: CGFloat = 18) -> NSImage {
        // 1. 废纸篓
        if node.isTrash {
            if let icon = sizedBundledIcon("icon_trash_small", size: size, asTemplate: true) {
                return icon
            }
        }

        // 2. 检查 URL 对应的特殊目录或路径
        if let url = node.url {
            let stdPath = url.standardizedFileURL.path
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

            if stdPath == home {
                if let icon = sizedBundledIcon("icon_tpl_home_small", size: size, asTemplate: true) {
                    return icon
                }
            } else if stdPath == home + "/Desktop" {
                if let icon = sizedBundledIcon("icon_tpl_desktop_small", size: size, asTemplate: true) {
                    return icon
                }
            } else if stdPath == home + "/Documents" {
                if let icon = sizedBundledIcon("icon_tpl_doc_small", size: size, asTemplate: true) {
                    return icon
                }
            } else if stdPath == home + "/Downloads" {
                if let icon = sizedBundledIcon("icon_tpl_download_small", size: size, asTemplate: true) {
                    return icon
                }
            } else if stdPath == home + "/Movies" {
                if let icon = sizedBundledIcon("icon_tpl_movie_small", size: size, asTemplate: true) {
                    return icon
                }
            } else if stdPath == home + "/Music" {
                if let icon = sizedBundledIcon("icon_tpl_music_small", size: size, asTemplate: true) {
                    return icon
                }
            } else if stdPath == home + "/Pictures" {
                if let icon = sizedBundledIcon("icon_tpl_picture_small", size: size, asTemplate: true) {
                    return icon
                }
            } else if stdPath == "/Applications" || stdPath == home + "/Applications" || stdPath == "/System/Applications" {
                if let icon = sizedBundledIcon("icon_tpl_apps_small", size: size, asTemplate: true) {
                    return icon
                }
            } else if stdPath == home + "/Library/Mobile Documents/com~apple~CloudDocs" {
                if let icon = sizedBundledIcon("icon_tpl_icloud_small", size: size, asTemplate: true) {
                    return icon
                }
            } else if stdPath == "/" {
                // 本地根系统卷 (Macintosh HD)
                if let icon = sizedBundledIcon("icon_tpl_indisk_small", size: size, asTemplate: true) {
                    return icon
                }
            }

            // 识别常见云盘 (OneDrive, Dropbox, Google Drive)
            let lowerPath = stdPath.lowercased()
            let lowerTitle = node.title.lowercased()
            if lowerPath.contains("onedrive") || lowerTitle.contains("onedrive") {
                if let icon = sizedBundledIcon("icon_tpl_onedrive_small", size: size, asTemplate: true) {
                    return icon
                }
            } else if lowerPath.contains("dropbox") || lowerTitle.contains("dropbox") {
                if let icon = sizedBundledIcon("icon_tpl_dropbox_small", size: size, asTemplate: true) {
                    return icon
                }
            } else if lowerPath.contains("google drive") || lowerPath.contains("googledrive") || lowerTitle.contains("google") {
                if let icon = sizedBundledIcon("icon_tpl_googledrive_small", size: size, asTemplate: true) {
                    return icon
                }
            }

            // 可推出卷 / DMG / 外部存储设备
            if node.isEjectableVolume {
                if let icon = sizedBundledIcon("icon_tpl_rmdisk_small", size: size, asTemplate: true) {
                    return icon
                }
            }

            // 本地其它磁盘卷
            if stdPath.hasPrefix("/Volumes/") {
                if let vals = try? url.resourceValues(forKeys: [.volumeIsLocalKey]), vals.volumeIsLocal == false {
                    if let icon = sizedBundledIcon("icon_tpl_net_host_small", size: size, asTemplate: true) {
                        return icon
                    }
                } else {
                    if let icon = sizedBundledIcon("icon_tpl_rmdisk_small", size: size, asTemplate: true) {
                        return icon
                    }
                }
            }
        }

        // 3. 网络服务器
        if node.kind == .server {
            let lower = (node.serverEntry?.urlString ?? "").lowercased()
            let resName = lower.hasPrefix("vnc://") ? "icon_tpl_vnc_small" : "icon_tpl_net_host_small"
            if let icon = sizedBundledIcon(resName, size: size, asTemplate: true) {
                return icon
            }
        }

        // 4. 用户自定义收藏文件夹或其它普通文件夹：使用通用简约文件夹图标
        if node.kind == .folder {
            if let icon = sizedBundledIcon("icon_tpl_folder_small", size: size, asTemplate: true) {
                return icon
            }
        }

        // 5. Fallback 到 SF Symbol
        if !node.symbol.isEmpty, let sym = symbol(node.symbol, size: size - 3) {
            sym.isTemplate = true
            return sym
        }

        let fallback = symbol("folder", size: size - 3) ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }

    /// 地址栏收藏五角星图标：
    /// - 未收藏（浅色模式）：`icon_favorite.tiff`（深灰空心星标）
    /// - 未收藏（深色模式）：`icon_favorite_dark.tiff`（银灰空心星标）
    /// - 已收藏：`icon_favorite_on.tiff`（黄色实心星标）
    static func favoriteStarIcon(isOn: Bool, isDark: Bool = false) -> NSImage? {
        let name: String
        if isOn {
            name = "icon_favorite_on"
        } else {
            name = isDark ? "icon_favorite_dark" : "icon_favorite"
        }
        return sizedBundledIcon(name, size: 16)
    }

    /// 轻量工具栏按钮（无边框、单色符号）。
    static func iconButton(_ symbolName: String,
                           tooltip: String,
                           target: AnyObject?,
                           action: Selector) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = symbol(symbolName, size: 13, weight: .medium)
        button.toolTip = tooltip
        button.target = target
        button.action = action
        button.setButtonType(.momentaryChange)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])
        return button
    }

    static func label(_ text: String = "",
                      size: CGFloat = 11,
                      weight: NSFont.Weight = .regular,
                      color: NSColor = .secondaryLabelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        field.isSelectable = false
        return field
    }

    static func hairlineView() -> NSView {
        let view = HairlineView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    /// 纯色底视图（在 draw 中绘制，保证每个视图渲染一致）。
    ///
    /// 注意：多个同构视图共用 `layer.backgroundColor` 时，实测会出现同色不同渲染
    /// （同一枚 0.12 的底色，有的窗格画成 0.12、有的画成 0.56），呈现从上到下逐渐变白。
    /// 改用 draw 填充后完全一致，因此背景色统一走绘制，不用 layer。
    static func backgroundView(_ color: NSColor) -> ThemeBackgroundView {
        let view = ThemeBackgroundView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.fillColor = color
        return view
    }

    /// 生成供 `NSVisualEffectView.maskImage` 使用的九宫格圆角遮罩：
    /// 让 macOS WindowServer 将背后的毛玻璃表面（`CGSWindowBackdrop`）、外发光边框及窗口阴影精确裁剪为圆角，彻底消除四角外的直角边缘。
    static func roundedCornerMask(radius: CGFloat = 12) -> NSImage {
        let side = radius * 2 + 2
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    /// 原生风格「右侧预览窗格」图标（外框圆角矩形 + 竖分割线 + 右侧缩略图方块 + 文本线条）
    static var previewPaneIcon: NSImage {
        let size = NSSize(width: 17, height: 13)
        let img = NSImage(size: size, flipped: false) { rect in
            let strokeColor = NSColor.black
            strokeColor.setStroke()
            strokeColor.setFill()

            // 1. 外层圆角矩形
            let outerRect = NSRect(x: 1, y: 1, width: 15, height: 11)
            let outerPath = NSBezierPath(roundedRect: outerRect, xRadius: 2.2, yRadius: 2.2)
            outerPath.lineWidth = 1.2
            outerPath.stroke()

            // 2. 中间竖直分割线（将左边主区域与右侧预览区分隔开）
            let splitX: CGFloat = 10.0
            let splitPath = NSBezierPath()
            splitPath.move(to: NSPoint(x: splitX, y: 1.6))
            splitPath.line(to: NSPoint(x: splitX, y: 11.4))
            splitPath.lineWidth = 1.0
            splitPath.stroke()

            // 3. 右侧上部小方块（缩略图）
            let thumbRect = NSRect(x: 11.6, y: 6.8, width: 3.2, height: 3.2)
            let thumbPath = NSBezierPath(roundedRect: thumbRect, xRadius: 0.6, yRadius: 0.6)
            thumbPath.fill()

            // 4. 右侧下部两条横线（属性文本）
            let line1 = NSBezierPath()
            line1.move(to: NSPoint(x: 11.6, y: 4.5))
            line1.line(to: NSPoint(x: 14.8, y: 4.5))
            line1.lineWidth = 0.9
            line1.stroke()

            let line2 = NSBezierPath()
            line2.move(to: NSPoint(x: 11.6, y: 2.7))
            line2.line(to: NSPoint(x: 14.8, y: 2.7))
            line2.lineWidth = 0.9
            line2.stroke()

            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - 内阴影（凹陷效果）

/// 在矩形内侧绘制内阴影，视觉上像被压进去的一个凹槽：
/// 上边与左边压暗、下边留一道高光。
enum InsetShadow {

    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let defaultTopGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [CGColor(gray: 0, alpha: 0.22), CGColor(gray: 0, alpha: 0)] as CFArray,
        locations: [0, 1]
    )
    private static let defaultLeftGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [CGColor(gray: 0, alpha: 0.13), CGColor(gray: 0, alpha: 0)] as CFArray,
        locations: [0, 1]
    )
    private static let defaultBottomGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [CGColor(gray: 1, alpha: 0.45), CGColor(gray: 1, alpha: 0)] as CFArray,
        locations: [0, 1]
    )

    /// 在 `rect` 内侧画内阴影。视图可以是 flipped 的，方向按视图坐标（y 向下）计算。
    static func draw(in rect: NSRect,
                     radius: CGFloat = 6,
                     strength: CGFloat = 1) {
        guard let context = NSGraphicsContext.current?.cgContext, rect.width > 1, rect.height > 1 else { return }

        let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let isDefaultStrength = abs(strength - 1.0) < 0.001

        context.saveGState()
        clip.addClip()

        // 上边：暗
        let topGrad = isDefaultStrength ? defaultTopGradient : CGGradient(
            colorsSpace: colorSpace,
            colors: [CGColor(gray: 0, alpha: 0.22 * strength), CGColor(gray: 0, alpha: 0)] as CFArray,
            locations: [0, 1]
        )
        if let gradient = topGrad {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: rect.minX, y: rect.minY),
                                       end: CGPoint(x: rect.minX, y: rect.minY + 4),
                                       options: [])
        }
        // 左边：暗
        let leftGrad = isDefaultStrength ? defaultLeftGradient : CGGradient(
            colorsSpace: colorSpace,
            colors: [CGColor(gray: 0, alpha: 0.13 * strength), CGColor(gray: 0, alpha: 0)] as CFArray,
            locations: [0, 1]
        )
        if let gradient = leftGrad {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: rect.minX, y: rect.minY),
                                       end: CGPoint(x: rect.minX + 4, y: rect.minY),
                                       options: [])
        }
        // 下边：亮
        let bottomGrad = isDefaultStrength ? defaultBottomGradient : CGGradient(
            colorsSpace: colorSpace,
            colors: [CGColor(gray: 1, alpha: 0.45 * strength), CGColor(gray: 1, alpha: 0)] as CFArray,
            locations: [0, 1]
        )
        if let gradient = bottomGrad {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: rect.minX, y: rect.maxY),
                                       end: CGPoint(x: rect.minX, y: rect.maxY - 2),
                                       options: [])
        }
        context.restoreGState()
    }

    /// 凹陷区域的底色（比窗口底色略深一点，让内阴影有依托）。
    static func fill(in rect: NSRect, radius: CGFloat = 6, strength: CGFloat = 1) {
        NSColor.labelColor.withAlphaComponent(0.045 * strength).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
}

/// 工具栏里的方形紧凑按钮：图标居中、无边框、不带系统那种椭圆边距。
/// 悬停 / 按下时给一层很浅的圆角底，让点击范围清楚。
final class SquareToolbarButton: NSButton {

    /// 按钮本身的边长（正方形）。
    static let side: CGFloat = 28

    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    var buttonSize: CGFloat = 28 {
        didSet {
            widthConstraint?.constant = buttonSize
            heightConstraint?.constant = buttonSize
        }
    }

    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            needsDisplay = true
        }
    }

    /// 处于选中状态时（常驻一层浅底，表示当前生效的那一项）。
    var isOn = false {
        didSet {
            guard oldValue != isOn else { return }
            needsDisplay = true
        }
    }

    /// 选中态 (isOn == true) 时是否绘制常驻背景浅灰底。
    /// 设为 false 时，选中仅靠图标/文字着色（如变蓝），不绘制背景灰色。
    var showsBackgroundWhenOn: Bool = true {
        didSet {
            guard oldValue != showsBackgroundWhenOn else { return }
            needsDisplay = true
        }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    init(size: CGFloat = 28) {
        self.buttonSize = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        commonInit()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        bezelStyle = .inline
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        setButtonType(.momentaryChange)
        let w = widthAnchor.constraint(equalToConstant: buttonSize)
        let h = heightAnchor.constraint(equalToConstant: buttonSize)
        widthConstraint = w
        heightConstraint = h
        NSLayoutConstraint.activate([w, h])
    }

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

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if isOn && showsBackgroundWhenOn {
            // 选中态用中性灰底（和系统访达的工具栏一致），不用强调色，避免抢视觉
            NSColor.labelColor.withAlphaComponent(isHovered ? 0.18 : 0.14).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        } else if isHovered || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.20 : 0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 在绘制时解析颜色，外观切换后自动重绘。
class ThemeBackgroundView: NSView {

    var fillColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard fillColor != .clear else { return }
        fillColor.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 不透明垫底层。
///
/// 系统动态色在 vibrancy（窗口材质）上下文里会解析成半透明变体，
/// 于是桌面/后面的窗口会透过来，表现为窗口颜色随背景变化、逐渐发白。
/// 这里显式在外观上下文里解析成设备色再写入 layer，alpha = 1，彻底挡住透光。
final class OpaqueBackgroundView: NSView {

    var color: NSColor = .clear { didSet { applyColor() } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        guard color != .clear else { return }
        wantsLayer = true
        let c = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let resolved = c.usingColorSpace(.deviceRGB) ?? c
            layer?.backgroundColor = resolved.withAlphaComponent(1).cgColor
        }
    }
}

/// 1 像素分隔线，随外观自动着色。
final class HairlineView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setFill()
        bounds.fill()
    }
}

/// 焦点描边覆盖层：画在窗格最上层，且不参与鼠标命中（点击穿透给下层）。
final class FocusRingOverlay: NSView {

    var color: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    var lineWidth: CGFloat = 2 {
        didSet { needsDisplay = true }
    }

    var isCardMode: Bool = false {
        didSet { needsDisplay = true }
    }

    /// 各个角的独立圆角（左上，右上，左下，右下）
    var cornerRadii: (topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) = (0, 0, 0, 0) {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard color != .clear else { return }
        let inset = lineWidth / 2
        let drawBounds = bounds.insetBy(dx: inset, dy: inset)
        guard drawBounds.width > 0, drawBounds.height > 0 else { return }

        let path: NSBezierPath
        if isCardMode {
            // 方案 2：卡片悬浮风，四周均为大圆角 R10
            path = NSBezierPath(roundedRect: drawBounds, xRadius: 10, yRadius: 10)
        } else if cornerRadii.bottomRight > 0 || cornerRadii.bottomLeft > 0 || cornerRadii.topRight > 0 || cornerRadii.topLeft > 0 {
            // 方案 3：智能角位贴合，使用选择性同心圆角
            path = makeSelectivePath(rect: drawBounds,
                                     tl: cornerRadii.topLeft,
                                     tr: cornerRadii.topRight,
                                     br: cornerRadii.bottomRight,
                                     bl: cornerRadii.bottomLeft)
        } else {
            path = NSBezierPath(roundedRect: drawBounds, xRadius: 3, yRadius: 3)
        }

        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()
    }

    private func makeSelectivePath(rect: NSRect, tl: CGFloat, tr: CGFloat, br: CGFloat, bl: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        path.move(to: NSPoint(x: minX + tl, y: minY))
        path.line(to: NSPoint(x: maxX - tr, y: minY))
        if tr > 0 {
            path.appendArc(from: NSPoint(x: maxX, y: minY), to: NSPoint(x: maxX, y: minY + tr), radius: tr)
        } else {
            path.line(to: NSPoint(x: maxX, y: minY))
        }

        path.line(to: NSPoint(x: maxX, y: maxY - br))
        if br > 0 {
            path.appendArc(from: NSPoint(x: maxX, y: maxY), to: NSPoint(x: maxX - br, y: maxY), radius: br)
        } else {
            path.line(to: NSPoint(x: maxX, y: maxY))
        }

        path.line(to: NSPoint(x: minX + bl, y: maxY))
        if bl > 0 {
            path.appendArc(from: NSPoint(x: minX, y: maxY), to: NSPoint(x: minX, y: maxY - bl), radius: bl)
        } else {
            path.line(to: NSPoint(x: minX, y: maxY))
        }

        path.line(to: NSPoint(x: minX, y: minY + tl))
        if tl > 0 {
            path.appendArc(from: NSPoint(x: minX, y: minY), to: NSPoint(x: minX + tl, y: minY), radius: tl)
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

// MARK: - 格式化

enum Format {
    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.isAdaptive = true
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        let v = max(0, value)
        if v < 1024 {
            return "\(v) B"
        }
        return byteFormatter.string(fromByteCount: v)
    }

    private static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let monthDayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let yearMonthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()

    private static let detailedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()

    /// 详情栏完整日期展示（1:1 还原访达信息栏：今天/昨天+时间，或完整年月日+星期+时间）
    static func detailedDate(_ date: Date) -> String {
        return detailedDateFormatter.string(from: date)
    }

    /// 今天的显示时间，往年的显示年份，其余显示「月-日 时:分」。
    /// 复用静态 DateFormatter 实例，避免列表滚动时每个单元格都重新分配 ICU 格式化器。
    static func date(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天 " + timeOnlyFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 " + timeOnlyFormatter.string(from: date)
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return monthDayTimeFormatter.string(from: date)
        }
        return yearMonthDayFormatter.string(from: date)
    }

    /// 持续时间：修改时间与创建时间之间的间隔。
    static func duration(_ end: Date, since start: Date) -> String {
        guard end > start, start > Date.distantPast.addingTimeInterval(1) else { return "--" }
        let seconds = Int(end.timeIntervalSince(start))
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时" }
        let days = hours / 24
        if days < 30 { return "\(days) 天" }
        let months = days / 30
        if months < 12 { return "\(months) 个月" }
        return "\(days / 365) 年"
    }
}
