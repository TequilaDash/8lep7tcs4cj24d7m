//
//  ProcessManagerView.swift
//  TequilaDash
//
//  进程管理（汉化移植自 StikDebug 的 Process Inspector）.
//
//  原理：经 LocalDevVPN 隧道（RPPairing 配对文件）连接设备的 app_service，
//  调用 `app_service_list_processes` 枚举全设备进程、`app_service_send_signal`
//  向指定 PID 发送信号（恢复 SIGCONT / 挂起 SIGSTOP / 结束 SIGKILL）.
//  与「启用 JIT / 拉起应用 / 卸载」走的是同一个 RSD 隧道通道，因此在
//  LiveContainer 访客沙盒内同样可用；前提是：配对文件 + LocalDevVPN + 开发者模式.
//
//  设备端 app_service 只回传 pid + 可执行路径，没有 Bundle ID / 友好名，
//  故列表显示名取路径末段（与 StikDebug 原版一致）.
//

import SwiftUI
import Foundation
import Darwin

// MARK: - 视图

struct ProcessManagerView: View {
    @State private var showLogViewer = false
    @StateObject private var viewModel = ProcessManagerViewModel()
    @State private var killCandidate: ProcessEntry?
    @State private var killConfirmTask: Task<Void, Never>?

    private var hasPairing: Bool { TunnelContext.shared.hasPairingFile }

    var body: some View {
        // 注意：不嵌套 NavigationStack！本页由 MoreView 的 NavigationView push 进入，
        // 嵌套导航栈会导致导航栏高度异常、标题/按钮错位（"tab 栏往下"的真凶）.
        // 与「描述文件管理」（AppExpiryView）同构：直接 List + navigationTitle.
        content
            .navigationTitle("进程管理")
            .navigationBarTitleDisplayMode(.inline)
            // 系统搜索栏（v0.2.90 样式）.
            .searchable(
                text: $viewModel.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索进程"
            )
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { viewModel.refresh() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isRefreshing)
                }
            }
            // 导航栏不设置 toolbarBackground，保持系统默认半透明毛玻璃效果，
            // 与「描述文件管理」（AppExpiryView）一致，可透视下方滚动内容.
            .task { viewModel.startAutoRefresh() }
            .onDisappear { viewModel.stopAutoRefresh() }
            .alert(item: $viewModel.alertItem) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("好"), action: {
                        if item.title == "加载进程失败" { viewModel.refresh() }
                    })
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        List {
            if viewModel.processes.isEmpty && !viewModel.isRefreshing {
                Section {
                    if !hasPairing {
                        PairingGuideCard(showsBackground: false, note: "进程管理还需要：① LocalDevVPN 已连接；② 开发者模式已开启.")
                            .listRowInsets(EdgeInsets())
                    } else {
                        // v0.3.677：两行裸 Text 空态 → 统一三态组件 AppStateSection（空列表态）。
                        // 原两行合并成一条 title + 一条 message，语义不变：没扫到进程，可能是设备空闲或隧道未就绪。
                        AppStateSection(state: .empty("未找到运行中的进程",
                                                      message: "设备可能处于空闲状态，或隧道尚未就绪.点击右上角刷新重试.",
                                                      icon: "gearshape.2"))
                    }
                }
            } else {
                Section {
                    if viewModel.sortedProcesses.isEmpty {
                        AppStateSection(state: .empty("没有匹配的进程",
                                                      message: "换个关键词试试.",
                                                      icon: "magnifyingglass"))
                    } else {
                        ForEach(viewModel.sortedProcesses) { process in
                            ProcessRow(
                                process: process,
                                activeControl: viewModel.activeControl(for: process),
                                isBusy: viewModel.isRunningControlAction,
                                isConfirming: killCandidate?.pid == process.pid,
                                onResumeTap: { viewModel.control(.resume, process: $0) },
                                onPauseTap: { viewModel.control(.pause, process: $0) },
                                onKillTap: { handleKillTap(for: $0) }
                            )
                        }
                    }
                } header: {
                    Text("运行中的进程（\(viewModel.processes.count)）")
                } footer: {
                    Text("恢复 / 挂起 / 结束经设备隧道下发，仅对当前设备生效.对系统关键进程发结束信号可能因权限不足失败.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 0)
        .refreshable { viewModel.refresh() }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Picker("排序", selection: $viewModel.sortMode) {
                    ForEach(ProcessSortMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .tint(AppTheme.categoryDevice)
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    viewModel.memoryWatchEnabled.toggle()
                    if viewModel.memoryWatchEnabled {
                        viewModel.fetchMemoryAsync()
                    }
                } label: {
                    Image(systemName: viewModel.memoryWatchEnabled ? "gauge.with.needle" : "gauge")
                        .foregroundColor(viewModel.memoryWatchEnabled ? AppTheme.categoryDevice : .secondary)
                }
                .accessibilityLabel(viewModel.memoryWatchEnabled ? "关闭内存监控" : "开启内存监控")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showLogViewer = true
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .accessibilityLabel("查看诊断日志")
            }
        }
        .sheet(isPresented: $showLogViewer) {
            SysmonLogView()
        }
    }

    private func handleKillTap(for process: ProcessEntry) {
        if killCandidate?.pid == process.pid {
            killConfirmTask?.cancel()
            killConfirmTask = nil
            killCandidate = nil
            viewModel.control(.kill, process: process)
        } else {
            killCandidate = process
            killConfirmTask?.cancel()
            killConfirmTask = Task {
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    if killCandidate?.pid == process.pid {
                        killCandidate = nil
                    }
                }
            }
        }
    }
}

// MARK: - 进程行

private struct ProcessRow: View {
    let process: ProcessEntry
    let activeControl: ProcessControlAction?
    let isBusy: Bool
    let isConfirming: Bool
    let onResumeTap: (ProcessEntry) -> Void
    let onPauseTap: (ProcessEntry) -> Void
    let onKillTap: (ProcessEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(process.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(process.memoryDisplay ?? "—")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(process.memoryDisplay != nil ? AppTheme.categoryDevice : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(process.memoryDisplay != nil ? AppTheme.categoryDevice.opacity(0.12) : Color.secondary.opacity(0.15)))
                Text("PID \(process.pid)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(process.executablePath)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Spacer()
                if activeControl != nil {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.accentColor)
                } else {
                    HStack(spacing: 8) {
                        Button {
                            onResumeTap(process)
                        } label: {
                            Image(systemName: ProcessControlAction.resume.systemImage)
                                .font(.title3)
                        }
                        .buttonStyle(TintedButtonStyle(tint: ProcessControlAction.resume.tint))
                        .controlSize(.small)
                        .labelStyle(.iconOnly)
                        .disabled(isBusy)

                        Button {
                            onPauseTap(process)
                        } label: {
                            Image(systemName: ProcessControlAction.pause.systemImage)
                                .font(.title3)
                        }
                        .buttonStyle(TintedButtonStyle(tint: ProcessControlAction.pause.tint))
                        .controlSize(.small)
                        .labelStyle(.iconOnly)
                        .disabled(isBusy)

                        Button {
                            onKillTap(process)
                        } label: {
                            if isConfirming {
                                Label("确认结束", systemImage: "checkmark.circle.fill")
                                    .font(.caption2.weight(.semibold))
                            } else {
                                Image(systemName: ProcessControlAction.kill.systemImage)
                                    .font(.title3)
                            }
                        }
                        .buttonStyle(TintedButtonStyle(tint: isConfirming ? AppTheme.success : ProcessControlAction.kill.tint))
                        .controlSize(.small)
                        // 固定 .titleOnly：确认态 label 是 Label（只出文字「确认结束」），
                        // 非确认态 label 是 Image（labelStyle 对 Image 无效，照常显图标）.
                        // 不能写三元 `isConfirming ? .titleOnly : .iconOnly`——两种
                        // LabelStyle 类型不同，编译器无法统一（v0.2.108 run 33253523553 报错）.
                        .labelStyle(.titleOnly)
                        .disabled(isBusy)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}


/// 进程管理诊断日志（查看 / 复制 / 分享 / 清空）.
///
/// 排版走共享的 `LogConsoleView`（逐行 `Text` + 行间 `Divider` + 自动滚底 + 复制带元信息头）——
/// 此前是**一整块 `Text`**，长日志糊成一坨。
struct SysmonLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []

    var body: some View {
        // 本页由 `.sheet` 弹出，**必须自带导航容器** —— 否则 `LogConsoleView` 的
        // `navigationTitle` 与工具栏（清除/复制/分享/完成）没有导航栏可挂，整条工具栏都不会出现。
        NavigationStack {
            LogConsoleView(
                lines: lines,
                title: "进程诊断日志",
                onClear: {
                    SysmonLogger.shared.clear()
                    refresh()
                },
                // 本页是 `.sheet` 弹出来的 → 需要「完成」按钮关闭
                onDone: { dismiss() },
                clearConfirmTitle: "确定清空进程诊断日志？"
            )
            .task {
                refresh()
                // 2s 轮询：进程扫描过程中能实时看到每一步
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { break }
                    refresh()
                }
            }
        }
    }

    /// `SysmonLogger` **没有按行取数的接口**，所以在 View 层取数。
    ///
    /// 注意： **不能写成 `fullLog()` + `suffix(maxRenderedLines)`**（虽然那样最短）：
    /// `fullLog()` 的合并顺序是 `内存缓冲（最新 500 行）+ 更早的文件行`，即**最新的一块在最前面**。
    /// 对它取 `suffix()` 拿到的是**最旧**的那批行；而日志页把最后一行当「最新」去自动滚底，
    /// 结果会停在最旧的一行上 —— 顺序反了。
    /// 所以这里优先**直接读日志文件尾部**（`logFileURL` 是公开属性）：文件是追加写的，
    /// 天然就是时间顺序、最新的在最后；而且每行都会落盘（`log(_:)` 里 append 到 buffer 后
    /// 立刻 `appendToFile`），文件本身就是完整来源。
    /// 文件读不到时（首次启动 / 刚清空）回退到 `fullLog()` —— 那种情况下它只剩内存那一段，
    /// 顺序本来就是对的。
    private func refresh() {
        var all = tailLines()
        if all.isEmpty {
            all = SysmonLogger.shared.fullLog()
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
        }
        let fresh = all.count > LogConsoleView.maxRenderedLines
            ? Array(all.suffix(LogConsoleView.maxRenderedLines))
            : all
        // 内容没变就不重新赋值（避免白触发 body 重算）
        guard fresh != lines else { return }
        lines = fresh
    }

    /// 读 `sysmon.log` 尾部（最多 512KB）并拆行（时间顺序，最新的在最后）。
    ///
    /// 只读尾部：本页 2s 轮询一次，而 `SysmonLogger` 的文件**没有滚动截断**
    /// （不像 `LoginLogger` 受 `LogLimitSettings` 限制），长期用下来会很大，整文件读是白烧。
    /// 从任意字节偏移开始读时首行必然被截断 —— 且**必须**从换行字节处切开：
    /// 日志含中文（多字节 UTF-8），从某个字符的中间字节开始解码会让整段解码直接失败。
    private func tailLines() -> [String] {
        let cap = 512 * 1024
        guard let handle = try? FileHandle(forReadingFrom: SysmonLogger.shared.logFileURL) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let offset = size > UInt64(cap) ? size - UInt64(cap) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              var data = try? handle.readToEnd() else { return [] }

        if offset > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return [] }
            data = data[data.index(after: newline)...]
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
}
