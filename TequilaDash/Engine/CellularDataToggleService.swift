//
//  CellularDataToggleService.swift
//  TequilaDash
//
//  照 Gnoix 1.2.15 的蜂窝开关链路逆向/反编译后重写移植.
//  真机取证（盘上 tunnellog 15:51:39）—— 初始化链路全绿，但 setter 一调用
//  即被系统拒绝（关/开均 CTError 2）⇒ 新增三件事：
//    1. 调用变体探测：首个 CTError 时一次性试遍「整型参数 / 主线程调用」，首个返回 0 的
//       变体本会话缓存胜出（排查调用方式/参数类型是否是变量；若属系统权限拒绝，全部变体
//    2. 极性别名：个别系统版本 setter 的布尔语义可能与预期相反，manager 以真实断网/恢复
//       联网实测校准后翻转并持久化（TequilaDash.CellularTogglePolarityInverted）.
//    3. 写入权限状态 @Published：支持页「私有开关 API」行下如实展示（受理/拒绝/不可用）.
//
//  · dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony")
//  · dlsym("_CTServerConnectionCreate") → 建一个 CTServerConnection
//  · dlsym("_CTServerConnectionSetCellularDataIsEnabled") → 程序化开关蜂窝{{TERM_fsvsvmiy}}
//  任一步失败 ⇒ `isPrivateAPIAvailable == false`，调用方（CellularTunnelManager）
//  自动回落快捷指令路径（的引导自建快捷指令链路原样保留，作为降级面）.
//

import Foundation
import Darwin

final class CellularDataToggleService: ObservableObject, @unchecked Sendable {
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
    /// init 期定死不再变（let），async 读侧无需加锁——
    /// NSLock.lock() 在 async 上下文不可用（CI 实锤），let 是最省事的正确解.
    private let ctConnection: OpaquePointer?
    /// `_CTServerConnectionSetCellularDataIsEnabled(connection, enabled) -> CTError`（Bool 版）.
    private let setCellularFunc: SetCellularFn?
    /// 同一符号的 Int32 版（boolean_t 疑似为 int；Bool 版被拒时换参类型再试）.
    private let setCellularFuncInt: SetCellularFnInt?

    /// 调用变体（首个 CTError 时一次性探遍，首个返回 0 的胜出并缓存本会话）.
    private enum CallVariant: String {
        case standardBool = "标准(Bool参数)"
        case intArg = "整型参数"
        case mainThread = "主线程调用"
    }

    /// 变体探测一次性标记 + 胜出变体（probeLock 保护；写入后只读）.
    private var probedVariants = false
    private var bestVariant: CallVariant = .standardBool
    private let probeLock = NSLock()

    /// 极性别名：个别系统版本 setter 的布尔语义可能与预期相反（传 false 反而开启）.
    /// manager 以「真实断网/恢复联网」实测校准后翻转，结果持久化，下次直接用对的语义.
    private static let polarityKey = "TequilaDash.CellularTogglePolarityInverted"
    var polarityInverted: Bool {
        get { UserDefaults.standard.bool(forKey: Self.polarityKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.polarityKey)
            CellularLogStore.shared.log(
                "蜂窝开关极性别名\(newValue ? "已翻转（bool 语义与预期相反）" : "已还原为默认语义")")
        }
    }

    /// 私有开关「写入权限」状态（支持页如实展示；探测/实测后更新）.
    @Published private(set) var privateStatusText: String

    private typealias CreateFn = @convention(c) (
        UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?
    ) -> OpaquePointer?
    private typealias SetCellularFn = @convention(c) (OpaquePointer?, Bool) -> Int32
    private typealias SetCellularFnInt = @convention(c) (OpaquePointer?, Int32) -> Int32

    private init() {
        // 全链分步日志进 CellularLogStore（镜像 LoginLogger）——
        // 「为什么没走私有 API」在日志面板里一眼可见.
        CellularLogStore.shared.log("蜂窝开关服务初始化：探测私有 CoreTelephony API…")
        let setup = Self.setupPrivateCoreTelephony()
        self.ctConnection = setup.connection
        self.setCellularFunc = setup.setterBool
        self.setCellularFuncInt = setup.setterInt
        self.isPrivateAPIAvailable = setup.connection != nil && setup.setterBool != nil
        switch isPrivateAPIAvailable {
        case true:
            self.privateStatusText = "写入权限未实测（首次调用后更新）"
            CellularLogStore.shared.log(
                "私有 CoreTelephony 蜂窝开关 API 就绪（_CTServerConnectionCreate + SetCellularDataIsEnabled）")
        case false:
            self.privateStatusText = "不可用：蜂窝开关将走快捷指令路径"
            CellularLogStore.shared.log(
                "私有 CoreTelephony 蜂窝开关 API 不可用：蜂窝开关将走快捷指令路径")
        }
    }


    private static func setupPrivateCoreTelephony()
        -> (connection: OpaquePointer?, setterBool: SetCellularFn?, setterInt: SetCellularFnInt?) {
        let log = CellularLogStore.shared
        let path = "/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony"
        guard let handle = dlopen(path, RTLD_NOW) else {
            log.log("私有 API·dlopen 失败：\(String(cString: dlerror()))")
            return (nil, nil, nil)
        }
        log.log("私有 API·dlopen 成功")
        guard let createSym = dlsym(handle, "_CTServerConnectionCreate") else {
            log.log("私有 API·dlsym(_CTServerConnectionCreate) 失败")
            return (nil, nil, nil)
        }
        guard let setSym = dlsym(handle, "_CTServerConnectionSetCellularDataIsEnabled") else {
            log.log("私有 API·dlsym(_CTServerConnectionSetCellularDataIsEnabled) 失败")
            return (nil, nil, nil)
        }
        log.log("私有 API·两个私有符号齐全")
        let create = unsafeBitCast(createSym, to: CreateFn.self)

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
            return (nil, nil, nil)
        }
        log.log("私有 API·CTServerConnection 创建成功（分配器=\(allocatorNote)）")
        // 同一符号按两种参数类型各落一个具名指针（dlsym 原始指针直接 cast，避免函数值互转）.
        let setterBool = unsafeBitCast(setSym, to: SetCellularFn.self)
        let setterInt = unsafeBitCast(setSym, to: SetCellularFnInt.self)
        return (connection, setterBool, setterInt)
    }

    // MARK: - 状态发布

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.privateStatusText = text }
    }

    // MARK: - 极性别名换算

    private func wireBool(_ enabled: Bool) -> Bool {
        polarityInverted ? !enabled : enabled
    }

    private func wireInt(_ enabled: Bool) -> Int32 {
        wireBool(enabled) ? 1 : 0
    }

    // MARK: - 开关

    /// 程序化设置蜂窝{{TERM_fsvsvmiy}}开关. `true` = 开，`false` = 关.
    /// C 调用内部可能阻塞（走 XPC），放到全局队列执行，不卡 MainActor.
    /// 返回 0 ≠ 蜂窝真的变了 —— 真实效果由 manager 以断网/恢复联网实测判定.
    func setCellularEnabled(_ enabled: Bool) async throws {
        guard let connection = ctConnection, let setter = setCellularFunc else {
            throw ToggleError.privateAPIUnavailable
        }
        CellularLogStore.shared.log("私有 API·setCellularEnabled(\(enabled ? "开" : "关")) 调用中…")
        let code: Int32 = try await invokeBest(enabled, connection: connection, setter: setter)
        guard code == 0 else {
            CellularLogStore.shared.log("私有 API·SetCellularDataIsEnabled 返回 CTError \(code)")
            // 首次被拒：一次性探遍调用变体（结果本会话缓存）；胜出则用胜出变体重打本次请求.
            if !probedVariants, let v = await probeVariantsOnce(initialCode: code) {
                bestVariant = v
                setStatus("写入已被系统受理（调用变体=\(v.rawValue)），真实效果以断网/恢复实测为准")
                let retry = try await invokeWithVariant(v, enabled: enabled)
                guard retry == 0 else {
                    CellularLogStore.shared.log("胜出变体重试仍返回 CTError \(retry)，按失败处理")
                    throw ToggleError.ctError(retry)
                }
                CellularLogStore.shared.log(
                    "私有 API·已\(enabled ? "打开" : "关闭")蜂窝{{TERM_fsvsvmiy}}（变体=\(v.rawValue)）")
                return
            }
            throw ToggleError.ctError(code)
        }
        CellularLogStore.shared.log("私有 API·已\(enabled ? "打开" : "关闭")蜂窝{{TERM_fsvsvmiy}}")
    }

    /// 走当前胜出变体（未探测前 = 标准路径，保持 行为）.
    private func invokeBest(
        _ enabled: Bool, connection: OpaquePointer?, setter: SetCellularFn?
    ) async throws -> Int32 {
        if probedVariants {
            return try await invokeWithVariant(bestVariant, enabled: enabled)
        }
        guard let c = connection, let f = setter else { throw ToggleError.privateAPIUnavailable }
        let wire = wireBool(enabled)
        return try await callOnUserQueue { f(c, wire) }
    }

    /// 同步领取探测资格（NSLock.lock/unlock 禁止在 async 上下文直调，收进同步函数）.
    /// - Returns: `true` = 本调用是探测者；`false` = 已有人探测过（或正在探测）.
    private func claimProbeSlot() -> Bool {
        probeLock.lock()
        defer { probeLock.unlock() }
        if probedVariants { return false }
        probedVariants = true
        return true
    }

    /// 变体探测（一次性；probeLock 防并发重入）.
    private func probeVariantsOnce(initialCode: Int32) async -> CallVariant? {
        guard claimProbeSlot() else { return nil }
        CellularLogStore.shared.log("变体探测：系统拒绝（CTError \(initialCode)），一次性试遍调用变体（结果本会话缓存）…")
        for v in [CallVariant.intArg, .mainThread] {
            do {
                let c = try await invokeWithVariant(v, enabled: true)
                CellularLogStore.shared.log("变体探测·\(v.rawValue) → \(c == 0 ? "返回 0（受理）" : "CTError \(c)")")
                if c == 0 { return v }
            } catch {
                CellularLogStore.shared.log("变体探测·\(v.rawValue) → 异常：\(error.localizedDescription)")
            }
        }
        CellularLogStore.shared.log("变体探测：全部变体均被系统拒绝（普通自签沙盒缺少 CommCenter 特权凭证，Gnoix 同款被拒）")
        setStatus("私有开关被系统拒绝（CTError \(initialCode)，普通自签沙盒缺少 CommCenter 特权凭证）")
        return nil
    }

    private func invokeWithVariant(_ v: CallVariant, enabled: Bool) async throws -> Int32 {
        switch v {
        case .standardBool:
            guard let c = ctConnection, let f = setCellularFunc else {
                throw ToggleError.privateAPIUnavailable
            }
            let wire = wireBool(enabled)
            return try await callOnUserQueue { f(c, wire) }
        case .intArg:
            guard let c = ctConnection, let f = setCellularFuncInt else {
                throw ToggleError.privateAPIUnavailable
            }
            let wire = wireInt(enabled)
            return try await callOnUserQueue { f(c, wire) }
        case .mainThread:
            guard let c = ctConnection, let f = setCellularFunc else {
                throw ToggleError.privateAPIUnavailable
            }
            let wire = wireBool(enabled)
            // @Sendable 闭包不能直捕非 Sendable 的 @convention(c) 函数值（RegionIsolation，CI 实锤）——
            // 装进 @unchecked Sendable 信箱搬运，语义不变：仍在主线程调用一次.
            let box = MainCallBox(c: c, f: f, wire: wire)
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.main.async { continuation.resume(returning: box.fire()) }
            }
        }
    }

    /// 跨隔离域搬运私有 C 指针的一次性信箱.
    private final class MainCallBox: @unchecked Sendable {
        let c: OpaquePointer?
        let f: SetCellularFn
        let wire: Bool
        init(c: OpaquePointer?, f: SetCellularFn, wire: Bool) {
            self.c = c
            self.f = f
            self.wire = wire
        }
        func fire() -> Int32 { f(c, wire) }
    }

    private func callOnUserQueue(_ body: @escaping () -> Int32) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: body())
            }
        }
    }
}