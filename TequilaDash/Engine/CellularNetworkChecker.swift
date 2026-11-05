//
//  CellularNetworkChecker.swift
//  TequilaDash
//
//  v0.3.755：常驻蜂窝/Wi-Fi 网络状态探针（Gnoix `CellularNetworkChecker` 同职责）.
//

import Foundation
import Network

/// 常驻 `NWPathMonitor` 探针：
/// · `isConnected` / `isWiFi` / `isCellularOnly` 供引擎与 UI 读取；
/// · `waitForCellularToTurnOff(timeoutSeconds:)` 供关蜂窝后等「路由重置窗口」——
///   蜂窝真正断掉的瞬间窗口打开，固定 sleep 只能赌时长.
final class CellularNetworkChecker: ObservableObject, @unchecked Sendable {
    static let shared = CellularNetworkChecker()

    @Published private(set) var isConnected: Bool = true
    @Published private(set) var isWiFi: Bool = true
    @Published private(set) var isCellularOnly: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.tequila.dash.cellular-network-checker")

    /// 最新一次 path 回调的「是否在线」带锁镜像（@Published 走主线程发布，读侧可能滞后一帧）.
    private final class ConnectedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = true
        func set(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    }
    private let connectedBox = ConnectedBox()

    /// 「蜂窝已断」等待：断网 resume(true)，超时 resume(false).
    private final class WaitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        /// 存入等待者；已有等待者时返回 false（避免重复等待互相踩）.
        func store(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard self.continuation == nil else { return false }
            self.continuation = continuation
            return true
        }

        func resumeIfPending(_ result: Bool) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }
    private let waitBox = WaitBox()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            let cellularOnly = connected && !wifi && path.usesInterfaceType(.cellular)
            self.connectedBox.set(connected)
            DispatchQueue.main.async {
                self.isConnected = connected
                self.isWiFi = wifi
                self.isCellularOnly = cellularOnly
            }
            if !connected {
                // 网络断开 = 蜂窝关闭触发的路由重置窗口已开.
                self.waitBox.resumeIfPending(true)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    /// 当前网络在线快照（读带锁镜像，不等主线程发布）.
    var isNetworkConnectedNow: Bool { connectedBox.value }

    // MARK: - BSD 接口快照（Gnoix `isWiFiInterfaceActive` 同款判定源）

    /// getifaddrs() 枚举 BSD 接口得到的状态快照：
    /// · `wifi` = en* 在 UP+RUNNING 且持有 IPv4/IPv6 地址（与状态栏 Wi-Fi 图标同源）；
    /// · `cellular` = pdp_ip* 同条件；
    /// · `utun` = utun* 同条件（VPN/隧道通道）.
    ///
    /// `NWPathMonitor.usesInterfaceType` 只描述「默认路由路径」，蜂窝 + utun 并存时会错判
    /// （连接诊断把蜂窝显示成 Wi-Fi 的根因）；接口状态是确定性事实.
    struct InterfaceSnapshot: Equatable {
        var wifi = false
        var cellular = false
        var utun = false
    }

    static func captureInterfaceSnapshot() -> InterfaceSnapshot {
        var snapshot = InterfaceSnapshot()
        var listPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&listPtr) == 0, let first = listPtr else { return snapshot }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = cur.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0 else { continue }
            guard let addr = cur.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            if name.hasPrefix("en") {
                snapshot.wifi = true
            } else if name.hasPrefix("pdp_ip") {
                snapshot.cellular = true
            } else if name.hasPrefix("utun") {
                snapshot.utun = true
            }
        }
        return snapshot
    }

    /// 等待网络真的断掉（Gnoix `waitForCellularToTurnOff` 同职责）.
    /// - Returns: 已断 / 等待期间断网 = `true`；超时仍在线 = `false`.
    ///   超时 `false` 不阻断调用方：后续还有隧道就绪探测兜底.
        func waitForCellularToTurnOff(timeoutSeconds: Double, shouldAbort: (() -> Bool)? = nil) async -> Bool {
        if !connectedBox.value { return true }
        // v0.3.763：100ms 切片轮询（感知即毫秒级推进），废弃单等待者 WaitBox ——
        // 多个等待者互抢一个坑位、cancel 只能杀「当时 pending」的那个，是取消不立即生效的根因.
        let deadline = Date().timeIntervalSinceReferenceDate + timeoutSeconds
        while Date().timeIntervalSinceReferenceDate < deadline {
            if shouldAbort?() == true { return false }
            if Task.isCancelled { return false }
            if !connectedBox.value { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !connectedBox.value
    }

    /// 取消未决等待（按「未等到」收场）.
    func cancelWait() {
        waitBox.resumeIfPending(false)
    }

    /// 等待网络恢复在线（v0.3.757：开蜂窝效果校验用）.
    /// - Returns: 期间恢复联网 = `true`；超时仍离线 = `false`.
        func waitForNetworkToReturn(timeoutSeconds: Double, shouldAbort: (() -> Bool)? = nil) async -> Bool {
        if connectedBox.value { return true }
        // Date 比较走 Double 时间戳（>=/<= 是 weak import 雷，守卫 swift_date_compare_guard.py 拦截）.
        // v0.3.763：100ms 切片 + shouldAbort 令牌，网络恢复即毫秒级返回.
        let deadline = Date().timeIntervalSinceReferenceDate + timeoutSeconds
        while Date().timeIntervalSinceReferenceDate < deadline {
            if shouldAbort?() == true { return false }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
            if connectedBox.value { return true }
        }
        return connectedBox.value
    }

    /// 一次性 Wi-Fi 探针（Gnoix `isWiFiInterfaceActive()` 同职责）.
    /// 探不到不冒充 Wi-Fi（默认 `false`，与 `isWiFiSatisfied` 的超时放行策略相反）.
    static func isWiFiInterfaceActive(timeout: TimeInterval = 1.0) -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.tequila.dash.wifi-probe")
        let semaphore = DispatchSemaphore(value: 0)
        let box = ConnectedBox()
        box.set(false)
        monitor.pathUpdateHandler = { path in
            box.set(path.usesInterfaceType(.wifi))
            semaphore.signal()
        }
        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        monitor.cancel()
        return box.value
    }
}
