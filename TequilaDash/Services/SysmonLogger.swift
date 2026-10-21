import Foundation

/// 进程管理诊断日志：sysmontap 内存查询每步关键事件记到
/// `Documents/SysmonLogs/sysmon.log`，独立于 LoginLogger.
/// 进程管理 toolbar 的日志按钮直接分享本文件.
/// `@unchecked Sendable`：唯一可变状态 `buffer` 的读写都在 `lock`（`NSLock`）保护下
/// （`log` / `fullLog` / `clear`），跨隔离域共享引用安全.
final class SysmonLogger: @unchecked Sendable {
    static let shared = SysmonLogger()

    private let lock = NSLock()
    private var buffer: [String] = []
    private let maxBufferLines = 500

    /// 日志文件位置（App 沙盒 Documents 内，文件浏览器可见）.
    var logFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/SysmonLogs")
            .appendingPathComponent("sysmon.log")
    }

    private init() {
        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func log(_ message: String) {
        let line = "[\(Self.timestamp())] \(message)"
        lock.lock()
        buffer.append(line)
        if buffer.count > maxBufferLines { buffer.removeFirst(buffer.count - maxBufferLines) }
        lock.unlock()
        appendToFile(line)
        print("[Sysmon] \(message)")
    }

    /// 全部日志文本（内存缓冲 + 文件内容合并，去重）.
    func fullLog() -> String {
        lock.lock()
        let mem = buffer
        lock.unlock()

        var fileLines: [String] = []
        if let data = try? Data(contentsOf: logFileURL),
           let text = String(data: data, encoding: .utf8) {
            fileLines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        let merged = mem + fileLines.filter { !mem.contains($0) }
        return merged.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: logFileURL)
    }

    private func appendToFile(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
