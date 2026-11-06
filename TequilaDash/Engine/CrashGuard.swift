import Foundation
import Darwin

/// 崩溃现场记录.
///
/// ## 为什么需要它
/// iOS 把崩溃报告写在沙盒外的 `/var/mobile/Library/Logs/CrashReporter`，
/// 必须走 `com.apple.crashreportcopymobile` 服务才读得到.排障时经常出现
/// 报告可能落到宿主容器名下，设备上也翻不到.
/// 这里装一个最小信号处理器：进程死之前把**信号编号、镜像基址偏移、返回地址链**
/// 追加写进 `Documents/LoginLogs/crash.log`.下次启动或用 SSH 取回后，
/// 拿 CI 产出的符号表（nm -nC，随构建工件上传）就能把地址换算成函数名.
///
/// ## 约束
/// 信号处理器里只能调用 async-signal-safe 接口：fd 与缓冲区都在 `install()`
/// 时预先准备好，处理器内只做 `backtrace(3)` + `write(2)`；
/// 写完恢复默认处理并 `raise`，让系统照常生成 .ips，两套证据不冲突.
enum CrashGuard {

    /// 崩溃记录落盘位置（与 login.log 同目录，SSH 里 `cat LoginLogs/crash.log` 可读）.
    static var logFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/LoginLogs")
            .appendingPathComponent("crash.log")
    }

    /// 已安装标记（重复调用无副作用）.
    nonisolated(unsafe) private static var installed = false
    /// 预打开的日志 fd —— 处理器里不能再 open(2)（非 async-signal-safe）.
    nonisolated(unsafe) private static var fd: Int32 = -1
    /// 预分配的输出缓冲与栈帧数组（处理器里不能再 malloc）.
    nonisolated(unsafe) private static var scratch = [UInt8](repeating: 0, count: 2048)
    nonisolated(unsafe) private static var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 32)
    /// 十六进制字符表（处理器里不能 Array(...) 分配，提前备好）.
    nonisolated(unsafe) private static var hexTable = Array("0123456789abcdef".utf8)

    /// 安装处理器.必须在 App 启动早期调用（越早越好，启动期崩溃也要抓）.
    static func install() {
        guard !installed else { return }
        installed = true
        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        fd = open(logFileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }

        var action = sigaction()
        action.__sigaction_u.__sa_sigaction = { sig, _, _ in
            CrashGuard.record(sig)
        }
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_SIGINFO | SA_ONSTACK
        for sig in [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP] {
            sigaction(sig, &action, nil)
        }
    }

    /// 上次运行留下的崩溃记录条数（启动时写进日志，方便一眼看出「上次是崩的」）.
    static func previousCrashCount() -> Int {
        guard let text = try? String(contentsOf: logFileURL, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: "\n").filter { $0.hasPrefix("[crash]") }.count
    }

    // MARK: - 处理器

    /// 信号处理器主体：只做「取栈帧 → 拼字节 → write」.
    private static func record(_ sig: Int32) {
        var idx = 0
        put("[crash] ".utf8, &idx)
        put("sig=".utf8, &idx)
        putDec(UInt(sig), &idx)
        put(" slide=0x".utf8, &idx)
        putHex(UInt(bitPattern: _dyld_get_image_vmaddr_slide(0)), &idx)
        put(" frames=".utf8, &idx)

        let count = frames.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return backtrace(base, Int32(buffer.count))
        }
        var written = 0
        for i in 0..<Int(max(count, 0)) {
            if written > 0 { put(",".utf8, &idx) }
            put("0x".utf8, &idx)
            putHex(frames[i].map { UInt(bitPattern: $0) } ?? 0, &idx)
            written += 1
        }
        put("\n".utf8, &idx)

        scratch.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = write(fd, base, idx)
        }

        // 交还系统默认处理：.ips 照常生成，两套证据并存.
        signal(sig, SIG_DFL)
        raise(sig)
    }

    /// 往 scratch 里追加字节（越界即截断，绝不扩容 —— 处理器里不能 malloc）.
    private static func put<S: Sequence>(_ bytes: S, _ idx: inout Int) where S.Element == UInt8 {
        for byte in bytes {
            guard idx < scratch.count - 1 else { return }
            scratch[idx] = byte
            idx += 1
        }
    }

    private static func putDec(_ value: UInt, _ idx: inout Int) {
        // 栈上临时缓冲：处理器里不能 malloc，withUnsafeTemporaryAllocation 不落堆.
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { digits in
            guard let base = digits.baseAddress else { return }
            var n = value
            var count = 0
            repeat {
                base[count] = UInt8(48 + Int(n % 10))
                n /= 10
                count += 1
            } while n > 0 && count < 20
            var i = count - 1
            while true {
                guard idx < scratch.count - 1 else { return }
                scratch[idx] = base[i]
                idx += 1
                if i == 0 { break }
                i -= 1
            }
        }
    }

    private static func putHex(_ value: UInt, _ idx: inout Int) {
        var started = false
        var shift = 60
        while shift >= 0 {
            let nibble = UInt8((value >> UInt(shift)) & 0xF)
            if nibble != 0 || started || shift == 0 {
                guard idx < scratch.count - 1 else { return }
                scratch[idx] = hexTable[Int(nibble)]
                idx += 1
                started = true
            }
            shift -= 4
        }
    }
}
