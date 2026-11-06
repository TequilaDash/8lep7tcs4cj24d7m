import SwiftUI

/// 蜂窝隧道支持（二级页）—— 「更多 → Cellular 隧道支持」点进来.
///
/// 用户裁定：快捷指令方案整体删除（shortcuts:// 跳前台严重冲突），
/// 开关方式收敛为三选：自动（私有优先，兜底卡点弹窗）/ 私有实现 / 卡点弹窗.
/// 页面只剩：开关方式 / 私有开关状态 / 总开关 / 右上角运行日志.
struct CellularSupportView: View {
    @AppStorage(CellularTunnelManager.enabledKey) private var enabled = false

    /// 右上角「运行日志」面板.
    @State private var showLog = false

    /// 私有开关「写入权限」状态（实时观察服务发布）.
    @ObservedObject private var toggleService = CellularDataToggleService.shared

    /// 私有开关 API 可用性（init 期探测定死）.
    private var privateAvailable: Bool {
        CellularDataToggleService.shared.isPrivateAPIAvailable
    }

    /// 开关方式三选绑定（写回即记日志，切换有痕）.
    private var modeBinding: Binding<CellularTunnelManager.ToggleMode> {
        Binding(
            get: { CellularTunnelManager.shared.toggleMode },
            set: {
                CellularTunnelManager.shared.toggleMode = $0
                CellularLogStore.shared.log("开关方式切换为 \($0.label)")
                AppHaptics.success()
            }
        )
    }

    var body: some View {
        List {
            Section {
                Picker("开关方式", selection: modeBinding) {
                    ForEach(CellularTunnelManager.ToggleMode.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 8) {
                    Image(systemName: privateAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(privateAvailable ? AppTheme.success : AppTheme.danger)
                    Text("私有开关 API")
                    Spacer(minLength: 8)
                    Text(privateAvailable ? "可用" : "不可用")
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                }
                if privateAvailable {
                    Text(toggleService.privateStatusText)
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("开关方式")
            }

            Section {
                NavigationLink {
                    NetworkDiscoveryView()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("网络发现（mDNS）")
                        Text("Bonjour 设备服务浏览，设备直连通道的数据源.")
                            .font(AppFont.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("网络发现")
            }

            Section {
                Toggle("蜂窝刷新", isOn: $enabled)
            } header: {
                Text("总开关")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Cellular 隧道支持")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showLog = true
                } label: {
                    Label("运行日志", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .sheet(isPresented: $showLog) {
            NavigationStack {
                CellularLogView()
            }
        }
    }
}
