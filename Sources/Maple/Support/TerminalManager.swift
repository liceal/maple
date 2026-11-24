import AppKit

/// 支持识别与适配的终端应用类型
public enum TerminalAppType: String, CaseIterable {
    case terminal  = "terminal"
    case warp      = "warp"
    case iterm2    = "iterm2"
    case ghostty   = "ghostty"
    case alacritty = "alacritty"
    case kitty     = "kitty"
    case wezterm   = "wezterm"
    case hyper     = "hyper"
    case custom    = "custom"

    public var defaultDisplayName: String {
        switch self {
        case .terminal:  return "终端 (系统内置)".localized
        case .warp:      return "Warp"
        case .iterm2:    return "iTerm2"
        case .ghostty:   return "Ghostty"
        case .alacritty: return "Alacritty"
        case .kitty:     return "Kitty"
        case .wezterm:   return "WezTerm"
        case .hyper:     return "Hyper"
        case .custom:    return "自定义终端…".localized
        }
    }

    public var candidateBundleIdentifiers: [String] {
        switch self {
        case .terminal:  return ["com.apple.Terminal"]
        case .warp:      return ["dev.warp.Warp-Stable", "dev.warp.Warp", "dev.warp.Warp-Dev"]
        case .iterm2:    return ["com.googlecode.iterm2"]
        case .ghostty:   return ["com.mitchellh.ghostty"]
        case .alacritty: return ["org.alacritty", "io.alacritty"]
        case .kitty:     return ["net.kovidgoyal.kitty"]
        case .wezterm:   return ["com.github.wez.wezterm"]
        case .hyper:     return ["co.zeit.hyper"]
        case .custom:    return []
        }
    }

    public var candidateAppNames: [String] {
        switch self {
        case .terminal:  return ["Terminal.app"]
        case .warp:      return ["Warp.app"]
        case .iterm2:    return ["iTerm.app", "iTerm2.app"]
        case .ghostty:   return ["Ghostty.app"]
        case .alacritty: return ["Alacritty.app"]
        case .kitty:     return ["kitty.app", "Kitty.app"]
        case .wezterm:   return ["WezTerm.app"]
        case .hyper:     return ["Hyper.app"]
        case .custom:    return []
        }
    }
}

/// 已安装的终端应用信息封装
public struct InstalledTerminal: Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let bundleIdentifier: String?
    public let appURL: URL
    public let type: TerminalAppType

    public var icon: NSImage {
        let img = NSWorkspace.shared.icon(forFile: appURL.path)
        img.size = NSSize(width: 16, height: 16)
        return img
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(appURL.standardizedFileURL.path.lowercased())
    }

    public static func == (lhs: InstalledTerminal, rhs: InstalledTerminal) -> Bool {
        return lhs.appURL.standardizedFileURL.path.lowercased() == rhs.appURL.standardizedFileURL.path.lowercased()
    }
}

/// 全局终端应用管理器
public final class TerminalManager {
    public static let shared = TerminalManager()

    private init() {}

    /// 扫描系统当前已安装的所有终端应用
    public func scanInstalledTerminals() -> [InstalledTerminal] {
        var results: [InstalledTerminal] = []
        var seenURLs = Set<String>()

        let searchDirs = [
            "/Applications",
            "/System/Applications/Utilities",
            "/System/Applications",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        ]

        for type in TerminalAppType.allCases where type != .custom {
            var foundURL: URL?
            var foundBundleId: String?

            // 1. 通过 Bundle ID 查找
            for bid in type.candidateBundleIdentifiers {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                    foundURL = url
                    foundBundleId = bid
                    break
                }
            }

            // 2. 若未找到，遍历常见安装目录查找
            if foundURL == nil {
                for dir in searchDirs {
                    for name in type.candidateAppNames {
                        let fullPath = (dir as NSString).appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: fullPath) {
                            let url = URL(fileURLWithPath: fullPath)
                            foundURL = url
                            if let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier {
                                foundBundleId = bid
                            } else {
                                foundBundleId = type.candidateBundleIdentifiers.first
                            }
                            break
                        }
                    }
                    if foundURL != nil { break }
                }
            }

            if let url = foundURL {
                let canonicalPath = url.standardizedFileURL.path.lowercased()
                if !seenURLs.contains(canonicalPath) {
                    seenURLs.insert(canonicalPath)

                    let bundle = Bundle(url: url)
                    let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? type.defaultDisplayName

                    results.append(InstalledTerminal(
                        id: foundBundleId ?? canonicalPath,
                        displayName: name,
                        bundleIdentifier: foundBundleId,
                        appURL: url,
                        type: type
                    ))
                }
            }
        }

        // 3. 检查用户配置的自定义终端应用
        if let customPath = AppSettings.customTerminalAppPath,
           FileManager.default.fileExists(atPath: customPath) {
            let customURL = URL(fileURLWithPath: customPath)
            let canonical = customURL.standardizedFileURL.path.lowercased()
            if !seenURLs.contains(canonical) {
                seenURLs.insert(canonical)
                let bundle = Bundle(url: customURL)
                let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? customURL.deletingPathExtension().lastPathComponent
                results.append(InstalledTerminal(
                    id: canonical,
                    displayName: name,
                    bundleIdentifier: bundle?.bundleIdentifier,
                    appURL: customURL,
                    type: .custom
                ))
            }
        }

        return results
    }

    /// 获取当前生效的默认终端应用（若未手动选定，优先选择 Warp / iTerm2 等现代终端，回退至系统内置终端）
    public func currentTerminal() -> InstalledTerminal {
        let terminals = scanInstalledTerminals()
        let preference = AppSettings.defaultTerminalBundleId

        if preference != "auto" && !preference.isEmpty {
            if let matched = terminals.first(where: {
                $0.bundleIdentifier == preference || $0.id == preference || $0.appURL.path == preference
            }) {
                return matched
            }
        }

        // 智能默认排序：用户若安装了 Warp 则默认推荐使用 Warp，其次 iTerm2，其次系统终端
        if let warp = terminals.first(where: { $0.type == .warp }) {
            return warp
        }
        if let iterm = terminals.first(where: { $0.type == .iterm2 }) {
            return iterm
        }
        if let ghostty = terminals.first(where: { $0.type == .ghostty }) {
            return ghostty
        }
        if let terminal = terminals.first(where: { $0.type == .terminal }) {
            return terminal
        }
        if let first = terminals.first {
            return first
        }

        // 终极兜底：系统终端
        let sysURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        return InstalledTerminal(
            id: "com.apple.Terminal",
            displayName: "终端 (系统内置)".localized,
            bundleIdentifier: "com.apple.Terminal",
            appURL: sysURL,
            type: .terminal
        )
    }

    /// 打开指定目录（保证终端工作路径直接处于当前目录）
    public func open(directoryURL: URL, using terminal: InstalledTerminal? = nil) {
        let term = terminal ?? currentTerminal()

        // 确保目标路径是文件夹目录（如果是文件，取其所在父目录）
        var targetURL = directoryURL.standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                targetURL = targetURL.deletingLastPathComponent()
            }
        }
        let path = targetURL.path

        switch term.type {
        case .warp:
            // 优先使用 Warp 官方专有 URL Scheme: warp://action/new_tab?path=...
            // 这是 Warp 打开指定目录最可靠且官方原生推荐的标准接口
            if let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let warpURL = URL(string: "warp://action/new_tab?path=\(encoded)") {
                if NSWorkspace.shared.open(warpURL) {
                    return
                }
            }
            // 兜底方案
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([targetURL], withApplicationAt: term.appURL, configuration: config, completionHandler: nil)

        case .iterm2:
            // iTerm2 通过 AppleScript 精准开启新窗口/标签页并直接进入目标目录
            let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let scriptSource = """
            tell application id "com.googlecode.iterm2"
                activate
                if (count of windows) = 0 then
                    set newWindow to (create window with default profile)
                    tell current session of newWindow
                        write text "cd \\"\(escaped)\\""
                    end tell
                else
                    tell current window
                        create tab with default profile
                        tell current session
                            write text "cd \\"\(escaped)\\""
                        end tell
                    end tell
                end if
            end tell
            """
            var err: NSDictionary?
            if let script = NSAppleScript(source: scriptSource) {
                _ = script.executeAndReturnError(&err)
                if err == nil {
                    return
                }
            }
            // 兜底方案
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([targetURL], withApplicationAt: term.appURL, configuration: config, completionHandler: nil)

        case .ghostty:
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([targetURL], withApplicationAt: term.appURL, configuration: config, completionHandler: nil)

        case .alacritty:
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = ["--working-directory", path]
            NSWorkspace.shared.openApplication(at: term.appURL, configuration: config, completionHandler: nil)

        case .kitty:
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = ["--directory", path]
            NSWorkspace.shared.openApplication(at: term.appURL, configuration: config, completionHandler: nil)

        case .wezterm:
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = ["start", "--cwd", path]
            NSWorkspace.shared.openApplication(at: term.appURL, configuration: config, completionHandler: nil)

        case .terminal, .hyper, .custom:
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([targetURL], withApplicationAt: term.appURL, configuration: config, completionHandler: nil)
        }
    }
}
