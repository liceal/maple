import AppKit

// MARK: - 磁盘文件变动全局通知

extension Notification.Name {
    /// 当有文件在磁盘上被移动、复制或删除后触发，以便各窗格与视图及时刷新
    static let filesDidChangeOnDisk = Notification.Name("MapleFilesDidChangeOnDiskNotification")
    /// 当用户切换是否显示隐藏文件设置时触发
    static let showHiddenFilesDidChange = Notification.Name("MapleShowHiddenFilesDidChangeNotification")
}

// MARK: - 拖拽项生成辅助工具

enum FileDragHelper {

    /// 为给定的文件 URL 列表生成原生拖拽项。
    /// - Parameters:
    ///   - urls: 选中的文件 URL
    ///   - pointInView: 鼠标在当前视图内的坐标
    /// - Returns: 可供 beginDraggingSession 使用的 NSDraggingItem 数组
    static func createDraggingItems(for urls: [URL], at pointInView: NSPoint) -> [NSDraggingItem] {
        guard !urls.isEmpty else { return [] }
        var items: [NSDraggingItem] = []
        let count = urls.count

        for (index, url) in urls.enumerated() {
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)

            if index == 0 {
                // 主视觉：在鼠标指针下方显示带轻微阴影的文件图标；若为多选则附带数字角标
                let iconSize: CGFloat = 36
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: iconSize, height: iconSize)

                let imageSize: NSSize
                let dragImage: NSImage

                if count > 1 {
                    let badgeText = "\(count)" as NSString
                    let font = NSFont.systemFont(ofSize: 11, weight: .bold)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: NSColor.white
                    ]
                    let textSize = badgeText.size(withAttributes: attrs)
                    let badgeW = max(textSize.width + 12, 20)
                    let badgeH: CGFloat = 18

                    imageSize = NSSize(width: iconSize + badgeW - 6, height: iconSize + 6)
                    dragImage = NSImage(size: imageSize)
                    dragImage.lockFocus()

                    icon.draw(in: NSRect(x: 0, y: 0, width: iconSize, height: iconSize))

                    let badgeRect = NSRect(x: iconSize - 8, y: iconSize - 14, width: badgeW, height: badgeH)
                    let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: badgeH / 2, yRadius: badgeH / 2)
                    NSColor.systemRed.setFill()
                    badgePath.fill()

                    let textPoint = NSPoint(
                        x: badgeRect.minX + (badgeW - textSize.width) / 2,
                        y: badgeRect.minY + (badgeH - textSize.height) / 2
                    )
                    badgeText.draw(at: textPoint, withAttributes: attrs)
                    dragImage.unlockFocus()
                } else {
                    imageSize = NSSize(width: iconSize, height: iconSize)
                    dragImage = icon
                }

                let frame = NSRect(
                    x: pointInView.x - iconSize / 2,
                    y: pointInView.y - iconSize / 2,
                    width: imageSize.width,
                    height: imageSize.height
                )
                item.setDraggingFrame(frame, contents: dragImage)
            } else {
                // 其余副选项目分配微小尺寸占位，确保剪贴板持有完整文件集合
                item.setDraggingFrame(NSRect(x: pointInView.x, y: pointInView.y, width: 1, height: 1), contents: NSImage())
            }

            items.append(item)
        }
        return items
    }
}

// MARK: - 跨窗格 / 跨视图文件传输核心

enum FileOperations {

    /// 从拖拽粘贴板中读取有效的本地文件 URL 列表
    static func readURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls
        }
        if let paths = info.draggingPasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return []
    }

    /// 判断拖拽放置时应当复制还是移动：
    /// 1. 若用户在拖拽时按住了 Option 键，强制执行复制；
    /// 2. 若拖拽源来自外部程序，或者源路径与目标路径跨越不同磁盘卷，执行复制；
    /// 3. 本程序内部在同一卷内拖拽，默认执行移动。
    static func shouldCopy(for info: NSDraggingInfo, destination: URL) -> Bool {
        if NSEvent.modifierFlags.contains(.option) {
            return true
        }
        guard info.draggingSource != nil else {
            // 来自外部应用（如其他程序或访达窗口），安全起见默认复制
            return true
        }
        return false
    }

    /// 在目标目录中生成不重名的文件 URL（若已存在则追加 " 2", " 3" 等）
    static func uniqueURL(for fileName: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let ns = fileName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var idx = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(idx)" : "\(base) \(idx).\(ext)"
            candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            idx += 1
        }
    }

    /// 执行文件移动或复制操作
    /// - Parameters:
    ///   - urls: 待移动或复制的文件 URL 列表
    ///   - destinationDirectory: 目标文件夹
    ///   - isCopy: true 为复制，false 为移动
    /// - Returns: 成功落入目标目录的文件 URL 列表
    @discardableResult
    static func transfer(urls: [URL], to destinationDirectory: URL, isCopy: Bool) -> [URL] {
        var createdURLs: [URL] = []
        let fm = FileManager.default
        let destPath = destinationDirectory.standardizedFileURL.path

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destPath, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        for source in urls {
            let srcPath = source.standardizedFileURL.path

            // 禁止将文件夹移动/复制到自身或其子目录中
            if srcPath == destPath || destPath.hasPrefix(srcPath + "/") {
                continue
            }
            // 若为移动且已经在当前目录下，跳过
            if !isCopy && source.deletingLastPathComponent().standardizedFileURL.path == destPath {
                continue
            }

            let targetName = source.lastPathComponent
            let targetURL = uniqueURL(for: targetName, in: destinationDirectory)

            do {
                if isCopy {
                    try fm.copyItem(at: source, to: targetURL)
                } else {
                    try fm.moveItem(at: source, to: targetURL)
                }
                createdURLs.append(targetURL)
            } catch {
                NSLog("[Maple FileOperations] Transfer failed from \(srcPath) to \(targetURL.path): \(error)")
            }
        }
        return createdURLs
    }

    /// 统一校验并执行文件重命名
    /// - Parameters:
    ///   - item: 待重命名的文件模型
    ///   - newName: 用户输入的新名称
    ///   - window: 宿主窗口（展示弹窗警报）
    ///   - onSuccess: 重命名成功后的回调（提供 oldURL 与 newURL）
    /// - Returns: 是否重命名成功
    @discardableResult
    static func performRename(item: FileItem, newName: String, window: NSWindow? = nil, onSuccess: (URL, URL) -> Void) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == item.name {
            return false
        }

        // 0. 长度校验（macOS APFS/HFS+ 文件系统文件名限制 255 字节，对齐访达同款提示）
        if trimmed.utf8.count > 255 {
            let alert = NSAlert()
            alert.messageText = String(format: "不能使用名称“%@”，因为它太长。".localized, trimmed)
            alert.informativeText = "请尝试使用字符较少，或不含标点符号的名称。".localized
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好".localized)
            alert.runModal()
            return false
        }

        // 1. 非法字符校验（斜杠与冒号，对齐访达 RN31/RN32）
        if trimmed.contains("/") || trimmed.contains(":") {
            let alert = NSAlert()
            alert.messageText = String(format: "不能使用名称“%@”。".localized, trimmed)
            alert.informativeText = "请尝试使用字符较少，或不含标点符号的名称。".localized
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好".localized)
            alert.runModal()
            return false
        }

        // 2. 保留名称校验（单独的点或点点，对齐访达 RN5）
        if trimmed == "." || trimmed == ".." {
            let alert = NSAlert()
            alert.messageText = String(format: "不能使用名称“%@”，因为它已被系统保留。".localized, trimmed)
            alert.informativeText = "请选取其他名称。".localized
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好".localized)
            alert.runModal()
            return false
        }

        // 3. 点前缀隐藏文件确认与系统保留提示（对齐访达 RN4 / RN3 / RN3.1）
        let oldName = item.name
        if trimmed.hasPrefix(".") && !oldName.hasPrefix(".") {
            if !AppSettings.showHidden {
                let alert = NSAlert()
                alert.messageText = "你不能使用以点“.”开头的名称，因为这些名称已被系统预留。请选取其他名称。".localized
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好".localized)
                alert.runModal()
                return false
            } else {
                let alert = NSAlert()
                alert.messageText = "你确定要使用以点“.”开头的名称吗？".localized
                alert.informativeText = "系统会将使用此类名称的项目视为不可见的文件。".localized
                alert.alertStyle = .warning
                alert.addButton(withTitle: "使用“.”".localized)
                alert.addButton(withTitle: "取消".localized)
                if alert.runModal() != .alertFirstButtonReturn {
                    return false
                }
            }
        }

        // 4. 重名校验（对齐访达 RN17）
        let oldURL = item.url
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(trimmed)
        if newURL.path == oldURL.path { return false }

        if FileManager.default.fileExists(atPath: newURL.path) {
            let alert = NSAlert()
            alert.messageText = String(format: "名称“%@”已被占用，请选取其他名称。".localized, trimmed)
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好".localized)
            alert.runModal()
            return false
        }

        // 5. 扩展名变更二次确认（对齐访达 RN12 / RN14）
        let oldExt = (oldName as NSString).pathExtension
        let newExt = (trimmed as NSString).pathExtension
        let isDirectory = item.isNavigable
        if !isDirectory && !oldExt.isEmpty && oldExt.caseInsensitiveCompare(newExt) != .orderedSame {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.informativeText = "如果进行这项更改，你的文稿可能会由另一个应用程序打开。".localized
            if newExt.isEmpty {
                alert.messageText = String(format: "你确定要移除扩展名“.%@”吗？".localized, oldExt)
                alert.addButton(withTitle: String(format: "保持 .%@", oldExt).localized)
                alert.addButton(withTitle: "移除".localized)
            } else {
                alert.messageText = String(format: "你确定要将扩展名“.%@”更改为“.%@”吗？".localized, oldExt, newExt)
                alert.addButton(withTitle: String(format: "保持 .%@", oldExt).localized)
                alert.addButton(withTitle: String(format: "使用 .%@", newExt).localized)
            }
            if alert.runModal() == .alertFirstButtonReturn {
                return false
            }
        }

        // 5. 执行文件移动（重命名）
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
            onSuccess(oldURL, newURL)
            return true
        } catch {
            let nsErr = error as NSError
            if (nsErr.domain == NSPOSIXErrorDomain && nsErr.code == Int(ENAMETOOLONG)) ||
               (nsErr.domain == NSCocoaErrorDomain && nsErr.code == CocoaError.fileWriteInvalidFileName.rawValue && trimmed.utf8.count > 255) {
                let alert = NSAlert()
                alert.messageText = String(format: "不能使用名称“%@”，因为它太长。".localized, trimmed)
                alert.informativeText = "请尝试使用字符较少，或不含标点符号的名称。".localized
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好".localized)
                alert.runModal()
            } else {
                NSAlert(error: error).runModal()
            }
            return false
        }
    }

    // MARK: - 复制副本（Duplicate）

    /// 复制所选文件/文件夹生成“副本”（支持多选与递增编号）
    @discardableResult
    static func duplicate(urls: [URL]) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        for url in urls {
            let dir = url.deletingLastPathComponent()
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let ext = url.pathExtension
            let base = ext.isEmpty || isDir ? name : (name as NSString).deletingPathExtension

            var candidateName = ext.isEmpty || isDir ? "\(base) 副本" : "\(base) 副本.\(ext)"
            var dest = dir.appendingPathComponent(candidateName)
            var counter = 2
            while fm.fileExists(atPath: dest.path) {
                candidateName = ext.isEmpty || isDir ? "\(base) 副本 \(counter)" : "\(base) 副本 \(counter).\(ext)"
                dest = dir.appendingPathComponent(candidateName)
                counter += 1
            }

            do {
                try fm.copyItem(at: url, to: dest)
                results.append(dest)
            } catch {
                NSLog("[Maple Duplicate] Failed to duplicate \(url.path): \(error)")
            }
        }
        if !results.isEmpty {
            playFileAddedSound()
            NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
        }
        return results
    }

    // MARK: - 压缩与解压缩（Compress & Decompress）

    /// 判断指定文件是否是压缩包
    static func isArchive(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "7z", "rar"].contains(ext)
    }

    /// 压缩选中的文件/文件夹为 zip 压缩包
    static func compress(urls: [URL], completion: @escaping ([URL]) -> Void) {
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var created: [URL] = []
            let fm = FileManager.default
            let dir = urls[0].deletingLastPathComponent()

            if urls.count == 1 {
                let src = urls[0]
                let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let base = isDir ? src.lastPathComponent : src.deletingPathExtension().lastPathComponent
                let zipName = "\(base).zip"
                let dest = uniqueURL(for: zipName, in: dir)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, dest.path]
                try? p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 && fm.fileExists(atPath: dest.path) {
                    created.append(dest)
                }
            } else {
                let dest = uniqueURL(for: "归档.zip", in: dir)
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
                try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: tempDir) }
                for u in urls {
                    let link = tempDir.appendingPathComponent(u.lastPathComponent)
                    try? fm.copyItem(at: u, to: link)
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", "--sequesterRsrc", tempDir.path, dest.path]
                try? p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 && fm.fileExists(atPath: dest.path) {
                    created.append(dest)
                }
            }

            DispatchQueue.main.async {
                if !created.isEmpty {
                    playFileAddedSound()
                    NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
                }
                completion(created)
            }
        }
    }

    /// 解压缩指定的归档文件到当前目录
    static func decompress(urls: [URL], completion: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for src in urls {
                let dir = src.deletingLastPathComponent()
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", src.path, dir.path]
                try? p.run()
                p.waitUntilExit()
            }
            DispatchQueue.main.async {
                playFileAddedSound()
                NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
                completion()
            }
        }
    }

    // MARK: - 直接永久删除（Delete Immediately）

    /// 直接永久删除文件/文件夹（不经过废纸篓，带确认弹窗）
    static func deleteImmediately(urls: [URL], window: NSWindow?, completion: @escaping (Bool) -> Void) {
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        let count = urls.count
        if count == 1 {
            let name = urls[0].lastPathComponent
            alert.messageText = String(format: "确定要永久删除“%@”吗？".localized, name)
            alert.informativeText = "此项目将被立即抹掉。您无法撤销此操作。".localized
        } else {
            alert.messageText = String(format: "确定要永久删除这 %d 个项目吗？".localized, count)
            alert.informativeText = "这些项目将被立即抹掉。您无法撤销此操作。".localized
        }
        alert.alertStyle = .critical
        let delBtn = alert.addButton(withTitle: "删除".localized)
        if #available(macOS 11.0, *) {
            delBtn.hasDestructiveAction = true
        }
        alert.addButton(withTitle: "取消".localized)

        let performAction = {
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var anySuccess = false
                for url in urls {
                    // 1. 尝试常规 FileManager 删除
                    do {
                        try fm.removeItem(at: url)
                    } catch {
                        // 继续尝试针对受保护目录的方案
                    }
                    if !fm.fileExists(atPath: url.path) {
                        anySuccess = true
                        continue
                    }

                    // 2. 针对废纸篓等受系统 TCC/Finder 保护的文件，通过 Finder AppleScript 彻底删除
                    let escapedPath = url.path.replacingOccurrences(of: "\\", with: "\\\\")
                                              .replacingOccurrences(of: "\"", with: "\\\"")
                    let script = """
                    tell application "Finder"
                        try
                            delete (POSIX file "\(escapedPath)" as alias)
                        end try
                    end tell
                    """
                    if let appleScript = NSAppleScript(source: script) {
                        var err: NSDictionary?
                        appleScript.executeAndReturnError(&err)
                    }
                    if !fm.fileExists(atPath: url.path) {
                        anySuccess = true
                        continue
                    }

                    // 3. 尝试解除文件锁定 (nouchg) 并强制 rm -rf 删除
                    let procUnlock = Process()
                    procUnlock.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
                    procUnlock.arguments = ["-R", "nouchg", url.path]
                    try? procUnlock.run()
                    procUnlock.waitUntilExit()

                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/bin/rm")
                    proc.arguments = ["-rf", url.path]
                    try? proc.run()
                    proc.waitUntilExit()

                    if !fm.fileExists(atPath: url.path) {
                        anySuccess = true
                    }
                }

                DispatchQueue.main.async {
                    if anySuccess {
                        playTrashSound()
                        NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
                    }
                    completion(anySuccess)
                }
            }
        }

        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    performAction()
                } else {
                    completion(false)
                }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                performAction()
            } else {
                completion(false)
            }
        }
    }

    // MARK: - 清倒废纸篓

    /// 清倒废纸篓（带二次确认弹窗与清倒音效）
    static func emptyTrash(window: NSWindow? = nil, completion: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = "确定要清倒废纸篓吗？".localized
        alert.informativeText = "此操作将永久抹掉废纸篓中的所有项目，且无法撤销。".localized
        alert.alertStyle = .critical
        alert.addButton(withTitle: "清倒废纸篓".localized)
        alert.addButton(withTitle: "取消".localized)

        let performEmpty = {
            let script = "tell application \"Finder\" to empty trash"
            if let appleScript = NSAppleScript(source: script) {
                var err: NSDictionary?
                appleScript.executeAndReturnError(&err)
            }
            playEmptyTrashSound()
            NotificationCenter.default.post(name: .filesDidChangeOnDisk, object: nil)
            completion?()
        }

        if let window = window {
            alert.beginSheetModal(for: window) { resp in
                if resp == .alertFirstButtonReturn {
                    performEmpty()
                }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                performEmpty()
            }
        }
    }

    // MARK: - 原生交互音效系统

    /// 播放新建文件 / 文件夹音效
    static func playFileAddedSound() {
        playSound(named: "FileAdded", fallbackPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/copy.aif")
    }

    /// 播放删除文件 / 移到废纸篓音效
    static func playTrashSound() {
        playSound(named: "FileRemoved", fallbackPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif")
    }

    /// 播放清倒废纸篓音效
    static func playEmptyTrashSound() {
        playSound(named: "EmptyTrash", fallbackPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/empty trash.aif")
    }

    private static func playSound(named name: String, fallbackPath: String? = nil) {
        // 1. 优先尝试从应用 Bundle 读取内置音效
        if let url = Bundle.main.url(forResource: name, withExtension: "aif") {
            if let sound = NSSound(contentsOf: url, byReference: true) {
                sound.play()
                return
            }
        }
        // 2. 尝试从 Resources 目录直读（开发/调试阶段）
        let localCandidate = URL(fileURLWithPath: "Resources/\(name).aif")
        if FileManager.default.fileExists(atPath: localCandidate.path) {
            if let sound = NSSound(contentsOf: localCandidate, byReference: true) {
                sound.play()
                return
            }
        }
        // 3. 兜底回退到系统同名音效
        if let fallbackPath, FileManager.default.fileExists(atPath: fallbackPath) {
            NSSound(contentsOfFile: fallbackPath, byReference: true)?.play()
        }
    }
}
