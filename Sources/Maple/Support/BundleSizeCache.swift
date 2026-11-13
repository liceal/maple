import Foundation

/// 应用程序包（.app）与目录大小的常驻内存缓存与异步并发计算管理器。
/// 解决 macOS 系统对 .app 目录的 fileSize 报 nil 导致列表显示 0 KB 的系统级问题。
final class BundleSizeCache {

    static let shared = BundleSizeCache()

    let cache = NSCache<NSURL, NSNumber>()
    private var pendingCallbacks: [URL: [(Int64) -> Void]] = [:]
    private let lock = NSLock()

    private init() {
        cache.countLimit = 5000
    }

    /// 获取已缓存的包/文件夹大小（单位：字节）
    func size(for url: URL) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: url as NSURL)?.int64Value
    }

    /// 手动存入大小
    func set(size: Int64, for url: URL) {
        lock.lock()
        cache.setObject(NSNumber(value: size), forKey: url as NSURL)
        lock.unlock()
    }

    /// 递归计算某个目录或包的大小（字节）
    static func calculateDirectorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let vals = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey])
            if vals?.isRegularFile == true {
                if let s = vals?.totalFileAllocatedSize ?? vals?.fileSize {
                    total += Int64(s)
                }
            }
        }
        return total
    }

    /// 异步获取包或目录大小：命中缓存立即回调；未命中则在全局队列异步计算，并在主线程合并回调所有等待方。
    func requestSize(for url: URL, completion: @escaping (Int64) -> Void) {
        lock.lock()
        if let cached = cache.object(forKey: url as NSURL) {
            lock.unlock()
            completion(cached.int64Value)
            return
        }
        if var callbacks = pendingCallbacks[url] {
            callbacks.append(completion)
            pendingCallbacks[url] = callbacks
            lock.unlock()
            return
        }
        pendingCallbacks[url] = [completion]
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let total = Self.calculateDirectorySize(at: url)
            self.lock.lock()
            let callbacks = self.pendingCallbacks.removeValue(forKey: url) ?? []
            self.cache.setObject(NSNumber(value: total), forKey: url as NSURL)
            self.lock.unlock()

            DispatchQueue.main.async {
                for cb in callbacks {
                    cb(total)
                }
            }
        }
    }
}
