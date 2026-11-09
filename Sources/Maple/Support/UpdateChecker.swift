import AppKit

public final class UpdateChecker: NSObject {
    public static let shared = UpdateChecker()

    /// 当前应用版本号
    public static var currentVersion: String {
        if let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !ver.isEmpty {
            return ver
        }
        return "1.0.7"
    }

    private let repoOwner = "liceal"
    private let repoName = "maple"

    private var activeProgressController: OnlineUpdateProgressController?

    private override init() {
        super.init()
    }

    /// 检查更新
    /// - Parameter isUserInitiated: 是否为用户主动点击。如果为 true，当是最新版或失败时会弹窗告知用户；若为静默后台检查则不打扰用户。
    public func checkForUpdates(isUserInitiated: Bool = true) {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Maple-App/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                if isUserInitiated {
                    DispatchQueue.main.async {
                        self.showErrorAlert(message: "检查更新失败", detail: "网络连接异常，请检查网络后再试：\(error.localizedDescription)")
                    }
                }
                return
            }

            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200, let data = data else {
                if isUserInitiated {
                    DispatchQueue.main.async {
                        self.showUpToDateAlert()
                    }
                }
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tagName = json["tag_name"] as? String {
                    
                    let remoteVer = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                    let localVer = UpdateChecker.currentVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                    let releaseNotes = (json["body"] as? String) ?? "修复若干已知问题，提升使用体验。"
                    let htmlUrl = (json["html_url"] as? String) ?? "https://github.com/\(self.repoOwner)/\(self.repoName)/releases"

                    // 解析匹配当前架构的安装镜像资产
                    var matchedDmgUrl: URL?
                    #if arch(arm64)
                    let targetArch = "arm64"
                    #else
                    let targetArch = "x86_64"
                    #endif

                    if let assets = json["assets"] as? [[String: Any]] {
                        for asset in assets {
                            if let name = asset["name"] as? String,
                               name.hasSuffix(".dmg"),
                               name.contains(targetArch),
                               let downloadUrlStr = asset["browser_download_url"] as? String,
                               let dUrl = URL(string: downloadUrlStr) {
                                matchedDmgUrl = dUrl
                                break
                            }
                        }
                        if matchedDmgUrl == nil {
                            for asset in assets {
                                if let name = asset["name"] as? String,
                                   name.hasSuffix(".dmg"),
                                   let downloadUrlStr = asset["browser_download_url"] as? String,
                                   let dUrl = URL(string: downloadUrlStr) {
                                    matchedDmgUrl = dUrl
                                    break
                                }
                            }
                        }
                    }

                    DispatchQueue.main.async {
                        if self.isVersion(remoteVer, newerThan: localVer) {
                            self.showNewVersionAlert(newVersion: remoteVer,
                                                     currentVersion: localVer,
                                                     notes: releaseNotes,
                                                     dmgURL: matchedDmgUrl,
                                                     htmlUrl: htmlUrl)
                        } else if isUserInitiated {
                            self.showUpToDateAlert()
                        }
                    }
                } else if isUserInitiated {
                    DispatchQueue.main.async {
                        self.showUpToDateAlert()
                    }
                }
            } catch {
                if isUserInitiated {
                    DispatchQueue.main.async {
                        self.showUpToDateAlert()
                    }
                }
            }
        }.resume()
    }

    /// 比较两个版本号：remote > local 返回 true
    private func isVersion(_ remote: String, newerThan local: String) -> Bool {
        let rParts = remote.split(separator: ".").compactMap { Int($0) }
        let lParts = local.split(separator: ".").compactMap { Int($0) }

        let count = max(rParts.count, lParts.count)
        for i in 0..<count {
            let r = i < rParts.count ? rParts[i] : 0
            let l = i < lParts.count ? lParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    private func showNewVersionAlert(newVersion: String, currentVersion: String, notes: String, dmgURL: URL?, htmlUrl: String) {
        let alert = NSAlert()
        alert.messageText = String(format: "发现新版本 Maple v%@ 🍁".localized, newVersion)
        
        let trimmedNotes = notes.count > 300 ? String(notes.prefix(300)) + "\n..." : notes
        alert.informativeText = "\("当前版本：".localized)v\(currentVersion)\n\("最新版本：".localized)v\(newVersion)\n\n\("更新说明：".localized)\n\(trimmedNotes)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "在线更新".localized)
        alert.addButton(withTitle: "稍后提示".localized)

        if let appIcon = NSApp.applicationIconImage {
            alert.icon = appIcon
        }

        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            if let dmgURL {
                self.startOnlineUpdate(newVersion: newVersion, dmgURL: dmgURL, fallbackURL: htmlUrl)
            } else if let url = URL(string: htmlUrl) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    public func startOnlineUpdate(newVersion: String, dmgURL: URL, fallbackURL: String) {
        let controller = OnlineUpdateProgressController(newVersion: newVersion, dmgURL: dmgURL, fallbackURL: fallbackURL)
        self.activeProgressController = controller
        controller.start()
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "已是最新版本".localized
        alert.informativeText = "Maple v\(UpdateChecker.currentVersion) \("目前已是最新版本，无需更新。".localized)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好".localized)

        if let appIcon = NSApp.applicationIconImage {
            alert.icon = appIcon
        }

        alert.runModal()
    }

    private func showErrorAlert(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

// MARK: - 在线更新下载与自动替换重启进度控制器

private final class OnlineUpdateProgressController: NSObject, URLSessionDownloadDelegate {

    private let newVersion: String
    private let dmgURL: URL
    private let fallbackURL: String

    private var window: NSWindow?
    private var progressIndicator: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var downloadTask: URLSessionDownloadTask?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    init(newVersion: String, dmgURL: URL, fallbackURL: String) {
        self.newVersion = newVersion
        self.dmgURL = dmgURL
        self.fallbackURL = fallbackURL
        super.init()
    }

    func start() {
        buildWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let task = session.downloadTask(with: dmgURL)
        self.downloadTask = task
        task.resume()
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "在线更新 Maple".localized
        win.center()
        win.isReleasedWhenClosed = false

        let root = NSView(frame: win.contentView?.bounds ?? .zero)
        root.wantsLayer = true

        let iconView = NSImageView(frame: NSRect(x: 24, y: 84, width: 48, height: 48))
        iconView.image = NSApp.applicationIconImage ?? NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "正在下载 Maple v\(newVersion)…")
        titleLabel.frame = NSRect(x: 86, y: 104, width: 310, height: 22)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        root.addSubview(titleLabel)

        let status = NSTextField(labelWithString: "准备下载更新包…")
        status.frame = NSRect(x: 86, y: 82, width: 310, height: 18)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        root.addSubview(status)
        self.statusLabel = status

        let progress = NSProgressIndicator(frame: NSRect(x: 86, y: 54, width: 310, height: 16))
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = 0
        root.addSubview(progress)
        self.progressIndicator = progress

        let cancelBtn = NSButton(title: "取消".localized, target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: 320, y: 14, width: 76, height: 28)
        root.addSubview(cancelBtn)

        win.contentView = root
        self.window = win
    }

    @objc private func cancelClicked() {
        downloadTask?.cancel()
        window?.close()
        window = nil
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let percent = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100.0
            progressIndicator?.isIndeterminate = false
            progressIndicator?.doubleValue = percent

            let writtenMB = Double(totalBytesWritten) / (1024 * 1024)
            let totalMB = Double(totalBytesExpectedToWrite) / (1024 * 1024)
            statusLabel?.stringValue = String(format: "已下载 %.1f MB / %.1f MB (%.0f%%)", writtenMB, totalMB, percent)
        } else {
            progressIndicator?.isIndeterminate = true
            progressIndicator?.startAnimation(nil)
            let writtenMB = Double(totalBytesWritten) / (1024 * 1024)
            statusLabel?.stringValue = String(format: "已下载 %.1f MB", writtenMB)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 保存下载的临时文件
        let tempDmg = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Maple_Update_\(UUID().uuidString).dmg")
        do {
            try? FileManager.default.removeItem(at: tempDmg)
            try FileManager.default.moveItem(at: location, to: tempDmg)
        } catch {
            showInstallError("无法保存更新文件：\(error.localizedDescription)")
            return
        }

        DispatchQueue.main.async {
            self.progressIndicator?.isIndeterminate = true
            self.progressIndicator?.startAnimation(nil)
            self.statusLabel?.stringValue = "下载完成，正在安装更新并准备重启…"
        }

        // 异步挂载并准备更新重启
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.installAndRelaunch(dmgPath: tempDmg.path)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as? NSError, error.code != NSURLErrorCancelled else { return }
        DispatchQueue.main.async {
            self.showInstallError("下载更新失败：\(error.localizedDescription)")
        }
    }

    private func installAndRelaunch(dmgPath: String) {
        // 1. 挂载 DMG 获取挂载点
        let mountTask = Process()
        mountTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mountTask.arguments = ["attach", "-nobrowse", "-readonly", "-plist", dmgPath]
        let outPipe = Pipe()
        mountTask.standardOutput = outPipe
        mountTask.standardError = Pipe()

        do {
            try mountTask.run()
            mountTask.waitUntilExit()
        } catch {
            showInstallError("挂载更新镜像失败：\(error.localizedDescription)")
            return
        }

        guard mountTask.terminationStatus == 0 else {
            showInstallError("无法读取更新安装包。")
            return
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        var mountPoint: String?
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let entities = plist["system-entities"] as? [[String: Any]] {
            for entity in entities {
                if let mp = entity["mount-point"] as? String {
                    mountPoint = mp
                    break
                }
            }
        }

        guard let validMountPoint = mountPoint,
              FileManager.default.fileExists(atPath: "\(validMountPoint)/Maple.app") else {
            showInstallError("在更新镜像中未找到 Maple.app。")
            return
        }

        // 2. 确定目标被替换的应用路径
        let currentAppPath: String
        let mainBundlePath = Bundle.main.bundlePath
        if mainBundlePath.hasSuffix(".app") {
            currentAppPath = mainBundlePath
        } else if FileManager.default.fileExists(atPath: "/Applications/Maple.app") {
            currentAppPath = "/Applications/Maple.app"
        } else {
            currentAppPath = mainBundlePath
        }

        let pid = ProcessInfo.processInfo.processIdentifier

        // 3. 编写无缝替换并重启的后台守护脚本
        let scriptPath = "/tmp/maple_updater_\(pid).sh"
        let scriptContent = """
        #!/bin/bash
        PID=\(pid)
        MOUNT_POINT="\(validMountPoint)"
        TARGET_APP="\(currentAppPath)"
        DMG_PATH="\(dmgPath)"

        # 等待旧应用完全退出
        while kill -0 "$PID" 2>/dev/null; do
            sleep 0.15
        done

        # 替换应用主体
        rm -rf "$TARGET_APP"
        cp -a "$MOUNT_POINT/Maple.app" "$TARGET_APP"

        # 卸载挂载点与清理临时文件
        /usr/bin/hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1
        rm -f "$DMG_PATH"
        rm -f "$0"

        # 移除 Gatekeeper 隔离属性确保直接丝滑打开
        xattr -d -r com.apple.quarantine "$TARGET_APP" 2>/dev/null || true

        # 重新拉起新版应用
        open "$TARGET_APP"
        """

        do {
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+x", scriptPath]
            try chmod.run()
            chmod.waitUntilExit()

            // 4. 启动独立后台脚本
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
            launcher.arguments = [scriptPath]
            try launcher.run()

            // 5. 优雅退出当前进程
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        } catch {
            showInstallError("执行更新脚本失败：\(error.localizedDescription)")
        }
    }

    private func showInstallError(_ message: String) {
        DispatchQueue.main.async {
            self.window?.close()
            self.window = nil

            let alert = NSAlert()
            alert.messageText = "在线更新异常".localized
            alert.informativeText = "\(message)\n\n\("您可以前往网页手动下载最新版本。".localized)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "前往网页".localized)
            alert.addButton(withTitle: "取消".localized)

            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: self.fallbackURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
