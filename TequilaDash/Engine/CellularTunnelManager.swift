import Foundation
import Network

/// 「Cellular隧道支持」——蜂窝网络（无 Wi-Fi）下也能连本地隧道.
///
/// 背景：iOS 系统限制使「设备走蜂窝上网时，回环 VPN 连不上本机自建的服务端」.
/// 解法（Gnoix 同款时序）：临时关掉蜂窝数据触发 iOS 底层路由表重建，
/// 在断网窗口内建隧道；通路在蜂窝恢复后仍可用（真机实测）.
///
/// v0.3.762 用户裁定：**快捷指令方案整体删除**（shortcuts:// 跳前台严重冲突），
/// 开关方式三选 = 自动（私有优先，兜底卡点弹窗）/ 私有实现 / 卡点弹窗；
/// 本类在任何路径下都不会再调用 `UIApplication.open`.
///
/// `@unchecked Sendable`：实例侧可变状态只有 `didTurnOffData`（stateLock 保护）与静默闸门
/// 去重标记（静态 + NSLock），跨隔离域共享本单例安全.
final class CellularTunnelManager: @unchecked Sendable {
    static let shared = CellularTunnelManager()
    private init() {}

    // MARK: - 静默闸门日志（v0.3.757）

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

    /// 轮询隧道就绪的总预算（对齐 SideStore `waitForMinimuxerReady(timeout: 2.0)`）.
    private static let readyTimeout: TimeInterval = 2.0
    /// 轮询间隔（对齐 SideStore `200_000_000` ns = 200ms）.
    private static let pollInterval: TimeInterval = 0.2
    /// 单次 TCP 探测超时（对齐 SideStore `MinimuxerConstants.defaultTCPProbeTimeoutMs` = 250ms）.
    private static let probeTimeout: TimeInterval = 0.25

    // MARK: - 开关与判据

    /// 用户是否开启「Cellular隧道支持」（默认关）.
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// 是否处于「蜂窝模式」= 开关开 + 当前没有 Wi-Fi.
    var isCellularMode: Bool {
        guard isEnabled else { return false }
        return !Self.isWiFiSatisfied()
    }

    // MARK: - 开关方式（v0.3.762：自动 / 私有实现 / 卡点弹窗）

    /// 蜂窝开关方式三选（v0.3.762：快捷指令方案删除，永不跳快捷指令）.
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
    /// 再等隧道就绪（用完由 `turnOnDataIfNeeded` 恢复）。iOS 在蜂窝上网时对回环 VPN
    /// 有系统级限制 ⇒ 不关蜂窝必然 `connect refused`.
    ///
    /// - Returns: 是否处于蜂窝模式且隧道已就绪（`false` = 未开开关 / 有 Wi-Fi / 轮询超时）.
    ///   未就绪时**不阻断**调用方：由后续 `ensureHeartbeat()` 如实报错（见 `AppDiscovery`）.
    ///
    /// 虽然内部要跑 async 的关蜂窝动作，但这个函数被 **28 个建隧道调用点**使用，
    /// 其中多数在同步上下文里。故内部用 `DispatchSemaphore` 等 async 结果 ——
    /// 与 `isWiFiSatisfied` 同款手法。蜂窝模式下阻塞调用线程最长约
    /// `关蜂窝效果判定(≤6s) + readyTimeout`；Wi-Fi 下第一道闸门就返回，零开销.
    @discardableResult
    func prepareForTunnel() -> Bool {
        // 快速闸门：平台 / 开关 / Wi-Fi。三项任一不满足直接返回，**不阻塞**。.
        guard isSupported, isEnabled else {
            Self.logGateOnce("disabled", "蜂窝隧道总开关未开，跳过蜂窝流程")
            return false
        }
        guard !Self.isWiFiSatisfied() else {
            Self.logGateOnce("wifi", "Wi-Fi 在线，跳过蜂窝流程")
            return false
        }

        // v0.3.767（Gnoix 对齐）：通路已在就绝不重复关蜂窝 —— 关蜂窝只为在断网窗口抢建通路，
        // 通路建立后蜂窝恢复仍可用（真机实测）；隧道已就绪时再关蜂窝纯属破坏（且此路径无人恢复）.
        // 零延迟直接放行（结论等价 waitForTunnelReady 成功）.
        if TunnelGate.isReady
            || LocalDevVPN.isReachable(ip: LocalDevVPN.targetIP, timeout: 0.5, port: RemotePairingPort.current) {
            TunnelGate.setReady(true)
            Self.logGateOnce("pathAlive", "通路已在（蜂窝恢复后仍可用），跳过关蜂窝直接放行")
            return true
        }

        // 关蜂窝（幂等：已关过就不重复跑）。同步等待 async 结果.
        let turnedOff = Self.runSync { await self.turnOffDataIfNeeded() }
        if !turnedOff {
            // 没关成（幂等跳过 / 私有被拒或无效）—— 不阻断，如实留痕.
            LoginLogger.shared.log("[Cellular] 关蜂窝未执行（原因见蜂窝开关日志），继续尝试建隧道",
                                  category: .tunnelCellular)
        }

        let ready = waitForTunnelReady(timeout: Self.readyTimeout)
        // 诊断：把「隧道到底在不在、候选对端是哪些、本机接口长什么样」如实打进日志.
        let peers = LocalDevVPN.candidateTunnelPeers()
        LoginLogger.shared.log(
            "[Cellular] 蜂窝模式，已关蜂窝=\(didTurnOffData)，隧道就绪=\(ready). utun=\(LocalDevVPN.isConnected) "
            + "候选对端=[\(peers.joined(separator: ", "))] 本机接口=\(LocalDevVPN.ipv4InterfaceSummary()).",
            category: .tunnelCellular)
        return ready
    }

    /// 有界轮询「隧道端口（49152）可达」，最多等 `timeout`.
    ///
    /// 每一轮都调 `LocalDevVPN.isAnyCandidateReachable(timeout:)` **并行**探全部候选对端
    /// （本机可能同时装着 Surge / Loon / Shadowrocket，各起一条 utun，
    /// 只探第一条 utun 会探错隧道）.
    func waitForTunnelReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        // Date 比较一律改比 Double 时间戳：iOS 27.2 beta 上 >=/<= 是 weak import（GOT 空则 PC=0 直接被杀），
        // < 与 > 今天仍是 strong，但同类雷会随 SDK 挪位置 —— 守卫 swift_date_compare_guard.py 统一拦四个比较符.
        while Date().timeIntervalSinceReferenceDate < deadline.timeIntervalSinceReferenceDate {
            if LocalDevVPN.isAnyCandidateReachable(timeout: Self.probeTimeout) { return true }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        return false
    }

    /// 同步等待一个 async 闭包的结果.
    ///
    /// 用于「内部逻辑是 async、但对外必须保持同步签名」的场合
    /// （典型就是 `prepareForTunnel`：28 个调用点全是同步上下文）。
    ///
    ///  **不可重入**：闭包内不得再调用本函数。当前唯一用途是等
    /// `turnOffDataIfNeeded()`（其内部只跑私有开关与效果判定），安全.
    private static func runSync(_ body: @escaping @MainActor () async -> Bool) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BoolBox()
        Task { @MainActor in
            box.set(await body())
            semaphore.signal()
        }
        // 上限 = 私有关蜂窝效果判定最长等待（2.5s + 3.5s 极性重试）+ 就绪轮询 + 余量.
        let ceiling: TimeInterval = 10 + readyTimeout + 2
        _ = semaphore.wait(timeout: .now() + .seconds(Int(ceiling)))
        return box.value
    }

    static func isWiFiSatisfied(timeout: TimeInterval = 0.5) -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.tequila.dash.cellular-path")
        let semaphore = DispatchSemaphore(value: 0)
        let box = BoolBox()
        // v0.3.638：默认值改成 true —— 超时时按「Wi-Fi 满足」处理（避免冷启动首帧不到把蜂窝用户卡 2.25s）.
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

    // MARK: - 关/开蜂窝（v0.3.762：只走私有 API 或交由卡点弹窗，快捷指令已删除）

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
                // 效果判定：setter 返回 0 只代表系统受理；以「蜂窝真断」为准（v0.3.757）.
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
        // v0.3.762 用户裁定：快捷指令方案整体删除 —— 自动模式的兜底是卡点弹窗，
        // 这里只如实返回 false，绝不自动跳转.
        CellularLogStore.shared.log("关蜂窝未由私有开关完成（门编排=\(orchestratedByGate)），交由卡点弹窗/调用方处理")
        return false
    }

    /// 恢复蜂窝数据（v0.3.762 起只走私有 API；快捷指令方案已删除）.
    ///
    /// 用完即还，不留副作用。私有开关被拒/无效果时只如实打日志并返回 false
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
                // 效果校验：setter 返回 0 ≠ 蜂窝真开了；8s 内没恢复联网视为未生效（v0.3.757）.
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
