import AppKit
import UniformTypeIdentifiers

/// 单个文件/目录的不可变快照。一次性取出全部资源属性，避免在排序/绘制时反复访问磁盘。
struct FileItem: Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let isHidden: Bool
    let size: Int64
    let modified: Date
    let created: Date
    let kind: String
    let tags: [String]

    var tagColors: [NSColor] {
        tags.map { Tags.color(named: $0, on: url) }
    }

    /// 目录（且不是包）才可进入。包（.app 等）按 Finder 习惯当作文件打开。
    var isNavigable: Bool { isDirectory && !isPackage }

    static let resourceKeys: [URLResourceKey] = [
        .nameKey,
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .isHiddenKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .localizedTypeDescriptionKey
    ]
    static let resourceKeySet: Set<URLResourceKey> = Set(resourceKeys)

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Self.resourceKeySet) else { return nil }
        self.url = url
        self.name = values.name ?? url.lastPathComponent
        self.isDirectory = values.isDirectory ?? false
        self.isPackage = values.isPackage ?? false
        self.isSymbolicLink = values.isSymbolicLink ?? false
        self.isHidden = values.isHidden ?? false
        if self.isPackage {
            if let cached = BundleSizeCache.shared.size(for: url) {
                self.size = cached
            } else {
                self.size = -1
            }
        } else if self.isDirectory {
            self.size = 0
        } else {
            self.size = Int64(values.fileSize ?? 0)
        }
        self.modified = values.contentModificationDate ?? .distantPast
        self.created = values.creationDate ?? .distantPast
        self.kind = values.localizedTypeDescription ?? ""
        let resolvedTags = Tags.tags(for: url)
        self.tags = resolvedTags
        if !resolvedTags.isEmpty {
            Tags.recordTrackedURL(url, hasTags: true, persist: false)
        }
    }

    /// 零磁盘 I/O 快速构造（供高性能搜索引擎直接从内存索引/stat 快照生成 FileItem）。
    init(fastURL url: URL,
         name: String,
         isDirectory: Bool,
         isPackage: Bool,
         isSymbolicLink: Bool = false,
         size: Int64 = 0,
         modified: Date,
         created: Date? = nil,
         tags: [String] = []) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.isHidden = name.hasPrefix(".")
        self.size = size
        self.modified = modified
        self.created = created ?? modified
        self.kind = IconCache.shared.kindDescription(forName: name, isDirectory: isDirectory, isPackage: isPackage)
        self.tags = tags
    }

    /// 判断是否是废纸篓路径
    static func isTrash(url: URL) -> Bool {
        if url.lastPathComponent == ".Trash" || url.path.hasSuffix("/.Trash") {
            return true
        }
        let homeTrash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        return url.standardizedFileURL.path == homeTrash.standardizedFileURL.path
    }

    /// 判断是否拥有控制 Finder 的自动化权限（不主动弹窗）
    static func hasFinderAutomationPermission() -> Bool {
        var aeDesc = AEDesc()
        let bundleID = "com.apple.finder"
        let status = bundleID.withCString { cStr in
            AECreateDesc(typeApplicationBundleID, cStr, strlen(cStr), &aeDesc)
        }
        defer { AEDisposeDesc(&aeDesc) }
        guard status == noErr else { return false }
        let permStatus = AEDeterminePermissionToAutomateTarget(&aeDesc, typeWildCard, typeWildCard, false)
        return permStatus == noErr
    }

    /// 检查废纸篓读取权限：
    /// 1. 若拥有完全磁盘访问权限（可直接读取 ~/.Trash），返回 true；
    /// 2. 若拥有访达自动化权限（可通过 AppleScript 读取废纸篓），返回 true。
    static func checkTrashPermission() -> Bool {
        let homeTrash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        if (try? FileManager.default.contentsOfDirectory(at: homeTrash, includingPropertiesForKeys: nil, options: [])) != nil {
            return true
        }
        return hasFinderAutomationPermission()
    }

    /// 请求自动化控制 Finder 权限（弹出系统级授权弹窗）
    static func requestFinderAutomationPermission() {
        var aeDesc = AEDesc()
        let bundleID = "com.apple.finder"
        let status = bundleID.withCString { cStr in
            AECreateDesc(typeApplicationBundleID, cStr, strlen(cStr), &aeDesc)
        }
        defer { AEDisposeDesc(&aeDesc) }
        if status == noErr {
            _ = AEDeterminePermissionToAutomateTarget(&aeDesc, typeWildCard, typeWildCard, true)
        }
    }

    /// 通过 Finder AppleScript 实时读取系统废纸篓（兼顾本地 ~/.Trash 与 iCloud Trash，并穿透 macOS TCC 限制）
    static func trashURLsFromFinder(showHidden: Bool = false) -> [URL] {
        if !hasFinderAutomationPermission() {
            requestFinderAutomationPermission()
        }
        let script = "tell application \"Finder\" to get URL of every item of trash"
        guard let appleScript = NSAppleScript(source: script) else { return [] }
        var error: NSDictionary?
        let descriptor = appleScript.executeAndReturnError(&error)
        if let error {
            NSLog("Maple: trashURLsFromFinder error: %@", error)
            return []
        }
        var urls: [URL] = []
        let count = descriptor.numberOfItems
        if count > 0 {
            for i in 1...count {
                if let itemDesc = descriptor.atIndex(i),
                   let urlString = itemDesc.stringValue,
                   let url = URL(string: urlString) {
                    if showHidden || !url.lastPathComponent.hasPrefix(".") {
                        urls.append(url)
                    }
                }
            }
        }
        return urls
    }

    /// 读取目录内容（不递归）。
    static func contents(of directory: URL, showHidden: Bool) -> [FileItem] {
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { options.insert(.skipsHiddenFiles) }

        // 1. 如果是废纸篓
        if isTrash(url: directory) {
            // 优先尝试 FileManager 直接读取
            do {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: resourceKeys,
                    options: options
                )
                // 只要直接读取成功（哪怕废纸篓为空），即可直接返回
                return urls.compactMap(FileItem.init(url:))
            } catch {
                // 直接读取受限（macOS TCC 隐私保护未授权完全磁盘），回退到通过 Finder 读取
                let trashURLs = trashURLsFromFinder(showHidden: showHidden)
                return trashURLs.compactMap(FileItem.init(url:))
            }
        }

        // 2. 常规目录读取
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: options
        ) {
            return urls.compactMap(FileItem.init(url:))
        }

        return []
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}


// MARK: - 附加信息

/// 「所有者」「群组」这类列的取值。
///
/// 这两个属性用 URLResourceValues 取不到（Swift 侧没有对应的键），
/// 只能走 attributesOfItem。这里加了缓存，列表滚动时不会反复读磁盘。
enum FileDetails {

    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 4000
        return cache
    }()

    /// 读取文件的所有者与所属组。
    static func ownerAndGroup(of url: URL) -> (owner: String, group: String) {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            let parts = (cached as String).components(separatedBy: "\t")
            return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
        }
        var owner = ""
        var group = ""
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            owner = attributes[.ownerAccountName] as? String ?? ""
            group = attributes[.groupOwnerAccountName] as? String ?? ""
        }
        cache.setObject("\(owner)\t\(group)" as NSString, forKey: key)
        return (owner, group)
    }
}

// MARK: - 图标缓存

/// 图标按「类型 / 扩展名」缓存（NSCache），同扩展名只取一次 NSWorkspace 图标；
/// 仅 .app 等包和特殊无扩展名文件按路径缓存。避免在表格滚动或网格渲染时反复阻塞主线程读磁盘。
final class IconCache {
    static let shared = IconCache()

    private let cache = NSCache<NSString, NSImage>()
    private let kindCache = NSCache<NSString, NSString>()
    private let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private let fileIcon = NSWorkspace.shared.icon(for: .data)

    init() {
        cache.countLimit = 2000
        kindCache.countLimit = 2000
    }

    /// 内存级快速类型描述（避免搜索结果列表为成百上千个结果逐个发起磁盘 resourceValues 查询）。
    func kindDescription(forName name: String, isDirectory: Bool, isPackage: Bool) -> String {
        if isDirectory && !isPackage {
            return "文件夹"
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if isPackage {
            if ext == "app" { return "应用程序" }
            if ext.isEmpty { return "包" }
        }
        guard !ext.isEmpty else { return "文稿" }
        let key = ext as NSString
        if let cached = kindCache.object(forKey: key) {
            return cached as String
        }
        let desc = UTType(filenameExtension: ext)?.localizedDescription ?? "\(ext.uppercased()) 文件"
        kindCache.setObject(desc as NSString, forKey: key)
        return desc
    }

    /// 过滤掉第三方应用 .icns 中可能损坏的低清 @1x 图层（例如将 16x16 误塞入 128pt @1x 槽位），仅保留高清 @2x Retina 图层
    static func preferRetinaRepresentations(_ icon: NSImage) -> NSImage {
        let hiRes = icon.representations.filter { $0.pixelsWide >= Int($0.size.width * 2) }
        guard !hiRes.isEmpty, hiRes.count < icon.representations.count else { return icon }
        let clean = NSImage(size: icon.size)
        for rep in hiRes {
            clean.addRepresentation(rep)
        }
        return clean
    }

    func icon(for item: FileItem) -> NSImage {
        if item.isPackage {
            let key = item.url.path as NSString
            if let hit = cache.object(forKey: key) { return hit }
            let icon = Self.preferRetinaRepresentations(NSWorkspace.shared.icon(forFile: item.url.path))
            cache.setObject(icon, forKey: key)
            return icon
        }

        if item.isDirectory {
            return folderIcon
        }

        let ext = (item.name as NSString).pathExtension.lowercased()
        let key = (ext.isEmpty ? item.name.lowercased() : ext) as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let rawIcon: NSImage
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            rawIcon = NSWorkspace.shared.icon(for: type)
        } else {
            rawIcon = NSWorkspace.shared.icon(forFile: item.url.path)
        }
        let icon = Self.preferRetinaRepresentations(rawIcon)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

