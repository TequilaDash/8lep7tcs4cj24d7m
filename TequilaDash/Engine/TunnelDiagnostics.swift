//
//  TunnelDiagnostics.swift
//  TequilaDash
//
//  v0.3.723：隧道诊断日志的**统一出口**（纯加法，不重写任何建隧道逻辑）.
//
//  为什么需要：本仓走 RSD 的隧道有 20 来份 `createTunnel` / `makeTunnel` 实现，
//  失败原因各写各的，用户点「设备信息」「文件浏览」「安装」「崩溃日志」看到的现象一样、
//  日志却散落在不同分类里，排障只能靠猜（SSHServerService.swift 里 ddiprobe / cdprobe
//  两大段注释反复在解释同一件事，就是没有统一出口的代价）.
//
//  本类型把它们统一到一个出口：一律写 `LoginLogger.Category.tunnelCellular`，
//  也就是界面「隧道日志」页（Views/TunnelLogView.swift）与 SSH `tunnellog` 命令读的
//  **同一份数据**。不新开分类、不新开日志文件、不新开存储 —— 现有 API 已经够用.
//
//  纪律（任务书硬约束）：
//    · 只记服务名、端口、错误码、错误原文前 200 字符；
//    · 绝不记配对文件内容、token、Apple ID、设备 UDID；
//    · 不改任何现有函数的语义与返回类型 —— 调用方在关键节点各加一行即可.
//

import Foundation

/// 隧道诊断日志的统一入口.
///
/// 用法（加法式，一行起效）：
/// ```swift
/// TunnelDiagnostics.begin("AFC 建隧道", "hostname=TequilaDashAFC")
/// // …原有的建隧道代码，一行都不改…
/// TunnelDiagnostics.succeed("AFC 建隧道")
/// TunnelDiagnostics.fail("AFC 建隧道", error: lastError)
/// ```
enum TunnelDiagnostics {

    /// 隧道日志页与 SSH `tunnellog` 共用的分类.
    /// 换分类会让界面那个页面看不到，所以这里写死，不开放参数.
    private static let category: LoginLogger.Category = .tunnelCellular

    /// 错误原文截断长度（任务书硬约束：只记前 200 字符）.
    private static let maxMessageChars = 200

    /// 服务表逐行写入的上限，防止一次诊断把 500 行缓冲冲干净.
    private static let maxServiceLines = 200

    // MARK: - 三态

    /// 记录「开始做某事」.
    /// - Parameters:
    ///   - stage: 阶段名，建议「功能名 + 动作」，例 `"AFC 建隧道"`.
    ///   - detail: 可选细节，例 `"hostname=TequilaDashAFC ip=10.7.0.1"`.
    static func begin(_ stage: String, _ detail: String? = nil) {
        emit("开始", stage, detail)
    }

    /// 记录「做成了」.
    static func succeed(_ stage: String, _ detail: String? = nil) {
        emit("成功", stage, detail)
    }

    /// 记录一条**不带三态语义**的观测（例：「两张 RSD 表的服务差异」）.
    ///
    /// 与 begin/succeed/fail 走同一出口、同一去重窗口，只是不写「开始/成功/失败」字样.
    static func note(_ stage: String, _ detail: String? = nil) {
        emit(nil, stage, detail)
    }

    /// 记录「失败了」，自动抽取 NSError 的 domain / code / 原文，并按 code 附一句人话.
    ///
    /// 失败时**一定**要调用它：隧道类失败的用户可见文案通常是「请检查 LocalDevVPN」这类
    /// 兜底话术，真实原因（配对文件过期 / 端口不通 / 服务没发布）只在这里留得下.
    static func fail(_ stage: String, error: Error?) {
        guard let error else {
            emit("失败", stage, "错误对象为空（上游没给原因）")
            return
        }
        let ns = error as NSError
        fail(stage,
             code: Int32(clamping: ns.code),
             message: ns.localizedDescription,
             domain: ns.domain)
    }

    /// FFI 错误码版本：调用方自己持有 `IdeviceFfiError` 指针时用这个.
    ///
    /// 本函数**不读也不释放**那个指针 —— 所有权仍归调用方，避免改变既有的
    /// `idevice_error_free` 语义（那是 v0.3.673 / v0.3.661 逐个文件修出来的纪律）.
    static func fail(_ stage: String,
                     code: Int32,
                     message: String?,
                     domain: String? = nil) {
        var parts: [String] = []
        if let domain, !domain.isEmpty { parts.append("domain=\(domain)") }
        parts.append("code=\(code)")
        if let hint = describe(code: code) { parts.append(hint) }
        if let message, !message.isEmpty { parts.append("原文=\(clip(message))") }
        emit("失败", stage, parts.joined(separator: " "))
    }

    /// 包一段可能抛错的操作：失败自动记 `fail` 再**原样抛回**，成功记 `succeed`.
    ///
    /// 只做日志：不改错误类型、不改返回值、不吞异常（`rethrows`）. 适合新写的调用点.
    static func track<T>(_ stage: String, _ detail: String? = nil,
                         _ body: () throws -> T) rethrows -> T {
        begin(stage, detail)
        do {
            let value = try body()
            succeed(stage)
            return value
        } catch {
            fail(stage, error: error)
            throw error
        }
    }

    // MARK: - 服务表

    /// 把设备广播的 RSD 服务表逐行写进隧道日志.
    ///
    /// 服务名本身不含敏感信息（形如 `com.apple.dt.simulate-location`），
    /// 但它是判定「设备到底发布了哪些服务」的唯一直接证据，值得留全.
    static func noteServiceTable(_ services: [String]) {
        LoginLogger.shared.log("RSD 服务表共 \(services.count) 条", category: category)
        for name in services.prefix(maxServiceLines) {
            LoginLogger.shared.log("  服务 \(name)", category: category)
        }
        if services.count > maxServiceLines {
            LoginLogger.shared.log("  （其余 \(services.count - maxServiceLines) 条已省略）",
                                   category: category)
        }
    }

    // MARK: - 错误码人话

    /// 把 `IdeviceError::code()`（Rust 侧 `idevice/src/lib.rs` 的 `code()`）翻成一句人话.
    ///
    /// 只覆盖隧道排障真正会撞到的那些；查不到就返回 nil，**不编造**.
    static func describe(code: Int32) -> String? {
        switch code {
        case 1: return "I/O 或传输层失败（Socket）：多半是隧道没起来或端口不通"
        case 3: return "TLS 握手失败（Rustls）"
        case 5: return "plist 解析失败"
        case 10: return "报文长度不足（NotEnoughBytes）"
        case 13: return "设备回了非预期响应（UnexpectedResponse）"
        case 17: return "会话未激活（SessionInactive）"
        case 19: return "连接未建立（NoEstablishedConnection）"
        case 20: return "对象不存在（NotFound）"
        case 21: return "服务不存在（ServiceNotFound）：设备侧没有发布该服务，重启手机后再试"
        case 22: return "找不到设备（DeviceNotFound）"
        case 23: return "设备已锁屏（DeviceLocked）：解锁后重试"
        case 24: return "未开启开发者模式（DeveloperModeNotEnabled）"
        case 29: return "镜像未挂载（ImageNotMounted）：DDI 没挂上"
        case 30: return "配对弹窗等待中（PairingDialogResponsePending）"
        case 31: return "用户拒绝了配对（UserDeniedPairing）"
        case 32: return "配对需要密码（PasswordProtected）"
        case 33: return "FFI 入参非法（FfiInvalidArg）"
        case 101: return "CoreDeviceProxy 隧道错误（CdTunnel）"
        case 102: return "usbmuxd 错误（Usbmuxd）"
        case 103: return "远程配对错误（RemotePairing）：配对文件过期或与设备不匹配"
        case 106: return "AFC 服务错误（Afc）"
        case 107: return "installation_proxy 错误（InstallationProxy）"
        case 108: return "core_device 错误（CoreDevice）"
        case 109: return "超时（Timeout）"
        default: return nil
        }
    }

    // MARK: - 内部

    private static let stateLock = NSLock()

    // 这三项是**受 stateLock 保护**的全局可变状态：读写全部在 stateLock.lock()/
    // unlock() 之间，逻辑上没有数据竞争。Swift 6 的并发检查看不到锁，只会看到
    // 「nonisolated 全局可变状态」，所以必须显式标 nonisolated(unsafe) 才编得过
    // （CI 实测：#MutableGlobalVariable error）.
    nonisolated(unsafe) private static var lastKey = ""
    nonisolated(unsafe) private static var lastAt = Date.distantPast
    nonisolated(unsafe) private static var suppressed = 0

    /// 同一条消息 1.5 秒内重复出现就压掉.
    ///
    /// 必须压：`AFCService.withClient` 是「一次操作建一次隧道」，翻一屏文件列表就能
    /// 刷出上百条一样的「AFC 建隧道 成功」，把 500 行缓冲（LoginLogger.maxBufferLines）
    /// 冲干净之后，真正要看的那条失败记录就被挤掉了.
    private static let dedupWindow: TimeInterval = 1.5

    private static func emit(_ state: String?, _ stage: String, _ detail: String?) {
        var head = stage
        if let state, !state.isEmpty { head += " " + state }
        let body = detail.map { "\(head) \(clip($0))" } ?? head
        stateLock.lock()
        let now = Date()
        if body == lastKey, now.timeIntervalSince(lastAt) < dedupWindow {
            suppressed += 1
            stateLock.unlock()
            return
        }
        let dropped = suppressed
        suppressed = 0
        lastKey = body
        lastAt = now
        stateLock.unlock()
        let suffix = dropped > 0 ? "（同上一行，另有 \(dropped) 次相同记录已省略）" : ""
        LoginLogger.shared.log(body + suffix, category: category)
    }

    /// 单行化 + 截断到 200 字符（错误原文常常带换行，多行会把日志行格式打乱）.
    private static func clip(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= maxMessageChars ? flat
                                             : String(flat.prefix(maxMessageChars)) + "…"
    }
}
