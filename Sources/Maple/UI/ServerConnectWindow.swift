import AppKit
import Network
import NetFS

/// “连接服务器”窗口控制器（⌘K）：支持输入远程地址（SMB / AFP / NFS / FTP / WebDAV / VNC）、
/// 测试连接连通性与延迟、管理常用服务器收藏列表，并在挂载成功后自动在当前窗格打开对应网络卷。
final class ServerConnectWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    static let shared = ServerConnectWindowController()

    /// 当保存的服务器列表发生变化时通知侧栏刷新。
    var onServersChanged: (() -> Void)?
    /// 当成功定位到已挂载卷或打开网络目录时，回调给主窗口在当前焦点窗格打开。
    var onOpenDirectory: ((URL) -> Void)?

    private var window: NSWindow?
    private let protocolPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let addressField = NSTextField()
    private let nameField = NSTextField()
    private let tableView = NSTableView()
    private let removeButton = NSButton()
    private let testButton = NSButton()
    private let statusSpinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private var spinnerWidthConstraint: NSLayoutConstraint?

    /// 当前正在进行的测试连接任务（用于取消上一次未完成的测试）。
    private var activeTestConnection: NWConnection?
    private var activeTestTimeout: DispatchWorkItem?

    /// 当前正在编辑的服务器条目 ID（从侧栏右键「编辑服务器连接…」或单击列表行进入）。
    private var editingEntryId: String?

    /// 等待挂载完成后自动跳转的目标 URL 与发起时间。
    private var pendingMountURL: URL?
    private var pendingMountTimestamp: TimeInterval = 0

    private let protocols: [(title: String, prefix: String, aliases: [String])] = [
        ("SMB (Windows / NAS 共享)", "smb://", ["smb://", "cifs://"]),
        ("AFP (Apple 文件共享)", "afp://", ["afp://"]),
        ("NFS (Unix 网络文件系统)", "nfs://", ["nfs://"]),
        ("FTP / FTPS", "ftp://", ["ftp://", "ftps://"]),
        ("WebDAV (HTTP/HTTPS)", "http://", ["http://", "https://", "webdav://", "webdavs://"]),
        ("VNC (远程屏幕共享)", "vnc://", ["vnc://"]),
        ("SSH / SFTP (终端连接)", "ssh://", ["ssh://", "sftp://"])
    ]

    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumeDidMount(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
    }

    func show(relativeTo parentWindow: NSWindow?, initialEntry: ServerEntry? = nil) {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }

        cancelActiveTest()
        editingEntryId = initialEntry?.id
        tableView.reloadData()
        if let entry = initialEntry {
            addressField.stringValue = entry.urlString
            nameField.stringValue = entry.name
            syncProtocolFromAddress()
            if let idx = AppSettings.savedServers.firstIndex(where: { $0.id == entry.id }) {
                tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                tableView.scrollRowToVisible(idx)
            } else {
                tableView.deselectAll(nil)
            }
        } else {
            tableView.deselectAll(nil)
            if addressField.stringValue.isEmpty {
                addressField.stringValue = "smb://"
                nameField.stringValue = ""
                protocolPopup.selectItem(at: 0)
            } else {
                syncProtocolFromAddress()
            }
        }
        setStatus("", color: .secondaryLabelColor, spinning: false)
        updateButtons()

        if let parent = parentWindow {
            let pf = parent.frame
            let wf = window.frame
            let origin = NSPoint(x: pf.midX - wf.width / 2, y: pf.midY - wf.height / 2)
            window.setFrameOrigin(origin)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(addressField)
        if let editor = addressField.currentEditor() {
            let len = (addressField.stringValue as NSString).length
            editor.selectedRange = NSRange(location: len, length: 0)
        }
    }

    // MARK: - 构建界面

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "连接服务器".localized
        win.isReleasedWhenClosed = false
        win.delegate = self

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        win.contentView = content

        // 顶部图标与说明
        let headerIcon = NSImageView()
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        headerIcon.image = Theme.serverIcon(size: 36)
        headerIcon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(headerIcon)

        let titleLabel = Theme.label("连接远程服务器", size: 14, weight: .semibold, color: .labelColor)
        let descLabel = Theme.label("输入服务器地址（如 smb://192.168.1.100 或 NAS 名称），可先测试连接或直接挂载浏览。", size: 11.5, color: .secondaryLabelColor)
        content.addSubview(titleLabel)
        content.addSubview(descLabel)

        // 协议与地址行
        let protoLabel = Theme.label("协议类型：", size: 12, weight: .medium, color: .labelColor)
        protocolPopup.translatesAutoresizingMaskIntoConstraints = false
        protocolPopup.controlSize = .regular
        protocolPopup.font = .systemFont(ofSize: 12)
        for item in protocols {
            protocolPopup.addItem(withTitle: item.title)
        }
        protocolPopup.target = self
        protocolPopup.action = #selector(protocolChanged)
        content.addSubview(protoLabel)
        content.addSubview(protocolPopup)

        let addrLabel = Theme.label("服务器地址：".localized, size: 12, weight: .medium, color: .labelColor)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.placeholderString = "smb://192.168.1.100/share"
        addressField.font = .systemFont(ofSize: 12.5)
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(connectClicked)
        content.addSubview(addrLabel)
        content.addSubview(addressField)

        let addFavButton = NSButton(title: "+ 收藏".localized, target: self, action: #selector(addFavoriteServerClicked))
        addFavButton.translatesAutoresizingMaskIntoConstraints = false
        addFavButton.bezelStyle = .rounded
        addFavButton.toolTip = "将当前服务器地址保存到左侧“服务器”分类".localized
        content.addSubview(addFavButton)

        let nameLabel = Theme.label("显示名称：".localized, size: 12, weight: .medium, color: .labelColor)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "可选，例如：家庭 NAS / 团队共享盘".localized
        nameField.font = .systemFont(ofSize: 12.5)
        content.addSubview(nameLabel)
        content.addSubview(nameField)

        // 已保存的服务器列表
        let listHeader = Theme.label("常用服务器（双击可直接连接）：".localized, size: 11.5, weight: .medium, color: .secondaryLabelColor)
        content.addSubview(listHeader)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableRowClicked)
        tableView.doubleAction = #selector(tableRowDoubleClicked)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        content.addSubview(scroll)

        // 状态反馈行（带进度菊花与状态文字）
        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false
        content.addSubview(statusSpinner)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(statusLabel)

        let spinnerWidth = statusSpinner.widthAnchor.constraint(equalToConstant: 0)
        spinnerWidthConstraint = spinnerWidth

        // 底部操作栏
        removeButton.title = "移除所选".localized
        removeButton.bezelStyle = .rounded
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.target = self
        removeButton.action = #selector(removeSelectedClicked)
        content.addSubview(removeButton)

        let browseNetButton = NSButton(title: "浏览网络邻居".localized, target: self, action: #selector(browseNetworkClicked))
        browseNetButton.bezelStyle = .rounded
        browseNetButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(browseNetButton)

        testButton.title = "测试连接".localized.localized
        testButton.bezelStyle = .rounded
        testButton.toolTip = "测试目标服务器主机与协议端口是否可连通".localized
        testButton.translatesAutoresizingMaskIntoConstraints = false
        testButton.target = self
        testButton.action = #selector(testConnectionClicked)
        content.addSubview(testButton)

        let cancelButton = NSButton(title: "取消".localized, target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancelButton)

        let connectButton = NSButton(title: "连接".localized, target: self, action: #selector(connectClicked))
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(connectButton)

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 500),
            content.heightAnchor.constraint(equalToConstant: 420),

            headerIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            headerIcon.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            headerIcon.widthAnchor.constraint(equalToConstant: 36),
            headerIcon.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: headerIcon.topAnchor, constant: 1),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            descLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            descLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            protoLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            protoLabel.topAnchor.constraint(equalTo: headerIcon.bottomAnchor, constant: 18),
            protoLabel.widthAnchor.constraint(equalToConstant: 74),

            protocolPopup.leadingAnchor.constraint(equalTo: protoLabel.trailingAnchor, constant: 6),
            protocolPopup.centerYAnchor.constraint(equalTo: protoLabel.centerYAnchor),
            protocolPopup.widthAnchor.constraint(equalToConstant: 220),

            addrLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            addrLabel.topAnchor.constraint(equalTo: protoLabel.bottomAnchor, constant: 14),
            addrLabel.widthAnchor.constraint(equalToConstant: 74),

            addressField.leadingAnchor.constraint(equalTo: addrLabel.trailingAnchor, constant: 6),
            addressField.centerYAnchor.constraint(equalTo: addrLabel.centerYAnchor),
            addressField.trailingAnchor.constraint(equalTo: addFavButton.leadingAnchor, constant: -8),

            addFavButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            addFavButton.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),
            addFavButton.widthAnchor.constraint(equalToConstant: 66),

            nameLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            nameLabel.topAnchor.constraint(equalTo: addrLabel.bottomAnchor, constant: 12),
            nameLabel.widthAnchor.constraint(equalToConstant: 74),

            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            listHeader.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            listHeader.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 16),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: listHeader.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            statusSpinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusSpinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            spinnerWidth,
            statusSpinner.heightAnchor.constraint(equalToConstant: 14),

            statusLabel.leadingAnchor.constraint(equalTo: statusSpinner.trailingAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: connectButton.topAnchor, constant: -12),
            statusLabel.heightAnchor.constraint(equalToConstant: 18),

            removeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            removeButton.centerYAnchor.constraint(equalTo: connectButton.centerYAnchor),

            browseNetButton.leadingAnchor.constraint(equalTo: removeButton.trailingAnchor, constant: 8),
            browseNetButton.centerYAnchor.constraint(equalTo: connectButton.centerYAnchor),

            testButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            testButton.centerYAnchor.constraint(equalTo: connectButton.centerYAnchor),
            testButton.widthAnchor.constraint(equalToConstant: 80),

            cancelButton.trailingAnchor.constraint(equalTo: connectButton.leadingAnchor, constant: -8),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelButton.widthAnchor.constraint(equalToConstant: 68),

            connectButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            connectButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            connectButton.widthAnchor.constraint(equalToConstant: 78)
        ])

        self.window = win
    }

    // MARK: - 状态与测试连接逻辑

    private func setStatus(_ text: String, color: NSColor, spinning: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
        if spinning {
            spinnerWidthConstraint?.constant = 16
            statusSpinner.startAnimation(nil)
        } else {
            statusSpinner.stopAnimation(nil)
            spinnerWidthConstraint?.constant = 0
        }
    }

    private func cancelActiveTest() {
        activeTestTimeout?.cancel()
        activeTestTimeout = nil
        activeTestConnection?.cancel()
        activeTestConnection = nil
        testButton.title = "测试连接".localized
    }

    /// 根据协议返回默认端口号。
    private static func defaultPort(for scheme: String?) -> UInt16 {
        switch (scheme ?? "smb").lowercased() {
        case "smb", "cifs": return 445
        case "afp":         return 548
        case "nfs":         return 2049
        case "ftp":         return 21
        case "ftps":        return 990
        case "http", "webdav":   return 80
        case "https", "webdavs": return 443
        case "vnc":         return 5900
        case "ssh", "sftp": return 22
        default:            return 445
        }
    }

    @objc private func testConnectionClicked() {
        cancelActiveTest()

        let rawAddr = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawAddr.isEmpty, !rawAddr.hasSuffix("://") else {
            NSSound.beep()
            setStatus("✗ 请输入完整的服务器地址后再测试", color: .systemRed, spinning: false)
            return
        }

        // 本地路径测试
        if rawAddr.hasPrefix("/") {
            if FileManager.default.fileExists(atPath: rawAddr) {
                setStatus("✓ 本地或已挂载路径存在且可访问", color: .systemGreen, spinning: false)
            } else {
                setStatus("✗ 路径不存在：\(rawAddr)", color: .systemRed, spinning: false)
            }
            return
        }

        let entry = ServerEntry(name: "", urlString: rawAddr)
        guard let url = entry.url, let host = url.host, !host.isEmpty else {
            NSSound.beep()
            setStatus("✗ 服务器地址格式无效，请检查后重试", color: .systemRed, spinning: false)
            return
        }

        let port: UInt16 = url.port.flatMap { UInt16(exactly: $0) } ?? Self.defaultPort(for: url.scheme)
        let schemeUpper = (url.scheme ?? "SMB").uppercased()
        setStatus("正在测试连接 \(host):\(port) (\(schemeUpper))…", color: .secondaryLabelColor, spinning: true)
        testButton.title = "测试中…".localized

        runTCPProbe(host: host, port: port, remoteURL: url, fallbackPort: (port == 445 && url.port == nil) ? 139 : nil)
    }

    private func runTCPProbe(host: String, port: UInt16, remoteURL: URL, fallbackPort: UInt16?) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            setStatus("✗ 端口号无效 (\(port))", color: .systemRed, spinning: false)
            testButton.title = "测试连接".localized
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        activeTestConnection = connection

        var finished = false
        let finishLock = NSLock()

        let complete: (Bool, String?) -> Void = { [weak self] success, errMsg in
            finishLock.lock()
            guard !finished else {
                finishLock.unlock()
                return
            }
            finished = true
            finishLock.unlock()

            connection.cancel()
            DispatchQueue.main.async {
                guard let self else { return }
                self.activeTestTimeout?.cancel()
                self.activeTestTimeout = nil
                self.activeTestConnection = nil

                if success {
                    let elapsedMs = max(1, Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))
                    let mounted = Self.findMountedVolume(matching: remoteURL) != nil
                    let mountSuffix = mounted ? "，当前已挂载" : ""
                    self.testButton.title = "测试连接".localized
                    self.setStatus("✓ 连接成功：\(host):\(port) 可正常访问（延迟 \(elapsedMs) ms\(mountSuffix)）",
                                   color: .systemGreen,
                                   spinning: false)
                } else if let fb = fallbackPort {
                    // SMB 445 不通时自动尝试 NetBIOS 139 端口
                    self.runTCPProbe(host: host, port: fb, remoteURL: remoteURL, fallbackPort: nil)
                } else {
                    self.testButton.title = "测试连接".localized
                    let detail = errMsg ?? "连接超时或目标端口未开放"
                    self.setStatus("✗ 连接失败：无法访问 \(host):\(port)（\(detail)）",
                                   color: .systemRed,
                                   spinning: false)
                }
            }
        }

        let timeoutItem = DispatchWorkItem {
            complete(false, "连接超时")
        }
        activeTestTimeout = timeoutItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3.5, execute: timeoutItem)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                complete(true, nil)
            case .failed(let error):
                complete(false, error.localizedDescription)
            case .waiting(let error):
                // 当目标端口直接返回 RST (Connection refused) 时，NWConnection 会进入 waiting 状态
                if case .posix(let code) = error, code == .ECONNREFUSED {
                    complete(false, "端口拒绝连接")
                } else if case .dns = error {
                    complete(false, "无法解析主机名")
                }
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
    }

    // MARK: - 交互逻辑

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === addressField {
            syncProtocolFromAddress()
        }
    }

    @objc private func protocolChanged() {
        let idx = protocolPopup.indexOfSelectedItem
        guard protocols.indices.contains(idx) else { return }
        let selected = protocols[idx]
        var current = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = current.lowercased()
        // 如果当前地址本身已经属于该协议族（例如 https:// 属于 WebDAV，ftps:// 属于 FTP），保留原前缀不强行覆盖
        if selected.aliases.contains(where: { lower.hasPrefix($0) }) {
            return
        }
        if let range = current.range(of: "://") {
            current = String(current[range.upperBound...])
        }
        addressField.stringValue = selected.prefix + current
    }

    private func syncProtocolFromAddress() {
        let lower = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let idx = protocols.firstIndex(where: { item in
            item.aliases.contains(where: { lower.hasPrefix($0) })
        }) {
            protocolPopup.selectItem(at: idx)
        }
    }

    @objc private func addFavoriteServerClicked() {
        let rawAddr = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawAddr.isEmpty, !rawAddr.hasSuffix("://") else {
            NSSound.beep()
            setStatus("✗ 请输入有效的服务器地址", color: .systemRed, spinning: false)
            return
        }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = AppSettings.addOrUpdateServer(id: editingEntryId, name: name, urlString: rawAddr)
        editingEntryId = saved.id
        tableView.reloadData()
        if let idx = AppSettings.savedServers.firstIndex(where: { $0.id == saved.id }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        updateButtons()
        onServersChanged?()
        setStatus("✓ 已保存到左侧“服务器”列表", color: .systemGreen, spinning: false)
    }

    @objc private func removeSelectedClicked() {
        let row = tableView.selectedRow
        let list = AppSettings.savedServers
        guard list.indices.contains(row) else { return }
        let removedId = list[row].id
        if editingEntryId == removedId {
            editingEntryId = nil
        }
        AppSettings.removeServer(id: removedId)
        tableView.reloadData()
        updateButtons()
        onServersChanged?()
        setStatus("已从常用服务器列表中移除", color: .secondaryLabelColor, spinning: false)
    }

    @objc private func browseNetworkClicked() {
        cancelActiveTest()
        window?.orderOut(nil)
        onOpenDirectory?(URL(fileURLWithPath: "/Network"))
    }

    @objc private func cancelClicked() {
        cancelActiveTest()
        window?.orderOut(nil)
    }

    @objc private func tableRowClicked() {
        let row = tableView.selectedRow
        let list = AppSettings.savedServers
        updateButtons()
        guard list.indices.contains(row) else {
            editingEntryId = nil
            return
        }
        let entry = list[row]
        editingEntryId = entry.id
        addressField.stringValue = entry.urlString
        nameField.stringValue = entry.name
        syncProtocolFromAddress()
        setStatus("", color: .secondaryLabelColor, spinning: false)
    }

    @objc private func tableRowDoubleClicked() {
        let row = tableView.clickedRow
        let list = AppSettings.savedServers
        guard list.indices.contains(row) else { return }
        let entry = list[row]
        editingEntryId = entry.id
        addressField.stringValue = entry.urlString
        nameField.stringValue = entry.name
        connect(entry: entry)
    }

    @objc private func connectClicked() {
        cancelActiveTest()
        let rawAddr = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawAddr.isEmpty, !rawAddr.hasSuffix("://") else {
            NSSound.beep()
            setStatus("✗ 请输入完整的服务器地址", color: .systemRed, spinning: false)
            return
        }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = AppSettings.addOrUpdateServer(id: editingEntryId, name: name, urlString: rawAddr)
        editingEntryId = saved.id
        tableView.reloadData()
        onServersChanged?()
        connect(entry: saved)
    }

    /// 连接指定服务器条目（亦可从侧栏直接调用）。
    func connect(entry: ServerEntry) {
        if entry.urlString.hasPrefix("/") {
            let fileURL = URL(fileURLWithPath: entry.urlString)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                window?.orderOut(nil)
                onOpenDirectory?(fileURL)
                return
            }
        }

        guard let remoteURL = entry.url else {
            NSSound.beep()
            setStatus("✗ 地址格式无效", color: .systemRed, spinning: false)
            return
        }

        let scheme = (remoteURL.scheme ?? "smb").lowercased()

        // VNC（远程屏幕共享）与 SSH/SFTP（终端连接）不属于磁盘卷挂载，直接交由系统对应应用打开
        if scheme == "vnc" || scheme == "ssh" || scheme == "sftp" {
            pendingMountURL = nil
            NSWorkspace.shared.open(remoteURL)
            window?.orderOut(nil)
            return
        }

        // 1. 检查是否已有对应的已挂载网络卷，若有则直接在当前焦点窗格打开该挂载目录
        if let mountedURL = Self.findMountedVolume(matching: remoteURL) {
            window?.orderOut(nil)
            onOpenDirectory?(mountedURL)
            return
        }

        // 2. 针对 WebDAV (http/https/webdav/webdavs) 及各类文件共享协议：
        // 若对 http/https 直接调 NSWorkspace.shared.open 会打开浏览器而非挂载磁盘，
        // 因此统一优先使用 macOS NetFS 框架挂载，挂载成功后直接打开挂载目录。
        var mountTargetURL = remoteURL
        if scheme == "webdav", var comp = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false) {
            comp.scheme = "http"
            if let u = comp.url { mountTargetURL = u }
        } else if scheme == "webdavs", var comp = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false) {
            comp.scheme = "https"
            if let u = comp.url { mountTargetURL = u }
        }

        pendingMountURL = mountTargetURL
        pendingMountTimestamp = ProcessInfo.processInfo.systemUptime
        setStatus("正在唤起系统连接…", color: .secondaryLabelColor, spinning: true)
        window?.orderOut(nil)

        let isWebDAV = (scheme == "http" || scheme == "https" || scheme == "webdav" || scheme == "webdavs")
        if isWebDAV {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var mountpoints: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(mountTargetURL as CFURL, nil, nil, nil, nil, nil, &mountpoints)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.setStatus("", color: .secondaryLabelColor, spinning: false)
                    if status == 0,
                       let array = mountpoints?.takeRetainedValue() as? [String],
                       let firstPath = array.first {
                        self.pendingMountURL = nil
                        let mountedURL = URL(fileURLWithPath: firstPath)
                        self.onServersChanged?()
                        self.onOpenDirectory?(mountedURL)
                    } else if let mountedURL = Self.findMountedVolume(matching: mountTargetURL) {
                        self.pendingMountURL = nil
                        self.onServersChanged?()
                        self.onOpenDirectory?(mountedURL)
                    }
                }
            }
        } else {
            NSWorkspace.shared.open(mountTargetURL)
        }
    }

    @objc private func volumeDidMount(_ note: Notification) {
        onServersChanged?()
        guard let mountedURL = note.userInfo?["NSWorkspaceVolumeURLKey"] as? URL else {
            return
        }
        guard let pendingURL = pendingMountURL else { return }
        // 超时 60 秒后不再自动劫持跳转
        if ProcessInfo.processInfo.systemUptime - pendingMountTimestamp > 60 {
            pendingMountURL = nil
            return
        }
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeURLForRemountingKey]
        guard let vals = try? mountedURL.resourceValues(forKeys: keys),
              vals.volumeIsLocal == false else {
            return
        }
        if let remountURL = vals.volumeURLForRemounting,
           let pendingHost = pendingURL.host?.lowercased(),
           remountURL.host?.lowercased() == pendingHost {
            pendingMountURL = nil
            onOpenDirectory?(mountedURL)
        }
    }

    /// 查找当前已挂载的网络卷中是否匹配给定的远程 URL。
    static func findMountedVolume(matching remoteURL: URL) -> URL? {
        guard let targetHost = remoteURL.host?.lowercased(), !targetHost.isEmpty else { return nil }
        let rawTargetPath = (remoteURL.path.removingPercentEncoding ?? remoteURL.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeURLForRemountingKey, .volumeNameKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []

        var hostMatchedFallback: URL?
        for vol in volumes {
            guard let vals = try? vol.resourceValues(forKeys: Set(keys)),
                  vals.volumeIsLocal == false else { continue }
            guard let remount = vals.volumeURLForRemounting,
                  remount.host?.lowercased() == targetHost else { continue }

            let remountPath = (remount.path.removingPercentEncoding ?? remount.path)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()
            let volName = (vals.volumeName ?? vol.lastPathComponent).lowercased()

            if !rawTargetPath.isEmpty {
                // 用户明确指定了共享子路径时，必须共享路径精确匹配（或与首层共享名一致）才视为同一挂载卷，避免同 IP 多共享盘串盘
                let targetFirstComponent = rawTargetPath.split(separator: "/").first.map(String.init) ?? rawTargetPath
                let remountFirstComponent = remountPath.split(separator: "/").first.map(String.init) ?? remountPath
                if remountPath == rawTargetPath || (!remountFirstComponent.isEmpty && remountFirstComponent == targetFirstComponent) {
                    return vol
                }
                if remountPath.isEmpty && volName == targetFirstComponent {
                    return vol
                }
            } else {
                if remountPath.isEmpty {
                    return vol
                }
                if hostMatchedFallback == nil {
                    hostMatchedFallback = vol
                }
            }
        }
        return rawTargetPath.isEmpty ? hostMatchedFallback : nil
    }

    /// 返回当前所有已挂载的远程/网络卷。
    static func mountedNetworkVolumes() -> [(name: String, url: URL, remountURL: URL?)] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeURLForRemountingKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var result: [(String, URL, URL?)] = []
        for url in urls {
            guard url.standardizedFileURL.path != "/",
                  let vals = try? url.resourceValues(forKeys: Set(keys)),
                  vals.volumeIsLocal == false else { continue }
            let name = vals.volumeName ?? url.lastPathComponent
            result.append((name, url, vals.volumeURLForRemounting))
        }
        return result
    }

    private func updateButtons() {
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    // MARK: - NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        AppSettings.savedServers.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let list = AppSettings.savedServers
        guard list.indices.contains(row) else { return nil }
        let entry = list[row]

        let cell = NSTableCellView()
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = Theme.serverIcon(urlString: entry.urlString, size: 18)

        let titleField = NSTextField(labelWithString: entry.hostDisplay)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail

        let addrField = NSTextField(labelWithString: entry.normalizedURLString)
        addrField.translatesAutoresizingMaskIntoConstraints = false
        addrField.font = .systemFont(ofSize: 11)
        addrField.textColor = .secondaryLabelColor
        addrField.lineBreakMode = .byTruncatingMiddle

        let isMounted = entry.url.flatMap { Self.findMountedVolume(matching: $0) } != nil
        let badge = NSTextField(labelWithString: isMounted ? "已连接" : "")
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .systemFont(ofSize: 10.5, weight: .medium)
        badge.textColor = .systemGreen

        cell.addSubview(iconView)
        cell.addSubview(titleField)
        cell.addSubview(addrField)
        cell.addSubview(badge)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 150),

            addrField.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 10),
            addrField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            addrField.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),

            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
