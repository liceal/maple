import Foundation

/// 列表视图可显示的列（名称列恒显，不在这里）。
/// 顺序即表头里从左到右的排列顺序。
enum ListColumn: String, CaseIterable {
    case path, created, modified, size, kind, owner, group, duration

    /// 内置默认列（与访达一致：修改日期 / 大小 / 种类）。
    static let builtInDefaults = ["modified", "size", "kind"]

    var title: String {
        switch self {
        case .path: return "位置"
        case .created: return "创建日期"
        case .modified: return "修改日期"
        case .size: return "大小"
        case .kind: return "种类"
        case .owner: return "所有者"
        case .group: return "群组"
        case .duration: return "持续时间"
        }
    }

    /// 表头与列表单元格的统一列宽（可被用户拖拽覆盖，持久化在 AppSettings.columnWidths）。
    var width: CGFloat {
        if let custom = AppSettings.columnWidths[rawValue] {
            return CGFloat(custom)
        }
        return defaultWidth
    }

    /// 内置默认列宽。
    var defaultWidth: CGFloat {
        switch self {
        case .path: return 180
        case .created, .modified: return 132
        case .size: return 72
        case .kind: return 84
        case .owner, .group: return 110
        case .duration: return 96
        }
    }

    /// 拖拽改宽时该列允许的最小宽度：再窄内容就看不完整了。
    var minWidth: CGFloat {
        switch self {
        case .path: return 100
        case .created, .modified: return 104
        case .size: return 56
        case .kind: return 68
        case .owner, .group: return 84
        case .duration: return 78
        }
    }

    /// 拖拽改宽时该列允许的最大宽度（无上限限制）。
    var maxWidth: CGFloat {
        10000
    }

    /// 该列对应的排序字段（没有对应关系时返回 nil）。
    var sortField: SortField? {
        switch self {
        case .created: return .created
        case .modified: return .modified
        case .size: return .size
        case .kind: return .kind
        default: return nil
        }
    }

    /// 取出这一列在某个文件上的值。
    func value(for item: FileItem) -> String {
        switch self {
        case .path:
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var p = item.url.deletingLastPathComponent().path
            if p.hasPrefix(home) {
                p = "~" + p.dropFirst(home.count)
            }
            return p
        case .created: return Format.date(item.created)
        case .modified: return Format.date(item.modified)
        case .size:
            if item.isNavigable {
                if AppSettings.calculateFolderSizes, let s = BundleSizeCache.shared.size(for: item.url) {
                    return Format.bytes(s)
                }
                return "--"
            }
            if item.isPackage {
                if let s = BundleSizeCache.shared.size(for: item.url) {
                    return Format.bytes(s)
                }
                if item.size > 0 {
                    return Format.bytes(item.size)
                }
                return "--"
            }
            return Format.bytes(item.size)
        case .kind: return item.kind
        case .owner: return FileDetails.ownerAndGroup(of: item.url).owner
        case .group: return FileDetails.ownerAndGroup(of: item.url).group
        case .duration: return Format.duration(item.modified, since: item.created)
        }
    }
}

enum SortField: String, CaseIterable {
    case name, kind, size, modified, created

    var title: String {
        switch self {
        case .name: return "名称"
        case .kind: return "种类"
        case .size: return "大小"
        case .modified: return "修改日期"
        case .created: return "创建日期"
        }
    }
}

enum GroupMode: String, CaseIterable {
    case none, kind, size, modified, created, nameInitial

    var title: String {
        switch self {
        case .none: return "不分组"
        case .kind: return "种类"
        case .size: return "大小"
        case .modified: return "修改日期"
        case .created: return "创建日期"
        case .nameInitial: return "名称首字母"
        }
    }
}

/// 一个分组（分组标题 + 该组内的条目，已按当前排序规则排好）。
struct FileSection {
    let title: String
    let rank: Int
    let items: [FileItem]
}

enum FileOrganizer {

    static func sections(items: [FileItem],
                         sort: SortField,
                         ascending: Bool,
                         group: GroupMode) -> [FileSection] {
        let sorted = items.sorted { lhs, rhs in
            let result = compare(lhs, rhs, by: sort)
            return ascending ? result : !result
        }

        guard group != .none else {
            return [FileSection(title: "", rank: 0, items: sorted)]
        }

        // 目录始终排在各组之前（与 Finder/QSpace 一致）
        var buckets: [String: (rank: Int, items: [FileItem])] = [:]
        for item in sorted {
            let key = bucketKey(for: item, group: group)
            if buckets[key.title] == nil {
                buckets[key.title] = (key.rank, [])
            }
            buckets[key.title]?.items.append(item)
        }

        return buckets
            .map { FileSection(title: $0.key, rank: $0.value.rank, items: $0.value.items) }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    // MARK: - 比较

    private static func compare(_ lhs: FileItem, _ rhs: FileItem, by field: SortField) -> Bool {
        // 目录优先
        if lhs.isNavigable != rhs.isNavigable { return lhs.isNavigable }

        switch field {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .kind:
            if lhs.kind != rhs.kind {
                return lhs.kind.localizedStandardCompare(rhs.kind) == .orderedAscending
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .size:
            if lhs.size != rhs.size { return lhs.size < rhs.size }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .modified:
            if lhs.modified != rhs.modified { return lhs.modified < rhs.modified }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .created:
            if lhs.created != rhs.created { return lhs.created < rhs.created }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - 分组

    private static func bucketKey(for item: FileItem, group: GroupMode) -> (title: String, rank: Int) {
        switch group {
        case .none:
            return ("", 0)

        case .kind:
            if item.isNavigable { return ("文件夹", 0) }
            let title = item.kind.isEmpty ? "其他" : item.kind
            return (title, 10)

        case .size:
            guard !item.isNavigable else { return ("文件夹", 0) }
            return sizeBucket(item.size)

        case .modified:
            return dateBucket(item.modified)

        case .created:
            return dateBucket(item.created)

        case .nameInitial:
            let first = item.name.first.map(String.init) ?? "#"
            guard let scalar = first.unicodeScalars.first else { return ("#", 99) }
            let isLatinLetter = CharacterSet.lowercaseLetters
                .union(.uppercaseLetters)
                .contains(scalar) && scalar.isASCII
            if isLatinLetter {
                return (first.uppercased(), Int(scalar.value))
            }
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
                return ("中文", 9000)
            }
            if CharacterSet.decimalDigits.contains(scalar) {
                return ("0-9", 100)
            }
            return ("#", 99_999)
        }
    }

    private static func sizeBucket(_ bytes: Int64) -> (title: String, rank: Int) {
        let mb: Int64 = 1024 * 1024
        let gb: Int64 = 1024 * mb
        switch bytes {
        case 0: return ("零字节", 1)
        case ..<mb: return ("小于 1 MB", 2)
        case ..<(10 * mb): return ("1 – 10 MB", 3)
        case ..<(100 * mb): return ("10 – 100 MB", 4)
        case ..<gb: return ("100 MB – 1 GB", 5)
        default: return ("大于 1 GB", 6)
        }
    }

    private static func dateBucket(_ date: Date) -> (title: String, rank: Int) {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return ("今天", 1) }
        if calendar.isDateInYesterday(date) { return ("昨天", 2) }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) { return ("本周", 3) }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .month) { return ("本月", 4) }
        let year = calendar.component(.year, from: date)
        let currentYear = calendar.component(.year, from: Date())
        if year == currentYear { return ("今年", 5) }
        return ("\(year) 年", 1000 + year)
    }
}
