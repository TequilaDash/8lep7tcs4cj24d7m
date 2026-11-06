//
//  CellularGlitchCoordinator.swift
//  TequilaDash
//
//  v0.3.760：蜂窝卡点协调器（Gnoix performCellularGlitchHandshake + CellularGlitchStep 同职责移植）.
//  v0.3.763：取消立即生效（epoch 令牌）+ 毫秒级响应（删全部秒级固定等待）+ 网络恢复自动收卡.
//

import Foundation
import SwiftUI

/// 卡点路径的失败（弹窗已展示过原因，调用方不必再弹自己的错误框）.
/// 文件级：供 CellularGlitchCoordinator 与 ResumeOnce 共用（嵌套类型跨类型不可见）.
struct CellularGlitchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 蜂窝卡点协调器 —— Gnoix「Glitch Protocol / 卡点时序」的移植版.
///
/// 纯蜂窝（无 Wi-Fi）时 iOS 会让本机配对/回环通路休眠，misagent 等依赖
/// RSD 隧道的操作建不起隧道。Gnoix 的解法：
/// 关掉蜂窝触发 iOS 底层路由表重建，在断网瞬间的窗口内抢建隧道执行注入；
/// 窗口期建立的通路在蜂窝恢复后仍可用（真机实测），App 退后台后失效需再卡点.
///
/// 时序（v0.3.763 事件驱动版）：
/// 1. 蜂窝在线 → 自动关（私有 API，被拒照常继续 —— Gnoix 同款）；
/// 2. 等 NWPathMonitor 感知「断网」（100ms 切片轮询，毫秒级推进）；
///    自动关没断就交给用户手动关（弹窗指引）；
/// 3. 断网瞬间 = 路由重置窗口 → **立即**执行操作（v0.3.763 删除 Gnoix 固定 1.2s 时隙）；
/// 4. 操作完成即显示就绪卡并尝试恢复蜂窝；**检测到网络恢复即自动收卡**
///    （Gnoix「自动返回」同款，事件驱动非定时）.
///
/// 取消语义（v0.3.763）：「cancel()」推进 epoch 令牌，所有在飞的等待/轮询
/// 在下一个 ≤100ms 切片内中止，弹卡立即消失、已关掉的蜂窝立即恢复.
final class CellularGlitchCoordinator: ObservableObject, @unchecked Sendable {
    static let shared = CellularGlitchCoordinator()

    enum Phase: Equatable {
        case idle
        /// 等待「断网」被感知（reason 说明当前是自动尝试还是等用户手动）.
        case waitingDisconnect(reason: String)
        /// 断网窗口已开（路由重置进行中），正在建立通路/执行操作.
        case injecting(label: String)
        case success
        case failed(message: String)
    }

    /// 弹窗请求（Identifiable 供 RootView 的 .sheet(item:)）.
    /// v0.3.762：快捷指令方案删除 —— 卡点弹窗只有「继续等手动关蜂窝」一条路，无二选按钮.
    struct ModalRequest: Identifiable {
        let id = UUID()
        let label: String
    }

    /// 异步门的判定结果（「awaitLoopbackGate」专用；同步门「beginLoopbackGate」维持 Bool 契约）.
    enum LoopbackGateVerdict {
        /// 无需卡点（Wi-Fi 在线 / 已离线窗口已开 / 已有卡点在跑）→ 调用方直接执行.
        case notNeeded
        /// 窗口已开 → 调用方执行，并用「endLoopbackGate()」配对收尾.
        case opened
        /// 用户取消或等待超时 → 调用方不要执行.
        case unavailable(message: String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var modalRequest: ModalRequest?
    /// 「蜂窝断开成功触发了 iOS 底层网络路由重置」是否已发生（弹窗正文据此切换）.
    @Published private(set) var routeResetFired = false

    private var runTask: Task<Void, Never>?
    private var gateTask: Task<Void, Never>?
    /// 同步门互斥（begin/end 都可能来自任意线程）.
    private let gateLock = NSLock()
    private var gateBusy = false
    /// 出口的「恢复蜂窝 + 自动收卡」任务（下一次 begin 会取消它，连续操作复用窗口）.
    private var restoreTask: Task<Void, Never>?

    // MARK: - epoch 取消令牌（v0.3.763：取消立即生效的核心）

    private let epochLock = NSLock()
    private var epochValue = 0

    /// 推进令牌：先前所有引用旧 epoch 的等待/轮询/收尾在下一个轮询切片内作废.
    @discardableResult
    private func bumpEpoch() -> Int {
        epochLock.lock()
        epochValue += 1
        let value = epochValue
        epochLock.unlock()
        return value
    }

    private func currentEpoch() -> Int {
        epochLock.lock()
        defer { epochLock.unlock() }
        return epochValue
    }

    /// 引用的 epoch 是否已过期（过期 = 已被取消或被新流程取代）.
    func isCancelled(_ epoch: Int) -> Bool {
        epochLock.lock()
        defer { epochLock.unlock() }
        return epoch != epochValue
    }

    // MARK: - 异步 API（View 层直接用）

    /// 发起一次卡点操作（fire-and-forget；进度/结果走弹窗）.
    func run(label: String, action: @escaping @Sendable () async throws -> Void) {
        guard runTask == nil else { return }
        let myEpoch = bumpEpoch()
        runTask = Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.glitchFlow(label: label, epoch: myEpoch, action: action) }
            catch { /* 弹窗已呈现，fire-and-forget 不再外抛 */ }
            await MainActor.run { self.runTask = nil }
        }
    }

    // MARK: - 通用门（同步链路接入点：所有建 RSD 隧道的回环操作）

    /// 通用门·入口（同步，可在任意线程调）.
    ///
    /// - Wi-Fi 在线 / 已离线（窗口已开）/ 已有卡点进行中 → 返回 false，调用方直接执行；
    /// - 蜂窝单网且在线 → 阻塞本线程，弹卡点卡：自动关蜂窝 → 等断网（8s）
    ///   → 未断交给用户手动关（900s）→ 断网感知即返回 true（毫秒级，无固定时隙）.
    ///
    /// 返回 true 时调用方**必须**用「defer { endLoopbackGate() }」配对；
    /// 返回 false 时不许调 end（会错误恢复别人的蜂窝状态）.
    @discardableResult
    func beginLoopbackGate(label: String) -> Bool {
        let checker = CellularNetworkChecker.shared
        // v0.3.761：Wi-Fi 判定改 BSD 接口快照（en* 持有地址才算），utun 场景不再误判.
        if CellularNetworkChecker.captureInterfaceSnapshot().wifi { return false }
        // v0.3.771（重做）：门只信「通路真的建着」—— TunnelGate.isReady 只被硬证据置真
        // （断网窗口内操作真实成功 / utun 对端可达）；直连端口探测不再参与判定：探测连得上
        // RSD 端口 ≠ 隧道能用（LC 实测假阳性，门放行后建隧道失败，卡点兜底被跳过）.
        if TunnelGate.isReady { return false }
        if !checker.isNetworkConnectedNow { return false }
        gateLock.lock()
        if gateBusy || runTask != nil { gateLock.unlock(); return false }
        gateBusy = true
        gateLock.unlock()

        // 连续回环操作复用同一窗口：取消出口挂起的「恢复蜂窝 + 自动收卡」.
        restoreTask?.cancel()
        restoreTask = nil

        let myEpoch = bumpEpoch()
        final class GateOutcomeBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: (down: Bool, cancelled: Bool) = (false, true)
            func set(_ v: (down: Bool, cancelled: Bool)) {
                lock.lock(); value = v; lock.unlock()
            }
            func get() -> (down: Bool, cancelled: Bool) {
                lock.lock(); defer { lock.unlock() }
                return value
            }
        }
        let box = GateOutcomeBox()
        let sem = DispatchSemaphore(value: 0)
        let task = Task { [weak self] in
            guard let self else { sem.signal(); return }
            let outcome = await self.gateOutcome(label: label, epoch: myEpoch)
            box.set(outcome)
            sem.signal()
        }
        gateTask = task
        sem.wait()

        let outcome = box.get()
        guard outcome.down, !outcome.cancelled else {
            gateLock.lock()
            gateBusy = false
            gateLock.unlock()
            Task { @MainActor in
                if self.isCancelled(myEpoch) {
                    self.phase = .idle
                    self.modalRequest = nil
                } else if !outcome.down {
                    self.phase = .failed(message: "等待关闭蜂窝网络超时，未执行" + label + ".")
                }
            }
            return false
        }
        Task { @MainActor in
            self.routeResetFired = true
            self.phase = .injecting(label: label)
        }
        // 断网感知即推进（毫秒级）：路由重置窗口已开，建隧道重试链路自带抖动吸收.
        return true
    }

    /// 异步门（actor / async 调用方用）：语义见「LoopbackGateVerdict」.
    func awaitLoopbackGate(label: String) async -> LoopbackGateVerdict {
        let checker = CellularNetworkChecker.shared
        if CellularNetworkChecker.captureInterfaceSnapshot().wifi { return .notNeeded }
        // v0.3.771（重做）：通路真的建着（硬证据置真，同 beginLoopbackGate 注释）⇒ 不再二次卡点.
        if TunnelGate.isReady { return .notNeeded }
        if !checker.isNetworkConnectedNow { return .notNeeded }
        let acquired: Bool = gateLock.withLock {
            if gateBusy || runTask != nil { return false }
            gateBusy = true
            return true
        }
        if !acquired { return .notNeeded }

        restoreTask?.cancel()
        restoreTask = nil

        let myEpoch = bumpEpoch()
        let outcome = await gateOutcome(label: label, epoch: myEpoch)
        guard outcome.down, !outcome.cancelled else {
            gateLock.withLock { gateBusy = false }
            await MainActor.run {
                if self.isCancelled(myEpoch) {
                    self.phase = .idle
                    self.modalRequest = nil
                } else {
                    self.phase = .failed(message: "等待关闭蜂窝网络超时，未执行" + label + ".")
                }
            }
            return .unavailable(message: "本地配对通路未能建立（蜂窝卡点未通过或已取消）.")
        }
        await MainActor.run {
            self.routeResetFired = true
            self.phase = .injecting(label: label)
        }
        return .opened
    }

    /// 门核心：弹卡 → 自动关 → 等断网（8s）→ 手动（900s）。
    /// 全部等待都挂 epoch 中止令牌 —— cancel() 后所有切片在 ≤100ms 内退出.
    private func gateOutcome(label: String, epoch: Int) async -> (down: Bool, cancelled: Bool) {
        let checker = CellularNetworkChecker.shared
        let manager = CellularTunnelManager.shared
        if isCancelled(epoch) { return (false, true) }
        await MainActor.run {
            guard !self.isCancelled(epoch) else { return }
            self.routeResetFired = false
            self.modalRequest = ModalRequest(label: label)
            self.phase = .waitingDisconnect(reason: "正在自动关闭「蜂窝网络」…")
        }
        if isCancelled(epoch) { return (false, true) }
        _ = await manager.turnOffDataIfNeeded(
            orchestratedByGate: true,
            shouldAbort: { [weak self] in self?.isCancelled(epoch) ?? true })
        if isCancelled(epoch) { return (false, true) }
        var ok = await checker.waitForCellularToTurnOff(
            timeoutSeconds: 8,
            shouldAbort: { [weak self] in self?.isCancelled(epoch) ?? true })
        if !ok, !isCancelled(epoch) {
            await MainActor.run {
                guard !self.isCancelled(epoch) else { return }
                self.phase = .waitingDisconnect(reason: "请在「控制中心」关闭「蜂窝网络」")
            }
            if isCancelled(epoch) { return (false, true) }
            ok = await checker.waitForCellularToTurnOff(
                timeoutSeconds: 900,
                shouldAbort: { [weak self] in self?.isCancelled(epoch) ?? true })
        }
        let cancelled = isCancelled(epoch)
        return (ok && !cancelled, cancelled)
    }

    /// 通用门·出口（与 begin/await 配对，调用方用 defer 保证执行）.
    /// 完成即收尾：立即尝试恢复蜂窝（私有 API），显示就绪卡；
    /// 检测到网络恢复即自动收卡（Gnoix「自动返回」同款，事件驱动非定时）.
    func endLoopbackGate() {
        gateLock.lock()
        gateBusy = false
        gateLock.unlock()
        let myEpoch = currentEpoch()
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            guard let self else { return }
            await self.finishAndAutoDismiss(epoch: myEpoch)
        }
    }

    /// 收尾共用：恢复蜂窝 → 就绪卡 → 网络恢复自动关卡.
    private func finishAndAutoDismiss(epoch: Int) async {
        _ = await CellularTunnelManager.shared.turnOnDataIfNeeded(
            shouldAbort: { [weak self] in self?.isCancelled(epoch) ?? true })
        await MainActor.run {
            guard !self.isCancelled(epoch) else { return }
            self.phase = .success
        }
        let back = await CellularNetworkChecker.shared.waitForNetworkToReturn(
            timeoutSeconds: 900,
            shouldAbort: { [weak self] in self?.isCancelled(epoch) ?? true })
        await MainActor.run {
            guard !self.isCancelled(epoch) else { return }
            if back || CellularNetworkChecker.shared.isNetworkConnectedNow {
                self.phase = .idle
                self.modalRequest = nil
            }
        }
    }

    /// 仅恢复蜂窝，不碰 UI（cancel 路径专用：用户取消后不许再弹任何卡）.
    private func restoreOnly(epoch: Int) async {
        _ = await CellularTunnelManager.shared.turnOnDataIfNeeded(
            shouldAbort: { [weak self] in self?.isCancelled(epoch) ?? true })
    }

    // MARK: - 用户操作

    /// 用户在「等待断网」阶段点了取消：推进 epoch，所有等待 ≤100ms 内中止，
    /// 弹卡立即收；已经自动关掉的蜂窝立即开始恢复（「没有及时释放」的修复）.
    func cancel() {
        let myEpoch = bumpEpoch()
        runTask?.cancel()
        gateTask?.cancel()
        restoreTask?.cancel()
        CellularNetworkChecker.shared.cancelWait()
        Task { @MainActor in
            self.phase = .idle
            self.modalRequest = nil
        }
        restoreTask = Task { [weak self] in
            guard let self else { return }
            await self.restoreOnly(epoch: myEpoch)
        }
    }

    /// 用户看完结果点「完成」关掉弹窗（同时中止后台恢复监控）.
    func dismiss() {
        bumpEpoch()
        restoreTask?.cancel()
        Task { @MainActor in
            phase = .idle
            modalRequest = nil
        }
    }

    // MARK: - 内部流程

    private func setPhase(_ p: Phase) async {
        await MainActor.run { phase = p }
    }

    private func glitchFlow<T>(label: String, epoch: Int, action: @escaping @Sendable () async throws -> T) async throws -> T {
        let checker = CellularNetworkChecker.shared
        let manager = CellularTunnelManager.shared
        await MainActor.run {
            routeResetFired = false
            modalRequest = ModalRequest(label: label)
        }
        // ① Wi-Fi 在线：无需卡点，直接执行（不开弹窗）.（v0.3.761：接口快照判定）
        if CellularNetworkChecker.captureInterfaceSnapshot().wifi {
            return try await action()
        }
        // ①b v0.3.771（重做）：通路真的建着 ⇒ 不弹卡直接执行（置真只认硬证据）.
        if TunnelGate.isReady {
            return try await action()
        }
        // ② 已经离线：路由重置窗口已开，直接进窗口.
        if !checker.isNetworkConnectedNow {
            return try await runInWindow(label: label, epoch: epoch, action: action)
        }
        // ③ 蜂窝在线：自动关（私有 API，被拒照常继续 —— Gnoix 同款）.
        await setPhase(.waitingDisconnect(reason: "正在自动关闭「蜂窝网络」…"))
        _ = await manager.turnOffDataIfNeeded(
            shouldAbort: { [weak self] in self?.isCancelled(epoch) ?? true })
        var down = await checker.waitForCellularToTurnOff(
            timeoutSeconds: 8,
            shouldAbort: { [weak self] in self?.isCancelled(epoch) ?? true })
        // ④ 自动关没断（私有被拒）：交给用户手动关，弹窗指引.
        if !down, !isCancelled(epoch) {
            await setPhase(.waitingDisconnect(reason: "请在「控制中心」关闭「蜂窝网络」"))
            down = await checker.waitForCellularToTurnOff(
                timeoutSeconds: 900,
                shouldAbort: { [weak self] in self?.isCancelled(epoch) ?? true })
        }
        guard down, !isCancelled(epoch) else {
            if isCancelled(epoch) {
                await MainActor.run {
                    self.phase = .idle
                    self.modalRequest = nil
                }
            } else {
                await setPhase(.failed(message: "等待关闭蜂窝网络超时，未执行" + label + "."))
            }
            throw CellularGlitchError(message: "等待关闭蜂窝网络超时.")
        }
        return try await runInWindow(label: label, epoch: epoch, action: action)
    }

    /// 断网窗口内执行：断网感知即推进（无固定时隙）+ 操作 + 完成后恢复蜂窝并自动收卡.
    private func runInWindow<T>(label: String, epoch: Int, action: @escaping @Sendable () async throws -> T) async throws -> T {
        await MainActor.run { routeResetFired = true }
        await setPhase(.injecting(label: label))
        do {
            let value = try await action()
            // v0.3.771（重做）：断网窗口内操作真实成功 = 通路真实建立的最强证据，在此置真 ——
            // 蜂窝恢复后门据此放行不再二次卡点（Gnoix 对齐：关一次蜂窝，之后蜂窝下直接用）.
            TunnelGate.setReady(true)
            TunnelDiagnostics.note("蜂窝通路", "断网窗口内操作成功，通路已真实建立，蜂窝恢复后不再卡点")
            if !isCancelled(epoch) {
                await setPhase(.success)
                restoreTask?.cancel()
                restoreTask = Task { [weak self] in
                    guard let self else { return }
                    await self.finishAndAutoDismiss(epoch: epoch)
                }
            }
            return value
        } catch {
            if isCancelled(epoch) {
                await MainActor.run {
                    if self.isCancelled(epoch) {
                        self.phase = .idle
                        self.modalRequest = nil
                    }
                }
                throw CellularGlitchError(message: "已取消.")
            }
            await setPhase(.failed(message: error.localizedDescription))
            // 包装重抛：调用方只 catch CellularGlitchError 即可避免重复弹框.
            throw CellularGlitchError(message: error.localizedDescription)
        }
    }
}
