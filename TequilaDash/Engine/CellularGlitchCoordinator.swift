//
//  CellularGlitchCoordinator.swift
//  TequilaDash
//
//  v0.3.760：蜂窝卡点协调器（Gnoix performCellularGlitchHandshake + CellularGlitchStep 同职责移植）.
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
/// 时序（与 Gnoix 1.2.16 一致）：
/// 1. 蜂窝在线 → 自动关（私有 API / 快捷指令，被拒照常继续 —— Gnoix 同款）；
/// 2. 等 NWPathMonitor 感知「断网」；自动关没断就交给用户手动关（弹窗指引）；
/// 3. 断网瞬间 = 路由重置窗口 → 睡 1.2s（Gnoix 卡点时隙）→ 执行操作；
/// 4. 完成后尝试恢复蜂窝（失败由弹窗指引手动开）.
///
/// v0.3.760 全量接入：所有建 RSD 隧道的回环操作统一经
/// `beginLoopbackGate(label:)` / `endLoopbackGate()` 接入本卡（同步链路三行接入），
/// 弹窗只管「通路建立」本身，操作成败由调用方自己的错误通道呈现.
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
    /// `showShortcutChoice`：自动模式下私有开关无效后，等待断网卡上出现
    /// 「改用快捷指令」按钮（用户裁定：自动 = 私有优先 → 卡点弹窗二选一）.
    struct ModalRequest: Identifiable {
        let id = UUID()
        let label: String
        var showShortcutChoice = false
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
    /// 出口调度的「延迟恢复蜂窝」工作项（下一次 begin 会取消它，连续操作复用窗口）.
    private var turnOnWorkItem: DispatchWorkItem?

    // MARK: - 异步 API（View 层直接用）

    /// 发起一次卡点操作（fire-and-forget；进度/结果走弹窗）.
    func run(label: String, action: @escaping @Sendable () async throws -> Void) {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.glitchFlow(label: label, action: action) }
            catch { /* 弹窗已呈现，fire-and-forget 不再外抛 */ }
            await MainActor.run { self.runTask = nil }
        }
    }

    // MARK: - 通用门（同步链路接入点：所有建 RSD 隧道的回环操作）

    /// 通用门·入口（同步，可在任意线程调）.
    ///
    /// - Wi-Fi 在线 / 已离线（窗口已开）/ 已有卡点进行中 → 返回 false，调用方直接执行；
    /// - 蜂窝单网且在线 → 阻塞本线程，弹卡点卡：自动关蜂窝 → 等断网（8s）
    ///   → 未断交给用户手动关（900s）→ 断网后睡 1.2s（路由重置时隙）→ 返回 true.
    ///
    /// 返回 true 时调用方**必须** `defer { endLoopbackGate() }`；
    /// 返回 false 时不许调 end（会错误恢复别人的蜂窝状态）.
    @discardableResult
    func beginLoopbackGate(label: String) -> Bool {
        let checker = CellularNetworkChecker.shared
        // v0.3.761：Wi-Fi 判定改 BSD 接口快照（en* 持有地址才算），utun 场景不再误判.
        if CellularNetworkChecker.captureInterfaceSnapshot().wifi { return false }
        if !checker.isNetworkConnectedNow { return false }
        gateLock.lock()
        if gateBusy || runTask != nil { gateLock.unlock(); return false }
        gateBusy = true
        gateLock.unlock()

        // 连续回环操作复用同一窗口：取消出口挂起的「延迟恢复蜂窝」.
        turnOnWorkItem?.cancel()
        turnOnWorkItem = nil

        let manager = CellularTunnelManager.shared
        let mode = manager.toggleMode
        final class GateOutcome: @unchecked Sendable {
            var down = false
            var cancelled = false
        }
        let outcome = GateOutcome()
        let sem = DispatchSemaphore(value: 0)
        let task = Task { [weak self] in
            guard let self else { sem.signal(); return }
            await MainActor.run {
                self.routeResetFired = false
                self.modalRequest = ModalRequest(label: label, showShortcutChoice: mode == .auto)
                self.phase = .waitingDisconnect(reason: "正在自动关闭「蜂窝网络」…")
            }
            _ = await manager.turnOffDataIfNeeded(orchestratedByGate: true)
            var ok = await checker.waitForCellularToTurnOff(timeoutSeconds: 8)
            if !ok, !Task.isCancelled {
                await MainActor.run { self.phase = .waitingDisconnect(reason: "请在「控制中心」关闭「蜂窝网络」") }
                ok = await checker.waitForCellularToTurnOff(timeoutSeconds: 900)
            }
            outcome.down = ok
            outcome.cancelled = Task.isCancelled
            sem.signal()
        }
        gateTask = task
        sem.wait()

        guard outcome.down, !outcome.cancelled else {
            gateLock.lock(); gateBusy = false; gateLock.unlock()
            Task { @MainActor in
                self.phase = .idle
                self.modalRequest = nil
            }
            return false
        }
        Task { @MainActor in
            self.routeResetFired = true
            self.phase = .injecting(label: label)
        }
        // Gnoix 关蜂窝后睡 1.2s 再执行：给 iOS 路由表重建留时隙.
        Thread.sleep(forTimeInterval: 1.2)
        return true
    }

    /// 通用门·出口（与 beginLoopbackGate 配对，调用方用 defer 保证执行）.
    /// 调度 5s 后恢复蜂窝（期间新 begin 会取消），弹窗随后收尾成「通路就绪」.
    func endLoopbackGate() {
        gateLock.lock(); gateBusy = false; gateLock.unlock()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                _ = await CellularTunnelManager.shared.turnOnDataIfNeeded()
                await MainActor.run { self.phase = .success }
            }
        }
        turnOnWorkItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: item)
    }

    // MARK: - 用户操作

    /// 用户在「等待断网」阶段点了取消.
    func cancel() {
        runTask?.cancel()
        gateTask?.cancel()
        CellularNetworkChecker.shared.cancelWait()
        Task { @MainActor in
            phase = .idle
            modalRequest = nil
        }
    }

    /// 弹窗「改用快捷指令」按钮：后台执行快捷指令关蜂窝；
    /// 900s 等待继续由探针感知断网自然收场，无需中断门流程.
    func switchToShortcutFallback() {
        gateLock.lock()
        let active = gateBusy
        gateLock.unlock()
        guard active else { return }
        CellularLogStore.shared.log("卡点弹窗：改用快捷指令关蜂窝")
        LoginLogger.shared.log("[Cellular] 卡点弹窗：改用快捷指令关蜂窝", category: .tunnelCellular)
        Task { @MainActor in
            _ = await CellularTunnelManager.shared.runShortcutTurnOff()
        }
    }

    /// 用户看完结果点「完成」关掉弹窗.
    func dismiss() {
        Task { @MainActor in
            phase = .idle
            modalRequest = nil
        }
    }

    // MARK: - 内部流程

    private func setPhase(_ p: Phase) async {
        await MainActor.run { phase = p }
    }

    private func glitchFlow<T>(label: String, action: @escaping @Sendable () async throws -> T) async throws -> T {
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
        // ② 已经离线：路由重置窗口已开，直接进窗口.
        if !checker.isNetworkConnectedNow {
            return try await runInWindow(label: label, action: action)
        }
        // ③ 蜂窝在线：自动关（私有 API / 快捷指令，被拒照常继续 —— Gnoix 同款）.
        await setPhase(.waitingDisconnect(reason: "正在自动关闭「蜂窝网络」…"))
        _ = await manager.turnOffDataIfNeeded()
        var down = await checker.waitForCellularToTurnOff(timeoutSeconds: 8)
        // ④ 自动关没断（私有被拒 + 快捷指令没建）：交给用户手动关，弹窗指引.
        if !down, !Task.isCancelled {
            await setPhase(.waitingDisconnect(reason: "请在「控制中心」关闭「蜂窝网络」"))
            down = await checker.waitForCellularToTurnOff(timeoutSeconds: 900)
        }
        guard down, !Task.isCancelled else {
            await setPhase(.failed(message: "等待关闭蜂窝网络超时，未执行\(label)."))
            throw CellularGlitchError(message: "等待关闭蜂窝网络超时.")
        }
        return try await runInWindow(label: label, action: action)
    }

    /// 断网窗口内执行：路由重置时隙 + 操作 + 完成后尝试恢复蜂窝.
    private func runInWindow<T>(label: String, action: @escaping @Sendable () async throws -> T) async throws -> T {
        await MainActor.run { routeResetFired = true }
        await setPhase(.injecting(label: label))
        // Gnoix 关蜂窝后睡 1.2s 再执行：给 iOS 路由表重建留时隙.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        do {
            let value = try await action()
            await setPhase(.success)
            // 完成后恢复蜂窝（复用开蜂窝全链路：私有 / 快捷指令 / 效果校验）；
            // 失败不吞结果 —— 弹窗成功页会指引手动开.
            _ = await CellularTunnelManager.shared.turnOnDataIfNeeded()
            return value
        } catch {
            await setPhase(.failed(message: error.localizedDescription))
            // 包装重抛：调用方只 catch CellularGlitchError 即可避免重复弹框.
            throw CellularGlitchError(message: error.localizedDescription)
        }
    }
}

