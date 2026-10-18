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
///   · 只读 `.tunnelCellular`（板块隔离，`LoginLogger.logText(categories:)` 已支持）
///   · 复用现成的 `LogConsoleView`（清除 / 复制 / 分享 / 完成 四件套）
///   · **不复用**任何别的日志页容器，不与其它板块混在一起
///
/// ## 收录范围
///
/// `LocalDevVPN`（建连 / 多候选拨号 / 心跳 / 探测）与
/// `CellularTunnelManager`（蜂窝判据 / 关开蜂窝快捷指令 / 就绪轮询）
/// 的全部日志。诊断页自身**不写日志**（v0.3.620 起只读，绝不建连）。
struct TunnelLogView: View {
    var body: some View {
        LogConsoleView(
            title: "隧道与蜂窝日志",
            categories: [.tunnelCellular],
            // 只清自己这一类，不穿透清别的板块
            //（`clear(categories:)` 自 v0.3.310 起支持，见 LoginLogger）
            onClear: {
                LoginLogger.shared.clear(categories: [.tunnelCellular])
            },
            clearConfirmTitle: "清空隧道与蜂窝日志？"
        )
    }
}
