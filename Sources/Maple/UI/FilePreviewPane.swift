import AppKit
import Quartz
import CoreServices
import ImageIO
import PDFKit
import AVFoundation

/// 支持整块区域呈现 I-beam 竖线光标的文本标签，支持自然鼠标拖拽框选文字
class SelectableLabel: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSelectable()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSelectable()
    }

    convenience init(selectableText: String = "") {
        self.init(frame: .zero)
        self.stringValue = selectableText
        configureSelectable()
    }

    func configureSelectable() {
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isBordered = false
        isBezeled = false
        focusRingType = .none
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}

/// 仿访达纯文字无边框链接按钮（更多/更少），鼠标悬浮呈现小手手势
final class LinkButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Spotlight、CoreServices、PDFKit 与 AVFoundation 元数据提取引擎（1:1 还原访达信息展示）
struct FileMetadataEngine {

    struct MetadataResult {
        let primaryRows: [(key: String, value: String)]
        let extendedRows: [(key: String, value: String)]
        var hasMore: Bool { !extendedRows.isEmpty }
    }

    static func extractMetadata(for url: URL, resourceValues: URLResourceValues? = nil) -> MetadataResult {
        var primary: [(String, String)] = []
        var extended: [(String, String)] = []

        var values = resourceValues
        if values == nil {
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                .contentModificationDateKey, .creationDateKey, .contentAccessDateKey,
                .localizedTypeDescriptionKey, .isSymbolicLinkKey
            ]
            values = try? url.resourceValues(forKeys: keys)
        }

        let ext = url.pathExtension.lowercased()
        let isPackage = values?.isPackage ?? false
        let isDirectory = values?.isDirectory ?? false

        // 1. 基准三行（与访达 1:1 对齐：创建时间、修改时间、上次打开时间）
        var creationDate = values?.creationDate
        var modificationDate = values?.contentModificationDate
        var accessDate = values?.contentAccessDate

        if creationDate == nil || modificationDate == nil {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                if creationDate == nil { creationDate = attrs[.creationDate] as? Date }
                if modificationDate == nil { modificationDate = attrs[.modificationDate] as? Date }
            }
        }
        if accessDate == nil {
            accessDate = modificationDate
        }

        if let c = creationDate {
            primary.append(("创建时间".localized, Format.detailedDate(c)))
        }
        if let m = modificationDate {
            primary.append(("修改时间".localized, Format.detailedDate(m)))
        }
        if let a = accessDate {
            primary.append(("上次打开时间".localized, Format.detailedDate(a)))
        }

        // 2. 根据文件具体类型提取专属属性（不一刀切，1:1 还原访达规则）
        if isPackage {
            // 应用程序
            extractApplicationMetadata(url: url, primary: &primary, extended: &extended)
        } else if isDirectory {
            // 文件夹：仅基础时间（与图 3 完全对齐，无更多按钮）
        } else if isImageExtension(ext) {
            // 图像文件：主信息为尺寸与分辨率，扩展信息为色彩空间、相机 EXIF 等（与图 2 / 图 4 对齐）
            extractImageMetadata(url: url, primary: &primary, extended: &extended)
        } else if isAudioExtension(ext) {
            // 音频文件：主信息显示时长，扩展信息显示表演者、专辑等
            extractAudioMetadata(url: url, primary: &primary, extended: &extended)
        } else if isVideoExtension(ext) {
            // 视频文件：主信息显示尺寸与时长，扩展信息显示编解码器
            extractVideoMetadata(url: url, primary: &primary, extended: &extended)
        } else if isDocumentExtension(ext) {
            // 文档与 PDF：主信息为基础时间，扩展信息包含标题、作者、页数、安全性等（与图 2 对齐）
            extractDocumentMetadata(url: url, ext: ext, primary: &primary, extended: &extended)
        }

        if values?.isSymbolicLink == true {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "?"
            extended.append(("链接目标".localized, target))
        }

        return MetadataResult(primaryRows: primary, extendedRows: extended)
    }

    private static func isImageExtension(_ ext: String) -> Bool {
        ["png", "jpg", "jpeg", "tiff", "tif", "webp", "gif", "heic", "heif", "svg", "bmp", "ico", "icns", "psd", "raw", "cr2", "nef"].contains(ext)
    }

    private static func isAudioExtension(_ ext: String) -> Bool {
        ["mp3", "m4a", "flac", "wav", "aac", "aiff", "aif", "ogg", "alac", "wma"].contains(ext)
    }

    private static func isVideoExtension(_ ext: String) -> Bool {
        ["mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv"].contains(ext)
    }

    private static func isDocumentExtension(_ ext: String) -> Bool {
        ["pdf", "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "keynote", "epub", "rtf", "txt", "csv", "md"].contains(ext)
    }

    private static func extractApplicationMetadata(url: URL, primary: inout [(String, String)], extended: inout [(String, String)]) {
        if let bundle = Bundle(url: url) {
            if let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String)
                          ?? (bundle.infoDictionary?["CFBundleVersion"] as? String),
               !version.isEmpty {
                primary.append(("版本".localized, version))
            }
            if let copyright = bundle.infoDictionary?["NSHumanReadableCopyright"] as? String, !copyright.isEmpty {
                extended.append(("版权".localized, copyright))
            }
            // 检查应用架构（Apple 芯片 / 通用 / Intel 64 位）
            if let execURL = bundle.executableURL, let handle = try? FileHandle(forReadingFrom: execURL) {
                let header = handle.readData(ofLength: 8)
                try? handle.close()
                if header.count >= 8 {
                    let magic = header.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }
                    if magic == 0xbebafeca || magic == 0xcafebabe {
                        extended.append(("架构".localized, "通用".localized))
                    } else if magic == 0xfeedfacf || magic == 0xcffaedfe {
                        let cpuType = header.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: Int32.self) }
                        if cpuType == 0x0100000C || cpuType == 12 {
                            extended.append(("架构".localized, "Apple 芯片".localized))
                        } else if cpuType == 0x01000007 || cpuType == 7 {
                            extended.append(("架构".localized, "Intel 64 位".localized))
                        }
                    }
                }
            }
        }
    }

    private static func extractImageMetadata(url: URL, primary: inout [(String, String)], extended: inout [(String, String)]) {
        var pixelWidth = 0
        var pixelHeight = 0
        var dpiX = 72
        var dpiY = 72
        var colorSpace: String?
        var profileName: String?
        var make: String?
        var model: String?
        var focalLength: String?
        var fNumber: String?
        var exposureTime: String?
        var iso: String?
        var hasAlpha: Bool?

        // 1. CGImageSource 读取物理像素与分辨率
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            func intVal(_ key: CFString) -> Int? {
                if let n = props[key] as? NSNumber { return n.intValue }
                if let i = props[key] as? Int { return i }
                return nil
            }
            func dblVal(_ key: CFString) -> Double? {
                if let n = props[key] as? NSNumber { return n.doubleValue }
                if let d = props[key] as? Double { return d }
                return nil
            }

            pixelWidth = intVal(kCGImagePropertyPixelWidth) ?? 0
            pixelHeight = intVal(kCGImagePropertyPixelHeight) ?? 0
            if let dx = dblVal(kCGImagePropertyDPIWidth), dx > 0 { dpiX = Int(dx) }
            if let dy = dblVal(kCGImagePropertyDPIHeight), dy > 0 { dpiY = Int(dy) }
            colorSpace = props[kCGImagePropertyColorModel] as? String
            profileName = props[kCGImagePropertyProfileName] as? String
            if let a = props[kCGImagePropertyHasAlpha] as? Bool { hasAlpha = a }

            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                make = tiff[kCGImagePropertyTIFFMake] as? String
                model = tiff[kCGImagePropertyTIFFModel] as? String
            }
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                if let f = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue ?? (exif[kCGImagePropertyExifFNumber] as? Double) {
                    fNumber = String(format: "f/%.1f", f)
                }
                if let fl = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue ?? (exif[kCGImagePropertyExifFocalLength] as? Double) {
                    focalLength = "\(Int(fl)) mm"
                }
                if let et = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue ?? (exif[kCGImagePropertyExifExposureTime] as? Double) {
                    exposureTime = et < 1 ? "1/\(Int(round(1.0 / et))) 秒" : "\(et) 秒"
                }
                if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = isos.first {
                    iso = "\(first.intValue)"
                } else if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isos.first {
                    iso = "\(first)"
                }
            }
        }

        // 2. Spotlight 补强
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            if pixelWidth == 0, let w = MDItemCopyAttribute(item, "kMDItemPixelWidth" as CFString) as? NSNumber {
                pixelWidth = w.intValue
            }
            if pixelHeight == 0, let h = MDItemCopyAttribute(item, "kMDItemPixelHeight" as CFString) as? NSNumber {
                pixelHeight = h.intValue
            }
            if let cs = MDItemCopyAttribute(item, "kMDItemColorSpace" as CFString) as? String {
                colorSpace = cs
            }
            if let pn = MDItemCopyAttribute(item, "kMDItemProfileName" as CFString) as? String {
                profileName = pn
            }
            if model == nil, let m = MDItemCopyAttribute(item, "kMDItemDeviceModel" as CFString) as? String {
                model = m
            }
            if make == nil, let mk = MDItemCopyAttribute(item, "kMDItemMake" as CFString) as? String {
                make = mk
            }
        }

        // 主信息：尺寸与分辨率（完全对齐图 2）
        if pixelWidth > 0 && pixelHeight > 0 {
            primary.append(("尺寸".localized, "\(pixelWidth)×\(pixelHeight)"))
        }
        if dpiX > 0 && dpiY > 0 {
            primary.append(("分辨率".localized, "\(dpiX)×\(dpiY)"))
        }

        // 扩展信息（点击「更多」时展开）
        if let colorSpace, !colorSpace.isEmpty {
            extended.append(("色彩空间".localized, colorSpace))
        }
        if let profileName, !profileName.isEmpty {
            extended.append(("颜色描述文件".localized, profileName))
        }
        if let model, !model.isEmpty {
            extended.append(("设备型号".localized, model))
        }
        if let make, !make.isEmpty {
            extended.append(("相机制造商标".localized, make))
        }
        if let focalLength { extended.append(("焦距".localized, focalLength)) }
        if let fNumber { extended.append(("光圈".localized, fNumber)) }
        if let exposureTime { extended.append(("曝光时间".localized, exposureTime)) }
        if let iso { extended.append(("ISO 速度".localized, iso)) }
        if let hasAlpha { extended.append(("Alpha 通道".localized, hasAlpha ? "是".localized : "否".localized)) }
    }

    private static func extractDocumentMetadata(url: URL, ext: String, primary: inout [(String, String)], extended: inout [(String, String)]) {
        var title: String?
        var authors: String?
        var version: String?
        var pages: String?
        var security: String?
        var creator: String?
        var encoder: String?

        // 1. PDFKit 直接读取（不依赖 Spotlight 索引）
        if ext == "pdf", let doc = PDFDocument(url: url) {
            if doc.pageCount > 0 {
                pages = "\(doc.pageCount)"
            }
            if let attrs = doc.documentAttributes {
                if let t = attrs[PDFDocumentAttribute.titleAttribute] as? String, !t.isEmpty { title = t }
                if let a = attrs[PDFDocumentAttribute.authorAttribute] as? String, !a.isEmpty { authors = a }
                if let c = attrs[PDFDocumentAttribute.creatorAttribute] as? String, !c.isEmpty { creator = c }
                if let p = attrs[PDFDocumentAttribute.producerAttribute] as? String, !p.isEmpty { encoder = p }
            }
        }

        // 2. Spotlight 索引补充
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            func strVal(_ key: String) -> String? {
                guard let val = MDItemCopyAttribute(item, key as CFString) else { return nil }
                if let s = val as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
                if let arr = val as? [String], !arr.isEmpty { return arr.joined(separator: ", ") }
                if let num = val as? NSNumber { return num.stringValue }
                return nil
            }

            if title == nil, let t = strVal("kMDItemTitle") { title = t }
            if authors == nil, let a = strVal("kMDItemAuthors") { authors = a }
            if version == nil, let v = strVal("kMDItemVersion") { version = v }
            if pages == nil, let p = strVal("kMDItemNumberOfPages") { pages = p }
            if security == nil, let s = strVal("kMDItemSecurityMethod") { security = s }
            if creator == nil, let c = strVal("kMDItemCreator") { creator = c }
            if encoder == nil, let e = strVal("kMDItemEncodingApplications") { encoder = e }
        }

        // 按照访达官方截图严格顺序组装扩展属性：
        // 标题、作者、版本、页数、安全性、内容创作者、编码软件
        if let title, !title.isEmpty { extended.append(("标题".localized, title)) }
        if let authors, !authors.isEmpty { extended.append(("作者".localized, authors)) }
        if let version, !version.isEmpty { extended.append(("版本".localized, version)) }
        if let pages, !pages.isEmpty { extended.append(("页数".localized, pages)) }
        if let security, !security.isEmpty { extended.append(("安全性".localized, security)) }
        if let creator, !creator.isEmpty { extended.append(("内容创作者".localized, creator)) }
        if let encoder, !encoder.isEmpty { extended.append(("编码软件".localized, encoder)) }
    }

    private static func extractAudioMetadata(url: URL, primary: inout [(String, String)], extended: inout [(String, String)]) {
        var duration: Double = 0
        var title: String?
        var authors: String?
        var album: String?
        var genre: String?
        var channels: String?
        var sampleRate: String?
        var bitRate: String?

        // 1. Spotlight
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            func strVal(_ key: String) -> String? {
                guard let val = MDItemCopyAttribute(item, key as CFString) else { return nil }
                if let s = val as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
                if let arr = val as? [String], !arr.isEmpty { return arr.joined(separator: ", ") }
                if let num = val as? NSNumber { return num.stringValue }
                return nil
            }

            if let dur = MDItemCopyAttribute(item, "kMDItemDurationSeconds" as CFString) as? NSNumber {
                duration = dur.doubleValue
            }
            title = strVal("kMDItemTitle")
            authors = strVal("kMDItemAuthors")
            album = strVal("kMDItemAlbum")
            genre = strVal("kMDItemGenre")
            channels = strVal("kMDItemAudioChannelCount")
            if let sr = MDItemCopyAttribute(item, "kMDItemAudioSampleRate" as CFString) as? NSNumber {
                sampleRate = "\(sr.intValue) Hz"
            }
            if let br = MDItemCopyAttribute(item, "kMDItemTotalBitRate" as CFString) as? NSNumber {
                bitRate = "\(br.intValue / 1000) kbps"
            }
        }

        // 2. AVURLAsset 兜底
        if duration <= 0 {
            let asset = AVURLAsset(url: url)
            let seconds = CMTimeGetSeconds(asset.duration)
            if seconds.isFinite && seconds > 0 { duration = seconds }
        }

        if duration > 0 {
            let s = Int(duration)
            let formatted = s >= 3600
                ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                : String(format: "%02d:%02d", s / 60, s % 60)
            primary.append(("时长".localized, formatted))
        }

        if let title, !title.isEmpty { extended.append(("标题".localized, title)) }
        if let authors, !authors.isEmpty { extended.append(("表演者".localized, authors)) }
        if let album, !album.isEmpty { extended.append(("专辑".localized, album)) }
        if let genre, !genre.isEmpty { extended.append(("流派".localized, genre)) }
        if let channels, !channels.isEmpty { extended.append(("音频声道".localized, channels)) }
        if let sampleRate, !sampleRate.isEmpty { extended.append(("采样速率".localized, sampleRate)) }
        if let bitRate, !bitRate.isEmpty { extended.append(("比特率".localized, bitRate)) }
    }

    private static func extractVideoMetadata(url: URL, primary: inout [(String, String)], extended: inout [(String, String)]) {
        var duration: Double = 0
        var width: Int = 0
        var height: Int = 0
        var codecs: String?
        var channels: String?
        var colorSpace: String?

        // 1. Spotlight
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            func strVal(_ key: String) -> String? {
                guard let val = MDItemCopyAttribute(item, key as CFString) else { return nil }
                if let s = val as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
                if let arr = val as? [String], !arr.isEmpty { return arr.joined(separator: ", ") }
                if let num = val as? NSNumber { return num.stringValue }
                return nil
            }

            if let w = MDItemCopyAttribute(item, "kMDItemPixelWidth" as CFString) as? NSNumber { width = w.intValue }
            if let h = MDItemCopyAttribute(item, "kMDItemPixelHeight" as CFString) as? NSNumber { height = h.intValue }
            if let dur = MDItemCopyAttribute(item, "kMDItemDurationSeconds" as CFString) as? NSNumber { duration = dur.doubleValue }
            codecs = strVal("kMDItemCodecs")
            channels = strVal("kMDItemAudioChannelCount")
            colorSpace = strVal("kMDItemColorSpace")
        }

        // 2. AVURLAsset 兜底
        if duration <= 0 || width == 0 {
            let asset = AVURLAsset(url: url)
            let seconds = CMTimeGetSeconds(asset.duration)
            if seconds.isFinite && seconds > 0 { duration = seconds }
            if let track = asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                if width == 0 { width = Int(abs(size.width)) }
                if height == 0 { height = Int(abs(size.height)) }
            }
        }

        if width > 0 && height > 0 {
            primary.append(("尺寸".localized, "\(width)×\(height)"))
        }
        if duration > 0 {
            let s = Int(duration)
            let formatted = s >= 3600
                ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                : String(format: "%02d:%02d", s / 60, s % 60)
            primary.append(("时长".localized, formatted))
        }

        if let codecs, !codecs.isEmpty { extended.append(("编解码器".localized, codecs)) }
        if let channels, !channels.isEmpty { extended.append(("音频声道".localized, channels)) }
        if let colorSpace, !colorSpace.isEmpty { extended.append(("颜色空间".localized, colorSpace)) }
    }
}

/// 详情行视图：左侧 label，右侧文字，占满整行；整行水平完全对齐访达设计
final class DetailRowView: NSView {

    let keyLabel = SelectableLabel(selectableText: "")
    let valueLabel = SelectableLabel(selectableText: "")
    private let divider = Theme.hairlineView()

    var showDivider: Bool {
        get { !divider.isHidden }
        set { divider.isHidden = !newValue }
    }

    init(key: String, value: String, showDivider: Bool = true) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        keyLabel.stringValue = key
        keyLabel.font = .systemFont(ofSize: 12, weight: .regular)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.alignment = .left
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        keyLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.stringValue = value
        valueLabel.font = .systemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byWordWrapping
        valueLabel.maximumNumberOfLines = 0
        valueLabel.allowsExpansionToolTips = true
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        [keyLabel, valueLabel].forEach {
            $0.isEditable = false
            $0.isSelectable = true
            $0.drawsBackground = false
            $0.isBordered = false
            $0.isBezeled = false
            $0.focusRingType = .none
        }

        addSubview(keyLabel)
        addSubview(valueLabel)

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.isHidden = !showDivider
        addSubview(divider)

        let heightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: 24)
        heightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            heightConstraint,

            keyLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            valueLabel.leadingAnchor.constraint(equalTo: keyLabel.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            valueLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        // 整行统一呈现竖线光标（I-beam）
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self {
            return valueLabel
        }
        return hit
    }
}

/// 列表模式与图标模式右侧独立文件预览栏（方案一：仿访达与 Maple 经典全功能预览面板）。
/// 支持 Quartz 原生实时渲染（PDF 翻页浏览、图片、音频/视频播放、文本等）、
/// 高清应用/文件夹图标、详细元数据列表（大小、修改/创建时间、尺寸、版本等）及多选概览。
final class FilePreviewPane: NSView {

    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
        override func mouseDown(with event: NSEvent) {
            // 阻断点击冒泡
        }
    }

    private let scroll = OverlayScrollView()
    private let documentView = FlippedDocumentView()

    /// QuickLook 实时预览容器与按需创建的视图（在释放或移出窗口前显式调用 close()，彻底解决 macOS 11 下 -[QLPreviewView dealloc] 断言崩溃）
    private let previewContainer = NSView()
    private var qlPreviewView: QLPreviewView?
    /// 高清图标展示区（供应用、普通文件、多选汇总及无 QuickLook 时使用）
    private let iconView = NSImageView()

    private let textContainer = NSView()
    private let nameLabel = SelectableLabel(selectableText: "")
    private let subtitleLabel = SelectableLabel(selectableText: "")
    private let infoHeaderContainer = NSView()
    private let infoHeaderLabel = NSTextField(labelWithString: "信息".localized)
    private let toggleMoreButton = LinkButton()
    private let infoStack = NSStackView()

    private var qlHeightConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private var currentURL: URL?
    private weak var sizeValueField: NSTextField?
    private var isExpanded: Bool = false
    private var currentPrimaryCount: Int = 0
    private var allRowViews: [DetailRowView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        closePreviewView()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            closePreviewView()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func closePreviewView() {
        if let ql = qlPreviewView {
            ql.previewItem = nil
            ql.close()
            ql.removeFromSuperview()
            qlPreviewView = nil
        }
    }

    private func ensurePreviewView() -> QLPreviewView? {
        if let existing = qlPreviewView {
            return existing
        }
        guard let ql = QLPreviewView(frame: previewContainer.bounds, style: .normal) else {
            return nil
        }
        ql.translatesAutoresizingMaskIntoConstraints = false
        ql.autostarts = true
        ql.shouldCloseWithWindow = false
        previewContainer.addSubview(ql)
        NSLayoutConstraint.activate([
            ql.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            ql.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            ql.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            ql.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor)
        ])
        qlPreviewView = ql
        return ql
    }

    override func mouseDown(with event: NSEvent) {
        // 阻断冒泡
    }

    private func build() {
        wantsLayer = true

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.scrollerStyle = .overlay
        addSubview(scroll)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = documentView

        // 1. QuickLook 实时渲染容器
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(previewContainer)

        // 2. 高清图标展示区
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(iconView)

        // 3. 文字与信息容器
        textContainer.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(textContainer)

        nameLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.maximumNumberOfLines = 3
        nameLabel.alignment = .left
        nameLabel.isSelectable = true
        nameLabel.focusRingType = .none
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
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

        qlHeightConstraint = previewContainer.heightAnchor.constraint(equalToConstant: 220)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 128)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            // 实时预览视口
            previewContainer.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 14),
            previewContainer.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 14),
            previewContainer.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -14),
            qlHeightConstraint,

            // 图标展示区
            iconView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 18),
            iconView.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 128),
            iconHeightConstraint,

            // 文字容器
            textContainer.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 14),
            textContainer.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
            textContainer.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            textContainer.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -20),

            nameLabel.topAnchor.constraint(equalTo: textContainer.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            subtitleLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            infoHeaderContainer.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            infoHeaderContainer.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            infoHeaderContainer.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),

            infoStack.topAnchor.constraint(equalTo: infoHeaderContainer.bottomAnchor, constant: 4),
            infoStack.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            infoStack.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            infoStack.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor)
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        scroll.backgroundColor = .controlBackgroundColor
        needsDisplay = true
    }

    // MARK: - 数据配置

    /// 配置单个选中项目
    func configure(with item: FileItem) {
        currentURL = item.url
        sizeValueField = nil
        isExpanded = false

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .creationDateKey, .contentAccessDateKey,
            .localizedTypeDescriptionKey, .isSymbolicLinkKey
        ]
        let values = try? item.url.resourceValues(forKeys: keys)
        let isDirectory = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false

        // 1. 顶部呈现：非包且非目录的文件，优先使用 QuickLook 实时渲染；目录、.app 或特殊项展示大图标
        if !isDirectory && !isPackage {
            previewContainer.isHidden = false
            iconView.isHidden = true
            ensurePreviewView()?.previewItem = item.url as QLPreviewItem
        } else {
            closePreviewView()
            previewContainer.isHidden = true
            iconView.isHidden = false
            let icon = IconCache.preferRetinaRepresentations(NSWorkspace.shared.icon(forFile: item.url.path))
            icon.size = NSSize(width: 128, height: 128)
            iconView.image = icon
        }

        // 2. 标题与副标题
        nameLabel.stringValue = item.name

        var initialSize: Int64?
        if !isDirectory {
            if let size = values?.fileSize ?? values?.totalFileAllocatedSize {
                initialSize = Int64(size)
            }
        } else if let cached = BundleSizeCache.shared.cache.object(forKey: item.url as NSURL) {
            initialSize = cached.int64Value
        }

        let kindText = values?.localizedTypeDescription ?? (isDirectory ? (isPackage ? "应用程序" : "文件夹") : "文件")
        if let initialSize {
            subtitleLabel.stringValue = "\(kindText) - \(Format.bytes(initialSize))"
        } else {
            subtitleLabel.stringValue = kindText
        }

        // 3. 元数据键值表（1:1 还原访达信息展示引擎）
        let metaResult = FileMetadataEngine.extractMetadata(for: item.url, resourceValues: values)
        buildRows(primary: metaResult.primaryRows, extended: metaResult.extendedRows)

        // 异步计算包（.app）或文件夹真实大小
        if (isPackage || isDirectory) && initialSize == nil {
            let targetURL = item.url
            BundleSizeCache.shared.requestSize(for: targetURL) { [weak self] total in
                guard let self, self.currentURL == targetURL else { return }
                let formatted = Format.bytes(total)
                self.subtitleLabel.stringValue = "\(kindText) - \(formatted)"
            }
        }
    }

    /// 配置多选汇总概览
    func configure(with items: [FileItem]) {
        guard !items.isEmpty else { return }
        if items.count == 1 {
            configure(with: items[0])
            return
        }

        currentURL = nil
        sizeValueField = nil
        closePreviewView()
        previewContainer.isHidden = true
        iconView.isHidden = false

        // 叠放图标
        let stackSize: CGFloat = 128
        let stackedImage = NSImage(size: NSSize(width: stackSize, height: stackSize), flipped: false) { rect in
            let icon1 = NSWorkspace.shared.icon(forFile: items[0].url.path)
            icon1.size = NSSize(width: 104, height: 104)
            icon1.draw(in: NSRect(x: 18, y: 18, width: 104, height: 104))

            let icon2 = NSWorkspace.shared.icon(forFile: items[1].url.path)
            icon2.size = NSSize(width: 104, height: 104)
            icon2.draw(in: NSRect(x: 6, y: 6, width: 104, height: 104))
            return true
        }
        iconView.image = stackedImage

        nameLabel.stringValue = "\(items.count) 个项目"
        subtitleLabel.stringValue = "已选择 \(items.count) 项"

        var totalKnownSize: Int64 = 0
        var hasDirectory = false
        for it in items {
            if it.isDirectory {
                hasDirectory = true
            } else {
                totalKnownSize += it.size
            }
        }

        var rows: [(String, String)] = [
            ("已选项目".localized, "\(items.count) \("项".localized)")
        ]
        if !hasDirectory {
            rows.append(("总大小".localized, Format.bytes(totalKnownSize)))
        } else {
            rows.append(("总大小".localized, "包含文件夹".localized))
        }

        buildRows(primary: rows, extended: [])
    }

    /// 配置未选择项目时的当前文件夹概览
    func configureEmpty(folder url: URL, itemsCount: Int) {
        currentURL = url
        sizeValueField = nil
        closePreviewView()
        previewContainer.isHidden = true
        iconView.isHidden = false

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 128, height: 128)
        iconView.image = icon

        let name = FileManager.default.displayName(atPath: url.path)
        nameLabel.stringValue = name.isEmpty ? url.lastPathComponent : name
        subtitleLabel.stringValue = "\("文件夹".localized) - \(itemsCount) \("项".localized)"

        var rows: [(String, String)] = [
            ("包含内容".localized, "\(itemsCount) \("项".localized)"),
            ("路径".localized, url.path)
        ]
        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]) {
            if let m = values.contentModificationDate {
                rows.append(("修改时间".localized, Format.detailedDate(m)))
            }
            if let c = values.creationDate {
                rows.append(("创建时间".localized, Format.detailedDate(c)))
            }
        }
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
}
