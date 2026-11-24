import Foundation
import CoreServices
import AppKit

/// 默认文件管理器（Launch Services）管理与状态检测辅助类
enum DefaultFileManager {
    static let mapleBundleId = "com.workbuddy.maple"
    static let finderBundleId = "com.apple.finder"

    /// 当前系统 `public.folder` 的默认打开应用 Bundle Identifier
    static var currentDefaultHandler: String? {
        if let handler = LSCopyDefaultRoleHandlerForContentType("public.folder" as CFString, .all)?.takeRetainedValue() as String? {
            return handler
        }
        return nil
    }

    /// 检测 Maple 是否为当前系统的默认文件管理器
    static var isMapleDefault: Bool {
        guard let current = currentDefaultHandler else { return false }
        return current.caseInsensitiveCompare(mapleBundleId) == .orderedSame
    }

    /// 将 Maple 设为系统默认文件管理器（public.folder 与 public.directory）
    @discardableResult
    static func setAsDefault() -> Bool {
        let status1 = LSSetDefaultRoleHandlerForContentType("public.folder" as CFString, .all, mapleBundleId as CFString)
        let status2 = LSSetDefaultRoleHandlerForContentType("public.directory" as CFString, .all, mapleBundleId as CFString)
        let success = (status1 == noErr && status2 == noErr)
        NotificationCenter.default.post(name: .defaultFileManagerDidChange, object: nil)
        return success
    }

    /// 恢复系统访达（Finder）为默认文件管理器
    @discardableResult
    static func restoreFinder() -> Bool {
        let status1 = LSSetDefaultRoleHandlerForContentType("public.folder" as CFString, .all, finderBundleId as CFString)
        let status2 = LSSetDefaultRoleHandlerForContentType("public.directory" as CFString, .all, finderBundleId as CFString)
        let success = (status1 == noErr && status2 == noErr)
        NotificationCenter.default.post(name: .defaultFileManagerDidChange, object: nil)
        return success
    }
}
