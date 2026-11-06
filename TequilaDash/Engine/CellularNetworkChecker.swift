//
//  CellularNetworkChecker.swift
//  TequilaDash
//
//  常驻蜂窝/Wi-Fi 网络状态探针（Gnoix `CellularNetworkChecker` 同职责）.
//

import Foundation
import Network

/// 常驻 `NWPathMonitor` 探针：
/// · `isConnected` / `isWiFi` / `isCellularOnly` 供引擎与 UI 读取；
/// · `waitForCellularToTurnOff` / `waitForNetworkToReturn` 供卡点链路等「路由重置窗口」
///   与「网络恢复」——**纯事件驱动**：`pathUpdateHandler` 是唯一推进源，
///   没有轮询、没有固定 sleep；`timeoutSeconds` 只是「iOS 万一不发 path 更新」
///   的一次性兜底上限（到点按未等到收场），不是节奏控制.
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

    /// 事件等待登记表：一个等待者 = 一个 id，**只会被唤醒一次**.
    ///
    /// 三个竞争方（先到先得，其余自动作废）：
    /// · 事件（`pathUpdateHandler`）→ `finishAll(true)`；
    /// · 取消（`cancelWait()`，由 epoch 推进触发）→ `finishAll(false)`；
    /// · 兜底上限（一次性 `asyncAfter`）→ `finish(id, false)`.
    private final class WaiterRegistry: @unchecked Sendable {
        private final class Slot {
            let continuation: CheckedContinuation<Bool, Never>
            var ceiling: DispatchWorkItem?
            var done = false
            init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        }
        private let lock = NSLock()
        private var slots: [UInt64: Slot] = [:]
        private var nextID: UInt64 = 0

        func enroll(_ continuation: CheckedContinuation<Bool, Never>) -> UInt64 {
            let slot = Slot(continuation)
            lock.lock()
            nextID += 1
            let id = nextID
            slots[id] = slot
            lock.unlock()
            return id
        }

        /// 挂兜底上限任务（登记完成后立刻挂）.
        func attachCeiling(_ id: UInt64, _ work: DispatchWorkItem) {
            lock.lock()
            let slot = slots[id]
            if let slot, !slot.done { slot.ceiling = work } else { lock.unlock(); work.cancel(); return }
            lock.unlock()
        }

        /// 按 id 唤醒（幂等）.
        func finish(_ id: UInt64, _ value: Bool) {
            lock.lock()
            guard let slot = slots[id], !slot.done else { lock.unlock(); return }
            slot.done = true
            slots.removeValue(forKey: id)
            let ceiling = slot.ceiling
            lock.unlock()
            ceiling?.cancel()
            slot.continuation.resume(returning: value)
        }

        /// 唤醒全部（事件 / 取消）.
        func finishAll(_ value: Bool) {
            lock.lock()
            let firing = slots.values.filter { !$0.done }
            firing.forEach { $0.done = true }
            slots.removeAll(keepingCapacity: true)
            lock.unlock()
            firing.forEach { slot in
                slot.ceiling?.cancel()
                slot.continuation.resume(returning: value)
            }
        }
    }
    /// 「蜂窝已断」等待者.
    private let disconnectRegistry = WaiterRegistry()
    /// 「网络已恢复」等待者.
    private let reconnectRegistry = WaiterRegistry()
    /// 兜底上限的一次性定时器队列（不跑轮询，只挂 asyncAfter）.
    private let ceilingQueue = DispatchQueue(label: "com.tequila.dash.cellular-network-checker.ceiling")

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
                // 网络断开 = 蜂窝关闭触发的路由重置窗口已开 ⇒ 唤醒「已断」等待者.
                self.disconnectRegistry.finishAll(true)
            } else {
                // 恢复联网 = 「开蜂窝生效」的实测证据 ⇒ 唤醒「已恢复」等待者.
                self.reconnectRegistry.finishAll(true)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    /// 当前网络在线快照（读带锁镜像，不等主线程发布）.
    var isNetworkConnectedNow: Bool { connectedBox.value }


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
    ///
    /// 推进只靠 `pathUpdateHandler` 事件；`timeoutSeconds` 为一次性兜底上限.
    /// - Returns: 已断 / 等待期间断网 = `true`；上限到点仍在线 = `false`.
    ///   返回 `false` 不阻断调用方：后续还有隧道就绪探测兜底.
    func waitForCellularToTurnOff(timeoutSeconds: Double, shouldAbort: (() -> Bool)? = nil) async -> Bool {
        if shouldAbort?() == true || Task.isCancelled { return false }
        if !connectedBox.value { return true }
        let woken: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let id = disconnectRegistry.enroll(continuation)
            // 登记与事件之间的竞态：登记瞬间蜂窝可能已断（path 回调可能已跑完）.
            if !connectedBox.value { disconnectRegistry.finish(id, true); return }
            if shouldAbort?() == true || Task.isCancelled { disconnectRegistry.finish(id, false); return }
            let work = DispatchWorkItem { [weak self] in self?.disconnectRegistry.finish(id, false) }
            disconnectRegistry.attachCeiling(id, work)
            self.ceilingQueue.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
        }
        // 唤醒可能略滞后于事实（path 回调与本地读序），出口按事实复核一次.
        return woken || !connectedBox.value
    }

    /// 取消全部未决等待（按「未等到」收场）. epoch 推进即调用，取消即刻生效、零轮询.
    func cancelWait() {
        disconnectRegistry.finishAll(false)
        reconnectRegistry.finishAll(false)
    }

    /// 等待网络恢复在线（开蜂窝效果校验用）. 同上，纯事件驱动 + 一次性上限.
    /// - Returns: 期间恢复联网 = `true`；上限到点仍离线 = `false`.
    func waitForNetworkToReturn(timeoutSeconds: Double, shouldAbort: (() -> Bool)? = nil) async -> Bool {
        if shouldAbort?() == true || Task.isCancelled { return false }
        if connectedBox.value { return true }
        let woken: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let id = reconnectRegistry.enroll(continuation)
            if connectedBox.value { reconnectRegistry.finish(id, true); return }
            if shouldAbort?() == true || Task.isCancelled { reconnectRegistry.finish(id, false); return }
            let work = DispatchWorkItem { [weak self] in self?.reconnectRegistry.finish(id, false) }
            reconnectRegistry.attachCeiling(id, work)
            self.ceilingQueue.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
        }
        return woken || connectedBox.value
    }

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
