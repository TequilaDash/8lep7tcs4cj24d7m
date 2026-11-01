import SwiftUI
import UIKit

/// 拉起应用（Launch Apps，汉化移植自 StikDebug 的 Other / Launch 标签页）.
/// 列出全部已安装应用（含系统应用），点击即以普通方式启动（不启用 JIT）.
///
/// 布局（本轮）：**布局 E（自适应网格）** —— 应用是「尺寸一致的图标条目流」，用 `AppAdaptiveGrid`
/// 按最小宽度自动决定列数（横竖屏 / 不同机型都铺满），比一列横条更像「启动台」.
///
/// 滚动性能：应用列表可达上百项，`AppAdaptiveGrid` 的单元格是**滚入视野才创建**；阶梯入场
/// 只作用于首屏窗口（见 `AppAppear.staggerWindow`），窗口外立即可见 —— 否则「绝对序号 × 步长」
/// 的延迟会让滚到后面的格子空白数秒，表现就是「上滑下滑反应一会」.
struct LaunchAppsView: View {
    @State private var apps: [JITAppInfo] = []
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var searchText = ""
    @State private var launchingBundleIDs: Set<String> = []
    @State private var feedback: LaunchFeedback?
    /// 明暗模式：底部提示条的浮层投影走 `AppShadow.raised`（深色下更重），需显式传入.
    @Environment(\.colorScheme) private var colorScheme

    private var hasPairing: Bool { TunnelContext.shared.hasPairingFile }

    private var filteredApps: [JITAppInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            Section {
                if isLoading && apps.isEmpty {
                    // v0.3.700：整页加载态收口到 AppLoadingRow（.page 档：大圈 + 标题居中）.
                    AppLoadingRow(title: "正在枚举已安装应用…", level: .page)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else if apps.isEmpty && !isLoading {
                    if !hasPairing {
                        PairingGuideCard(showsBackground: false, note: "拉起应用需已连接 LocalDevVPN.")
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, AppTheme.pageInset)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        // 空态 banner：与「空间回收」同款（`InfoActionCard` 白底圆角卡）.
                        InfoActionCard(
                            icon: "arrow.clockwise",
                            title: "未获取到应用列表",
                            message: "点击右上角刷新重试；仍为空请确认 LocalDevVPN 已连接、配对文件有效."
                        )
                        .appCard()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } else if !searchText.isEmpty && filteredApps.isEmpty {
                    // 搜索无结果 banner：与「空间回收」的「立即扫描」同款视觉（白底圆角卡 + 左侧图标）.
                    InfoActionCard(
                        icon: "magnifyingglass",
                        title: "没有匹配的应用",
                        message: "换名称或 Bundle ID 重试."
                    )
                    .appCard()
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AppTheme.pageInset)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        AppSectionHeader("全部应用",
                                         subtitle: "共 \(filteredApps.count) 个",
                                         symbol: "app.grid.3x3",
                                         tint: AppModule.device.tint)
                        AppAdaptiveGrid(items: filteredApps, minimum: 92, spacing: 12) { app in
                            launchTile(app)
                        }
                        Text("点击应用即前台拉起（普通启动，不启用 JIT）.")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, AppTheme.pageInset)
                    .padding(.top, 4)
                    .padding(.bottom, 32)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppTheme.surfaceBase)
        .navigationTitle("拉起应用")
        .navigationBarTitleDisplayMode(.inline)
        // 搜索框常驻（`displayMode: .always`）——用户 2026-10-13 要求「回到之前那样常驻」.
        // 本页容器是 `List`：系统会把常驻搜索框计入内容安全区，第一行不会被压住；更关键的是
        // iOS 26/27 的搜索缩卡呈现只对 `ScrollView` 容器触发，`List` 被系统豁免 —— 全仓唯一
        // 缩卡页（2026-10-30/11-01 用户两次截图实证：进程管理 List 不缩、本页 ScrollView 缩）
        // 因此改为 List 承载网格，外观不变，`SearchBarInsetProbe` 测高让位链随之删除.
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索应用或 Bundle ID")
        .avoidSearchZoom()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    AppHaptics.tap()
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .onAppear {
            if apps.isEmpty { Task { await load() } }
        }
        .overlay(alignment: .bottom) {
            if let feedback {
                Text(feedback.message)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .appGlassCapsule()
                    .foregroundStyle(feedback.success ? AppTheme.success : AppTheme.danger)
                    .appRaisedShadow(colorScheme)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 24)
            }
        }
        .alert("拉起失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    /// 自适应网格里的应用格子（布局 E）：大图标 + 名称居中，点击拉起；拉起中盖一层毛玻璃 + 转圈.
    private func launchTile(_ app: JITAppInfo) -> some View {
        Button {
            AppHaptics.tap()
            launch(app)
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    JITAppIconView(bundleID: app.bundleID, size: 60)
                    if launchingBundleIDs.contains(app.bundleID) {
                        Color.clear
                            .frame(width: 60, height: 60)
                            .appGlass(radius: 60 * (8.0 / 36.0))
                        ProgressView()
                    }
                }
                Text(app.name)
                    .font(AppFont.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(AppSurface.card)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
        .appPressable(scale: 0.94)
        .disabled(launchingBundleIDs.contains(app.bundleID))
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let apps = try await Task.detached(priority: .userInitiated) {
                try JITEnableService.shared.listAllApps()
            }.value
            await MainActor.run { self.apps = apps }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func launch(_ app: JITAppInfo) {
        guard !launchingBundleIDs.contains(app.bundleID) else { return }
        launchingBundleIDs.insert(app.bundleID)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try JITEnableService.shared.launchApp(bundleID: app.bundleID)
                }.value
                await MainActor.run {
                    launchingBundleIDs.remove(app.bundleID)
                    showFeedback("「\(app.name)」已启动", success: true)
                }
            } catch {
                await MainActor.run {
                    launchingBundleIDs.remove(app.bundleID)
                    showFeedback("「\(app.name)」启动失败", success: false)
                }
            }
        }
    }

    private func showFeedback(_ message: String, success: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            feedback = LaunchFeedback(message: message, success: success)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                feedback = nil
            }
        }
    }
}

private struct LaunchFeedback: Identifiable {
    let id = UUID()
    let message: String
    let success: Bool
}
