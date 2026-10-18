import SwiftUI

/// 隧道 / 蜂窝日志 —— **独立板块**，只读 `.tunnelCellular` 一类。
///
/// ## 为什么单独一页（而不是塞进现有日志页）
///
/// 本仓已有 9 个分类、多个日志入口（登录诊断 / AppStore / 下载 / 爱思源 / 共享转换 /
/// 软件源 / 崩溃分析）。隧道这一段**没有自己的入口**，全写 `.general`，
/// 于是「连接诊断」页看不出任何有用信息，用户报障时只能在几千行通用日志里翻。
///
/// 用户实测指正：隧道问题必须能**单独导出**。本页即为此而建：
///   · 只读 `.tunnelCellular`（板块隔离，`LoginLogger.recentLines(_:categories:)` 已支持）
///   · 复用现成的 `LogConsoleView`（清除 / 复制 / 分享 / 完成 四件套）
///   · **不复用**任何别的日志页容器，不与其它板块混在一起
///
/// ## 收录范围
///
/// `LocalDevVPN`（建连 / 多候选拨号 / 心跳 / 探测）与
/// `CellularTunnelManager`（蜂窝判据 / 关开蜂窝快捷指令 / 就绪轮询）
/// 的全部日志。诊断页自身**不写日志**（v0.3.620 起只读，绝不建连）。
struct TunnelLogView: View {

    /// 该页要显示的日志分类（隧道蜂窝专属）
    var categories: [LoginLogger.Category] = [.tunnelCellular]

    /// 逐行日志（`LogConsoleView` 的输入）
    @State private var lines: [String] = []

    var body: some View {
        LogConsoleView(
            lines: lines,
            title: "隧道与蜂窝日志",
            onClear: {
                // 只清「隧道蜂窝」这一类：不能调无参 clear()，那会穿透清掉全部板块的历史日志。
                LoginLogger.shared.clear(categories: Set(categories))
                refresh()
            },
            // 不传 onDone：本页是 `MoreView` 的 `NavigationLink` push 出来的，
            // 系统返回按钮已经在做同一件事，再加「完成」就是两个等价按钮。
            clearConfirmTitle: "确定清空隧道与蜂窝日志？"
        )
        .task {
            refresh()
            // 2s 轮询：隧道状态变化（建连 / 掉线重连 / 蜂窝开关）都是秒级发生的，
            // 不实时刷新就看不到现场（蓝牙 / 共享转换日志页同款）。
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                refresh()
            }
        }
    }

    /// 取该分类最近的日志行。
    ///
    /// 用 `recentLines(_:categories:)` 而不是 `logText(categories:)`：前者直接给逐行数组，
    /// 后者返回拼好的整块字符串还要再拆一次。行数上限取 `LogConsoleView.maxRenderedLines`。
    private func refresh() {
        let fresh = LoginLogger.shared.recentLines(LogConsoleView.maxRenderedLines, categories: categories)
        // 轮询每 2s 重跑一次；内容没变就不重新赋值，避免白白触发 body 重算。
        guard fresh != lines else { return }
        lines = fresh
    }
}
