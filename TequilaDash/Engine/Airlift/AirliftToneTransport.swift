import AirliftFFI
import Darwin
import Foundation

/// Airlift 传输层错误.
///
/// 与 AirBeep 的 `CallRecordingToneError` **刻意解耦**：本仓 `CallRecordingToneService`
/// 有自己的 `ToneError`，由它负责把本错误映射过去。这样传输层不依赖任何业务类型.
enum AirliftTransportError: Error, LocalizedError, Sendable {
    /// 本 build 缺少 AirliftFFI 的读文件符号（补丁未生效 / 库未链接）.
    case unavailable
    /// airlift 返回非 0，附原生错误信息.
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "本 build 缺少 AirLift 文件访问支持."
        case .failed(let reason):
            return "AirLift 操作失败：\(reason)"
        }
    }
}

/// `RTLD_DEFAULT` 是 C 宏（`((void *) -2)`），Swift 无法从 iOS SDK 导入
/// （`dlfcn.h` 报 "structure not supported"）。其值平台稳定且有据可查，
/// 故按需构造等价值。全局常量会被严格并发判为非 Sendable，因此改为工厂函数.
private func rtlDefaultHandle() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(bitPattern: -2)
}

/// 一个待写入的提示音文件（名字 + 内容）.
struct AirliftToneFile: Sendable {
    let name: String
    let data: Data
}

/// 串行化**阻塞式** AirLift 调用，并把文件协议细节挡在 SwiftUI 层之外。
/// 沙盒逃逸仍由原生库完成；本类型只提供文件字节并跨 C 边界搬运.
///
/// ## 移植说明（对齐 AirBeep 的 `AirliftToneTransport`）
/// · 读：`al_exploit_read_file`（补丁新增，经 `dlsym` 解析 —— 与 AirBeep 同款，
///   对「头文件是否声明该符号」不敏感）.
/// · 写：`al_exploit_write_dir`（基础库自带，直接经 `AirliftFFI` 模块调用）.
/// · 目标主机：AirBeep 写死 `10.7.0.1`；本仓改为读 `LocalDevVPN.targetIP`
///   （与本仓 AFC / RSD 隧道同一来源，见 `LocalDevVPN` 的解析优先级）.
/// · 目标目录：AirBeep 写死通话提示音目录；本仓改为**入参**，供通用文件接口复用.
///
/// ## 与 AirBeep 的一处**有意**差异（并发）
/// AirBeep 把阻塞调用丢到 `DispatchQueue.global()`，再在 `await` 处挂起 actor ——
/// 由于挂起期间 actor 可重入，**两次调用仍会并发跑**（actor 并未真正串行化）。
/// 本仓对齐「RSD 隧道并发铁律」（同 hostname 并发建隧道会互相抢占），改用**专用串行队列**
/// 让「串行化」名副其实；同时 `al_set_target_host` 写的是 Rust 侧进程级全局，
/// 并发调用会互相踩，串行是正确性要求而非保守选择.
actor AirliftToneTransport {
    static let shared = AirliftToneTransport()

    /// 专用串行队列：所有阻塞式 AirLift 调用都在这条队列上排队执行.
    private static let queue = DispatchQueue(
        label: "com.tequila.dash.airlift",
        qos: .userInitiated
    )

    private typealias ExploitReadFileFn = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void)?,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
        UnsafeMutablePointer<Int>?,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32

    private typealias BytesFreeFn = @convention(c) (UnsafeMutablePointer<UInt8>?, Int) -> Void
    private typealias SetTargetFn = @convention(c) (UnsafePointer<CChar>?) -> Int32

    // MARK: - FFI 符号（进程内只解析一次）

    /// `al_exploit_read_file` 的函数指针；解析不到为 nil.
    ///
    /// **能缓存**：`AirliftFFI.xcframework` 是**静态库**（`project.yml` 里 `link: true` /
    /// `embed: false`），符号被链进主可执行文件，`RTLD_DEFAULT` 必然解析到主二进制；
    /// 进程内没有任何 `dlclose` 路径，函数地址恒定.
    /// **要缓存**：`dlsym` 每次都要遍历已加载镜像的符号表，而这条路径每次读都会走到.
    private static let readFileFn: ExploitReadFileFn? = {
        guard let symbol = dlsym(rtlDefaultHandle(), "al_exploit_read_file") else { return nil }
        return unsafeBitCast(symbol, to: ExploitReadFileFn.self)
    }()

    /// `al_bytes_free` 的函数指针；解析不到为 nil.
    ///
    /// 与 `readFileFn` **必须成对可用**：只拿到读、拿不到释放，等于每次读都漏一份
    /// 文件大小的内存（成对校验见 `readSync` 开头）.
    private static let bytesFreeFn: BytesFreeFn? = {
        guard let symbol = dlsym(rtlDefaultHandle(), "al_bytes_free") else { return nil }
        return unsafeBitCast(symbol, to: BytesFreeFn.self)
    }()

    /// `al_set_target_host` 的函数指针；解析不到为 nil.
    ///
    /// 缺符号时**只留痕不抛错**：库内默认目标与本仓出厂目标一致，拒绝运行反而会把
    /// 本来能用的默认路径一起弄坏；但绝不静默 —— 记一行日志，随导出一起给出去.
    private static let setTargetFn: SetTargetFn? = {
        guard let symbol = dlsym(rtlDefaultHandle(), "al_set_target_host") else {
            AirliftLog.shared.append("airlift: 未解析到 al_set_target_host，目标主机退回库内默认值")
            return nil
        }
        return unsafeBitCast(symbol, to: SetTargetFn.self)
    }()

    /// 读一个设备上的绝对路径.
    func read(path: String, pairingPath: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    let data = try Self.readSyncWithRetry(path: path, pairingPath: pairingPath)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 把若干文件**写入**设备上的目标目录.
    func write(files: [AirliftToneFile], directory: String, pairingPath: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    try Self.writeSync(files: files, directory: directory, pairingPath: pairingPath)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 同步实现（在后台队列上执行）

    private static func readSync(path: String, pairingPath: String) throws -> Data {
        // 读 / 释放必须成对可用：只拿到读、拿不到 al_bytes_free 时，每次读都会把
        // 一整份文件大小的堆内存漏在进程里（Rust 侧是 mem::forget 出来的 Box）.
        guard let readFile = readFileFn, let freeBytes = bytesFreeFn else {
            throw AirliftTransportError.unavailable
        }

        configureTargets()

        var output: UnsafeMutablePointer<UInt8>?
        var outputLength = 0
        var outputError: UnsafeMutablePointer<CChar>?
        let result = pairingPath.withCString { pairingCString in
            path.withCString { pathCString in
                readFile(
                    pairingCString,
                    pathCString,
                    AirliftLog.ffiCallback,
                    nil,
                    &output,
                    &outputLength,
                    &outputError
                )
            }
        }

        // 先把两块所有权都接过来，再判返回码：
        // · out_error 只要非空就必须 al_string_free（成功路径也可能带回告警字符串）.
        // · out_data 只在 result == 0 时由 Rust 填入；这里仍按「非空即拥有」释放 ——
        //   不依赖「非 0 必为 null」这条隐含约定，将来 Rust 改成「部分结果 + 非 0」
        //   也不会漏. 长度取返回后立刻快照的 outputLength，必须与分配长度逐字节相等，
        //   因为 al_bytes_free 走的是 Box::from_raw(slice)，长度错了就是未定义行为.
        let message = outputError.map { String(cString: $0) }
        if let outputError {
            al_string_free(outputError)
        }
        // 先拷字节、再释放原生缓冲 —— 顺序反了就是 use-after-free.
        var data: Data?
        if let output {
            data = Data(bytes: output, count: outputLength)
            freeBytes(output, outputLength)
        }

        guard result == 0 else {
            // 原文**原样**留在错误里，不在这里改写：真正给用户看的那一版由
            // `readSyncWithRetry` 在重试额度用尽后统一翻译，那里才知道一共试了几次.
            AirliftLog.shared.append("airlift: 读取 \(path) 失败（\(result)）：\(message ?? "无错误文案")")
            throw AirliftTransportError.failed(message ?? "AirLift 读取失败（\(result)）")
        }
        guard let data else {
            AirliftLog.shared.append("airlift: \(path) 返回码为 0 但数据为空")
            throw AirliftTransportError.failed("AirLift 未返回 \(path) 的数据")
        }
        return data
    }

    // MARK: - 读：有界重试 + 可读文案

    /// AirTraffic 恢复类失败的重试上限（**不含**首次尝试，故总尝试次数是 3）.
    private static let readRetryLimit = 2
    /// 两次尝试之间的间隔. 首次尝试在 Rust 侧已经等满约 20 秒，这里只补设备侧
    /// ATC 会话收尾 / Media 落盘所需的余量，等太久会把界面卡到用户以为死机.
    private static let readRetryDelay: TimeInterval = 1.5
    /// 整轮重试（含首次尝试与全部间隔）的总时长上限，超过即不再发起下一次尝试.
    private static let readRetryTotalTimeLimit: TimeInterval = 60

    /// 读一个设备上的绝对路径，**只**对 AirTraffic 恢复类失败做有界重试.
    ///
    /// 重试**只走 `readSync` 这一个入口**，不在本函数里复制任何 FFI 调用序列：
    /// `readSync` 里的「先拷字节并 freeBytes / 先取文案并无条件 al_string_free / 再判返回码」
    /// 这套顺序是 v0.3.673 的成果，必须原样保留. 每次尝试都是**独立一次完整调用**，
    /// 它自己申请、自己释放，返回的 `Data` 是 Swift 侧拷贝 —— 上一次尝试的裸指针
    /// 在本函数里从未被持有，因此不存在「已释放的指针被第二次使用」的路径.
    ///
    /// 不重试的失败（立刻上抛，重试只会白等）：配对文件读不出 / 隧道建不起 /
    /// AFC 通道不可用 / 文件不存在 / 路径非法等确定性错误.
    ///
    /// 每轮循环开头做两项检查（均复用既有 `.failed`，不新增错误 case）：
    /// `Task.isCancelled` 为真即抛「已取消.」；距整轮开始超过
    /// `readRetryTotalTimeLimit` 即抛「重试超过 N 秒.」. 单次 FFI 调用是阻塞的，
    /// 这两项检查只能发生在两次尝试之间.
    private static func readSyncWithRetry(path: String, pairingPath: String) throws -> Data {
        var attempt = 1
        let startedAt = CFAbsoluteTimeGetCurrent()
        while true {
            if Task.isCancelled {
                throw AirliftTransportError.failed("已取消.")
            }
            if CFAbsoluteTimeGetCurrent() - startedAt >= Self.readRetryTotalTimeLimit {
                throw AirliftTransportError.failed("重试超过 \(Int(Self.readRetryTotalTimeLimit)) 秒.")
            }
            do {
                return try readSync(path: path, pairingPath: pairingPath)
            } catch let error as AirliftTransportError {
                // 只有 `.failed` 里判定为 AirTraffic 恢复类的才继续；`.unavailable` 是配置
                // 问题，重试没有意义。配对缺失的真实抛出点：AirLiftExploit.swift:178 抛
                // AirLiftError.pairingRequired（另一个枚举）.
                guard case .failed(let rawReason) = error,
                      Self.isAirTrafficRecoveryFailure(rawReason) else {
                    throw error
                }
                // 额度用尽：把原始串翻成用户能看懂的一版再抛（原文上面已进日志）.
                guard attempt <= Self.readRetryLimit else {
                    throw AirliftTransportError.failed(
                        Self.readFailureText(rawReason: rawReason, attempts: attempt)
                    )
                }
                AirliftLog.shared.append(
                    "airlift: \(path) 第 \(attempt) 次读取遇到 AirTraffic 恢复失败，\(Self.readRetryDelay) 秒后重试"
                )
                // 本队列是串行队列、且此刻没有别的 Airlift 调用在跑，睡眠不会堵住别人.
                Thread.sleep(forTimeInterval: Self.readRetryDelay)
                attempt += 1
            }
        }
    }

    /// 失败原文是否属于「设备侧 AirTraffic 没把文件搬回来」这一类.
    ///
    /// 判据取自 `Resources/Scripts/airlift-read-file.patch` 里 `exploit_read_file` 的三处
    /// 收尾 `return Err(...)`（该补丁与上游逐字节一致，字符串不能改，故只能在这里认）：
    /// · `AirTraffic did not recover <path>; any moved copy remains in Media` —— 20 秒轮询耗尽.
    /// · `AirTraffic: ReadyForSync not observed while reading <leaf>` —— 会话没握手成功.
    /// · `AirTraffic: AssetManifest not observed while reading <leaf>` —— 清单没回.
    /// 其余（配对 / 隧道 / AFC / 路径 / 解压）一律不重试.
    private static func isAirTrafficRecoveryFailure(_ rawReason: String) -> Bool {
        rawReason.contains("AirTraffic did not recover")
            || rawReason.contains("AirTraffic: ReadyForSync not observed")
            || rawReason.contains("AirTraffic: AssetManifest not observed")
    }

    /// 把 Rust 的原始错误串翻成用户能看懂的中文（只翻 AirTraffic 恢复类，其余原样返回）.
    ///
    /// 原文**不丢**：它已由 `readSync` / `readSyncWithRetry` 写进 `AirliftLog`，
    /// 本函数只产出摆在提示音页上的那一句. `attempts` 是**总尝试次数**（含首次），
    /// 所以「已自动重试 N 次」里的 N 是 `attempts - 1`.
    private static func readFailureText(rawReason: String, attempts: Int) -> String {
        guard Self.isAirTrafficRecoveryFailure(rawReason) else { return rawReason }
        return "设备侧文件搬运没在 20 秒内完成.已自动重试 \(attempts - 1) 次仍失败，请锁屏再解锁后重试."
    }

    private static func writeSync(files: [AirliftToneFile], directory: String, pairingPath: String) throws {
        configureTargets()
        removeStaleStagingDirectories()

        // 暂存目录用唯一名字，由下面这一条 defer 统一兜底删除：
        // · createDirectory 失败 ⇒ 磁盘上什么都没建，无需清理.
        // · 单个文件写失败（磁盘满 / 文件名非法）⇒ 直接 throw 出本函数，defer 已挂上，暂存目录照删.
        // · airlift 写失败 ⇒ 同样走 defer.
        // 清理刻意用 try?：删除失败不得顶掉真正的错误原因（调用方要看到 airlift 的报错）.
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "TequilaDash-Airlift-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        for file in files {
            // 文件名是入参：带路径分隔符会写到暂存目录之外（.atomic 还会先在同目录建临时文件）.
            // 本仓调用方只传提示音文件名，这里按契约拒绝，不做静默改写.
            guard !file.name.isEmpty,
                  !file.name.contains("/"),
                  file.name != ".",
                  file.name != ".." else {
                throw AirliftTransportError.failed("非法的暂存文件名：\(file.name)")
            }
            try file.data.write(
                to: stagingDirectory.appending(path: file.name),
                options: .atomic
            )
        }

        var outputError: UnsafeMutablePointer<CChar>?
        let result = pairingPath.withCString { pairingCString in
            stagingDirectory.path.withCString { sourceCString in
                directory.withCString { targetCString in
                    al_exploit_write_dir(
                        pairingCString,
                        sourceCString,
                        targetCString,
                        AirliftLog.ffiCallback,
                        nil,
                        &outputError
                    )
                }
            }
        }

        // 先取文案、再无条件释放：无论返回码是几，out_error 非空就归调用方释放.
        let message = outputError.map { String(cString: $0) }
        if let outputError {
            al_string_free(outputError)
        }

        guard result == 0 else {
            throw AirliftTransportError.failed(message ?? "AirLift 写入失败（\(result)）")
        }
    }

    /// 清掉**上一个进程**残留的暂存目录.
    ///
    /// `writeSync` 里的 `defer` 只能覆盖「进程还活着」的失败路径. 被用户强杀 / 崩溃 /
    /// 看门狗终止时，已经建好的 `TequilaDash-Airlift-<UUID>` 目录会留在 tmp 里；
    /// 系统虽会不定期清理 tmp，但不保证时机，而一个目录就是一整套提示音的体积.
    /// 调用点在本函数自己建目录**之前**，且所有调用都在同一条串行队列上，
    /// 因此此刻看到的同名目录必定是遗留物；再加「10 分钟没动过」的门槛兜底.
    private static func removeStaleStagingDirectories() {
        let prefix = "TequilaDash-Airlift-"
        let cutoff = Date().addingTimeInterval(-600)
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: manager.temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            // 读不到类型或时间就跳过：宁可留一个目录，也不误删正在用的.
            guard let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey]
            ), values.isDirectory == true,
               let modified = values.contentModificationDate,
               modified <= cutoff else { continue }
            try? manager.removeItem(at: entry)
        }
    }

    /// 把 airlift 的目标主机设为**本仓当前隧道对端**（不再是 AirBeep 写死的 10.7.0.1）.
    ///
    /// ## 为什么符号缓存了、目标值仍要每次重写
    /// `al_set_target_host` 写的是 **Rust 侧进程级全局**，全 App 只有这一份；而
    /// `LocalDevVPN.targetIP` 在运行期会变（用户在「设置 → 本地隧道」改 `TunnelDeviceIP`，
    /// 见 LocalDevVPN.swift:29-34）. 所以能缓存的是**符号地址**（`setTargetFn`，进程内恒定），
    /// 不能缓存的是**目标值**：每次操作都要把当前目标重新写进去，否则用户改完隧道地址后，
    /// 后续操作仍会连旧地址.
    private static func configureTargets() {
        guard let setTarget = setTargetFn else { return }
        _ = LocalDevVPN.targetIP.withCString { setTarget($0) }
    }
}
