//
//  CellularGlitchCoordinator.swift
//  TequilaDash
//
//  v0.3.760：蜂窝卡点协调器（Gnoix performCellularGlitchHandshake + CellularGlitchStep 同职责移植）.
//

import Foundation
import SwiftUI

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
final class CellularGlitchCoordinator: ObservableObject, @unchecked Sendable {
    static let shared = CellularGlitchCoordinator()

    enum Phase: Equatable {
        case idle
        /// 等待「断网」被感知（reason 说明当前是自动尝试还是等用户手动）.
        case waitingDisconnect(reason: String)
        /// 断网窗口已开（路由重置进行中），正在执行操作.
        case injecting(label: String)
        case success
        case failed(message: String)
    }

    /// 弹窗请求（Identifiable 供 RootView 的 .sheet(item:)）.
    struct ModalRequest: Identifiable {
        let id = UUID()
        let label: String
    }

    /// 卡点路径的失败（弹窗已展示过原因，调用方不必再弹自己的错误框）.
    struct GlitchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var modalRequest: ModalRequest?
    /// 「蜂窝断开成功触发了 iOS 底层网络路由重置」是否已发生（弹窗正文据此切换）.
    @Published private(set) var routeResetFired = false

    private var runTask: Task<Void, Never>?

    /// 发起一次卡点操作（fire-and-forget；进度/结果走弹窗）.
    func run(label: String, action: @escaping @Sendable () async throws -> Void) {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.glitchFlow(label: label, action: action)
            await MainActor.run { self.runTask = nil }
        }
    }

    /// await 版：等卡点流程收场并把结果带回调用方.
    /// Wi-Fi 在线时不开弹窗直接执行；卡点路径的失败以 GlitchError 抛回
    /// （弹窗里已经展示过原因，调用方不必重复提示）.
    func runAndWait<T>(label: String, action: @escaping @Sendable () async throws -> T) async throws -> T {
        guard runTask == nil else {
            throw GlitchError(message: "已有蜂窝卡点操作进行中，请等它结束再试.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeOnce(continuation: continuation)
            runTask = Task { [weak self] in
                guard let self else { return }
                var outcome: Result<T, Error>?
                do {
                    try await self.glitchFlow(label: label, action: action)
                    // glitchFlow 正常返回不代表 action 成功 —— 成败以 phase 为准.
                    if case .failed(let message) = self.phase {
                        outcome = .failure(GlitchError(message: message))
                    }
                } catch {
                    outcome = .failure(error)
                }
                await MainActor.run { self.runTask = nil }
                gate.resume(with: outcome)
            }
        }
    }

    /// 用户在「等待断网」阶段点了取消.
    func cancel() {
        runTask?.cancel()
        CellularNetworkChecker.shared.cancelWait()
        Task { @MainActor in
            phase = .idle
            modalRequest = nil
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

    private func glitchFlow(label: String, action: @escaping @Sendable () async throws -> Void) async {
        let checker = CellularNetworkChecker.shared
        let manager = CellularTunnelManager.shared
        await MainActor.run {
            routeResetFired = false
            modalRequest = ModalRequest(label: label)
        }
        do {
            // ① Wi-Fi 在线：无需卡点，直接执行（不开弹窗）.
            if checker.isWiFi && checker.isNetworkConnectedNow {
                try await action()
                return
            }
            // ② 已经离线：路由重置窗口已开，直接进窗口.
            if !checker.isNetworkConnectedNow {
                try await runInWindow(label: label, action: action)
                return
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
                return
            }
            try await runInWindow(label: label, action: action)
        } catch is CancellationError {
            await setPhase(.idle)
        } catch {
            await setPhase(.failed(message: error.localizedDescription))
        }
    }

    /// 断网窗口内执行：路由重置时隙 + 操作 + 完成后尝试恢复蜂窝.
    private func runInWindow(label: String, action: @escaping @Sendable () async throws -> Void) async {
        await MainActor.run { routeResetFired = true }
        await setPhase(.injecting(label: label))
        // Gnoix 关蜂窝后睡 1.2s 再执行：给 iOS 路由表重建留时隙.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        do {
            try await action()
        } catch {
            await setPhase(.failed(message: error.localizedDescription))
            return
        }
        await setPhase(.success)
        // 完成后恢复蜂窝（复用开蜂窝全链路：私有 / 快捷指令 / 效果校验）；
        // 失败不吞结果 —— 弹窗成功页会指引手动开.
        _ = await CellularTunnelManager.shared.turnOnDataIfNeeded()
    }
}

/// continuation 只许 resume 一次的包装（runAndWait 的成败都要收场）.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }
    func resume(with outcome: Result<T, Error>?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        switch outcome {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        case nil: continuation.resume(throwing: GlitchError(message: "蜂窝卡点流程提前结束."))
        }
    }
}
