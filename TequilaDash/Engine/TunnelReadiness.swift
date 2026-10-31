//
//  TunnelReadiness.swift
//  TequilaDash
//
//  隧道就绪状态机（v0.3.726）—— 把「点一下功能 → 现场探测 3 秒 / 直连卡 4 分钟」
//  换成「后台持续探测 + 调用方读缓存」.
//
//  ## 为什么
//  用户主诉（2026-10-30）：依赖隧道的功能如果先前未打开 LocalDevVPN 就可能卡住
//  不能及时响应；期望**实时的、无需等待无延迟，一旦连接到隧道就能用**.
//  旧做法两头的亏：
//   - 隧道通着：安装链路现场预检 3 秒（IPAInstallService.tunnelProbeTimeoutSeconds），
//     纯粹白等 —— 预检结果 99% 是「通」；
//   - 隧道没起：没有预检的服务直进 Rust connect，os error 60 要挂 75 秒到 4 分 45 秒
//     （隧道日志 2026-10-30 15:27 TequilaDashProfiles 实测 75 秒）.
//
//  ## 结构（Swift 6 并发合规）
//  - `TunnelGate`：无隔离的线程安全缓存 + 同步闸门 `guardReady()` —— 供任意线程的
//    同步 `createTunnel()` 零等待调用；缓存说通 → 立刻放行，说不通 → 立刻抛人话错误
//    （并踢一次立即重探），绝不现场长探测.
//  - `TunnelReadiness`：@MainActor ObservableObject，后台 Task 常驻探测（不通 1.5 秒
//    一拍、通了 20 秒保活，NWPathMonitor 网络变化立即加拍），每拍把结论写回
//    `TunnelGate` 并发布到 `isReady` —— UI 之后要显示「隧道已就绪」直接观察它.
//

import Foundation
import Network

/// 隧道未就绪（后台探测结论 + 一次立即重探仍不通）.
struct TunnelReadinessError: LocalizedError {
    let ip: String
    let port: UInt16

    var errorDescription: String? {
        "隧道未就绪（\(ip):\(port) 探测不可达）. 连接回环工具后重试."
    }
}

/// 线程安全的隧道就绪缓存 + 同步闸门（建隧道前的唯一入口）.
enum TunnelGate {

    private static let lock = NSLock()
    private nonisolated(unsafe) static var ready = false

    /// 最近一次后台探测的结论（任意线程同步读，零等待）.
    static var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    static func setReady(_ value: Bool) {
        lock.lock()
        ready = value
        lock.unlock()
    }

    /// 建隧道前现场补探测的超时（失败路径 0.5 秒封顶，硬规则 29）.
    private static let probeTimeout: TimeInterval = 0.5

    /// 建隧道前的同步闸门：
    /// 缓存说通 → 放行（零等待，消除旧 3 秒预检）；说不通 → 现场补**一次** 0.5 秒权威探测
    /// （消除缓存 1.5 秒陈旧窗口的误报），仍不通 → 立即抛人话错误（代替旧的 75 秒～4 分 45 秒挂死）.
    static func guardReady() throws {
        if isReady { return }
        // 主线程探测器：谁在主线程同步建隧道，隧道日志立刻点名（HARD-RULES 29：
        // 主线程任何等待都是卡死；这里只记日志不拦截，修复责任在调用方）.
        if Thread.isMainThread {
            let frames = Thread.callStackSymbols.dropFirst(2).prefix(3).joined(separator: " <- ")
            TunnelDiagnostics.note("主线程隧道调用", frames.isEmpty ? "guardReady 在主线程同步等待" : frames)
        }
        let reachable = LocalDevVPN.isReachable(ip: LocalDevVPN.targetIP, timeout: probeTimeout, port: RemotePairingPort.current)
        if reachable {
            setReady(true)
            // 让 MainActor 侧的发布状态跟上（后台补一拍，不阻塞调用方）.
            Task { @MainActor in
                await TunnelReadiness.shared.probeOnce()
            }
            return
        }
        Task { @MainActor in
            await TunnelReadiness.shared.probeOnce()
        }
        throw TunnelReadinessError(ip: LocalDevVPN.targetIP, port: RemotePairingPort.current)
    }
}

@MainActor
final class TunnelReadiness: ObservableObject {

    nonisolated(unsafe) static let shared = TunnelReadiness()

    /// 后台探测的缓存结论（主线程发布；UI 可直接观察）.
    @Published private(set) var isReady: Bool = false
    /// 最近一次探测时间（诊断用）.
    @Published private(set) var lastCheckedAt: Date?
    /// 最近一次「不可达 → 可达」的翻转时刻.
    @Published private(set) var becameReadyAt: Date?

    private var started = false
    private var probeTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    /// 探测节奏：不通 1.5 秒一拍（尽快发现 VPN 起来），通 20 秒保活确认.
    private static let downInterval: TimeInterval = 1.5
    private static let upInterval: TimeInterval = 20.0
    /// 单次探测超时（非阻塞 connect + poll）.
    private static let probeTimeout: TimeInterval = 0.5

    /// nonisolated：`nonisolated(unsafe) static let shared = TunnelReadiness()` 的初始化
    /// 跑在非隔离上下文，@MainActor 隔离的 init 会让全文件编译失败（CI 124497181277 实锤）.
    private nonisolated init() {}

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        probeTask = Task.detached(priority: .utility) { [weak self] in
            await self?.probeLoop()
        }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            // 网络路径变化（VPN 建立/断开、Wi-Fi 切换）→ 立即重探.
            Task { @MainActor [weak self] in
                await self?.probeOnce()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.tequila.dash.tunnelreadiness.path"))
        TunnelDiagnostics.note("隧道就绪", "后台探测已启动（target=\(LocalDevVPN.targetIP):\(RemotePairingPort.current)）")
    }

    // MARK: - 探测

    /// 立即探测一次（socket 在后台线程跑，结论回主线程发布 + 写入 TunnelGate 缓存）.
    func probeOnce() async {
        let ip = LocalDevVPN.targetIP
        let port = RemotePairingPort.current
        let timeout = Self.probeTimeout
        let reachable = await Task.detached(priority: .utility) {
            LocalDevVPN.isReachable(ip: ip, timeout: timeout, port: port)
        }.value
        let now = Date()
        TunnelGate.setReady(reachable)
        lastCheckedAt = now
        if reachable && !isReady { becameReadyAt = now }
        if reachable != isReady {
            TunnelDiagnostics.note("隧道就绪", reachable
                ? "状态翻转：不可达 → 可达（\(ip):\(port)）"
                : "状态翻转：可达 → 不可达（\(ip):\(port)）")
        }
        isReady = reachable
    }

    private func probeLoop() async {
        while !Task.isCancelled {
            let before = isReady
            await probeOnce()
            // 状态翻转后的下一拍立即跟近（尽快把新结论钉住），否则按新节奏走.
            let interval = before == isReady ? (isReady ? Self.upInterval : Self.downInterval) : Self.downInterval
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}
