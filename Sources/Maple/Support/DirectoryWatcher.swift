import CoreServices
import Foundation

/// 目录文件系统监视器，基于 macOS 原生 FSEvents 实现。
///
/// 当外部程序（如 Chrome 下载、终端脚本、文件解压、拖入等）对当前目录或子项发生变动时，
/// 自动触发防抖回调通知上层刷新，无需用户手动切换文件夹。
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private(set) var watchedURL: URL?
    private let onChange: () -> Void

    init?(url: URL, latency: TimeInterval = 0.25, onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard start(url: url, latency: latency) else { return nil }
    }

    func isWatching(url: URL) -> Bool {
        guard stream != nil, let watched = watchedURL else { return false }
        return watched.standardizedFileURL.path == url.standardizedFileURL.path
    }

    private func start(url: URL, latency: TimeInterval) -> Bool {
        stop()
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        self.watchedURL = url

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let clientCallBackInfo = clientCallBackInfo else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            watcher.onChange()
        }

        let pathsToWatch = [path] as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)

        guard let createdStream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return false }

        self.stream = createdStream
        FSEventStreamSetDispatchQueue(createdStream, DispatchQueue.main)
        FSEventStreamStart(createdStream)
        return true
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        self.watchedURL = nil
    }

    deinit {
        stop()
    }
}
