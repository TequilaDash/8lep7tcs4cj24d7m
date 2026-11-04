//
//  CellularDataToggleService.swift
//  TequilaDash
//
//  v0.3.755：照 Gnoix 1.2.15 的蜂窝开关链路逆向/反编译后重写移植.
//
//  Gnoix 未公开源码，本文件依据对其二进制的反汇编结论实现：
//  · dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony")
//  · dlsym("_CTServerConnectionCreate") → 建一个 CTServerConnection
//  · dlsym("_CTServerConnectionSetCellularDataIsEnabled") → 程序化开关蜂窝{{TERM_fsvsvmiy}}
//  任一步失败 ⇒ `isPrivateAPIAvailable == false`，调用方（CellularTunnelManager）
//  自动回落快捷指令路径（v0.3.650 起的引导自建快捷指令链路原样保留，作为降级面）.
//

import Foundation
import Darwin

/// 程序化开关蜂窝{{TERM_fsvsvmiy}}（私有 CoreTelephony C API，Gnoix 同款职责）.
final class CellularDataToggleService: @unchecked Sendable {
    static let shared = CellularDataToggleService()

    enum ToggleError: LocalizedError {
        case privateAPIUnavailable
        case ctError(Int32)

        var errorDescription: String? {
            switch self {
            case .privateAPIUnavailable:
                return "私有 CoreTelephony 蜂窝开关 API 不可用."
            case .ctError(let code):
                return "蜂窝开关私有 API 返回错误码 \(code)."
            }
        }
    }

    /// 私有 API 是否可用. `false` 时调用方应走快捷指令路径.
    let isPrivateAPIAvailable: Bool

    /// `_CTServerConnectionCreate` 产出的 connection.
    /// 三者均 init 期定死不再变（let），async 读侧无需加锁——
    /// NSLock.lock() 在 async 上下文不可用（CI 实锤），let 是最省事的正确解.
    private let ctConnection: OpaquePointer?
    /// `_CTServerConnectionSetCellularDataIsEnabled(connection, enabled) -> CTError`.
    private let setCellularFunc: SetCellularFn?

    private typealias CreateFn = @convention(c) (
        UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?
    ) -> OpaquePointer?
    private typealias SetCellularFn = @convention(c) (OpaquePointer?, Bool) -> Int32

    private init() {
        // v0.3.756：全链分步日志进 CellularLogStore（镜像 LoginLogger）——
        // 「为什么没走私有 API」在日志面板里一眼可见.
        CellularLogStore.shared.log("蜂窝开关服务初始化：探测私有 CoreTelephony API…")
        let setup = Self.setupPrivateCoreTelephony()
        self.ctConnection = setup.connection
        self.setCellularFunc = setup.setter
        self.isPrivateAPIAvailable = setup.connection != nil && setup.setter != nil
        CellularLogStore.shared.log(
            isPrivateAPIAvailable
                ? "私有 CoreTelephony 蜂窝开关 API 就绪（_CTServerConnectionCreate + SetCellularDataIsEnabled）"
                : "私有 CoreTelephony 蜂窝开关 API 不可用：蜂窝开关将走快捷指令路径")
    }

    // MARK: - 私有 API 探测（Gnoix setupPrivateCoreTelephony 同职责）

    private static func setupPrivateCoreTelephony()
        -> (connection: OpaquePointer?, setter: SetCellularFn?) {
        let log = CellularLogStore.shared
        let path = "/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony"
        guard let handle = dlopen(path, RTLD_NOW) else {
            log.log("私有 API·dlopen 失败：\(String(cString: dlerror()))")
            return (nil, nil)
        }
        log.log("私有 API·dlopen 成功")
        guard let createSym = dlsym(handle, "_CTServerConnectionCreate") else {
            log.log("私有 API·dlsym(_CTServerConnectionCreate) 失败")
            return (nil, nil)
        }
        guard let setSym = dlsym(handle, "_CTServerConnectionSetCellularDataIsEnabled") else {
            log.log("私有 API·dlsym(_CTServerConnectionSetCellularDataIsEnabled) 失败")
            return (nil, nil)
        }
        log.log("私有 API·两个私有符号齐全")
        let create = unsafeBitCast(createSym, to: CreateFn.self)

        // Gnoix 传的是 kCFAllocatorSystemDefault（GOT 槽解引用）；公开片段常见传 NULL.
        // 两种都试，先系统分配器后 NULL.
        let allocator = Unmanaged.passUnretained(kCFAllocatorSystemDefault).toOpaque()
        var connection = create(allocator, nil, nil)
        var allocatorNote = "kCFAllocatorSystemDefault"
        if connection == nil {
            connection = create(nil, nil, nil)
            allocatorNote = "NULL"
        }
        guard connection != nil else {
            log.log("私有 API·CTServerConnectionCreate 两次尝试（系统分配器/NULL）均返回空 ⇒ 判定不可用")
            return (nil, nil)
        }
        log.log("私有 API·CTServerConnection 创建成功（分配器=\(allocatorNote)）")
        return (connection, unsafeBitCast(setSym, to: SetCellularFn.self))
    }

    // MARK: - 开关

    /// 程序化设置蜂窝{{TERM_fsvsvmiy}}开关. `true` = 开，`false` = 关.
    /// C 调用内部可能阻塞（走 XPC），放到全局队列执行，不卡 MainActor.
    func setCellularEnabled(_ enabled: Bool) async throws {
        guard let connection = ctConnection, let setter = setCellularFunc else {
            throw ToggleError.privateAPIUnavailable
        }
        CellularLogStore.shared.log("私有 API·setCellularEnabled(\(enabled ? "开" : "关")) 调用中…")
        let code: Int32 = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: setter(connection, enabled))
            }
        }
        guard code == 0 else {
            CellularLogStore.shared.log("私有 API·SetCellularDataIsEnabled 返回 CTError \(code)")
            throw ToggleError.ctError(code)
        }
        CellularLogStore.shared.log("私有 API·已\(enabled ? "打开" : "关闭")蜂窝{{TERM_fsvsvmiy}}")
    }
}
