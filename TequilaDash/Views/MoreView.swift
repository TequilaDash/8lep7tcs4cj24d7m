import SwiftUI

/// The "More" hub gathers secondary destinations that don't need their own
/// bottom-tab slots. Features are organized into logical sections for better
/// discoverability (v0.3.29: 22 features → 7 categorized sections).
///
/// v0.3.xxx：按巨魔录音机（TRApp）设计语言重做，与主页 `HomeView` **统一观感**
/// （原为 `List .insetGrouped` + `MoreCard`）：
/// - **页边距 20**（`AppTheme.pageInset`，原 16）；**大标题**走系统 `.large`（34pt bold）.
/// - **功能入口改 inset-grouped 卡片分组**（分段标题 + 连续圆角卡片），行 =
///   连续圆角图标底 + **17pt semibold** 标题 + **13pt footnote** 副标题 + 右 chevron
///   （走 `AppLayout.swift` 的共享 `AppNavRow`，与主页同一实现；分隔线全宽贯通）.
/// - **强调色**统一到 `AppTheme.accent`（亮 `#005493` / 暗 `#76D6FF`，自适应）.
/// - 图标 `.hierarchical` 分层渲染；工具栏动作补触觉 `AppHaptics.tap()`.
/// - **布局**：分段标题统一用 `AppSectionHeader`（品牌色竖条 + 主标题）；「设备工具」6 项平级工具
///   改用 **2 列卡片网格**（`AppCardGrid` + `AppGridTile`，布局 B），其余分组仍走全宽行（布局 A）.
///
/// ⚠️ 仅改样式：`isVisible(_:)` 热补丁过滤、`NavigationLazyView(item.destination)` 懒加载、
/// 两个 toolbar sheet（设备控制 / 设置）与 `MoreItem` 数据定义均**原样保留**.
struct MoreView: View {
    @ObservedObject private var hotfix = HotfixService.shared
    @ObservedObject var appList: AppListViewModel
    /// 重置配对文件。会抛错（建连进行中时 TunnelContext 拒绝删除，返回 -8）.
    var onResetPairing: () throws -> Void
    @State private var showSettings = false
    @State private var showTunnelLog = false
    @State private var showDeviceControl = false

    // MARK: - 分组数据

    private struct MoreItem: Identifiable {
        let id: String
        let icon: String
        let title: String
        let subtitle: String
        let destination: AnyView

        init(_ id: String, _ icon: String, _ title: String, _ subtitle: String, _ dest: some View) {
            self.id = id
            self.icon = icon
            self.title = title
            self.subtitle = subtitle
            self.destination = AnyView(dest)
        }
    }

    /// 热补丁接管点：feature.<id>.hidden 标志可隐藏任意功能入口
    private func isVisible(_ item: MoreItem) -> Bool {
        !hotfix.isFeatureHidden(item.id)
    }

    /// 分组定义（v0.3.29：22 个功能 → 7 个逻辑分区）.
    /// 每项 =（分段标题, 分段 SF Symbol, 脚注, **是否网格**, 条目）.
    ///
    /// `isGrid` 显式写在分组定义里，不再靠「标题字符串属于某个集合」反查 —— 改标题不会静默退回
    /// 全宽行，读定义处即知该组用哪种布局（布局 B 网格 / 布局 A 全宽行）.
    private var sections: [(header: String, symbol: String, footer: String?, isGrid: Bool, items: [MoreItem])] {
        [
            // v0.3.412：漏洞利用 —— 置顶的普通导航行，点进去是二级选择页。
            ("漏洞利用", "ladybug.fill", nil, false, [
                MoreItem("exploit", "ladybug.fill", "漏洞利用",
                         "选择使用的漏洞利用",
                         ExploitSelectionView()),
            ]),
            ("配对文件", "key.horizontal", "重置/更换配对文件后从这里重新导入", false, [
                MoreItem("pairing-import", "key.horizontal", "配对文件导入",
                         "文件导入 / 剪贴板 / 无线配对",
                         PairingSetupView(viewModel: appList)),
            ]),
            ("设备工具", "wrench.and.screwdriver", "需要配对文件 + LocalDevVPN 隧道", true, [
                MoreItem("virtual-location", "location.fill", "虚拟定位",
                         "地图定位模拟，支持轨迹",
                         VirtualLocationView()),
                MoreItem("jit", "bolt.fill", "启用 JIT",
                         "以调试模式启动应用",
                         JITEnableView()),
                MoreItem("launch-apps", "arrow.up.forward.app.fill", "拉起应用",
                         "一键在前台拉起已装应用",
                         LaunchAppsView()),
                MoreItem("process-manager", "cpu", "进程管理",
                         "查看 / 挂起 / 结束设备进程",
                         ProcessManagerView()),
                MoreItem("pip-keepalive", "pip.enter", "PiP 保活",
                         "画中画保活防杀后台",
                         PiPKeepAliveView()),
                MoreItem("ssh-debug", "terminal", "小型SSH服务",
                         "局域网无线连接诊断",
                         SSHDebugView()),
            ]),
            ("应用安装", "arrow.down.app.fill", "签名、安装与下载", false, [
                MoreItem("ipa-install", "arrow.down.app.fill", "IPA 侧载",
                         "签名安装 IPA",
                         IPAInstallView()),
                MoreItem("signed-ipa", "app.badge.checkmark", "IPA 安装",
                         "在线 / 覆盖安装已签名 IPA",
                         SignedIPAInstallView()),
                MoreItem("ipa-import", "square.and.arrow.down.on.square", "共享转换",
                         "导入他人分享的 IPA 并修补安装",
                         ImportView()),
                MoreItem("pairing-install", "tray.and.arrow.down.fill", "管理配对文件",
                         "写入其它侧载工具，复用配对身份",
                         PairingInstallView()),
            ]),
            ("文件管理", "folder.fill", nil, false, [
                MoreItem("file-browser", "folder.fill", "文件浏览器",
                         "浏览编辑设备文件",
                         FileBrowserRootView(appList: appList)),
                MoreItem("afc", "externaldrive.fill", "AFC 管理",
                         "AFC 文件浏览 / 导入导出文件",
                         AFCBrowserView()),
            ]),
            ("个性化", "paintbrush.fill", nil, false, [
                MoreItem("wallpaper", "photo.fill.on.rectangle.fill", "壁纸",
                         "导入壁纸包",
                         WallpaperView()),
                MoreItem("dialer", "circle.grid.3x3.fill", "拨号器主题",
                         "替换拨号键盘主题",
                         DialerThemeView()),
                MoreItem("ringtones", "music.note.list", "铃声管理",
                         "导入 / 导出铃声",
                         RingtonesView()),
            ]),
            ("系统工具", "gearshape.2.fill", nil, false, [
                MoreItem("app-expiry", "calendar.badge.clock", "预置描述管理",
                         "过期描述管理（.mobileprovision）",
                         AppExpiryView()),
                MoreItem("profile-install", "shield.lefthalf.filled", "发送描述文件",
                         "导入描述文件到本机",
                         ProfileInstallView()),
                MoreItem("profile-config", "list.bullet.rectangle.portrait.fill", "配置描述管理",
                         "描述文件管理（.mobileprofile）",
                         ProfileConfigView()),
                MoreItem("ipcc", "antenna.radiowaves.left.and.right", "IPCC 安装",
                         "导入运营商 .ipcc 配置",
                         IPCCInstallView()),
                MoreItem("ddi", "iphone.and.arrow.forward", "开发者镜像",
                         "下载开发者镜像",
                         DDIDownloadView()),
                MoreItem("kernelcache", "cpu.fill", "下载 KernelCache",
                         "下载内核缓存",
                         KernelCacheView()),
                MoreItem("domain-blocker", "shield.fill", "屏蔽域名",
                         "DNS 屏蔽域名",
                         DomainBlockerView()),
                MoreItem("call-recording", "speaker.slash.fill", "禁用通话录音",
                         "静音通话录音提示音",
                         CallRecordingToneView()),
            ]),
            ("账户与安全", "lock.shield.fill", nil, false, [
                MoreItem("certificates", "checkmark.seal.fill", "证书管理",
                         "管理开发证书",
                         CertificateView()),
                MoreItem("mdm-manage", "shield.lefthalf.filled.badge.checkmark", "MDM 管理",
                         "沙盒逃逸 / 描述文件备份还原",
                         MDMManageView()),
                MoreItem("memory", "memorychip", "增加内存限制",
                         "提高内存上限",
                         IncreaseMemoryView()),
            ]),
            ("数据与诊断", "chart.bar.doc.horizontal", nil, false, [
                MoreItem("backups", "externaldrive.fill.badge.timemachine", "备份",
                         "备份恢复管理",
                         BackupsListView(appList: appList)),
                MoreItem("crash-logs", "chart.bar.doc.horizontal", "崩溃分析",
                         "崩溃日志分析",
                         CrashLogView()),
                // 独立板块：只读「隧道蜂窝」一类日志，不与崩溃分析 / 业务日志混在一起
                MoreItem("tunnel-log", "dot.radiowaves.left.and.right", "隧道日志",
                         "建连 / 心跳 / 蜂窝快捷指令",
                         TunnelLogView()),
                MoreItem("configurations", "checklist", "配置管理",
                         "系统配置管理",
                         ConfigurationsView()),
            ]),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(sections, id: \.header) { section in
                    moreSection(section)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, AppTheme.pageInset)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        // v0.3.xxx：与 `HomeView` 同为一级 tab 根视图，页面底统一走 `AppTheme.surfaceBase`
        // （原先取 `Color(.systemBackground)`，两个 tab 之间切换时底色会跳）.
        .background(AppTheme.surfaceBase)
        .navigationTitle("更多")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    AppHaptics.tap()
                    showDeviceControl = true
                } label: {
                    Image(systemName: "power")
                        .imageScale(.large)
                }
                .accessibilityLabel("设备控制")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    AppHaptics.tap()
                    showTunnelLog = true
                } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .imageScale(.large)
                }
                .accessibilityLabel("隧道日志")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    AppHaptics.tap()
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .imageScale(.large)
                }
            }
        }
        .sheet(isPresented: $showDeviceControl) {
            NavigationStack {
                DeviceControlView()
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsForm(onResetPairing: onResetPairing)
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") {
                                showSettings = false
                            }
                        }
                    }
            }
        }
        .navigationDestination(isPresented: $showTunnelLog) {
            NavigationLazyView(TunnelLogView())
        }
    }

    // MARK: - 分组渲染（两种布局：网格 / 全宽行）

    /// 单个功能分组：分段标题（`AppSectionHeader`，带品牌色竖条）+ 内容 + 可选脚注.
    /// 内容按分组自带的 `isGrid` 二选一：卡片网格（布局 B）或全宽行（布局 A）.
    /// 热补丁把整组都隐藏时不渲染该组（避免只剩一个空标题）.
    @ViewBuilder
    private func moreSection(_ section: (header: String, symbol: String, footer: String?, isGrid: Bool, items: [MoreItem])) -> some View {
        let items = section.items.filter(isVisible)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                AppSectionHeader(section.header, symbol: section.symbol)
                if section.isGrid {
                    AppCardGrid(items: items, columns: 2) { item in
                        NavigationLink {
                            NavigationLazyView(item.destination)
                        } label: {
                            AppGridTile(icon: item.icon, title: item.title, subtitle: item.subtitle)
                        }
                        .appPressable()
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            NavigationLink {
                                NavigationLazyView(item.destination)
                            } label: {
                                AppNavRow(icon: item.icon, title: item.title, subtitle: item.subtitle)
                            }
                            .buttonStyle(.plain)
                            // 末行不附分隔线（组尾）
                            if item.id != items.last?.id {
                                rowDivider
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 硬规则 5：设置类列表用**全宽行 + 发丝分隔**，不套 16 圆角卡片。
                    // 原先这里 .appCard(padding: 0) 把全宽行塞进了卡片，与规则冲突；
                    // TreasureBoxView.swift:252-259 早已改成全宽，本处对齐它。
                    // 行内自带 padding(.horizontal, 14)，分隔线用 AppHairline 全宽。
                }
                if let footer = section.footer {
                    Text(footer)
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    /// 行分隔线：**全宽**发丝（`AppHairline`）.
    ///
    /// 规则 5 的全宽行语言里，分隔线应当整行贯通（原先 `padding(.leading, 56)` 是给卡片内行用的
    /// 缩进线，本页行已脱离卡片）—— 见 `TreasureBoxView.swift:273-274` 同款.
    ///
    /// v0.3.xxx：删掉上一版残留的「左缩进对齐到图标底右侧（图标 30 + 间距 12 + 左内边距 14 = 56）」
    /// 描述 —— 该公式自改成全宽起就与代码矛盾，Step 3 方案「不足 11」点名.
    private var rowDivider: some View {
        AppHairline()
    }
}

