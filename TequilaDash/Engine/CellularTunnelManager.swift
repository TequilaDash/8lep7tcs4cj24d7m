import Foundation
import Network
import NetworkExtension

/// 「Cellular隧道支持」——蜂窝网络（无 Wi-Fi）下也能连本地隧道.
///
/// 背景：iOS 系统限制使「设备走蜂窝上网时，回环 VPN 连不上本机自建的服务端」.
/// 在断网窗口内建隧道；通路在蜂窝恢复后仍可用（真机实测）.
///
/// 开关方式三选 = 自动（私有优先，兜底卡点弹窗）/ 私有实现 / 卡点弹窗；
/// 本类在任何路径下都不会再调用 `UIApplication.open`.
///
/// `@unchecked Sendable`：实例侧可变状态只有 `didTurnOffData`（stateLock 保护）与静默闸门
/// 去重标记（静态 + NSLock），跨隔离域共享本单例安全.
final class CellularTunnelManager: @unchecked Sendable {
    static let shared = CellularTunnelManager()
    private init() {}


    // prepareForTunnel 的两道快速闸门此前是**零日志** return —— 用户开着蜂窝总开关测试时，
    // 「面板一条日志都没有」的最大嫌疑就是它们（总开关没开 / 冷启动 Wi-Fi 误判）.
    // 现在补日志：面板侧每会话各记一次（28 个调用点会反复撞闸门，防刷屏）；盘上恒记.
    private static let gateFlagLock = NSLock()
    // 访问全部收在 gateFlagLock 临界区内；nonisolated(unsafe) 只是关掉并发检查器的全局可变告警.
    private static nonisolated(unsafe) var loggedGateBails: Set<String> = []

    private static func logGateOnce(_ key: String, _ text: String) {
        gateFlagLock.lock()
        let first = !loggedGateBails.contains(key)
        if first { loggedGateBails.insert(key) }
        gateFlagLock.unlock()
        if first {
            CellularLogStore.shared.log(text)
        }
        LoginLogger.shared.log("[Cellular] " + text, category: .tunnelCellular)
    }

    /// `UserDefaults` 键. 沿用本仓「模块.项」点号惯例（与 `TunnelManager.kindKey` 同款）.
    static let enabledKey = "TequilaDash.CellularTunnelSupport"

    /// 不许出现秒级轮询/退避. 推进源是两个真事件：`NEVPNStatusDidChange`（内置隧道
    /// 会话状态变化）与 `NWPathMonitor.pathUpdateHandler`（第三方 utun 建/拆会改接口集，
    /// LocalDevVPN 的隧道归它管，且 start 后必有一次初值回调）.
    /// 本预算只兜「两个事件源都不来」的极端情形.
    private static let readyBudgetMs: Int = 250
    /// 事件缺席时的毫秒级复查间隔（不是退避秒数）.
    private static let readyTickMs: Int = 20
    /// 单次 TCP 探测上限（socket connect 自身的花费，对齐 SideStore `defaultTCPProbeTimeoutMs` = 250ms）.
    private static let probeTimeoutMs: Int = 250
    /// 卡点窗口内主动建链的收摊上限（毫秒命名）：隧道起来时路径事件会立刻唤醒并提前返回，
    /// 这个值只是「事件整段不来」时的兜底线，不是 sleep 时长.
    static let bringUpCeilingMs: Int = 4000
    /// `LocalDevVPN.isAnyCandidateReachable` 要秒制参数，这里只做单位换算.
    private static var probeTimeout: TimeInterval { Double(probeTimeoutMs) / 1000.0 }

    // MARK: - 开关与判据

    /// 用户是否开启「Cellular隧道支持」（默认关）.
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// 是否处于「蜂窝模式」= 开关开 + 当前没有 Wi-Fi.
    var isCellularMode: Bool {
        guard isEnabled else { return false }
        return !Self.isWiFiSatisfied()
    }


    enum ToggleMode: String, CaseIterable {
        /// 优先私有 API；被系统拒绝或无效果时由卡点弹窗接管（引导手动关蜂窝）.
        case auto
        /// 只走私有 API，被系统拒绝或无效果时如实失败，不弹卡不回落.
        case privateOnly
        /// 跳过私有 API，直接走卡点弹窗引导手动关/开蜂窝.
        case guidedCard

        var label: String {
            switch self {
            case .auto: return "Auto"
            case .privateOnly: return "私有实现"
            case .guidedCard: return "卡点弹窗"
            }
        }
    }

    static let toggleModeKey = "CellularToggleMode"

    /// 当前开关方式（UserDefaults 持久化，缺省 auto；
    /// 历史值 shortcutsOnly 读不到枚举自动回落 auto，等效于关闭已删除的方案）.
    var toggleMode: ToggleMode {
        get {
            ToggleMode(rawValue: UserDefaults.standard.string(forKey: Self.toggleModeKey) ?? "") ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.toggleModeKey)
        }
    }


    /// 本次会话内是否已经关过蜂窝. 用锁保护（`turnOff/OnDataIfNeeded` 可能被不同线程调）.
    private let stateLock = NSLock()
    private var cachedDidTurnOffData = false
    private var didTurnOffData: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return cachedDidTurnOffData }
        set { stateLock.lock(); cachedDidTurnOffData = newValue; stateLock.unlock() }
    }

    // MARK: - 建隧道前

    /// 建隧道**前**调用.
    ///
    /// 蜂窝模式下先尝试关掉蜂窝（私有 API；被拒/无效按开关方式决定是否弹卡点弹窗），
    /// 再等隧道就绪（用完由 `turnOnDataIfNeeded` 恢复）.iOS 在蜂窝上网时对回环 VPN
    /// 有系统级限制 ⇒ 不关蜂窝必然 `connect refused`.
    ///
    /// - Returns: 是否处于蜂窝模式且隧道已就绪（`false` = 未开开关 / 有 Wi-Fi / 就绪等待在毫秒级预算内未连通）.
    ///   未就绪时**不阻断**调用方：由后续 `ensureHeartbeat()` 如实报错（见 `AppDiscovery`）.
    ///
    /// 虽然内部要跑 async 的关蜂窝动作，但这个函数被 **28 个建隧道调用点**使用，
    /// 其中多数在同步上下文里.故内部用 `DispatchSemaphore` 等 async 结果 ——
    /// 与 `isWiFiSatisfied` 同款手法.蜂窝模式下阻塞调用线程最长约
    /// `关蜂窝效果判定上限(2.5s + 3.5s 极性重试) + 毫秒级就绪预算(250ms + 探测)`；
    /// Wi-Fi 下第一道闸门就返回，零开销.
    @discardableResult
    func prepareForTunnel() -> Bool {
        // 快速闸门：平台 / 开关 / Wi-Fi.三项任一不满足直接返回，**不阻塞**..
        guard isSupported, isEnabled else {
            Self.logGateOnce("disabled", "蜂窝隧道总开关未开，跳过蜂窝流程")
            return false
        }
        guard !Self.isWiFiSatisfied() else {
            Self.logGateOnce("wifi", "Wi-Fi 在线，跳过蜂窝流程")
            return false
        }

        // （断网窗口内真实成功 / utun 对端），直连端口探测不参与（LC 实测假阳性）；
        // 隧道已就绪时再关蜂窝纯属破坏（且此路径无人恢复）. 零延迟直接放行.
        if TunnelGate.isReady {
            Self.logGateOnce("pathAlive", "通路已在（真实建立且未被清），跳过关蜂窝直接放行")
            return true
        }

        // 关蜂窝（幂等：已关过就不重复跑）.同步等待 async 结果.
        let turnedOff = Self.runSync { await self.turnOffDataIfNeeded() }
        if !turnedOff {
            // 没关成（幂等跳过 / 私有被拒或无效）—— 不阻断，如实留痕.
            LoginLogger.shared.log("[Cellular] 关蜂窝未执行（原因见蜂窝开关日志），继续尝试建隧道",
                                  category: .tunnelCellular)
        }

        let ready = Self.waitForBringUp()
        // 诊断：把「隧道到底在不在、候选对端是哪些、本机接口长什么样」如实打进日志.
        let peers = LocalDevVPN.candidateTunnelPeers()
        LoginLogger.shared.log(
            "[Cellular] 蜂窝模式，已关蜂窝=\(didTurnOffData)，隧道就绪=\(ready). utun=\(LocalDevVPN.isConnected) "
            + "候选对端=[\(peers.joined(separator: ", "))] 本机接口=\(LocalDevVPN.ipv4InterfaceSummary()).",
            category: .tunnelCellular)
        return ready
    }

    ///
    /// 两路事件源，命中即 `wake.signal()` 立刻返回（不再靠时间撞运气）：
    ///   · `NEVPNStatusDidChange` —— 内置隧道（`TunnelKind.builtIn`）的会话状态变化.
    ///     回调必须派到独立 `OperationQueue`：`queue: nil` 在 posting 线程同步执行，
    ///     而本函数常在主线程阻塞调用 ⇒ 事件永远进不来.
    ///   · `NWPathMonitor.pathUpdateHandler` —— LocalDevVPN / Surge / Loon 这些**别的 App**
    ///     建的隧道不向我们进程发 NE 状态通知（NEVPNStatusDidChange 只发给会话拥有者），
    ///     但它们建/拆 utun 会改变接口集 ⇒ 路径更新是唯一可用的外部事件.
    ///
    /// 毫秒级兜底 = 事件整段不来时，每 `readyTickMs`(20ms) 复查一次，累计不超过
    /// `readyBudgetMs`(250ms)；全程无秒级 sleep，也无无界等待.
    ///
    /// 探测一律走 `LocalDevVPN.isAnyCandidateReachable(timeout:)` **并行**探全部候选对端
    /// （本机可能同时装着 Surge / Loon / Shadowrocket，各起一条 utun，只探第一条会探错隧道）.

    // MARK: - 主动建链

    /// 需要隧道但探测不通时**主动踢一次建链**（只发起、不等结果）.
    ///
    /// 载体差别决定能不能程序化发起：
    ///   · `.localDevVPN` —— 深链由该 App 建链，判据与冷却都在 `LocalDevVPN.startWhenNeeded()` 里
    ///     （utun 已在时是零副作用空操作）；
    ///   · `.builtIn` —— 本 App 自己的 NE 会话，可直接 start；
    ///   · Surge / Loon / Shadowrocket —— 只能跳出本 App 抢前台，卡点弹窗正在前景，
    ///     自动跳走会打断用户操作，故只记日志、由用户在该工具内自行开启.
    /// 不等结果的原因：`start()` 内部要经主线程做 UIKit 调用，而同步入口常在主线程阻塞 ⇒ 等它就是死锁；
    /// 就绪与否一律交给后续事件探测.
    @discardableResult
    static func kickBringUp(reason: String) -> Bool {
        switch TunnelManager.selectedKind {
        case .localDevVPN:
            guard LocalDevVPN.startWhenNeeded() else { return false }
            logGateOnce("bringup-localdevvpn", "主动拉起 LocalDevVPN：" + reason + "，已发起深链建链")
            return true
        case .builtIn:
            Task { await TunnelManager.provider(for: .builtIn).start() }
            logGateOnce("bringup-builtin", "主动拉起内置隧道：" + reason + "，已发起 NE 会话")
            return true
        case .shadowrocket, .surge, .loon:
            logGateOnce("bringup-jump", "跳转类隧道载体不自动跳走：" + reason + "，请在该工具内开启隧道")
            return false
        }
    }

    /// 同步就绪入口：先探，探不到就主动建链一次，再等事件（`prepareForTunnel` 用）.
    static func waitForBringUp(budgetMs: Int = CellularTunnelManager.readyBudgetMs) -> Bool {
        if probePeers() { return true }
        let kicked = kickBringUp(reason: "关蜂窝后探测未命中")
        let ready = shared.waitForTunnelReady(budgetMs: budgetMs)
        if !ready {
            LoginLogger.shared.log(
                "[Cellular] 主动建链后仍未就绪（已发起=" + String(kicked) + "）. utun="
                + String(LocalDevVPN.isConnected) + " 接口=" + LocalDevVPN.ipv4InterfaceSummary()," ,
                category: .tunnelCellular)
        }
        return ready
    }

    /// 卡点窗口内的异步入口：先按毫秒预算建链，仍不通再用收摊上限等一次（事件命中即提前返回）.
    @discardableResult
    func bringUpTunnel() async -> Bool {
        let first = await Task.detached(priority: .userInitiated) { Self.waitForBringUp() }.value
        if first { return true }
        return await Task.detached(priority: .userInitiated) {
            Self.shared.waitForTunnelReady(budgetMs: Self.bringUpCeilingMs)
        }.value
    }

    func waitForTunnelReady(budgetMs: Int = CellularTunnelManager.readyBudgetMs) -> Bool {
        if Self.probePeers() { return true }

        let hit = BoolBox()
        let wake = DispatchSemaphore(value: 0)
        let token = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: Self.statusQueue
        ) { _ in
            if Self.probePeers() { hit.set(true); wake.signal() }
        }
        let pathQueue = DispatchQueue(label: "com.tequila.dash.tunnel-ready-path")
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in
            if Self.probePeers() { hit.set(true); wake.signal() }
        }
        monitor.start(queue: pathQueue)

        // systemUptime 比 Double（不用 Date 比较：iOS 27.2 beta 上 >=/<= 是 weak import，
        // GOT 空则 PC=0 直接被杀；守卫 swift_date_compare_guard.py 统一拦 Date 比较）.
        let deadline = ProcessInfo.processInfo.systemUptime + Double(budgetMs) / 1000.0
        while !hit.value, ProcessInfo.processInfo.systemUptime < deadline {
            // 20ms 毫秒级 tick：被事件 signal 唤醒时立刻退出，不等满.
            _ = wake.wait(timeout: .now() + .milliseconds(Self.readyTickMs))
            if Self.probePeers() { hit.set(true); break }
        }
        monitor.cancel()
        NotificationCenter.default.removeObserver(token)
        // 回调可能已在别的队列上排队：摘掉两路源后再判一次，不漏最后一路事件.
        return hit.value || Self.probePeers()
    }

    /// 一次并行就绪探测（多候选，R8 硬规则）.
    private static func probePeers() -> Bool {
        LocalDevVPN.isAnyCandidateReachable(timeout: probeTimeout)
    }

    /// `NEVPNStatusDidChange` 回调的执行队列（单串行；调用线程阻塞时事件仍能送达）.
    private static let statusQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.tequila.dash.tunnel-status"
        return queue
    }()

    /// 同步等待一个 async 闭包的结果.
    ///
    /// 用于「内部逻辑是 async、但对外必须保持同步签名」的场合
    /// （典型就是 `prepareForTunnel`：28 个调用点全是同步上下文）.
    ///
    ///  **不可重入**：闭包内不得再调用本函数.当前唯一用途是等
    /// `turnOffDataIfNeeded()`（其内部只跑私有开关与效果判定），安全.
    private static func runSync(_ body: @escaping @MainActor () async -> Bool) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BoolBox()
        Task { @MainActor in
            box.set(await body())
            semaphore.signal()
        }
        // 上限 = 关蜂窝效果判定上限（2.5s + 3.5s 极性重试）+ 毫秒级就绪预算(250ms)+两次探测 + 余量.
        let ceiling: TimeInterval = 6 + Double(readyBudgetMs + probeTimeoutMs * 2) / 1000.0 + 2
        _ = semaphore.wait(timeout: .now() + .seconds(Int(ceiling)))
        return box.value
    }

    static func isWiFiSatisfied(timeout: TimeInterval = 0.5) -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.tequila.dash.cellular-path")
        let semaphore = DispatchSemaphore(value: 0)
        let box = BoolBox()
        box.set(true)
        monitor.pathUpdateHandler = { path in
            box.set(path.usesInterfaceType(.wifi))
            semaphore.signal()
        }
        monitor.start(queue: queue)
        let gotCallback = semaphore.wait(timeout: .now() + timeout) == .success
        monitor.cancel()
        if !gotCallback {
            LoginLogger.shared.log(
                "[Cellular] NWPathMonitor 首帧 \(timeout)s 未到，按「Wi-Fi 满足」放行（避免误判蜂窝阻塞 2.25s）.",
                category: .tunnelCellular)
        }
        return box.value
    }


    /// 尝试关闭蜂窝数据（私有 CoreTelephony API；失败按开关方式决定后续）.
    ///
    /// 返回值语义：`true` = 私有开关实测断网生效（`didTurnOffData` 已置位）；
    /// `false` = 被拒 / 无效果 / 未尝试 —— 自动模式的兜底是卡点弹窗
    /// （由 `CellularGlitchCoordinator.beginLoopbackGate` 弹卡等待手动断网），
    /// 本函数**绝不自动执行任何跳转**.
    @MainActor
    @discardableResult
    func turnOffDataIfNeeded(orchestratedByGate: Bool = false, shouldAbort: (() -> Bool)? = nil) async -> Bool {
        guard isSupported && isEnabled else { return false }
        guard !didTurnOffData else { return false }
        guard !Self.isWiFiSatisfied() else {
            LoginLogger.shared.log("[Cellular] Wi-Fi 已连接，跳过关蜂窝",
                                   category: .tunnelCellular)
            CellularLogStore.shared.log("Wi-Fi 已连接，跳过关蜂窝")
            return false
        }

        let mode = toggleMode
        CellularLogStore.shared.log("关蜂窝开始（模式=\(mode.label)）")
        if mode == .guidedCard {
            CellularLogStore.shared.log("卡点弹窗模式：跳过私有开关，直接交由卡点弹窗引导手动关蜂窝")
            return false
        }

        let service = CellularDataToggleService.shared
        if service.isPrivateAPIAvailable {
            do {
                try await service.setCellularEnabled(false)
                var down = await CellularNetworkChecker.shared.waitForCellularToTurnOff(timeoutSeconds: 2.5, shouldAbort: shouldAbort)
                if !down, shouldAbort?() != true, CellularNetworkChecker.shared.isNetworkConnectedNow {
                    // 仍未断且仍在线 ⇒ 可能 bool 极性别名（参数语义与预期相反），翻转重试一枪.
                    CellularLogStore.shared.log("私有 API 返回成功但 2.5s 未断网，翻转极性别名重试")
                    service.polarityInverted = !service.polarityInverted
                    do {
                        try await service.setCellularEnabled(false)
                        down = await CellularNetworkChecker.shared.waitForCellularToTurnOff(timeoutSeconds: 3.5, shouldAbort: shouldAbort)
                    } catch {
                        CellularLogStore.shared.log("极性重试调用失败（\(error.localizedDescription)）")
                    }
                    if !down {
                        CellularLogStore.shared.log("翻转后仍未断网，还原极性，判定私有开关无效")
                        service.polarityInverted = !service.polarityInverted
                    }
                }
                if down || !CellularNetworkChecker.shared.isNetworkConnectedNow {
                    didTurnOffData = true
                    CellularLogStore.shared.log("私有 API 关蜂窝生效（实测断网），路由重置窗口已开")
                    LoginLogger.shared.log("[Cellular] 私有 API 关蜂窝生效（实测断网）",
                                           category: .tunnelCellular)
                    return true
                }
                CellularLogStore.shared.log("私有 API 调用完成但蜂窝未断，判定无效")
                LoginLogger.shared.log("[Cellular] 私有 API 关蜂窝调用完成但未断网（疑似无效果）",
                                       category: .tunnelCellular)
                CellularLogStore.shared.log("私有开关被系统拒绝或无效")
            } catch {
                // CTError ≠ 0 是系统明确拒绝（真机实锤 CTError 2）——极性重试无意义，快速按失败走.
                CellularLogStore.shared.log("私有 API 关蜂窝失败（\(error.localizedDescription)）")
                LoginLogger.shared.log(
                    "[Cellular] 私有 API 关蜂窝失败（\(error.localizedDescription)）",
                    category: .tunnelCellular)
                CellularLogStore.shared.log("私有开关被系统拒绝或无效")
            }
        } else {
            CellularLogStore.shared.log("私有 CoreTelephony API 不可用")
        }

        if mode == .privateOnly {
            CellularLogStore.shared.log("私有实现模式：关蜂窝私有开关被拒或无效，按选择如实失败")
            return false
        }
        // 这里只如实返回 false，绝不自动跳转.
        CellularLogStore.shared.log("关蜂窝未由私有开关完成（门编排=\(orchestratedByGate)），交由卡点弹窗/调用方处理")
        return false
    }

    ///
    /// 用完即还，不留副作用.私有开关被拒/无效果时只如实打日志并返回 false
    /// （`didTurnOffData` 保持 true，下个生命周期信号再试；用户也可在卡点弹窗里手动开）.
    @MainActor
    @discardableResult
    func turnOnDataIfNeeded(shouldAbort: (() -> Bool)? = nil) async -> Bool {
        guard didTurnOffData else { return false }
        let mode = toggleMode
        CellularLogStore.shared.log("开蜂窝开始（模式=\(mode.label)）")
        if mode == .guidedCard {
            CellularLogStore.shared.log("卡点弹窗模式：跳过私有开关，由用户在卡点弹窗里手动恢复蜂窝")
            return false
        }

        let service = CellularDataToggleService.shared
        if service.isPrivateAPIAvailable {
            do {
                try await service.setCellularEnabled(true)
                let back = await CellularNetworkChecker.shared.waitForNetworkToReturn(timeoutSeconds: 8, shouldAbort: shouldAbort)
                if back || CellularNetworkChecker.shared.isNetworkConnectedNow {
                    didTurnOffData = false
                    CellularLogStore.shared.log("私有 API 开蜂窝生效（实测恢复联网）")
                    LoginLogger.shared.log("[Cellular] 私有 API 开蜂窝生效（实测恢复联网）",
                                           category: .tunnelCellular)
                    return true
                }
                CellularLogStore.shared.log("私有 API 开蜂窝后 8s 未恢复联网，视为未生效")
                LoginLogger.shared.log("[Cellular] 私有 API 开蜂窝后未恢复联网（疑似无效果）",
                                       category: .tunnelCellular)
            } catch {
                CellularLogStore.shared.log("私有 API 开蜂窝失败（\(error.localizedDescription)）")
                LoginLogger.shared.log(
                    "[Cellular] 私有 API 开蜂窝失败（\(error.localizedDescription)）",
                    category: .tunnelCellular)
            }
        } else {
            CellularLogStore.shared.log("私有 CoreTelephony API 不可用")
        }
        return false
    }

    /// 本次会话内是否已经通过 `turnOffDataIfNeeded()` 关过蜂窝（只读探针）.
    /// `TequilaDashApp` 的生命周期 observer（非隔离域）先用它判断，再决定是否起 Task 恢复蜂窝.
    var hasTurnedOffDataInThisSession: Bool { didTurnOffData }
    var isSupported: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }
}

/// `NWPathMonitor` 回调与调用线程之间的同步盒子.
/// Swift 6 严格并发下不允许在 `@Sendable` 闭包里改写捕获的 `var`，故用带锁的引用类型.
private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set(_ value: Bool) {
        lock.lock(); stored = value; lock.unlock()
    }

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
