import SwiftUI

/// 空间回收顶部分段控件的当前页签.
enum ReclaimSegment: String, CaseIterable, Identifiable {
    case regular = "常规清理"
    case container = "容器管理"
    var id: String { rawValue }
}

/// 「空间回收」板块总入口.
///
/// 用分段控件（分栏）在两类清理之间切换，二者底层共用同一个
/// `ReclaimAppView` 详情页：
/// - **常规清理**：扫描并回收**系统应用**的缓存与临时文件（`ReclaimTabView`）.
/// - **容器管理**：扫描并回收 **LiveContainer 内应用**的缓存与临时文件（`LiveCleanTabView`）.
///
/// 标题统一由本视图持有（"空间回收"），子视图不再设置各自标题，
/// 避免切到容器管理时大标题变成"容器管理".
///
/// 分段控件不再以固定条放在列表上方，而是作为列表的一部分随内容滚动，
/// 避免固定条遮挡首项内容.
struct SpaceReclaimView: View {
    @ObservedObject var appList: AppListViewModel
    @State private var segment: ReclaimSegment = .regular

    var body: some View {
        Group {
            switch segment {
            case .regular:
                ReclaimTabView(appList: appList, segment: $segment)
            case .container:
                LiveCleanTabView(appList: appList, segment: $segment)
            }
        }
        // 规则 31「引擎不熄火」：本页是用户点名的重灾区（先开 App、再开 VPN → 整页灰死）.
        // 两个页签各自还接了后续扫描，这里兜底覆盖页签尚未实例化时的就绪翻转 ——
        // resumeAfterTunnelReady() 自己带幂等闸（待发位 + 非加载中等），重复触发不会重复建隧道.
        .onTunnelReady {
            appList.resumeAfterTunnelReady()
        }
        .navigationTitle("空间回收")
        .navigationBarTitleDisplayMode(.large)
    }
}
