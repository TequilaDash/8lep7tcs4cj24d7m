//
//  RemotePairingPort.swift
//  TequilaDash
//
//  RPPairing 通道解析（端口 + 直连端点；iOS 27.2 起端口不再保证是 49152）
//
//  背景：iOS 26 / 27 早期，设备端 Remote Pairing 服务一直固定 49152，全仓二十余处
//  建隧道代码把数字写死。iOS 27.2 起这个假设不再成立（上游 StikDebug 的修法是用
//  Bonjour 发现 _remotepairing._tcp，取不到才回落 49152），继续写死会让所有依赖
//  配对连接的功能整体连不上，而用户看到的只是「隧道建不起来」。
//
//  本文件负责两件事：
//    1. 给出当前该用的端口。调用点一律写 RemotePairingPort.current，不要自己再写数字。
//    2. v0.3.769（Gnoix 取证对齐）：直连端点 = 回环 127.0.0.1 + Bonjour 发现的 RSD 端口。
//       Gnoix 二进制取证实锤（gnoix_strings.txt）：「Endpoint = 127.0.0.1:0」
//       「muxer.rs 127.0.0.1 Starting listener」——它连的是设备自己的回环地址，
//       不经任何 utun，蜂窝下照样通（回环 TCP 不需要本地网络权限）。
//
//  直连通道纯事件驱动（用户硬规则：零延迟、禁轮询、禁墙钟新鲜窗）：
//    正向事件打戳：Bonjour 解析出端口（服务在）、probeDirectEndpoint 探测通过；
//    反向事件清戳：探测失败、Bonjour 解析超时（服务消失）、网络路径变化
//    （NWPathMonitor，清完立即重解析）、隧道建立失败（invalidate）。
//
//  端口解析三级，任何一级失败都退回 49152（与旧行为完全一致，因此不会比现在更差）：
//    1. 用户手动覆盖（UserDefaults 键 rppairing.portOverride）
//    2. Bonjour 发现 _remotepairing._tcp. / _remoted._tcp.（结果缓存 60 秒）
//    3. 49152
//
//  关键约束：current 绝不同步等待网络。Bonjour 解析最长 5 秒，而所有调用点都在同步
//  构造 sockaddr 的路径上，卡在这里会钉住主线程。因此解析在后台线程跑，结果写进缓存，
//  current 只读缓存。缓存过期时 current 顺手踢一次后台解析，下一次调用就能拿到新端口。
//  对用户的表现是「第一次可能还是 49152，重试一次就对了」。
//
//  解析实现参考 StikDebug 的 RemotePairingPortResolver 与 SideStore 的
//  MinimuxerWrapper.resolveDiscoveredRemotePairingPort（同一套 Bonjour 服务类型与
//  回落策略），按本仓的线程模型重写：那边是同步解析后立刻建连，这边必须缓存。
//

import Darwin
import Foundation
import Network

enum RemotePairingPort {

    /// 旧行为端口，也是所有解析失败时的回落值。
    static let fallback: UInt16 = 49152

    /// 手动覆盖键。留空表示不覆盖。
    static let overrideDefaultsKey = "rppairing.portOverride"
    /// 解析结果回写键，供 ObjC 侧 TDRPPairingPort() 读取。
    static let resolvedDefaultsKey = "rppairing.resolvedPort"
    /// Bonjour 最近解析出的设备自身 IPv4（直连候选，持久化跨启动）。
    static let directIPDefaultsKey = "rppairing.directIP"
    /// 直连端点主机（当前恒为回环 127.0.0.1），与 directIPAt 成对读写（ObjC 候选链读）。
    static let directHostDefaultsKey = "rppairing.directHost"
    /// 直连戳：最近一次正向事件的 epoch 秒（>0 = 直连端点可用；0 = 不可用）。
    static let directIPAtDefaultsKey = "rppairing.directIPAt"

    /// Bonjour 同时浏览两型：_remotepairing._tcp 是经典服务名，_remoted._tcp 是
    /// iOS 17+ remoted 守护进程的新名（Gnoix RemotePairingPortDiscoverer 同款双浏览）。
    fileprivate static let serviceTypes = ["_remotepairing._tcp.", "_remoted._tcp."]
    fileprivate static let bonjourDomain = "local."
    private static let cacheTTL: TimeInterval = 60
    private static let browseTimeout: TimeInterval = 5
    /// 直连端点：Gnoix 取证定案——设备自身的回环地址（设备上的 App 连本机 RSD 就走 127.0.0.1）.
    static let loopbackHost = "127.0.0.1"

    private static let stateLock = NSLock()
    // 下面四项全部只在 stateLock 内读写。Swift 6 的并发检查看不到锁，
    // 会按「nonisolated 可变全局状态」报错，因此显式标 nonisolated(unsafe)。
    nonisolated(unsafe) private static var cachedPort: UInt16?
    nonisolated(unsafe) private static var cachedAt: Date?
    nonisolated(unsafe) private static var lastSource = "未解析"
    nonisolated(unsafe) private static var resolving = false
    nonisolated(unsafe) private static var pathMonitor: NWPathMonitor?
    nonisolated(unsafe) private static var pathMonitorStarted = false

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
        let direct = freshDirectIPCandidate.map { "，直连 \($0)" } ?? ""
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let port = cachedPort else { return "\(fallback)（回落，尚未解析成功）\(direct)" }
        return "\(port)（\(lastSource)\(direct)）"
    }

    /// 提前解析一次，不阻塞调用方。App 启动与 VPN 连上时各调一次即可。
    static func warmUp() {
        startPathMonitorIfNeeded()
        kickResolveIfIdle()
    }

    /// 作废端口缓存。隧道建立失败后调用，下一次 current 会重新解析。
    /// 同时清直连戳（反向事件：连不上 → 直连端点视为不可用）.
    static func invalidate() {
        stateLock.lock()
        cachedAt = nil
        stateLock.unlock()
        clearDirect(reason: "隧道建立失败")
    }

    /// 同步解析一次（最长约 timeout + 1 秒）。只给诊断页这类可以等的路径用，
    /// 不要在构造 sockaddr 的同步路径上调。
    @discardableResult
    static func resolveNow(timeout: TimeInterval = browseTimeout) -> UInt16 {
        if let manual = manualOverride {
            record(port: manual, ip: nil, source: "手动覆盖")
            return manual
        }
        let result = discover(timeout: timeout)
        record(port: result.port, ip: result.ip, source: result.source)
        return result.port
    }

    // MARK: - 直连通道（v0.3.768 Gnoix 对齐）

    /// Bonjour 最近解析出的设备自身 IPv4（合法、非回环才返回）。
    static var discoveredIP: String? {
        let raw = (UserDefaults.standard.string(forKey: directIPDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidIPv4(raw), !raw.hasPrefix("127."), !raw.hasPrefix("0.") else { return nil }
        return raw
    }

    /// 直连候选（纯事件驱动）：直连戳存在 → 返回回环端点；否则 nil。
    /// 调用方拿去建连绝不落空挂死（Rust 首个 connect 无超时，戳不在绝不给候选）.
    static var freshDirectIPCandidate: String? {
        let at = UserDefaults.standard.double(forKey: directIPAtDefaultsKey)
        guard at > 0 else { return nil }
        let host = (UserDefaults.standard.string(forKey: directHostDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? loopbackHost : host
    }

    /// 直连探测：回环端点 + 当前端口，带超时上限（默认 0.5s）。
    /// 通过 → 打戳（正向事件）；失败 → 清戳（反向事件）。
    /// 这是唯一判定「直连现在可用」的入口，TunnelGate / 建连候选链全看这个戳.
    @discardableResult
    static func probeDirectEndpoint(timeout: TimeInterval = 0.5) -> Bool {
        let ok = LocalDevVPN.isReachable(ip: loopbackHost, timeout: timeout, port: current)
        if ok {
            stampDirect(source: "直连探测")
        } else {
            clearDirect(reason: "直连探测未通过")
        }
        return ok
    }

    /// 诊断用：最近一次解析来源（Bonjour / 手动覆盖 / 回落 / 未解析）.
    static var lastSourceDescription: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastSource
    }

    /// 正向事件打戳（Bonjour 解析成功 / 直连探测通过）.
    private static func stampDirect(source: String) {
        let defs = UserDefaults.standard
        let wasDown = defs.double(forKey: directIPAtDefaultsKey) <= 0
        defs.set(loopbackHost, forKey: directHostDefaultsKey)
        defs.set(Date().timeIntervalSince1970, forKey: directIPAtDefaultsKey)
        if wasDown {
            TunnelDiagnostics.note("直连通道", "回环端点可用（\(loopbackHost):\(current)，\(source)）")
        }
    }

    /// 反向事件清戳（探测失败 / 解析超时 / 网络路径变化 / 隧道建立失败）.
    private static func clearDirect(reason: String) {
        let defs = UserDefaults.standard
        guard defs.double(forKey: directIPAtDefaultsKey) > 0 else { return }
        defs.set(0, forKey: directIPAtDefaultsKey)
        defs.removeObject(forKey: directHostDefaultsKey)
        TunnelDiagnostics.note("直连通道", "回环端点戳已清（\(reason)）")
    }

    /// 网络路径变化事件（NWPathMonitor）：清直连戳 → 作废端口缓存 → 立即重解析.
    /// 纯事件驱动：路径不变就不动，无任何轮询.
    private static func startPathMonitorIfNeeded() {
        stateLock.lock()
        if pathMonitorStarted { stateLock.unlock(); return }
        pathMonitorStarted = true
        stateLock.unlock()
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { _ in
            clearDirect(reason: "网络路径变化")
            invalidate()
            kickResolveIfIdle()
        }
        monitor.start(queue: DispatchQueue(label: "com.tequila.dash.rppairing.path"))
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
            record(port: result.port, ip: result.ip, source: result.source)
        }
    }

    private static func record(port: UInt16, ip: String?, source: String) {
        stateLock.lock()
        cachedPort = port
        cachedAt = Date()
        lastSource = source
        resolving = false
        stateLock.unlock()
        // 同步一份给 ObjC（TunnelContext.m 的 TDRPPairingPort 从这两个键读，
        // 见该文件顶部注释：.m 不引 Swift 生成头，改用 UserDefaults 传值）.
        UserDefaults.standard.set(Int(port), forKey: resolvedDefaultsKey)
        // 直连戳事件：Bonjour 解析成功 = 服务在（正向打戳）；解析失败回落 = 服务消失（清戳）.
        if source == "Bonjour" {
            stampDirect(source: "Bonjour")
        } else if source == "回落" {
            clearDirect(reason: "Bonjour 未发现服务")
        }
        if let ip {
            let previous = UserDefaults.standard.string(forKey: directIPDefaultsKey)
            UserDefaults.standard.set(ip, forKey: directIPDefaultsKey)
            if previous != ip {
                TunnelDiagnostics.note("直连通道", "Bonjour 解析设备 IP \(ip):\(port)（\(source)）")
            }
        }
        TunnelDiagnostics.note("配对端口", "\(port)（\(source)）")
    }

    /// 在后台线程上跑一次 Bonjour 发现。返回端口、设备 IP 与来源。
    private static func discover(timeout: TimeInterval) -> (port: UInt16, ip: String?, source: String) {
        let worker = BonjourPortWorker()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            worker.search(timeout: timeout)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout + 1) == .success, let port = worker.resolvedPort else {
            return (fallback, nil, "回落")
        }
        return (port, worker.resolvedIP, "Bonjour")
    }

    private static func isValidIPv4(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var addr = in_addr()
        return s.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    /// 从 NetService.addresses（sockaddr 打包 Data）提取第一个非回环 IPv4。
    /// 供本文件 Bonjour 解析与「网络发现」页共用.
    static func ipv4Address(of service: NetService) -> String? {
        guard let datas = service.addresses else { return nil }
        for data in datas where data.count >= MemoryLayout<sockaddr_in>.size {
            var sin = sockaddr_in()
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let src = raw.baseAddress else { return }
                withUnsafeMutableBytes(of: &sin) { dest in
                    memcpy(dest.baseAddress!, src, MemoryLayout<sockaddr_in>.size)
                }
            }
            guard sin.sin_family == sa_family_t(AF_INET) else { continue }
            var inAddr = sin.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString: buf)
            if !ip.hasPrefix("127."), !ip.hasPrefix("0.") { return ip }
        }
        return nil
    }
}

/// NetServiceBrowser 的回调要求有 run loop，这里在后台线程上手动泵。
private final class BonjourPortWorker: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {

    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    private(set) var resolvedPort: UInt16?
    private(set) var resolvedIP: String?

    func search(timeout: TimeInterval) {
        browsers = RemotePairingPort.serviceTypes.map { type in
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.schedule(in: .current, forMode: .default)
            browser.searchForServices(ofType: type, inDomain: RemotePairingPort.bonjourDomain)
            return browser
        }
        let deadline = Date().addingTimeInterval(timeout)
        // Date 比较改比 Double 时间戳（守卫 swift_date_compare_guard.py：beta 上 >=/<= 是 weak import）.
        while resolvedPort == nil,
              Date().timeIntervalSinceReferenceDate < deadline.timeIntervalSinceReferenceDate {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        browsers.forEach { $0.stop() }
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
        if resolvedIP == nil, let ip = RemotePairingPort.ipv4Address(of: sender) {
            resolvedIP = ip
        }
    }
}
