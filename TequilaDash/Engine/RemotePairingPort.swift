//
//  RemotePairingPort.swift
//  TequilaDash
//
//  RPPairing 隧道端口解析（iOS 27.2 起不再保证是 49152）
//
//  背景：iOS 26 / 27 早期，设备端 Remote Pairing 服务一直监听 49152，全仓二十余处
//  建隧道代码把数字写死。iOS 27.2 起这个假设不再成立（上游 StikDebug 的修法是用
//  Bonjour 发现 _remotepairing._tcp，取不到才回落 49152），继续写死会让所有依赖
//  配对连接的功能整体连不上，而用户看到的只是「隧道建不起来」。
//
//  本文件只负责一件事：给出当前该用的端口。调用点一律写 RemotePairingPort.current，
//  不要自己再写数字。
//
//  解析三级，任何一级失败都退回 49152（与旧行为完全一致，因此不会比现在更差）：
//    1. 用户手动覆盖（UserDefaults 键 rppairing.portOverride）
//    2. Bonjour 发现 _remotepairing._tcp.（结果缓存 60 秒）
//    3. 49152
//
//  关键约束：current 绝不同步等待网络。Bonjour 解析最长 5 秒，而所有调用点都在同步
//  构造 sockaddr 的路径上，卡在这里会钉住主线程。因此解析在后台线程跑，结果写进缓存，
//  current 只读缓存。缓存过期时 current 顺手踢一次后台解析，下一次调用就能拿到新端口。
//  对用户的表现是「第一次可能还是 49152，重试一次就对了」。
//
//  解析实现参考 StikDebug 的 RemotePairingPortResolver（同一条 Bonjour 服务类型与
//  回落策略），按本仓的线程模型重写：那边是同步解析后立刻建连，这边必须缓存。
//

import Foundation

enum RemotePairingPort {

    /// 旧行为端口，也是所有解析失败时的回落值。
    static let fallback: UInt16 = 49152

    /// 手动覆盖键。留空表示不覆盖。
    static let overrideDefaultsKey = "rppairing.portOverride"
    /// 解析结果回写键，供 ObjC 侧 TDRPPairingPort() 读取。
    static let resolvedDefaultsKey = "rppairing.resolvedPort"

    fileprivate static let bonjourType = "_remotepairing._tcp."
    fileprivate static let bonjourDomain = "local."
    private static let cacheTTL: TimeInterval = 60
    private static let browseTimeout: TimeInterval = 5

    private static let stateLock = NSLock()
    // 下面四项全部只在 stateLock 内读写。Swift 6 的并发检查看不到锁，
    // 会按「nonisolated 可变全局状态」报错，因此显式标 nonisolated(unsafe)。
    nonisolated(unsafe) private static var cachedPort: UInt16?
    nonisolated(unsafe) private static var cachedAt: Date?
    nonisolated(unsafe) private static var lastSource = "未解析"
    nonisolated(unsafe) private static var resolving = false

    // MARK: - 对外

    /// 用户在设置里填的手动端口。非法值一律忽略。
    static var manualOverride: UInt16? {
        let raw = (UserDefaults.standard.string(forKey: overrideDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let value = UInt16(raw), value != 0 else { return nil }
        return value
    }

    /// 当前该用的端口。同步返回，永不阻塞。
    static var current: UInt16 {
        if let manual = manualOverride { return manual }
        stateLock.lock()
        let port = cachedPort
        let age = cachedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        stateLock.unlock()
        if age > cacheTTL { kickResolveIfIdle() }
        return port ?? fallback
    }

    /// 诊断用：当前端口从哪来。
    static var summary: String {
        if let manual = manualOverride { return "\(manual)（手动覆盖）" }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let port = cachedPort else { return "\(fallback)（回落，尚未解析成功）" }
        return "\(port)（\(lastSource)）"
    }

    /// 提前解析一次，不阻塞调用方。App 启动与 VPN 连上时各调一次即可。
    static func warmUp() {
        kickResolveIfIdle()
    }

    /// 作废缓存。隧道建立失败后调用，下一次 current 会重新解析。
    static func invalidate() {
        stateLock.lock()
        cachedAt = nil
        stateLock.unlock()
    }

    /// 同步解析一次（最长约 timeout + 1 秒）。只给诊断页这类可以等的路径用，
    /// 不要在构造 sockaddr 的同步路径上调。
    @discardableResult
    static func resolveNow(timeout: TimeInterval = browseTimeout) -> UInt16 {
        if let manual = manualOverride {
            record(port: manual, source: "手动覆盖")
            return manual
        }
        let result = discover(timeout: timeout)
        record(port: result.port, source: result.source)
        return result.port
    }

    // MARK: - 内部

    private static func kickResolveIfIdle() {
        if manualOverride != nil { return }
        stateLock.lock()
        if resolving { stateLock.unlock(); return }
        resolving = true
        stateLock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let result = discover(timeout: browseTimeout)
            record(port: result.port, source: result.source)
        }
    }

    private static func record(port: UInt16, source: String) {
        stateLock.lock()
        cachedPort = port
        cachedAt = Date()
        lastSource = source
        resolving = false
        stateLock.unlock()
        // 同步一份给 ObjC（TunnelContext.m 的 TDRPPairingPort 从这两个键读，
        // 见该文件顶部注释：.m 不引 Swift 生成头，改用 UserDefaults 传值）.
        UserDefaults.standard.set(Int(port), forKey: resolvedDefaultsKey)
        TunnelDiagnostics.note("配对端口", "\(port)（\(source)）")
    }

    /// 在后台线程上跑一次 Bonjour 发现。返回端口与来源。
    private static func discover(timeout: TimeInterval) -> (port: UInt16, source: String) {
        let worker = BonjourPortWorker()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            worker.search(timeout: timeout)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout + 1) == .success, let port = worker.resolvedPort else {
            return (fallback, "回落")
        }
        return (port, "Bonjour")
    }
}

/// NetServiceBrowser 的回调要求有 run loop，这里在后台线程上手动泵。
private final class BonjourPortWorker: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private(set) var resolvedPort: UInt16?

    func search(timeout: TimeInterval) {
        browser.delegate = self
        browser.schedule(in: .current, forMode: .default)
        browser.searchForServices(ofType: RemotePairingPort.bonjourType,
                                  inDomain: RemotePairingPort.bonjourDomain)
        let deadline = Date().addingTimeInterval(timeout)
        while resolvedPort == nil && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        browser.stop()
        services.forEach { $0.stop() }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 4)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if (1...65535).contains(sender.port), resolvedPort == nil {
            resolvedPort = UInt16(sender.port)
        }
    }
}
