import AppKit

/// 标签定义（名称、显示颜色、系统扩展属性存储的颜色索引与标识符）
struct TagDefinition: Hashable {
    let name: String
    let color: NSColor
    let colorKey: String
    let xattrIndex: Int
}

enum Tags {

    private static var _cachedAll: [TagDefinition]?
    private static var _cachedSpotlightTags: [TagDefinition]?
    private static var activeRenameSearcher: TagSearch?

    /// 标签调色盘：包含 macOS 原生的调色盘颜色与 Spotlight 颜色编号
    static let palette: [(key: String, defaultName: String, color: NSColor, xattrIndex: Int)] = [
        ("none", "无颜色", .clear, 0),
        ("gray", "灰色", .systemGray, 1),
        ("green", "绿色", .systemGreen, 2),
        ("purple", "紫色", .systemPurple, 3),
        ("blue", "蓝色", .systemBlue, 4),
        ("yellow", "黄色", .systemYellow, 5),
        ("red", "红色", .systemRed, 6),
        ("orange", "橙色", .systemOrange, 7)
    ]

    private static let userDefaultsKey = "MapleTagList_v4"
    private static let hiddenTagsKey = "MapleHiddenTags"
    private static let deletedTagsKey = "MapleDeletedSystemTags"
    private static let customTagColorsKey = "MapleCustomTagColors"
    private static let trackedTaggedPathsKey = "MapleTrackedTaggedPaths_v1"
    private static var _trackedPaths: Set<String>?

    /// 获取本地实时追踪的带标签文件/文件夹路径集合（解决 Spotlight 索引延迟导致右键改标签后侧栏数据滞后的问题）
    private static var trackedPaths: Set<String> {
        get {
            if let cached = _trackedPaths { return cached }
            let saved = (UserDefaults.standard.array(forKey: trackedTaggedPathsKey) as? [String]) ?? []
            let set = Set(saved)
            _trackedPaths = set
            return set
        }
        set {
            _trackedPaths = newValue
            UserDefaults.standard.set(Array(newValue), forKey: trackedTaggedPathsKey)
        }
    }

    /// 记录某个文件/文件夹当前的标签状态到本地实时缓存表（不立即刷盘的高频读取场景可传 persist: false）
    static func recordTrackedURL(_ url: URL, hasTags: Bool, persist: Bool = true) {
        let path = url.standardizedFileURL.path
        guard !path.isEmpty else { return }
        var current = trackedPaths
        let changed: Bool
        if hasTags {
            changed = current.insert(path).inserted
        } else {
            changed = (current.remove(path) != nil)
        }
        if changed {
            _trackedPaths = current
            if persist {
                UserDefaults.standard.set(Array(current), forKey: trackedTaggedPathsKey)
            }
        }
    }

    /// 从本地追踪表中筛选出当前磁盘上真实带有指定标签的 URL（直接读取 xattr，0 延迟）
    static func locallyTrackedURLs(tagged tag: String) -> [URL] {
        var current = trackedPaths
        var dirty = false
        var matched: [URL] = []
        let fm = FileManager.default

        for path in current {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
                current.remove(path)
                dirty = true
                continue
            }
            let url = URL(fileURLWithPath: path)
            let fileTags = tags(for: url)
            if fileTags.isEmpty {
                current.remove(path)
                dirty = true
            } else if fileTags.contains(tag) {
                matched.append(url)
            }
        }
        if dirty {
            trackedPaths = current
        }
        return matched
    }

    /// 获取所有标签：实时以系统访达（ProjectsItems.sfl3 / SyncedPreferences / com.apple.finder.plist）为准，
    /// 保持名称、颜色与顺序与访达一致；并叠加用户在 Maple 内手动隐藏或额外新增的标签。
    static var all: [TagDefinition] {
        if let cached = _cachedAll { return cached }

        startFinderWatcherIfNeeded()

        let hiddenSet = Set((UserDefaults.standard.array(forKey: hiddenTagsKey) as? [String]) ?? [])
        let deletedSet = Set((UserDefaults.standard.array(forKey: deletedTagsKey) as? [String]) ?? [])
        let customColors = (UserDefaults.standard.dictionary(forKey: customTagColorsKey) as? [String: String]) ?? [:]

        // 1. 优先实时从系统访达读取真实标签（确保在访达重命名、改色、调整顺序后自动同步）
        let loadedFromSystem = loadFinderTagsFromSystem(includeUnpinned: false)
        if !loadedFromSystem.isEmpty {
            var list: [TagDefinition] = []
            var seen = Set<String>()
            for def in loadedFromSystem {
                if hiddenSet.contains(def.name) || deletedSet.contains(def.name) { continue }
                seen.insert(def.name)
                if let customKey = customColors[def.name], let p = palette.first(where: { $0.key == customKey }) {
                    list.append(TagDefinition(name: def.name, color: p.color, colorKey: p.key, xattrIndex: p.xattrIndex))
                } else {
                    list.append(def)
                }
            }
            _cachedAll = list
            return list
        }

        // 2. 若系统访达无返回，回退使用本地已保存的标签列表（如用户在 Maple 中手动新增的标签）
        if let stored = UserDefaults.standard.array(forKey: userDefaultsKey) as? [[String: Any]], !stored.isEmpty {
            var list: [TagDefinition] = []
            for dict in stored {
                guard let name = dict["name"] as? String, !name.isEmpty,
                      let key = dict["colorKey"] as? String else { continue }
                if hiddenSet.contains(name) || deletedSet.contains(name) { continue }
                let item = palette.first(where: { $0.key == key })
                let color = item?.color ?? .clear
                let xattr = item?.xattrIndex ?? 0
                list.append(TagDefinition(name: name, color: color, colorKey: key, xattrIndex: xattr))
            }
            _cachedAll = list
            return list
        }

        _cachedAll = []
        return []
    }

    /// 直接解析 NSKeyedArchiver 二进制 plist（.sfl3 / .sfl2）中的 $objects 图，不依赖私有类（如 SFLListItem），无弃用警告且兼容 macOS 11~15+
    private static func parseSFLTags(from data: Data, includeUnpinned: Bool) -> [TagDefinition] {
        guard let rootPlist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objects = rootPlist["$objects"] as? [Any],
              let top = rootPlist["$top"] as? [String: Any] else {
            return []
        }

        func uidIndex(_ value: Any?) -> Int? {
            guard let value else { return nil }
            if value is [String: Any] || value is [Any] || value is String || value is NSNumber || value is Data {
                if let dict = value as? [String: Any], let idx = dict["CF$UID"] as? Int {
                    return idx
                }
                return nil
            }
            let desc = String(describing: value)
            if desc.contains("CFKeyedArchiverUID"),
               let range = desc.range(of: "value = "),
               let end = desc[range.upperBound...].firstIndex(of: "}") {
                return Int(desc[range.upperBound..<end])
            }
            return nil
        }

        func resolve(_ value: Any?) -> Any? {
            guard let value else { return nil }
            if let idx = uidIndex(value), idx >= 0, idx < objects.count {
                let obj = objects[idx]
                if let str = obj as? String, str == "$null" { return nil }
                return obj
            }
            if let str = value as? String, str == "$null" { return nil }
            return value
        }

        func decodeDict(_ obj: Any?) -> [String: Any]? {
            guard let raw = resolve(obj) as? [String: Any] else { return nil }
            if let keys = raw["NS.keys"] as? [Any], let vals = raw["NS.objects"] as? [Any] {
                var out: [String: Any] = [:]
                for i in 0..<min(keys.count, vals.count) {
                    if let k = resolve(keys[i]) as? String, let v = resolve(vals[i]) {
                        out[k] = v
                    }
                }
                return out
            }
            var out: [String: Any] = [:]
            for (k, v) in raw where k != "$class" {
                if let resolved = resolve(v) {
                    out[k] = resolved
                }
            }
            return out
        }

        func decodeArray(_ obj: Any?) -> [Any]? {
            guard let raw = resolve(obj) else { return nil }
            if let arr = raw as? [Any] {
                return arr.compactMap { resolve($0) }
            }
            if let dict = raw as? [String: Any], let objs = dict["NS.objects"] as? [Any] {
                return objs.compactMap { resolve($0) }
            }
            return nil
        }

        guard let rootDict = decodeDict(top["root"]),
              let rawItems = decodeArray(rootDict["items"]) else {
            return []
        }

        var result: [TagDefinition] = []
        var seen = Set<String>()

        for rawItem in rawItems {
            guard let item = decodeDict(rawItem) else { continue }
            let props = decodeDict(item["CustomItemProperties"]) ?? item

            guard let name = (item["Name"] as? String)
                    ?? (props["Name"] as? String),
                  !name.isEmpty else { continue }

            if !includeUnpinned {
                if let showing = props["kLSSharedTagFileListItemShowing"] as? Bool, !showing {
                    continue
                }
                if let isHidden = props["com.apple.LSSharedFileList.ItemIsHidden"] as? Bool, isHidden {
                    continue
                }
            }

            let colorIdx = (props["kLSSharedTagFileListItemLabel"] as? Int)
                ?? (props["Label"] as? Int)
                ?? (item["Label"] as? Int)
                ?? 0

            let pItem = palette.first(where: { $0.xattrIndex == colorIdx }) ?? palette[0]
            if seen.insert(name).inserted {
                result.append(TagDefinition(name: name, color: pItem.color, colorKey: pItem.key, xattrIndex: pItem.xattrIndex))
            }
        }
        return result
    }

    /// 从系统访达中读取真实标签（完整保留访达名称、颜色编号与顺序）
    static func loadFinderTagsFromSystem(includeUnpinned: Bool = false) -> [TagDefinition] {
        var result: [TagDefinition] = []
        var seenNames = Set<String>()

        // 策略 A: 读取 ~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ProjectsItems.sfl3 / sfl2
        // （需授予完全磁盘访问权限，包含访达侧栏最精确的顺序、颜色索引与勾选状态）
        let fileManager = FileManager.default
        let sflPaths = [
            "com.apple.LSSharedFileList.ProjectsItems.sfl3",
            "com.apple.LSSharedFileList.ProjectsItems.sfl2"
        ]
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let sflDir = appSupport?.appendingPathComponent("com.apple.sharedfilelist")

        for filename in sflPaths {
            guard let fileURL = sflDir?.appendingPathComponent(filename),
                  fileManager.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL) else { continue }
            let parsed = parseSFLTags(from: data, includeUnpinned: includeUnpinned)
            if !parsed.isEmpty {
                return parsed
            }
        }

        // 策略 B: 读取 ~/Library/SyncedPreferences/com.apple.finder.plist 中的 values.FinderTagDict.value.FinderTags
        let syncedPath = ("~/Library/SyncedPreferences/com.apple.finder.plist" as NSString).expandingTildeInPath
        if fileManager.fileExists(atPath: syncedPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: syncedPath)),
           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            if let values = plist["values"] as? [String: Any],
               let tagDict = values["FinderTagDict"] as? [String: Any],
               let value = tagDict["value"] as? [String: Any],
               let finderTags = value["FinderTags"] as? [[String: Any]] {
                for item in finderTags {
                    guard let name = item["n"] as? String ?? item["name"] as? String, !name.isEmpty else { continue }
                    if !includeUnpinned, let visible = item["v"] as? Bool, !visible { continue }
                    let colorIdx = item["l"] as? Int ?? 0
                    let pItem = palette.first(where: { $0.xattrIndex == colorIdx }) ?? palette[0]
                    if !seenNames.contains(name) {
                        seenNames.insert(name)
                        result.append(TagDefinition(name: name, color: pItem.color, colorKey: pItem.key, xattrIndex: pItem.xattrIndex))
                    }
                }
            }
        }
        if !result.isEmpty { return result }

        // 策略 C: 无完全磁盘访问权限时的降级读取：
        // 仅使用颜色准确的 FavoriteTagNames（槽位 1..7 固定对应红/橙/黄/绿/蓝/紫/灰，改名后颜色依然准确）
        // 以及磁盘文件上实际使用的 Spotlight 标签（自带 xattr 真实颜色），不读取残缺无色的 ViewSettingsDictionary
        let finderPrefPath = ("~/Library/Preferences/com.apple.finder.plist" as NSString).expandingTildeInPath
        let spotlightTags = discoverSpotlightTags()
        if fileManager.fileExists(atPath: finderPrefPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: finderPrefPath)),
           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {

            let slotToXattr = [1: 6, 2: 7, 3: 5, 4: 2, 5: 4, 6: 3, 7: 1]

            if let favs = plist["FavoriteTagNames"] as? [String] {
                for (slotIdx, name) in favs.enumerated() where !name.isEmpty && !seenNames.contains(name) {
                    seenNames.insert(name)
                    if let sp = spotlightTags.first(where: { $0.name == name }), sp.xattrIndex > 0 {
                        result.append(sp)
                    } else if let xattrIdx = slotToXattr[slotIdx],
                              let pItem = palette.first(where: { $0.xattrIndex == xattrIdx }) {
                        result.append(TagDefinition(name: name, color: pItem.color, colorKey: pItem.key, xattrIndex: pItem.xattrIndex))
                    } else {
                        result.append(TagDefinition(name: name, color: .clear, colorKey: "none", xattrIndex: 0))
                    }
                }
            }
        }

        for sp in spotlightTags where !sp.name.isEmpty && !seenNames.contains(sp.name) {
            seenNames.insert(sp.name)
            result.append(sp)
        }

        return result
    }

    /// 获取系统中存在的全部标签（包含边栏显示的标签、访达中未勾选在边栏的标签、以及磁盘 Spotlight 中发现的所有标签）
    static var allSystemTags: [TagDefinition] {
        var result: [TagDefinition] = []
        var seen = Set<String>()

        let customColors = (UserDefaults.standard.dictionary(forKey: customTagColorsKey) as? [String: String]) ?? [:]
        let deletedSet = Set((UserDefaults.standard.array(forKey: deletedTagsKey) as? [String]) ?? [])

        // 1. 当前边栏中的标签
        for def in all {
            seen.insert(def.name)
            result.append(def)
        }

        // 2. 访达中存在但未在边栏显示的标签
        for def in loadFinderTagsFromSystem(includeUnpinned: true) {
            if !seen.contains(def.name) && !deletedSet.contains(def.name) {
                seen.insert(def.name)
                if let customKey = customColors[def.name], let p = palette.first(where: { $0.key == customKey }) {
                    result.append(TagDefinition(name: def.name, color: p.color, colorKey: p.key, xattrIndex: p.xattrIndex))
                } else {
                    result.append(def)
                }
            }
        }

        // 3. 从 Spotlight 动态发现磁盘文件上的所有标签
        for def in discoverSpotlightTags() {
            if !seen.contains(def.name) && !deletedSet.contains(def.name) {
                seen.insert(def.name)
                if let customKey = customColors[def.name], let p = palette.first(where: { $0.key == customKey }) {
                    result.append(TagDefinition(name: def.name, color: p.color, colorKey: p.key, xattrIndex: p.xattrIndex))
                } else {
                    result.append(def)
                }
            }
        }

        return result
    }

    /// 供「所有标签…」分栏视图使用的全部标签列表
    static var allTagsForBrowser: [TagDefinition] {
        let locale = Locale(identifier: "zh_CN")
        return allSystemTags.sorted {
            $0.name.compare($1.name, options: [.numeric, .caseInsensitive], range: nil, locale: locale) == .orderedAscending
        }
    }

    /// 扫描 Spotlight 与本地追踪表中所有带标签的文件，提取标签名称与颜色索引（用于「所有标签…」展示，如 "123"）
    static func discoverSpotlightTags(forceRefresh: Bool = false) -> [TagDefinition] {
        if !forceRefresh, let cached = _cachedSpotlightTags {
            return cached
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-0", "kMDItemUserTags == '*'"]
        let pipe = Pipe()
        process.standardOutput = pipe

        var candidatePaths: [String] = Array(trackedPaths)
        var seenPaths = Set(candidatePaths)

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let output = String(data: data, encoding: .utf8) {
                let paths = output.split(separator: "\0")
                for pathSub in paths where !pathSub.isEmpty {
                    let p = URL(fileURLWithPath: String(pathSub)).standardizedFileURL.path
                    if seenPaths.insert(p).inserted {
                        candidatePaths.append(p)
                    }
                }
            }
        } catch {}

        var tagColorMap: [String: Int] = [:]
        var orderedNames: [String] = []
        let fm = FileManager.default

        for path in candidatePaths where !path.isEmpty && fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            let entries = rawUserTagEntries(for: url)
            if !entries.isEmpty {
                recordTrackedURL(url, hasTags: true, persist: false)
                for entry in entries {
                    if tagColorMap[entry.name] == nil {
                        orderedNames.append(entry.name)
                        tagColorMap[entry.name] = entry.colorIndex
                    } else if (tagColorMap[entry.name] ?? 0) == 0 && entry.colorIndex > 0 {
                        tagColorMap[entry.name] = entry.colorIndex
                    }
                }
            } else {
                let fallbackTags = tags(for: url)
                recordTrackedURL(url, hasTags: !fallbackTags.isEmpty, persist: false)
                for name in fallbackTags {
                    if tagColorMap[name] == nil {
                        orderedNames.append(name)
                        tagColorMap[name] = 0
                    }
                }
            }
        }

        let customColors = (UserDefaults.standard.dictionary(forKey: customTagColorsKey) as? [String: String]) ?? [:]
        var discovered: [TagDefinition] = []
        for name in orderedNames {
            if let customKey = customColors[name], let p = palette.first(where: { $0.key == customKey }) {
                discovered.append(TagDefinition(name: name, color: p.color, colorKey: p.key, xattrIndex: p.xattrIndex))
            } else {
                let idx = tagColorMap[name] ?? 0
                let p = palette.first(where: { $0.xattrIndex == idx }) ?? palette[0]
                discovered.append(TagDefinition(name: name, color: p.color, colorKey: p.key, xattrIndex: p.xattrIndex))
            }
        }
        _cachedSpotlightTags = discovered
        return discovered
    }

    /// 读取单个文件 com.apple.metadata:_kMDItemUserTags 中的原始 (name, colorIndex) 列表
    static func rawUserTagEntries(for url: URL) -> [(name: String, colorIndex: Int)] {
        let attrName = "com.apple.metadata:_kMDItemUserTags"
        let length = url.path.withCString { getxattr($0, attrName, nil, 0, 0, 0) }
        guard length > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: length)
        let readLen = url.path.withCString { getxattr($0, attrName, &buffer, length, 0, 0) }
        guard readLen > 0 else { return [] }

        let data = Data(buffer)
        guard let rawList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String] else {
            return []
        }
        var result: [(String, Int)] = []
        for item in rawList {
            let parts = item.split(separator: "\n", maxSplits: 1)
            let tagName = String(parts.first ?? "")
            guard !tagName.isEmpty else { continue }
            let idx = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            result.append((tagName, idx))
        }
        return result
    }

    /// 监听访达标签配置变动（com.apple.finder.plist 与 ProjectsItems.sfl3）
    private static var finderWatcherSources: [DispatchSourceFileSystemObject] = []
    private static func startFinderWatcherIfNeeded() {
        guard finderWatcherSources.isEmpty else { return }
        let paths = [
            ("~/Library/Preferences/com.apple.finder.plist" as NSString).expandingTildeInPath,
            ("~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ProjectsItems.sfl3" as NSString).expandingTildeInPath
        ]
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
            source.setEventHandler {
                _cachedAll = nil
                _cachedSpotlightTags = nil
                NotificationCenter.default.post(name: .tagsDidChange, object: nil)
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            finderWatcherSources.append(source)
        }
    }

    private static func save(list: [TagDefinition]) {
        let array = list.map { ["name": $0.name, "colorKey": $0.colorKey] }
        UserDefaults.standard.set(array, forKey: userDefaultsKey)
        _cachedAll = list
    }

    /// 拖拽重排边栏标签顺序并持久化
    static func reorderSidebarTags(names: [String]) {
        let current = all
        var map: [String: TagDefinition] = [:]
        for def in current { map[def.name] = def }
        var reordered: [TagDefinition] = []
        var seen = Set<String>()
        for name in names {
            if let def = map[name], seen.insert(name).inserted {
                reordered.append(def)
            }
        }
        for def in current where seen.insert(def.name).inserted {
            reordered.append(def)
        }
        save(list: reordered)
    }

    /// 根据标签名取颜色
    static func color(named name: String, on url: URL? = nil) -> NSColor {
        if let found = all.first(where: { $0.name == name }) {
            return found.color
        }
        if let customColors = UserDefaults.standard.dictionary(forKey: customTagColorsKey) as? [String: String],
           let key = customColors[name],
           let p = palette.first(where: { $0.key == key }) {
            return p.color
        }
        // 如果提供了具体文件 URL，优先读取该文件扩展属性里为该标签记录的颜色索引（例如 "123\n1" 为灰色、"123\n2" 为绿色）
        if let url {
            let entries = rawUserTagEntries(for: url)
            if let match = entries.first(where: { $0.name == name }), match.colorIndex > 0,
               let p = palette.first(where: { $0.xattrIndex == match.colorIndex }) {
                return p.color
            }
        }
        if let found = discoverSpotlightTags().first(where: { $0.name == name }), found.color != .clear {
            return found.color
        }
        return .clear
    }

    /// 根据标签名取系统 xattr 编号 (1..7, 0为无颜色)
    static func colorIndex(for name: String) -> Int {
        if let found = all.first(where: { $0.name == name }) {
            return found.xattrIndex
        }
        if let customColors = UserDefaults.standard.dictionary(forKey: customTagColorsKey) as? [String: String],
           let key = customColors[name],
           let p = palette.first(where: { $0.key == key }) {
            return p.xattrIndex
        }
        if let found = discoverSpotlightTags().first(where: { $0.name == name }) {
            return found.xattrIndex
        }
        return 0
    }

    /// 新增标签
    @discardableResult
    static func addTag(name: String? = nil, colorKey: String? = nil) -> TagDefinition {
        var current = all

        // 选择未使用的颜色
        let usedKeys = Set(current.map { $0.colorKey })
        let chosenItem: (key: String, defaultName: String, color: NSColor, xattrIndex: Int)
        if let key = colorKey, let match = palette.first(where: { $0.key == key }) {
            chosenItem = match
        } else if let unused = palette.dropFirst().first(where: { !usedKeys.contains($0.key) }) {
            chosenItem = unused
        } else {
            chosenItem = palette[4] // 默认蓝色
        }

        // 确定标签名
        let tagName: String
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            tagName = name.trimmingCharacters(in: .whitespaces)
        } else {
            let base = chosenItem.defaultName
            if !current.contains(where: { $0.name == base }) {
                tagName = base
            } else {
                var idx = 2
                while current.contains(where: { $0.name == "新标签 \(idx)" || $0.name == "\(base) \(idx)" }) {
                    idx += 1
                }
                tagName = "\(base) \(idx)"
            }
        }

        let newDef = TagDefinition(name: tagName, color: chosenItem.color, colorKey: chosenItem.key, xattrIndex: chosenItem.xattrIndex)
        var deletedSet = Set((UserDefaults.standard.array(forKey: deletedTagsKey) as? [String]) ?? [])
        if deletedSet.remove(tagName) != nil {
            UserDefaults.standard.set(Array(deletedSet), forKey: deletedTagsKey)
        }
        current.append(newDef)
        save(list: current)
        NotificationCenter.default.post(name: .tagsDidChange, object: nil)
        return newDef
    }

    /// 修改指定标签的颜色（支持边栏标签及「所有标签…」中的标签）
    static func updateTagColor(named name: String, colorKey: String) {
        let (color, xattrIdx): (NSColor, Int) = {
            if colorKey == "none" {
                return (.clear, 0)
            }
            if let p = palette.first(where: { $0.key == colorKey }) {
                return (p.color, p.xattrIndex)
            }
            return (.systemGray, 1)
        }()

        var customColors = (UserDefaults.standard.dictionary(forKey: customTagColorsKey) as? [String: String]) ?? [:]
        customColors[name] = colorKey
        UserDefaults.standard.set(customColors, forKey: customTagColorsKey)

        var current = all
        if let idx = current.firstIndex(where: { $0.name == name }) {
            current[idx] = TagDefinition(name: name, color: color, colorKey: colorKey, xattrIndex: xattrIdx)
            save(list: current)
        }
        _cachedSpotlightTags = nil

        // 异步更新所有被打上该标签的文件的扩展属性颜色
        DispatchQueue.global(qos: .utility).async {
            let urls = findURLs(tagged: name)
            for url in urls {
                let fileTags = tags(for: url)
                setTags(fileTags, on: url)
            }
            DispatchQueue.main.async {
                _cachedSpotlightTags = nil
                NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
                NotificationCenter.default.post(name: .tagsDidChange, object: nil)
            }
        }

        NotificationCenter.default.post(name: .tagsDidChange, object: nil)
    }

    /// 判断标签是否当前显示在边栏中
    static func isTagInSidebar(named name: String) -> Bool {
        return all.contains(where: { $0.name == name })
    }

    /// 将标签添加到边栏显示
    static func showTagInSidebar(named name: String) {
        var hiddenSet = Set((UserDefaults.standard.array(forKey: hiddenTagsKey) as? [String]) ?? [])
        hiddenSet.remove(name)
        UserDefaults.standard.set(Array(hiddenSet), forKey: hiddenTagsKey)

        var current = all
        if !current.contains(where: { $0.name == name }) {
            if let sysDef = allSystemTags.first(where: { $0.name == name }) {
                current.append(sysDef)
            } else {
                let c = color(named: name)
                let idx = colorIndex(for: name)
                let key = palette.first(where: { $0.xattrIndex == idx })?.key ?? "none"
                current.append(TagDefinition(name: name, color: c, colorKey: key, xattrIndex: idx))
            }
            save(list: current)
        }
        NotificationCenter.default.post(name: .tagsDidChange, object: nil)
    }

    /// 从边栏中移除/隐藏标签（仅不显示在侧栏，不删除已标记文件的标签）
    static func hideTagFromSidebar(named name: String) {
        var hiddenSet = Set((UserDefaults.standard.array(forKey: hiddenTagsKey) as? [String]) ?? [])
        hiddenSet.insert(name)
        UserDefaults.standard.set(Array(hiddenSet), forKey: hiddenTagsKey)

        var current = all
        current.removeAll { $0.name == name }
        save(list: current)
        NotificationCenter.default.post(name: .tagsDidChange, object: nil)
    }

    /// 移除标签并从所有被标记的文件/文件夹中剥离该标签（同时支持边栏标签与「所有标签…」中的额外标签）
    @discardableResult
    static func removeTag(named name: String, extraURLs: [URL] = []) -> (definition: TagDefinition, index: Int, affectedURLs: [URL])? {
        var current = all
        let def: TagDefinition
        let idx: Int
        if let foundIdx = current.firstIndex(where: { $0.name == name }) {
            def = current[foundIdx]
            idx = foundIdx
            current.remove(at: foundIdx)
            save(list: current)
        } else if let sysDef = allSystemTags.first(where: { $0.name == name }) {
            def = sysDef
            idx = -1
        } else {
            def = TagDefinition(name: name, color: color(named: name), colorKey: "none", xattrIndex: colorIndex(for: name))
            idx = -1
        }

        // 同时将该标签记入隐藏与已删除列表，避免默认标签在下次刷新时自动回到边栏或「所有标签…」
        var hiddenSet = Set((UserDefaults.standard.array(forKey: hiddenTagsKey) as? [String]) ?? [])
        hiddenSet.insert(name)
        UserDefaults.standard.set(Array(hiddenSet), forKey: hiddenTagsKey)

        var deletedSet = Set((UserDefaults.standard.array(forKey: deletedTagsKey) as? [String]) ?? [])
        deletedSet.insert(name)
        UserDefaults.standard.set(Array(deletedSet), forKey: deletedTagsKey)

        // 收集受影响的文件和文件夹
        var urlSet = Set(extraURLs)
        let found = findURLs(tagged: name)
        for url in found {
            urlSet.insert(url)
        }
        let affected = Array(urlSet)

        // 从每个文件和文件夹中剥离该标签
        for url in affected {
            removeTag(from: url, tag: name)
        }

        _cachedSpotlightTags = nil
        NotificationCenter.default.post(name: .tagsDidChange, object: nil)
        return (def, idx, affected)
    }

    /// 恢复已删除标签到指定位置
    static func restoreTag(_ def: TagDefinition, at index: Int) {
        var hiddenSet = Set((UserDefaults.standard.array(forKey: hiddenTagsKey) as? [String]) ?? [])
        hiddenSet.remove(def.name)
        UserDefaults.standard.set(Array(hiddenSet), forKey: hiddenTagsKey)

        var deletedSet = Set((UserDefaults.standard.array(forKey: deletedTagsKey) as? [String]) ?? [])
        deletedSet.remove(def.name)
        UserDefaults.standard.set(Array(deletedSet), forKey: deletedTagsKey)

        if index >= 0 {
            var current = all
            current.removeAll { $0.name == def.name }
            let insertIndex = min(max(0, index), current.count)
            current.insert(def, at: insertIndex)
            save(list: current)
        }
        _cachedSpotlightTags = nil
        NotificationCenter.default.post(name: .tagsDidChange, object: nil)
    }

    /// 通过 Spotlight / mdfind + 本地追踪表查找所有打上特定标签的文件/文件夹 URL（并用 xattr 实时二次校验，剔除过期索引）
    static func findURLs(tagged tag: String) -> [URL] {
        var mergedMap: [String: URL] = [:]
        for url in locallyTrackedURLs(tagged: tag) {
            mergedMap[url.standardizedFileURL.path] = url
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        let escaped = tag.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        process.arguments = ["-0", "kMDItemUserTags == \"\(escaped)\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        let fm = FileManager.default
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let output = String(data: data, encoding: .utf8) {
                let paths = output.split(separator: "\0")
                for path in paths where !path.isEmpty {
                    let strPath = String(path)
                    guard fm.fileExists(atPath: strPath) else { continue }
                    let url = URL(fileURLWithPath: strPath)
                    let currentTags = tags(for: url)
                    recordTrackedURL(url, hasTags: !currentTags.isEmpty, persist: false)
                    // 二次校验：只有磁盘 xattr 当前真实包含该标签时才纳入（解决刚取消标签但 Spotlight 尚未刷新的滞后问题）
                    if currentTags.contains(tag) {
                        mergedMap[url.standardizedFileURL.path] = url
                    }
                }
            }
        } catch {}
        return Array(mergedMap.values)
    }

    /// 重命名标签：同步更新设置与所有被标记文件的系统 kMDItemUserTags 扩展属性
    static func renameTag(oldName: String, newName: String) {
        guard oldName != newName, !newName.isEmpty else { return }
        var current = all
        if let idx = current.firstIndex(where: { $0.name == oldName }) {
            let old = current[idx]
            current[idx] = TagDefinition(name: newName, color: old.color, colorKey: old.colorKey, xattrIndex: old.xattrIndex)
            save(list: current)
        }

        var customColors = (UserDefaults.standard.dictionary(forKey: customTagColorsKey) as? [String: String]) ?? [:]
        if let oldColor = customColors.removeValue(forKey: oldName) {
            customColors[newName] = oldColor
            UserDefaults.standard.set(customColors, forKey: customTagColorsKey)
        }

        let urls = findURLs(tagged: oldName)
        for url in urls {
            replaceTag(on: url, oldTag: oldName, newTag: newName)
        }
        _cachedSpotlightTags = nil

        let searcher = TagSearch()
        activeRenameSearcher = searcher
        searcher.search(tag: oldName) { extraURLs in
            DispatchQueue.global(qos: .utility).async {
                for url in extraURLs {
                    replaceTag(on: url, oldTag: oldName, newTag: newName)
                }
                DispatchQueue.main.async {
                    _cachedSpotlightTags = nil
                    NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
                }
            }
        }

        NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
        NotificationCenter.default.post(name: .tagsDidChange, object: nil)
    }

    /// 获取指定文件的所有标签名（直接读取内核 VFS 扩展属性 com.apple.metadata:_kMDItemUserTags，零缓存滞后且无多余 I/O）
    static func tags(for url: URL) -> [String] {
        let name = "com.apple.metadata:_kMDItemUserTags"
        let length = url.path.withCString { getxattr($0, name, nil, 0, 0, 0) }
        guard length > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: length)
        let readLen = url.path.withCString { getxattr($0, name, &buffer, length, 0, 0) }
        guard readLen > 0 else { return [] }

        let data = Data(buffer)
        if let rawList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String] {
            return rawList.map { item in
                let parts = item.split(separator: "\n", maxSplits: 1)
                return String(parts.first ?? "")
            }.filter { !$0.isEmpty }
        }
        return []
    }

    /// 给文件加上某个标签
    static func addTag(tag: String, to url: URL) {
        var fileTags = tags(for: url)
        if !fileTags.contains(tag) {
            fileTags.append(tag)
            setTags(fileTags, on: url)
        }
    }

    /// 切换某个标签的打标状态
    static func toggleTag(on url: URL, tag: String) {
        var fileTags = tags(for: url)
        if let idx = fileTags.firstIndex(of: tag) {
            fileTags.remove(at: idx)
        } else {
            fileTags.append(tag)
        }
        setTags(fileTags, on: url)
    }

    /// 将标签写入文件（同时更新 NSURLTagNamesKey、com.apple.metadata:_kMDItemUserTags 与本地实时追踪表）
    static func setTags(_ fileTags: [String], on url: URL) {
        let nsURL = url as NSURL
        if fileTags.isEmpty {
            try? nsURL.setResourceValue(nil, forKey: .tagNamesKey)
        } else {
            try? nsURL.setResourceValue(fileTags, forKey: .tagNamesKey)
        }

        url.path.withCString { path in
            if fileTags.isEmpty {
                _ = removexattr(path, "com.apple.metadata:_kMDItemUserTags", 0)
            } else {
                let taggedWithColors = fileTags.map { name -> String in
                    let idx = colorIndex(for: name)
                    return "\(name)\n\(idx)"
                }
                if let data = try? PropertyListSerialization.data(fromPropertyList: taggedWithColors, format: .binary, options: 0) {
                    _ = data.withUnsafeBytes { raw in
                        setxattr(path, "com.apple.metadata:_kMDItemUserTags", raw.baseAddress, raw.count, 0, 0)
                    }
                }
            }
        }
        nsURL.removeCachedResourceValue(forKey: .tagNamesKey)
        recordTrackedURL(url, hasTags: !fileTags.isEmpty, persist: true)
        _cachedSpotlightTags = nil
    }

    /// 从文件移除某个标签
    static func removeTag(from url: URL, tag: String) {
        var fileTags = tags(for: url)
        guard let idx = fileTags.firstIndex(of: tag) else { return }
        fileTags.remove(at: idx)
        setTags(fileTags, on: url)
    }

    /// 替换文件的标签名
    static func replaceTag(on url: URL, oldTag: String, newTag: String) {
        var fileTags = tags(for: url)
        guard let idx = fileTags.firstIndex(of: oldTag) else { return }
        fileTags[idx] = newTag
        setTags(fileTags, on: url)
    }

    /// 侧栏小圆点
    static func dotImage(color: NSColor, diameter: CGFloat = 10) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let ovalRect = rect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(ovalIn: ovalRect)
            if color == .clear {
                path.lineWidth = 1.2
                NSColor.secondaryLabelColor.setStroke()
                path.stroke()
            } else {
                color.setFill()
                path.fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 访达侧栏底部「所有标签…」的双重叠圆圈图标 (○○)
    static func allTagsIcon(size: CGFloat = 14) -> NSImage {
        let imgSize = NSSize(width: size, height: size)
        let image = NSImage(size: imgSize, flipped: false) { rect in
            let d: CGFloat = 8.4
            let y: CGFloat = (rect.height - d) / 2
            let leftRect = NSRect(x: 0.6, y: y, width: d, height: d)
            let rightRect = NSRect(x: 5.0, y: y, width: d, height: d)

            NSColor.secondaryLabelColor.setStroke()

            // 右侧完整圆环
            let rightPath = NSBezierPath(ovalIn: rightRect)
            rightPath.lineWidth = 1.2
            rightPath.stroke()

            // 左侧圆环（裁剪掉与右侧圆环内部重叠的区域，呈现访达原生双环叠放效果）
            NSGraphicsContext.saveGraphicsState()
            let clipPath = NSBezierPath(rect: rect)
            clipPath.appendOval(in: rightRect.insetBy(dx: -0.6, dy: -0.6))
            clipPath.windingRule = .evenOdd
            clipPath.addClip()

            let leftPath = NSBezierPath(ovalIn: leftRect)
            leftPath.lineWidth = 1.2
            leftPath.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 右键菜单：已选中实心圆 + 居中对勾
    static func checkedDotImage(color: NSColor, diameter: CGFloat = 18) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let ovalRect = rect.insetBy(dx: 0.8, dy: 0.8)
            let path = NSBezierPath(ovalIn: ovalRect)
            if color == .clear {
                path.lineWidth = 1.4
                NSColor.secondaryLabelColor.setStroke()
                path.stroke()
            } else {
                color.setFill()
                path.fill()
            }

            // 居中白色（或对比色）对勾
            let check = NSBezierPath()
            let w = rect.width
            let h = rect.height
            check.move(to: NSPoint(x: w * 0.28, y: h * 0.48))
            check.line(to: NSPoint(x: w * 0.44, y: h * 0.30))
            check.line(to: NSPoint(x: w * 0.74, y: h * 0.68))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            if color == .clear {
                NSColor.controlAccentColor.setStroke()
            } else {
                NSColor.white.setStroke()
            }
            check.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 右键菜单：未选中空心圆环
    static func ringDotImage(color: NSColor, diameter: CGFloat = 18) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let ovalRect = rect.insetBy(dx: 1.2, dy: 1.2)
            let path = NSBezierPath(ovalIn: ovalRect)
            path.lineWidth = 1.5

            if color == .clear {
                NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
                path.stroke()
            } else {
                color.withAlphaComponent(0.10).setFill()
                path.fill()
                color.withAlphaComponent(0.85).setStroke()
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 调色盘图标（实心圆点或无颜色空心圆）
    static func paletteIcon(color: NSColor?, diameter: CGFloat = 14) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let img = NSImage(size: size, flipped: false) { rect in
            let circleRect = rect.insetBy(dx: 1.0, dy: 1.0)
            let path = NSBezierPath(ovalIn: circleRect)
            if let color, color != .clear {
                color.setFill()
                path.fill()
                let border = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.25, dy: 0.25))
                border.lineWidth = 0.5
                NSColor(white: 0.0, alpha: 0.2).setStroke()
                border.stroke()
            } else {
                path.lineWidth = 1.2
                NSColor.secondaryLabelColor.setStroke()
                path.stroke()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// 用 Spotlight + 本地实时追踪表列出某个标签下的所有文件（访达侧栏点标签的行为，0 延迟同步增删）。
final class TagSearch {

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    deinit { cancel() }

    func cancel() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        query?.stop()
        query = nil
    }

    /// 合并本地实时追踪表与 Spotlight 结果，并对每个候选 URL 做直接 xattr 二次校验
    private static func mergeAndVerify(tag: String, spotlightURLs: [URL]) -> [URL] {
        var mergedMap: [String: URL] = [:]
        // 1. 先放入本地实时追踪表中当前确实带有该标签的文件/文件夹（解决刚加标签但 Spotlight 尚未索引的问题）
        for url in Tags.locallyTrackedURLs(tagged: tag) {
            mergedMap[url.standardizedFileURL.path] = url
        }

        // 2. 遍历 Spotlight 返回的候选结果，用直接 xattr 读取二次校验（解决刚移除标签但 Spotlight 仍返回旧数据的问题）
        let fm = FileManager.default
        for url in spotlightURLs {
            let stdPath = url.standardizedFileURL.path
            guard fm.fileExists(atPath: stdPath) else { continue }
            let currentTags = Tags.tags(for: url)
            Tags.recordTrackedURL(url, hasTags: !currentTags.isEmpty, persist: false)
            if currentTags.contains(tag) {
                mergedMap[stdPath] = url
            } else {
                mergedMap.removeValue(forKey: stdPath)
            }
        }

        return mergedMap.values.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// 结果分两步回传：
    /// 1) 毫秒级立即回传本地实时追踪表中的最新匹配项（右键改标签后 0 延迟立即可见）；
    /// 2) Spotlight 异步流式回传全盘索引结果，并经 xattr 二次校验合并。
    func search(tag: String, completion: @escaping ([URL]) -> Void) {
        cancel()

        // 第一阶段：本地追踪表 0ms 即时回传（如果已有已知带该标签的文件，先立即呈现）
        let immediate = Self.mergeAndVerify(tag: tag, spotlightURLs: [])
        if !immediate.isEmpty {
            completion(immediate)
        }

        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemUserTags == %@", tag)
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]
        self.query = query

        let collect: () -> Void = { [weak self, weak query] in
            guard let self, let query, query === self.query else { return }
            query.disableUpdates()
            var urls: [URL] = []
            urls.reserveCapacity(query.resultCount)
            for index in 0..<query.resultCount {
                guard let item = query.result(at: index) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                urls.append(URL(fileURLWithPath: path))
            }
            query.enableUpdates()
            let verified = Self.mergeAndVerify(tag: tag, spotlightURLs: urls)
            completion(verified)
        }

        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { _ in
                collect()
            }
            observers.append(observer)
        }

        query.start()
    }
}

extension Notification.Name {
    static let tagsDidChange = Notification.Name("TagsDidChangeNotification")
}
