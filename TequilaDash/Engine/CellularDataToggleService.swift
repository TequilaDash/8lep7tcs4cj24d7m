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
        let setup = Self.setupPrivateCoreTelephony()
        self.ctConnection = setup.connection
        self.setCellularFunc = setup.setter
        self.isPrivateAPIAvailable = setup.connection != nil && setup.setter != nil
        LoginLogger.shared.log(
            isPrivateAPIAvailable
                ? "[Cellular] 私有 CoreTelephony 蜂窝开关 API 就绪（Gnoix 同款 _CTServerConnectionCreate + SetCellularDataIsEnabled）"
                : "[Cellular] 私有 CoreTelephony 蜂窝开关 API 不可用，蜂窝开关走快捷指令路径",
            category: .tunnelCellular)
    }

    // MARK: - 私有 API 探测（Gnoix setupPrivateCoreTelephony 同职责）

    private static func setupPrivateCoreTelephony()
        -> (connection: OpaquePointer?, setter: SetCellularFn?) {
        let path = "/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony"
        guard let handle = dlopen(path, RTLD_NOW) else {
            return (nil, nil)
        }
        guard let createSym = dlsym(handle, "_CTServerConnectionCreate"),
              let setSym = dlsym(handle, "_CTServerConnectionSetCellularDataIsEnabled") else {
            return (nil, nil)
        }
        let create = unsafeBitCast(createSym, to: CreateFn.self)

        // Gnoix 传的是 kCFAllocatorSystemDefault（GOT 槽解引用）；公开片段常见传 NULL.
        // 两种都试，先系统分配器后 NULL.
        let allocator = Unmanaged.passUnretained(kCFAllocatorSystemDefault).toOpaque()
        var connection = create(allocator, nil, nil)
        if connection == nil {
            connection = create(nil, nil, nil)
        }
        guard connection != nil else {
            return (nil, nil)
        }
        let setter = unsafeBitCast(setSym, to: SetCellularFn.self)
        return (connection, setter)
    }

    // MARK: - 开关

    /// 程序化设置蜂窝{{TERM_fsvsvmiy}}开关. `true` = 开，`false` = 关.
    /// C 调用内部可能阻塞（走 XPC），放到全局队列执行，不卡 MainActor.
    func setCellularEnabled(_ enabled: Bool) async throws {
        guard let connection = ctConnection, let setter = setCellularFunc else {
            throw ToggleError.privateAPIUnavailable
        }
        let code: Int32 = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: setter(connection, enabled))
            }
        }
        guard code == 0 else {
            LoginLogger.shared.log(
                "[Cellular] SetCellularDataIsEnabled(\(enabled)) 返回 CTError \(code)",
                category: .tunnelCellular)
            throw ToggleError.ctError(code)
        }
        LoginLogger.shared.log(
            "[Cellular] 私有 API 已\(enabled ? "打开" : "关闭")蜂窝{{TERM_fsvsvmiy}}",
            category: .tunnelCellular)
    }
}
