//
//  ProcessManagerViewModel.swift
//  TequilaDash
//
//  从 ProcessManagerView.swift 拆分而来：原文件 1298 行、9 个 top-level 声明，
//  拆成 4 个文件以满足「每文件 ≤ 600 行」的规模约束.
//  本文件只承载视图模型 ProcessManagerViewModel，
//  成员逐字节原样搬运，未做任何逻辑改动.
//

import SwiftUI
import Foundation
import Darwin

/// Swift 6：本类是 SwiftUI 的 UI 模型，只在主线程读写（唯一消费者 ProcessManagerView）→
/// 标 `@MainActor` 是语义正确的隔离，同时让 `self` 成为 Sendable：
/// 各 Task / Task.detached 内层 `MainActor.run { self.x = … }` 捕获 self 的
/// `sending 'self'` 诊断自然消失（那些闭包本来就在主线程执行，线程语义与顺序不变）。
/// verifyKill 注释中「@MainActor 类内 Task {} 继承主线程隔离」即为此预留.
@MainActor
final class ProcessManagerViewModel: ObservableObject {
    @Published private(set) var processes: [ProcessEntry] = []
    /// v0.3.47：排序模式
    /// v0.3.47：排序模式
    @Published var sortMode: ProcessSortMode = .defaultOrder
    /// v0.3.45：内存监控开关（持久化到 UserDefaults）
    @Published var memoryWatchEnabled: Bool = UserDefaults.standard.bool(forKey: "ProcessMemoryWatch") {
        didSet { UserDefaults.standard.set(memoryWatchEnabled, forKey: "ProcessMemoryWatch") }
    }
    @Published var searchText: String = ""
    @Published var isRefreshing = false
    @Published private(set) var activeControlState: (pid: Int, action: ProcessControlAction)?
    /// 统一的提示弹窗通道（操作结果 / 错误）.v0.2.106：此前双 .alert 并存，
    /// 后注册覆盖先注册导致「进程已结束」等操作弹窗从不弹出.
    @Published var alertItem: ProcessAlert?

    private var refreshTask: Task<Void, Never>?
    private var controlTimeoutTask: Task<Void, Never>?
    /// SIGKILL 后的二次验证任务（检查目标 PID 是否真的消失）.
    private var killVerifyTask: Task<Void, Never>?

    /// v0.3.47：排序后的进程列表（在搜索过滤基础上）
    var sortedProcesses: [ProcessEntry] {
        switch sortMode {
        case .defaultOrder:
            return filteredProcesses
        case .byName:
            return filteredProcesses.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .byMemory:
            // 未上报内存（nil）排最后；其余按占用从大到小
            return filteredProcesses.sorted {
                ($0.memoryBytes ?? -1) > ($1.memoryBytes ?? -1)
            }
        }
    }

    var filteredProcesses: [ProcessEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return processes }
        return processes.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            $0.executablePath.localizedCaseInsensitiveContains(query) ||
            "\($0.pid)".contains(query)
        }
    }

    var isRunningControlAction: Bool { activeControlState != nil }

    func activeControl(for process: ProcessEntry) -> ProcessControlAction? {
        guard activeControlState?.pid == process.pid else { return nil }
        return activeControlState?.action
    }

    func startAutoRefresh() {
        refresh()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { break }
                await MainActor.run { self.refresh() }
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        controlTimeoutTask?.cancel()
        controlTimeoutTask = nil
        killVerifyTask?.cancel()
        killVerifyTask = nil
    }

    /// v0.3.38：内存查询完全异步——独立 Task，绝不阻塞进程列表
    func fetchMemoryAsync() {
        Task.detached(priority: .utility) { [weak self] in
            guard let vm = self else { return }
            let memMap = (try? ProcessManagerService.shared.fetchMemoryUsage()) ?? [:]
            await MainActor.run {
                // vm 已在外层解包（非 Optional），直接用
                guard !vm.processes.isEmpty else { return }
                for i in vm.processes.indices {
                    if let mem = memMap[Int32(vm.processes[i].pid)] {
                        vm.processes[i].memoryBytes = Int64(mem)
                    }
                }
            }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            do {
                // v0.3.38：先立即显示进程列表（不再等内存查询，避免几秒空白）
                let entries = try ProcessManagerService.shared.listProcesses()
                await MainActor.run {
                    guard let self else { return }
                    self.processes = entries
                    self.isRefreshing = false
                }
                // 内存异步后补（不阻塞刷新流程；受监控开关控制）——需在主 actor 上调用
                await MainActor.run {
                    if self?.memoryWatchEnabled == true {
                        self?.fetchMemoryAsync()
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    // v0.3.251: 无配对文件属预期状态(页面已有独立引导卡片),
                    // 不再弹窗 —— 否则弹窗[好] -> refresh() -> 再弹窗, 无限循环.
                    if PairingGate.isPairingError(error.localizedDescription)
                        || !TunnelContext.shared.hasPairingFile {
                        self.isRefreshing = false
                        return
                    }
                    self.alertItem = ProcessAlert(title: "加载进程失败", message: error.localizedDescription)
                    self.isRefreshing = false
                }
            }
        }
    }

    /// SIGKILL 最终复核（v0.2.107）：1.5 秒后重新枚举进程，**无论结果如何都弹
    /// 一个结论**——目标 PID 消失 → 「进程已结束」；仍在 → 「进程可能仍在运行」
    /// （受保护 / 前台 App 被 SpringBoard 拉起 / 权限不足）.
    /// 注意：@MainActor 类内 `Task { }` 继承主线程隔离，self 非 Optional，
    /// 用 `[self]` 强捕获.
    private func verifyKill(_ targetPID: Int) {
        killVerifyTask?.cancel()
        killVerifyTask = Task { [self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            let stillAlive = await Task.detached(priority: .utility) {
                (try? ProcessManagerService.shared.listProcesses())?
                    .contains { $0.pid == targetPID } ?? false
            }.value
            guard !Task.isCancelled else { return }
            self.killVerifyTask = nil
            self.refresh()
            if stillAlive {
                self.alertItem = ProcessAlert(title: "进程可能仍在运行", message: "PID \(targetPID) 已发送 SIGKILL，但刷新后仍出现在进程列表中.常见原因：系统关键进程受保护、前台 App 被 SpringBoard 自动拉起、或设备 app_service 权限不足.")
            } else {
                self.alertItem = ProcessAlert(title: "进程已结束", message: "PID \(targetPID) 已退出后台.")
            }
        }
    }

    func control(_ action: ProcessControlAction, process: ProcessEntry) {
        guard activeControlState == nil else {
            alertItem = ProcessAlert(title: "操作进行中", message: "上一项进程操作尚未完成，请稍候.")
            return
        }

        let targetPID = process.pid
        let targetName = process.displayName
        activeControlState = (targetPID, action)
        controlTimeoutTask?.cancel()
        controlTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self else { return }
            if self.activeControlState?.pid == targetPID && self.activeControlState?.action == action {
                await MainActor.run {
                    self.activeControlState = nil
                    self.alertItem = ProcessAlert(title: action.timeoutTitle, message: action.timeoutMessage(for: targetPID))
                }
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try ProcessManagerService.shared.sendSignal(action, toPID: targetPID, expectedName: targetName)
                await MainActor.run {
                    guard let self else { return }
                    self.controlTimeoutTask?.cancel()
                    self.controlTimeoutTask = nil
                    guard self.activeControlState?.pid == targetPID && self.activeControlState?.action == action else { return }
                    self.activeControlState = nil
                    self.refresh()
                    if action == .kill {
                        // SIGKILL：不立即弹成功，等 1.5 秒复核结果后给**一个**最终
                        // 结论弹窗（已结束 / 可能仍在运行），保证一定有反馈
                        // （v0.2.107：避免成功弹窗被复核弹窗覆盖导致用户看不到）.
                        self.verifyKill(targetPID)
                    } else {
                        self.alertItem = ProcessAlert(title: action.successTitle, message: action.successMessage(for: targetPID))
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.controlTimeoutTask?.cancel()
                    self.controlTimeoutTask = nil
                    guard self.activeControlState?.pid == targetPID && self.activeControlState?.action == action else { return }
                    self.activeControlState = nil
                    self.alertItem = ProcessAlert(title: action.failureTitle, message: error.localizedDescription)
                }
            }
        }
    }
}
