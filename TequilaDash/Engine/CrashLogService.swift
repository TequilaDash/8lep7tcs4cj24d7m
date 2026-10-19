import Foundation

/// 崩溃分析服务：通过「配对文件 + LocalDevVPN」隧道连接
/// com.apple.crashreportcopymobile，再用 `crash_report_client_to_afc`
/// 把它转成 **AFC 客户端**浏览日志目录（v0.2.127）.
///
/// 为什么转 AFC：crashreportcopymobile 的 ls 对子目录参数会返回
/// Afc(ObjectNotFound)（服务端行为），而转成的 AFC 视图是**标准文件系统
/// 视图**（根下是 CrashReporter / DiagnosticLogs / Logs 等真实子目录），
/// 目录 / 文件类型一目了然，进入子目录、读内容、删除全部走 AFC 协议.
///
/// 同样遵循 RSD 隧道并发铁律（本服务内所有操作串行）.
final class CrashLogService {

    /// Swift 6 并发检查：本类型非 Sendable，但没有可变实例状态 ——
    /// 只有一条串行队列 `queue` 与计算属性 `pairingPath`，隧道/客户端句柄都是方法内局部量，
    /// 且所有 FFI 操作都在这条串行队列上执行。实例本身线程安全，`shared` 共享无风险。
    nonisolated(unsafe) static let shared = CrashLogService()
    private init() {}

    private let queue = DispatchQueue(label: "com.tequila.dash.crashlog")

    /// 崩溃日志条目（AFC 视图路径）.
    struct Entry: Identifiable, Equatable {
        let name: String
        let path: String
        let isDirectory: Bool
        /// 文件字节数（目录为 0）；list 走 AFCService.listDirectory 时已逐条
        /// afc_get_file_info，带上这两个字段不产生额外 FFI 往返.
        let size: Int64
        /// 修改时间（AFC 秒级时间戳，取不到为 nil）.
        let modified: Date?
        var id: String { path }
    }

    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "CrashLog", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else { return makeError(fallback) }
        let message = ffiError.pointee.message.map { String(cString: $0) } ?? ""
        let code = Int(ffiError.pointee.code)
        idevice_error_free(ffiError)
        return NSError(domain: "CrashLog", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message])
    }

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }

    private func createTunnel() throws -> TunnelHandles {
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw makeError("未检测到配对文件.请到「更多 → 配对文件导入」导入配对文件（需 LocalDevVPN + 开发者模式）.")
        }
        var pairingFile: OpaquePointer?
        if let ffiError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw error(from: ffiError, fallback: "读取配对文件失败")
        }
        guard let pairingFile else { throw makeError("读取配对文件失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian
        // 蜂窝隧道支持（默认关）：开关开 + 无 Wi-Fi 时先等本地隧道就绪；其余情况为 no-op.
        CellularTunnelManager.shared.prepareForTunnel()
        let deviceIP = LocalDevVPN.targetIP
        let parseResult = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard parseResult == 1 else {
            throw makeError("隧道 IP 无效：\(deviceIP)（请检查「设置 → 本地隧道」）")
        }

        var lastError: NSError?
        for attempt in 0..<3 {
            var tunnel = TunnelHandles()
            let ffiError = "TequilaDashCrash".withCString { hn in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing(
                            $0, socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hn, pairingFile, nil, nil,
                            &tunnel.adapter, &tunnel.handshake
                        )
                    }
                }
            }
            if let ffiError {
                lastError = error(from: ffiError, fallback: "创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
            } else if tunnel.adapter != nil, tunnel.handshake != nil {
                return tunnel
            } else {
                var incomplete = tunnel
                incomplete.free()
                lastError = makeError("创建开发者隧道失败")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
    }

    /// 连接 crashreportcopymobile → `crash_report_client_to_afc` 转 AFC 客户端.
    /// 注意：to_afc 会**消费并释放** crashreport 客户端，之后直接使用 AFC 句柄.
    private func withAfcClient<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var tunnel = try createTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var lastError: NSError?
        for attempt in 0..<3 {
            var crashClient: OpaquePointer?
            if let ffiError = crash_report_client_connect_rsd(adapter, handshake, &crashClient) {
                lastError = error(from: ffiError, fallback: "连接崩溃日志服务失败")
            } else if let crashClient {
                var afc: OpaquePointer?
                if let ffiError = crash_report_client_to_afc(crashClient, &afc) {
                    lastError = error(from: ffiError, fallback: "转换崩溃日志 AFC 客户端失败")
                } else if let afc {
                    defer { afc_client_free(afc) }
                    return try body(afc)
                } else {
                    lastError = makeError("转换崩溃日志 AFC 客户端失败")
                }
            } else {
                lastError = makeError("连接崩溃日志服务失败")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("连接崩溃日志服务失败")
    }

    /// ▸ v0.3.490：把 crashreport AFC 会话开放给宿主能力层
    /// （根 = `/var/mobile/Library/Logs/CrashReporter`）。
    ///
    /// ## 为什么要开
    /// `afc.*` 能力要支持**多个根**，而每个根是一条**不同的服务会话**：
    /// · `com.apple.afc` 的根是 `/var/mobile/Media`
    /// · `com.apple.crashreportcopymobile` 的根是 CrashReporter
    ///
    /// 后者只有本服务知道怎么连（`crash_report_client_connect_rsd` → `to_afc`），
    /// 所以把会话借出去比在能力层重写一遍连接逻辑更稳。
    ///
    /// 注意： 与 `afc.list/read/...` 的 `root: "crash"` 对应；调用方拿到的 `path`
    /// 是**相对 CrashReporter 根**的。
    func withAfc<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try syncOnQueue { try withAfcClient { try body($0) } }
    }

    /// 在串行队列上执行可能抛错的闭包（Theos 的 DispatchQueue.sync 无 throwing
    /// 重载，用 Result 包装绕开 —— v0.2.122 实锤）.
    private func syncOnQueue<T>(_ body: () throws -> T) throws -> T {
        var result: Result<T, Error>!
        queue.sync {
            do { result = .success(try body()) }
            catch { result = .failure(error) }
        }
        return try result.get()
    }

    // MARK: - 列表 / 拉取 / 删除（AFC 视图）

    /// 崩溃日志判据：`.ips` 及系统已同步形态 `.ips.synced` / `.ips.ca.synced`
    /// （上游 Xrash 66 份真机样本中 52 份是 synced 形态，只认 `.ips` 会漏掉大多数）.
    static func isCrashLogName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".ips")
            || lower.hasSuffix(".ips.synced")
            || lower.hasSuffix(".ips.ca.synced")
    }

    /// Xrash 结构化解析：把拉取到的日志交给 ReportDecoder，返回
    /// 「摘要字段 + 一句话解释」文本；空文件 / 非文本等解析失败返回 nil，
    /// 调用方退回原文预览.
    func analyze(data: Data, fileName: String) -> String? {
        guard let report = try? ReportDecoder.decode(data, fileName: fileName) else { return nil }
        let execPath = report.crash?.process.path
        var row = ReportDecoder.summary(path: fileName, byteCount: UInt64(data.count), modified: Date())
        row = ReportDecoder.enrich(row, header: report.header,
                                   executablePath: (execPath?.isEmpty == true) ? nil : execPath)
        var lines: [String] = []
        lines.append("Process: \(row.processName)")
        if let bugType = row.bugType {
            lines.append("Kind: \(row.kind.rawValue) (bug_type \(bugType))")
        } else {
            lines.append("Kind: \(row.kind.rawValue)")
        }
        lines.append("Date: \(row.date.formatted(date: .abbreviated, time: .standard))")
        lines.append("Size: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
        if let bundleID = row.bundleID { lines.append("Bundle ID: \(bundleID)") }
        if let version = row.appVersion { lines.append("Version: \(version)") }
        if let os = row.osVersion { lines.append("OS: \(os)") }
        if let incident = row.incidentID { lines.append("Incident: \(incident)") }
        if row.isSynced { lines.append("Synced: yes") }
        lines.append("")
        if let crash = report.crash {
            lines.append(ReportExplainer.explanation(for: crash))
        } else if let panic = report.panic {
            lines.append(panic.panicString.split(separator: "\n").first.map(String.init) ?? "")
        }
        return lines.joined(separator: "\n")
    }

    /// 列出日志目录.`subdirectory` 为 nil 时列根目录
    /// （含 CrashReporter / DiagnosticLogs / Logs 等子目录，v0.2.127 起可进入）.
    /// 列表本身不做后缀过滤，`.ips` / `.ips.synced` / `.ips.ca.synced` 均按原样返回
    /// （是否算崩溃日志用 `isCrashLogName(_:)` 判定）.
    func list(subdirectory: String? = nil) throws -> [Entry] {
        try syncOnQueue {
            try withAfcClient { afc in
                let list = try AFCService.listDirectory(client: afc, path: subdirectory ?? "/")
                return list.map { Entry(name: $0.name, path: $0.path, isDirectory: $0.isDirectory, size: $0.size, modified: $0.modified) }
            }
        }
    }

    /// 设备信息首屏「崩溃日志」的次数。
    ///
    /// **口径 = 系统崩溃（panic）次数**，即 CrashReporter 根目录下的 `panic-full-*`。
    /// 依据：爱思 9.0 的崩溃处理字符串全部围绕 `/panic-full-`（`panicString` /
    /// `crashJson` / `diagnosis`），且真机 iPhone15,4 / iOS 27 上它的首屏显示 **0 次**；
    /// 而该机根目录里除 panic 外还有 30 多个 `.ips`（大多是
    /// `*.diskwrites_resource-*` 磁盘写入诊断、`WiFiLQMMetrics-*` 网络指标、
    /// `JetsamEvent-*` 内存事件与若干 App 崩溃报告）——按"所有 .ips"数会得到 30+，
    /// 与爱思对不上。若以后要单独展示 App 崩溃，用 `appCrashReportCount()`。
    func crashReportCount() throws -> Int {
        let entries = try list()
        return entries.filter { !$0.isDirectory && $0.name.lowercased().hasPrefix("panic-full") }.count
    }

    /// App / 系统守护进程的崩溃报告条数（不含 panic、不含资源与网络诊断；
    /// 后缀判据为 `isCrashLogName(_:)`，含 .ips.synced / .ips.ca.synced 形态）
    func appCrashReportCount() throws -> Int {
        let entries = try list()
        let excluded = ["diskwrites_resource", "wifilqmmetrics", "metric", "shutterbug", "jetsamevent"]
        return entries.filter { entry in
            guard !entry.isDirectory else { return false }
            let name = entry.name.lowercased()
            guard Self.isCrashLogName(name) else { return false }
            return !name.hasPrefix("panic-full") && !excluded.contains { name.contains($0) }
        }.count
    }

    /// v0.2.128：改为 1MB 分块 `afc_file_read`.
    /// `afc_file_read_entire` 在导出时返回 Afc(UnknownError)，分块读更稳，
    /// 且失败时能带上"已读多少字节"便于定位.
    private func pullInternal(client: OpaquePointer, path: String) throws -> Data {
        var handle: OpaquePointer?
        if let ffiError = path.withCString({ afc_file_open(client, $0, AfcRdOnly, &handle) }) {
            throw error(from: ffiError, fallback: "打开日志失败：\(path)")
        }
        guard let handle else { throw makeError("打开日志失败：\(path)") }
        defer { afc_file_close(handle) }

        var result = Data()
        // afc_file_read 的 len 是 uintptr_t → Swift UInt（bytes_read 才是 size_t/Int）
        let chunkSize: UInt = 1 << 20
        while true {
            var buffer: UnsafeMutablePointer<UInt8>?
            var got = 0
            if let ffiError = afc_file_read(handle, &buffer, chunkSize, &got) {
                // v0.3.673：**先释放已读缓冲再抛**. Rust 侧 afc_file_read 在错误路径
                // 不写 *data（buffer 仍为 nil），所以这里只需把上一轮残留清掉；
                // 旧实现在 throw 之后才注册 defer，失败路径直接跳过释放.
                if let buffer, got > 0 { afc_file_read_data_free(buffer, got) }
                throw error(from: ffiError,
                            fallback: "读取日志失败（已读 \(result.count) 字节）：\(path)")
            }
            guard let buffer, got > 0 else {
                // 0 字节：读完（或空文件），无缓冲可放.
                if let buffer { afc_file_read_data_free(buffer, 0) }
                break
            }
            // v0.3.673：**每块读完立即释放**. 旧写法把 defer 写在循环体内 ——
            // defer 到函数返回才执行，于是每读一块就多压 1MB 不释放，
            // 导出大日志（几十 MB）时内存线性膨胀.
            result.append(Data(bytes: buffer, count: got))
            afc_file_read_data_free(buffer, got)
            if got < Int(chunkSize) { break }
        }
        return result
    }

    /// 拉取日志文件内容（.ips 是 JSON 文本）.
    func pull(_ path: String) throws -> Data {
        try syncOnQueue {
            try withAfcClient { afc in
                try pullInternal(client: afc, path: path)
            }
        }
    }

    private func removeInternal(client: OpaquePointer, path: String) throws {
        if let ffiError = path.withCString({ afc_remove_path(client, $0) }) {
            throw error(from: ffiError, fallback: "删除日志失败：\(path)")
        }
    }

    /// 删除日志（目录会连内容一起删）.
    func remove(_ path: String) throws {
        try syncOnQueue {
            try withAfcClient { afc in
                try removeInternal(client: afc, path: path)
            }
        }
    }

    // MARK: - 导出

    /// 导出目录（TequilaDash 自己 Documents 下的 CrashLogs 文件夹，文件 App 可见）.
    ///
    /// v0.3.673：**建目录失败不再被折成成功**. 旧实现 `try? createDirectory` 之后
    /// 照样把路径返回，于是"目录建不出来"要等到写第一个文件才炸，
    /// 而且错误信息变成一句与原因无关的写文件失败. 现在直接抛，原因留在调用方.
    static func exportDirectory() throws -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("CrashLogs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            // static 上下文里没有实例方法 makeError，这里直接构同域错误.
            throw NSError(domain: "CrashLog", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "创建导出目录失败：\(error.localizedDescription)",
            ])
        }
        return dir.path
    }

    /// 批量导出：**同一条 AFC 连接**循环拉取（v0.2.125 修复过死锁，v0.2.127 改为
    /// AFC 视图后保留同款结构）.progress 在后台队列调用，UI 负责切主线程.
    func export(entries: [Entry], progress: ((Int, Int) -> Void)? = nil) throws -> [String] {
        try syncOnQueue {
            try withAfcClient { afc in
                // v0.3.673：**目录先建、失败即报**（旧实现把建目录失败吞掉，见 exportDirectory）.
                let dir = try Self.exportDirectory()
                var exported: [String] = []
                do {
                    for (index, entry) in entries.enumerated() {
                        let data = try pullInternal(client: afc, path: entry.path)
                        let safeName = entry.path.replacingOccurrences(of: "/", with: "_")
                        let target = URL(fileURLWithPath: dir).appendingPathComponent(safeName)
                        // v0.3.673：**原子写**. 旧的非原子写在空间不足/中途失败时
                        // 会留下一个截断的 .ips，看起来像"导出成功的日志".
                        try data.write(to: target, options: .atomic)
                        exported.append(target.path)
                        progress?(index + 1, entries.count)
                    }
                } catch {
                    // v0.3.673：**批失败即清场**. 旧实现抛错时已导出的文件留在
                    // CrashLogs 目录里，界面只报"导出失败"，用户无法分辨哪些是完整的.
                    for path in exported { try? FileManager.default.removeItem(atPath: path) }
                    throw error
                }
                return exported
            }
        }
    }

    /// 批量删除：同一条 AFC 连接循环删除，返回失败数.
    func removeBatch(_ entries: [Entry], progress: ((Int, Int) -> Void)? = nil) throws -> Int {
        try syncOnQueue {
            try withAfcClient { afc in
                var failed = 0
                // v0.3.673：**失败原因不再丢**. 旧实现只数个数，真实原因
                // （Afc(PermDenied) / ObjectNotFound / 连接已断）被直接丢弃，
                // 用户看到"失败 N 个"却没有任何可反馈的线索.
                var failureReasons: [String] = []
                for (index, entry) in entries.enumerated() {
                    do {
                        try removeInternal(client: afc, path: entry.path)
                    } catch {
                        failed += 1
                        if failureReasons.count < 5 {
                            failureReasons.append("\(entry.name)：\(error.localizedDescription)")
                        }
                    }
                    progress?(index + 1, entries.count)
                }
                if failed > 0 {
                    LoginLogger.shared.log(
                        "[崩溃日志] 删除 \(entries.count) 个，失败 \(failed) 个："
                        + failureReasons.joined(separator: " / ")
                    )
                }
                return failed
            }
        }
    }
}
