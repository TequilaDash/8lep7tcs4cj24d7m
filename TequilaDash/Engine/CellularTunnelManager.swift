import Foundation
import Network
import UIKit

/// 「Cellular隧道支持」——蜂窝网络（无 Wi-Fi）下也能连本地隧道.
///
/// 背景：iOS 系统限制使「设备走蜂窝上网时，回环 VPN 连不上本机自建的服务端」.
/// SideStore 的 `CellularRefreshManager`（`SideStore/Core/Shortcuts/CellularRefreshManager.swift`）
/// 用 iOS 快捷指令临时关掉蜂窝数据，但那要求用户先在「快捷指令」App 里**自建**
/// `TurnOffData` / `TurnOnData` 两个快捷指令 —— 这是把本该由 App 承担的事推给用户，本仓**不采用**.
///
/// 本仓的做法：**不碰蜂窝开关，直接尝试连隧道**. 隧道连的是本地地址（`LocalDevVPN.targetIP`，
/// 默认 `10.7.0.1`），本就不依赖 Wi-Fi；蜂窝下若连不上，如实报错，不做任何「需要用户手动操作」的设计.
/// 换言之，这里只保留 SideStore 里真正有用的那部分：**判是否蜂窝 + 有界等隧道就绪**.
///
/// 与 SideStore 的逐项对应（保留部分）：
///   · `isCellularRefreshEnabled`（UserDefaults）   → `TequilaDash.CellularTunnelSupport`
///   · `minimuxer.network.isWifiSatisfied`           → `NWPathMonitor` 的 `usesInterfaceType(.wifi)`
///   · `waitForMinimuxerReady(timeout: 2.0)`         → 有界轮询（250ms 并行探多候选，见 `waitForTunnelReady`）
///   · `core.isReady(withNetworkCheck: false)`       → 本仓无「Wi-Fi 网络门」，天然等价于 `false`
///
/// ⚠️ 默认关（`UserDefaults` 无值即 `false`）⇒ 开关不开时本类全部方法都是 no-op，
/// **不改变 Wi-Fi 下既有行为**（兼容纪律，与 `TunnelManager` 同款）.
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
    private static var loggedGateBails: Set<String> = []

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
    ///
    /// 为什么不沿用 `LocalDevVPN.isTunnelReachable()` 的 1 秒：1s 探测 + 0.2s 间隔，
    /// 在 2 秒预算里只能试约 2 次；换成 250ms 后同样预算能试 4~8 次，
    /// 与 SideStore 的节奏一致（隧道刚起的那零点几秒正是关键窗口）.
    private static let probeTimeout: TimeInterval = 0.25

    // MARK: - 开关与判据

    /// 用户是否开启「Cellular隧道支持」（默认关）.
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// 是否处于「蜂窝模式」= 开关开 + 当前没有 Wi-Fi.
    /// 判据与 SideStore 的 `isCellularMode`（`!isWifiSatisfied`）同义.
    var isCellularMode: Bool {
        guard isEnabled else { return false }
        return !Self.isWiFiSatisfied()
    }

    // MARK: - 建隧道前

    /// 建隧道**前**调用.
    ///
    /// v0.3.613 起照 SideStore `turnOffDataIfNeeded` 补全：蜂窝模式下**先临时关掉蜂窝数据**
    /// 再等隧道就绪（用完由 `turnOnDataIfNeeded` 恢复）。此前只「等」不「关」，
    /// 而 iOS 在蜂窝上网时对回环 VPN 有系统级限制 ⇒ 必然 `connect refused`（用户实测无效）。
    ///
    /// - Returns: 是否处于蜂窝模式且隧道已就绪（`false` = 未开开关 / 有 Wi-Fi / 轮询超时）.
    ///   未就绪时**不阻断**调用方：由后续 `ensureHeartbeat()` 如实报错（见 `AppDiscovery`）.
    /// 建隧道**前**调用。
    ///
    /// v0.3.647 起重写，**照 SideStore `CellularRefreshManager.turnOffDataIfNeeded` 的完整时序**。
    ///
    /// 原实现只「等」不「关」（L67-72：直接 waitForTunnelReady），而蜂窝下回环 VPN
    /// 被 iOS 系统级限制，不关蜂窝必然 `connect refused` ⇒ 蜂窝支持形同虚设。
    /// 且 `turnOffDataIfNeeded()` 是恒返回 false 的死函数（L219-223），从没被调用过。
    ///
    /// SideStore 的正确时序（`CellularRefreshManager.swift` 逐行对照）：
    ///   1. `guard !isWifiSatisfied` —— Wi-Fi 下**直接跳过**，不跑任何快捷指令
    ///   2. 跑 `TurnOffData` 快捷指令
    ///   3. 成功 ⇒ `didTurnOffData = true` + `sleep(baseDelay)`（等蜂窝真正断）
    ///   4. `waitForMinimuxerReady(timeout: 2.0)`（每 200ms 探一次）
    ///   5. **不承诺 radio 状态**：URL 被受理 ≠ 蜂窝已关，故返回值为「隧道是否就绪」
    /// v0.3.647：**保持同步签名**（不变）。
    ///
    /// 虽然内部要跑 async 的关蜂窝动作，但这个函数被 **28 个建隧道调用点**使用，
    /// 其中多数在同步上下文里。改成 async 会波及 28 个文件的调用链，风险远大于收益。
    /// 故内部用 `DispatchSemaphore` 等 async 结果 —— 与 `isWiFiSatisfied` 同款手法。
    ///
    /// ⚠️ 这样会在蜂窝模式下阻塞调用线程最多 `readyTimeout + baseDelay`。
    /// 蜂窝本来就是「准备阶段多等一会」的场景，可接受；Wi-Fi 下第一道闸门就返回，零开销。
    @discardableResult
    func prepareForTunnel() -> Bool {
        // 快速闸门：平台 / 开关 / Wi-Fi。三项任一不满足直接返回，**不阻塞**。
        // v0.3.757：不再是静默 return —— 面板与盘上日志都如实留痕（详见 logGateOnce）.
        guard isSupported, isEnabled else {
            Self.logGateOnce("disabled", "蜂窝隧道总开关未开，跳过蜂窝流程")
            return false
        }
        guard !Self.isWiFiSatisfied() else {
            Self.logGateOnce("wifi", "Wi-Fi 在线，跳过蜂窝流程")
            return false
        }

        // 关蜂窝（幂等：已关过就不重复跑）。同步等待 async 结果。
        let turnedOff = Self.runSync { await self.turnOffDataIfNeeded() }
        if !turnedOff {
            // 没关成（幂等跳过 / 私有被拒 / 快捷指令没装 / 没被受理）—— 不阻断，如实留痕.
            // v0.3.757：具体原因已进蜂窝开关日志（面板可见），这里只留盘上索引.
            LoginLogger.shared.log("[Cellular] 关蜂窝未执行（原因见蜂窝开关日志），继续尝试建隧道",
                                  category: .tunnelCellular)
        }

        let ready = waitForTunnelReady(timeout: Self.readyTimeout)
        // 诊断：把「隧道到底在不在、候选对端是哪些、本机接口长什么样」如实打进日志.
        // 对齐 SideStore `DeviceConnectionManager.refresh()` 的那段多行 debugLog
        // （probable-vpn host / derived peer IP / reachable）—— 没有这段，
        // 日志只能看到「就绪=false」，分不清「根本没有 utun」还是「utun 在但端口被拒」
        // （后者在真机日志里表现为 `connect: Connection refused (os error 61)`）.
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
    /// （对齐 SideStore `DeviceConnectionManager.resolveLocalVPNTunnel` 的并行 `tcpProbe`；
    /// 本机可能同时装着 Surge / Loon / Shadowrocket，各起一条 utun，
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

    // MARK: - Wi-Fi 判据

    /// 当前是否已满足 Wi-Fi（`NWPath.usesInterfaceType(.wifi)`）.
    ///
    /// 本仓此前**没有**任何网络路径判据（研究报告 §2.1：`NWPathMonitor` 全仓命中 0），
    /// 故这里新写一个轻量同步探测：起一个 `NWPathMonitor`，等它的**首个**路径回调
    /// （`timeout` 内），取 `usesInterfaceType(.wifi)` 后立刻 `cancel`.
    /// 取不到（超时）时**保守返回 `false`**（视作非 Wi-Fi，与 SideStore
    /// 「Wi-Fi 未满足即视为蜂窝」的语义一致）.
    /// v0.3.638：**超时分支改为返回 true（视作 Wi-Fi）**，并缓存 monitor 结果。
    ///
    /// 原实现有两个问题，叠加起来会把 Wi-Fi 用户误判成蜂窝：
    ///   1. 每次调用都**新建** `NWPathMonitor`。`start(queue:)` 之后首帧 path 回调
    ///      **不保证**在 0.5s 内到达（冷启动 / 网络切换 / 系统负载高时经常 1s+）；
    ///   2. 超时后返回 `box.value`，而 `BoolBox` 默认值是 `false`。
    ///
    /// 于是「抢不到首帧」⇒ 返回 false ⇒ `isCellularMode` 判成 **true**
    /// ⇒ 即便用户明确连着 Wi-Fi，也会走进蜂窝分支，
    /// 再白等 `waitForTunnelReady(2.0)`（实测阻塞 2.25s）。
    ///
    /// 而 `prepareForTunnel()` 被 **27 个建隧道调用点**调用（25 个还丢弃返回值），
    /// 这段阻塞直接从上层 35s 握手预算里扣，是「一直转圈最后报隧道失败」的放大器。
    ///
    /// 正确取向：**判不出来就当作 Wi-Fi 放行**。因为：
    ///   · 蜂窝分支的唯一作用是多等 2 秒（不改变连通性）；
    ///   · 误判成蜂窝的代价（27 处各卡 2.25s）远大于漏判（蜂窝下少等 2s，由后续探测兜底）。
    /// 同步等待一个 async 闭包的结果。
    ///
    /// 用于「内部逻辑是 async、但对外必须保持同步签名」的场合
    /// （典型就是 `prepareForTunnel`：28 个调用点全是同步上下文）。
    ///
    /// ⚠️ **不可重入**：闭包内不得再调用本函数。当前唯一用途是等
    /// `turnOffDataIfNeeded()`（其内部只跑快捷指令 + sleep），安全。
    private static func runSync(_ body: @escaping @MainActor () async -> Bool) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BoolBox()
        Task { @MainActor in
            box.set(await body())
            semaphore.signal()
        }
        // 上限 = 配置的快捷指令等待（关/开取大者，已夹到 0...30s）+ 就绪轮询 + 2s 余量，
        // 避免极端情况下永久挂死；v0.3.741 起延时可配置，故按实际配置算而不是写死 1s.
        let ceiling = Self.configuredBaseDelayCeiling + readyTimeout + 2
        _ = semaphore.wait(timeout: .now() + .seconds(Int(ceiling)))
        return box.value
    }
    static func isWiFiSatisfied(timeout: TimeInterval = 0.5) -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.tequila.dash.cellular-path")
        let semaphore = DispatchSemaphore(value: 0)
        let box = BoolBox()
        // v0.3.638：默认值改成 true —— 超时时按「Wi-Fi 满足」处理（见上方说明）。
        box.set(true)
        monitor.pathUpdateHandler = { path in
            box.set(path.usesInterfaceType(.wifi))
            semaphore.signal()
        }
        monitor.start(queue: queue)
        let gotCallback = semaphore.wait(timeout: .now() + timeout) == .success
        monitor.cancel()
        if !gotCallback {
            // 打一条日志，让「首帧没抢到」这件事可见（否则它是静默的）
            LoginLogger.shared.log(
                "[Cellular] NWPathMonitor 首帧 \(timeout)s 未到，按「Wi-Fi 满足」放行（避免误判蜂窝阻塞 2.25s）.",
                category: .tunnelCellular)
        }
        return box.value
    }

    // MARK: - 关/开蜂窝（照 SideStore CellularRefreshManager 移植，v0.3.613）

    /// 快捷指令名（可自定义，与 SideStore 的 `turnOffDataShortcutName` 同款）.
    static let turnOffShortcutKey = "TurnOffDataShortcutName"
    static let turnOnShortcutKey = "TurnOnDataShortcutName"
    static let defaultTurnOffShortcut = "TurnOffData"
    static let defaultTurnOnShortcut = "TurnOnData"

    // MARK: - 开关方式（v0.3.756：Auto / 私有实现 / 快捷指令）

    /// 蜂窝开关方式三选.
    enum ToggleMode: String, CaseIterable {
        /// 优先私有 API，失败回落快捷指令（默认）.
        case auto
        /// 只走私有 API（失败不回落）.
        case privateOnly
        /// 只走快捷指令.
        case shortcutsOnly

        var label: String {
            switch self {
            case .auto: return "自动"
            case .privateOnly: return "私有实现"
            case .shortcutsOnly: return "快捷指令"
            }
        }
    }

    static let toggleModeKey = "CellularToggleMode"

    /// 当前开关方式（UserDefaults 持久化，缺省 auto）.
    var toggleMode: ToggleMode {
        get {
            ToggleMode(rawValue: UserDefaults.standard.string(forKey: Self.toggleModeKey) ?? "") ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.toggleModeKey)
        }
    }

    /// 关/开蜂窝后各等多久再探隧道（对齐 SideStore
    /// `defaultTurnOffDataBaseDelay` / `defaultTurnOnDataBaseDelay` = 1.0s）.
    ///
    /// v0.3.741：从写死 1.0s 改为可配置（与 SideStore 设置页同款两栏），
    /// 键与 UI 同源；取值统一过 `sanitizeBaseDelay` 夹到 0...30 秒.
    static let turnOffBaseDelayKey = "TurnOffDataBaseDelay"
    static let turnOnBaseDelayKey = "TurnOnDataBaseDelay"
    static let defaultBaseDelay: TimeInterval = 1.0
    /// 允许范围：0 = 不等待；上限 30 秒（防手滑填 9999 把刷新拖死）.
    static let baseDelayRange: ClosedRange<Double> = 0...30

    /// 夹取延时到合法范围；非有限值回落默认.
    static func sanitizeBaseDelay(_ raw: Double) -> TimeInterval {
        guard raw.isFinite else { return defaultBaseDelay }
        return min(max(raw, baseDelayRange.lowerBound), baseDelayRange.upperBound)
    }

    /// 关/开两档延时里的较大者（同步等待的上限用）.
    private static var configuredBaseDelayCeiling: TimeInterval {
        let off = UserDefaults.standard.object(forKey: turnOffBaseDelayKey) as? Double
            ?? defaultBaseDelay
        let on = UserDefaults.standard.object(forKey: turnOnBaseDelayKey) as? Double
            ?? defaultBaseDelay
        return sanitizeBaseDelay(max(off, on))
    }

    /// 用户配置的「关蜂窝后等待」秒数.
    var turnOffBaseDelay: TimeInterval {
        Self.sanitizeBaseDelay(
            UserDefaults.standard.object(forKey: Self.turnOffBaseDelayKey) as? Double
                ?? Self.defaultBaseDelay)
    }

    /// 用户配置的「开蜂窝后等待」秒数.
    var turnOnBaseDelay: TimeInterval {
        Self.sanitizeBaseDelay(
            UserDefaults.standard.object(forKey: Self.turnOnBaseDelayKey) as? Double
                ?? Self.defaultBaseDelay)
    }

    /// 本次会话内是否已经关过蜂窝. 用锁保护（`turnOff/OnDataIfNeeded` 可能被不同线程调）.
    private let stateLock = NSLock()
    private var cachedDidTurnOffData = false
    private var didTurnOffData: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return cachedDidTurnOffData }
        set { stateLock.lock(); cachedDidTurnOffData = newValue; stateLock.unlock() }
    }

    /// 清洗快捷指令名（照 SideStore `sanitizeShortcutName`：去控制字符、`/`、`:`，
    /// 截断到 100 字符，空则回落默认名）.
    static func sanitizeShortcutName(_ name: String, fallback: String) -> String {
        var s = name.components(separatedBy: .controlCharacters).joined()
        s = s.replacingOccurrences(of: "\n", with: "")
        s = s.replacingOccurrences(of: "\r", with: "")
        s = s.replacingOccurrences(of: "/", with: "")
        s = s.replacingOccurrences(of: ":", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 100 {
            s = String(s.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? fallback : s
    }

    /// 用户配置的关蜂窝快捷指令名（未设或为空时回落 `TurnOffData`）.
    var turnOffShortcutName: String {
        Self.sanitizeShortcutName(
            UserDefaults.standard.string(forKey: Self.turnOffShortcutKey) ?? "",
            fallback: Self.defaultTurnOffShortcut)
    }

    /// 用户配置的开蜂窝快捷指令名（未设或为空时回落 `TurnOnData`）.
    var turnOnShortcutName: String {
        Self.sanitizeShortcutName(
            UserDefaults.standard.string(forKey: Self.turnOnShortcutKey) ?? "",
            fallback: Self.defaultTurnOnShortcut)
    }

    /// 构造 `shortcuts://run-shortcut?name=<名>`（对齐 SideStore `shortcutURL`）.
    static func shortcutURL(for name: String) -> URL {
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "run-shortcut"
        c.queryItems = [URLQueryItem(name: "name", value: name)]
        return c.url ?? URL(string: "shortcuts://run-shortcut?name=\(name)")!
    }

    /// 执行 `TurnOffData` 快捷指令（临时关掉蜂窝数据）.
    ///
    /// 为什么必须做这一步：iOS 在**蜂窝上网**时对「回环 VPN 访问本机服务」有系统级限制，
    /// 不关蜂窝就必然 `connect: Connection refused (os error 61)`。
    /// SideStore 能在蜂窝下连通，靠的正是这一步 —— 本仓 v0.3.612 之前把它砍了
    /// （注释写「不碰蜂窝开关」），于是蜂窝支持形同虚设（用户实测「支持了鸡毛」）。
    /// 本轮照 SideStore 补回。
    ///
    /// 调用方需保证在主线程（`UIApplication.shared.open` 要求）.
    /// 执行 `TurnOffData` 快捷指令（临时关掉蜂窝数据）—— 照 SideStore 同名函数实现。
    ///
    /// 四道闸门（与 SideStore `turnOffDataIfNeeded` 逐行对应）：
    ///   1. `guard isSupported && isEnabled` —— 平台 / 开关
    ///   2. `guard !didTurnOffData` —— 已关过就不重复跑（幂等）
    ///   3. `guard !isWifiSatisfied` —— Wi-Fi 下跳过
    ///   4. 只有 openURL 成功才置 `didTurnOffData = true` 并进入等待
    ///
    /// ⚠️ **不承诺 radio 状态**：`UIApplication.open` 返回 true 只代表系统受理了这个 URL，
    /// 不代表蜂窝数据已关闭（这正是 v0.3.616 撤销「伪造路径」的原因）。
    /// 所以这里的返回值语义是「是否执行了关闭动作」，调用方仍需靠 TCP 探测确认真实连通性。
    @MainActor
    @discardableResult
    func turnOffDataIfNeeded() async -> Bool {
        guard isSupported && isEnabled else { return false }
        guard !didTurnOffData else { return false }
        // Wi-Fi 下不跑快捷指令（SideStore 同款闸门）。
        guard !Self.isWiFiSatisfied() else {
            LoginLogger.shared.log("[Cellular] Wi-Fi 已连接，跳过关闭蜂窝快捷指令",
                                  category: .tunnelCellular)
            CellularLogStore.shared.log("Wi-Fi 已连接，跳过关蜂窝")
            return false
        }

        // v0.3.756：开关方式三选（自动=私有优先回落快捷指令 / 私有实现 / 快捷指令）.
        let mode = toggleMode
        CellularLogStore.shared.log("关蜂窝开始（模式=\(mode.label)）")
        if mode != .shortcutsOnly {
            let service = CellularDataToggleService.shared
            if service.isPrivateAPIAvailable {
                do {
                    try await service.setCellularEnabled(false)
                    // v0.3.757：效果判定 —— setter 返回 0 只代表系统受理；以「蜂窝真断」为准.
                    var down = await CellularNetworkChecker.shared.waitForCellularToTurnOff(timeoutSeconds: 2.5)
                    if !down && CellularNetworkChecker.shared.isNetworkConnectedNow {
                        // 仍未断且仍在线 ⇒ 可能 bool 极性别名（参数语义与预期相反），翻转重试一枪.
                        CellularLogStore.shared.log("私有 API 返回成功但 2.5s 未断网，翻转极性别名重试")
                        service.polarityInverted = !service.polarityInverted
                        do {
                            try await service.setCellularEnabled(false)
                            down = await CellularNetworkChecker.shared.waitForCellularToTurnOff(timeoutSeconds: 3.5)
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
                    LoginLogger.shared.log("[Cellular] 私有 API 调用完成但蜂窝未断（疑似无效果）",
                                          category: .tunnelCellular)
                    if mode == .privateOnly {
                        CellularLogStore.shared.log("模式=私有实现：不走快捷指令兜底，本次关蜂窝未执行")
                        return false
                    }
                    CellularLogStore.shared.log("自动模式：回落快捷指令路径")
                } catch {
                    // v0.3.757：CTError ≠ 0 是系统明确拒绝（真机实锤 CTError 2）——
                    // 极性重试无意义，快速按失败走（不再浪费 6s 等待）.
                    CellularLogStore.shared.log("私有 API 关蜂窝失败（\(error.localizedDescription)）")
                    LoginLogger.shared.log(
                        "[Cellular] 私有 API 关蜂窝失败（\(error.localizedDescription)）",
                        category: .tunnelCellular)
                    if mode == .privateOnly {
                        CellularLogStore.shared.log("模式=私有实现：不走快捷指令兜底，本次关蜂窝未执行")
                        return false
                    }
                    CellularLogStore.shared.log("自动模式：回落快捷指令路径")
                }
            } else {
                CellularLogStore.shared.log("私有 API 不可用")
                if mode == .privateOnly {
                    CellularLogStore.shared.log("模式=私有实现：本次关蜂窝未执行（请改用自动或快捷指令）")
                    return false
                }
            }
        }

        let name = turnOffShortcutName
        // v0.3.650：**没建快捷指令就绝不跳转**。
        //
        // 原实现直接 `UIApplication.shared.open(shortcuts://run-shortcut?name=...)`，
        // 用户没建过该快捷指令时会被强行跳到快捷指令 App，并看到
        // 「该文件不存在。未找到快捷指令 "TurnOffData"」—— 这正是用户截图报的问题。
        //
        // 现在先用持久化标记判断（iOS 无公开 API 可查快捷指令是否存在，
        // 但「用户是否已确认建好」是我们自己的信息，不算伪造系统状态）。
        guard CellularShortcutInstaller.isShortcutInstalled(name) else {
            LoginLogger.shared.log(
                "[Cellular] 快捷指令「\(name)」未创建，跳过跳转（引导用户先创建）",
                category: .tunnelCellular)
            return false
        }

        let url = Self.shortcutURL(for: name)
        CellularLogStore.shared.log("执行关蜂窝快捷指令「\(name)」（会短暂跳到快捷指令 App）")
        LoginLogger.shared.log("[Cellular] 执行关蜂窝快捷指令「\(name)」…", category: .tunnelCellular)
        let ok = await UIApplication.shared.open(url)
        guard ok else {
            LoginLogger.shared.log("[Cellular] 关蜂窝快捷指令未被系统受理（URL: \(url.absoluteString)）",
                                  category: .tunnelCellular)
            return false
        }

        didTurnOffData = true
        // 等蜂窝真正断掉：SideStore 用 `sleep(baseDelay)`（默认值见 AppConstants.Shortcuts）。
        try? await Task.sleep(nanoseconds: UInt64(turnOffBaseDelay * 1_000_000_000))
        return true
    }

    /// 本次会话内是否已经通过 `turnOffDataIfNeeded()` 关过蜂窝（只读探针）.
    ///
    /// v0.3.655 新增：给 `TequilaDashApp` 的生命周期 observer 用 ——
    /// 它在 observer 回调（非隔离域）里需要先判断「有没有真的关过」，
    /// 但不能直接读 `didTurnOffData`（`private`，且由 `stateLock` 保护）.
    /// 收一个只读访问器，让并发边界仍然留在本类内部。
    var hasTurnedOffDataInThisSession: Bool { didTurnOffData }

    /// 执行 `TurnOnData` 快捷指令（恢复蜂窝数据）. 用完即还，不留副作用.
    ///
    /// v0.3.655：**补上调用点**（此前全仓零调用点，见 `TequilaDashApp.restoreCellularDataIfNeeded`）。
    /// 同时补一道 `isShortcutInstalled` 闸门 —— 与 `turnOffDataIfNeeded` 对称：
    /// 用户没建 `TurnOnData` 时，不跳转到快捷指令 App 报「未找到快捷指令」，
    /// 只如实打日志并返回 false（`didTurnOffData` 保持 true，下个生命周期信号再试）。
    @MainActor
    @discardableResult
    func turnOnDataIfNeeded() async -> Bool {
        guard didTurnOffData else { return false }
        // v0.3.756：开蜂窝同样按开关方式三选走.
        let mode = toggleMode
        CellularLogStore.shared.log("开蜂窝开始（模式=\(mode.label)）")
        if mode != .shortcutsOnly {
            let service = CellularDataToggleService.shared
            if service.isPrivateAPIAvailable {
                do {
                    try await service.setCellularEnabled(true)
                    // v0.3.757：效果校验 —— setter 返回 0 ≠ 蜂窝真开了；8s 内没恢复联网视为未生效.
                    let back = await CellularNetworkChecker.shared.waitForNetworkToReturn(timeoutSeconds: 8)
                    if back || CellularNetworkChecker.shared.isNetworkConnectedNow {
                        didTurnOffData = false
                        CellularLogStore.shared.log("私有 API 开蜂窝生效（实测恢复联网）")
                        LoginLogger.shared.log("[Cellular] 私有 API 开蜂窝生效（实测恢复联网）",
                                              category: .tunnelCellular)
                        try? await Task.sleep(nanoseconds: UInt64(turnOnBaseDelay * 1_000_000_000))
                        return true
                    }
                    CellularLogStore.shared.log("私有 API 开蜂窝后 8s 未恢复联网，视为未生效")
                    LoginLogger.shared.log("[Cellular] 私有 API 开蜂窝后未恢复联网（疑似无效果）",
                                          category: .tunnelCellular)
                    if mode == .privateOnly {
                        CellularLogStore.shared.log("模式=私有实现：开蜂窝未生效（可到控制中心手动开蜂窝）")
                        return false
                    }
                    CellularLogStore.shared.log("自动模式：回落快捷指令路径")
                } catch {
                    CellularLogStore.shared.log("私有 API 开蜂窝失败（\(error.localizedDescription)）")
                    LoginLogger.shared.log(
                        "[Cellular] 私有 API 开蜂窝失败（\(error.localizedDescription)）",
                        category: .tunnelCellular)
                    if mode == .privateOnly {
                        CellularLogStore.shared.log("模式=私有实现：不走快捷指令兜底（可到控制中心手动开蜂窝）")
                        return false
                    }
                    CellularLogStore.shared.log("自动模式：回落快捷指令路径")
                }
            } else {
                CellularLogStore.shared.log("私有 API 不可用")
                if mode == .privateOnly {
                    CellularLogStore.shared.log("模式=私有实现：开蜂窝未执行（可到控制中心手动开蜂窝）")
                    return false
                }
            }
        }
        let name = turnOnShortcutName
        guard CellularShortcutInstaller.isShortcutInstalled(name) else {
            LoginLogger.shared.log(
                "[Cellular] 快捷指令「\(name)」未创建，跳过开蜂窝跳转（引导用户先创建）",
                category: .tunnelCellular)
            return false
        }
        let url = Self.shortcutURL(for: name)
        CellularLogStore.shared.log("执行开蜂窝快捷指令「\(name)」（会短暂跳到快捷指令 App）")
        LoginLogger.shared.log("[Cellular] 执行开蜂窝快捷指令「\(name)」…", category: .tunnelCellular)
        let ok = await UIApplication.shared.open(url)
        if ok { didTurnOffData = false }
        try? await Task.sleep(nanoseconds: UInt64(turnOnBaseDelay * 1_000_000_000))
        return ok
    }

    /// 平台是否支持（照 SideStore：tvOS 不支持）.
    var isSupported: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }

    // MARK: - 快捷指令（v0.3.650 起改为「引导用户自建」）

    /// ⚠️ 这里**没有**「自动安装快捷指令」。
    ///
    /// 历史（三段都留记录，避免下一个人再走一遍）：
    /// · v0.3.599 试过 `shortcuts://import-shortcut?...&silent=true` 静默导入
    ///   ⇒ 真机实测 URL 无效 + 强制跳转（v0.3.616 撤销）。
    /// · v0.3.616 把 installer 改成恒 false 的死函数，但没删这个入口，
    ///   于是 v0.3.647 让蜂窝真的去跑指令时就炸了「未找到 TurnOffData」。
    /// · v0.3.650 源码对照确认：LiveContainer 自己无蜂窝代码（外包 SideStore）；
    ///   SideStore `Core/Shortcuts/` 下只有 `CellularRefreshManager.swift`，
    ///   **不创建也不引导创建**（issue #1393/#1413/#1191 全是用户抱怨）。
    ///
    /// ⇒ 结论：iOS 不允许第三方代建快捷指令，两个参考项目都要求用户自建。
    ///   所以改为 UI 引导（`CellularShortcutGuideView`）+ 运行前拦截（见 `turnOffDataIfNeeded`）。
    ///
    /// 本函数保留为**兼容占位**（无调用点），不再声称能装任何东西。
    @MainActor
    @discardableResult
    func ensureShortcutsInstalled() async -> Bool {
        // 如实返回 false：我们不会、也不能替用户创建快捷指令。
        LoginLogger.shared.log(
            "[Cellular] 快捷指令需用户自建（iOS 不允许第三方代建），引导页见设置 → Cellular隧道支持",
            category: .tunnelCellular)
        return false
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
