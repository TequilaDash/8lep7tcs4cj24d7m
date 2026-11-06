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
//  - `TunnelReadiness`：@MainActor ObservableObject，纯事件驱动（v0.3.769，用户硬规则：
//    零延迟、禁轮询）—— 网络路径变化、回前台、guardReady 按需补探三类事件触发
//    probeOnce，结论写回 `TunnelGate` 并发布到 `isReady`，无任何后台常驻循环.
//

import Foundation
import Network
import UIKit

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
        // v0.3.768（Gnoix 对齐）：utun 对端不通再探设备直连通道（各 0.5s 上限）.
        let reachable = LocalDevVPN.isChannelReachable(timeout: probeTimeout)
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
    private var pathMonitor: NWPathMonitor?
    /// 最近一次探测是否走了直连通道（状态翻转时才记日志）.
    private var lastProbeWasDirect = false
    /// 单次探测超时（非阻塞 connect + poll）.
    private static let probeTimeout: TimeInterval = 0.5

    /// nonisolated：`nonisolated(unsafe) static let shared = TunnelReadiness()` 的初始化
    /// 跑在非隔离上下文，@MainActor 隔离的 init 会让全文件编译失败（CI 124497181277 实锤）.
    private nonisolated init() {}

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            // 网络路径变化（VPN 建立/断开、Wi-Fi 切换、蜂窝开关）→ 立即重探.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.probeOnce()
                // v0.3.766（Gnoix 对齐）：网络恢复而隧道仍不可达 ⇒ 事件驱动拉起重建.
                self.rebuildTunnelIfNeeded(networkSatisfied: path.status == .satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.tequila.dash.tunnelreadiness.path"))
        // 事件二：App 回前台 → 立即重探（后台期间网络可能已变，UI 不能拿旧结论）.
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.probeOnce()
            }
        }
        TunnelDiagnostics.note("隧道就绪", "事件驱动探测已启动（target=\(LocalDevVPN.targetIP):\(RemotePairingPort.current)）")
    }

    // MARK: - 探测

    /// 立即探测一次（socket 在后台线程跑，结论回主线程发布 + 写入 TunnelGate 缓存）.
    func probeOnce() async {
        let ip = LocalDevVPN.targetIP
        let port = RemotePairingPort.current
        let timeout = Self.probeTimeout
        // v0.3.768（Gnoix 对齐）：先探 utun 对端（既有判据），不通再探设备直连通道
        // （Bonjour 解析的设备自身 IP + RSD 端口）——蜂窝下 LocalDevVPN 隧道死透，
        // RSD 监听设备所有网卡仍可直连；iOS 只限制应用连 127.0.0.1 回环，不限自身网卡.
        let utunReachable = await Task.detached(priority: .utility) {
            LocalDevVPN.isReachable(ip: ip, timeout: timeout, port: port)
        }.value
        var reachable = utunReachable
        var viaDirect = false
        if !utunReachable {
            viaDirect = await Task.detached(priority: .utility) {
                RemotePairingPort.probeDirectEndpoint(timeout: timeout)
            }.value
            reachable = viaDirect
        }
        let now = Date()
        TunnelGate.setReady(reachable)
        lastCheckedAt = now
        if reachable && !isReady { becameReadyAt = now }
        if reachable != isReady {
            TunnelDiagnostics.note("隧道就绪", reachable
                ? "状态翻转：不可达 → 可达（\(ip):\(port)）"
                : "状态翻转：可达 → 不可达（\(ip):\(port)）")
        }
        if viaDirect != lastProbeWasDirect {
            TunnelDiagnostics.note("直连通道", viaDirect
                ? "utun(\(ip):\(port))不可达，设备直连(\(RemotePairingPort.discoveredIP ?? "-"):\(port))接管"
                : "直连通道让位（utun 可达或直连探测未通过）")
            lastProbeWasDirect = viaDirect
        }
        isReady = reachable
    }

    /// 网络恢复事件驱动的隧道重建（Gnoix 对齐）.
    ///
    /// 蜂窝开关 / Wi-Fi 切换时 iOS 可能拆掉 LocalDevVPN 的 NE tunnel；探测循环
    /// 只探不建 ⇒ 隧道死后 App 停在「未就绪」，只能手动重进页面。这里在「网络
    /// 恢复（path satisfied）而隧道仍不可达」时调 `LocalDevVPN.startWhenNeeded()`：
    /// 其内部判据（选中 localDevVPN + 无任何 utun + 5 秒冷却 + 用户开关）保证
    /// utun 幸存时是零副作用空操作；卡点弹窗进行中不拉起（不能抢用户前台），
    /// App 在后台也不拉起（后台 open 他 App 会被系统拒绝而误跳 App Store）.
    private func rebuildTunnelIfNeeded(networkSatisfied: Bool) {
        guard networkSatisfied else { return }
        guard !TunnelGate.isReady else { return }
        guard CellularGlitchCoordinator.shared.phase == .idle else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        if LocalDevVPN.startWhenNeeded() {
            TunnelDiagnostics.note("隧道就绪", "网络恢复而隧道不可达，已事件驱动拉起 LocalDevVPN 重建")
        }
    }

}
