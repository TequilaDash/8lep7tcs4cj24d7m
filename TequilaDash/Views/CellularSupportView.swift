import SwiftUI

/// 蜂窝隧道支持（二级页）—— 「更多 → Cellular 隧道支持」点进来.
///
/// 用户要求（2026-11-01）：一级页只留入口，开关与全部配置都搬到这里；
/// 首次进入自动弹创建引导（支持跳过），页内提供「重新引导示范」.
/// 字段对齐 SideStore 的 User Customizations → CELLULAR REFRESH：
/// 总开关 / 开·关快捷指令名 / 开·关基础延时 / 恢复默认.
/// 输入框**预填当前生效值**（不是占位符）—— 用户要求「你得帮我预填入」.
///
/// 为什么快捷指令要用户自建：iOS 没有给第三方 App 创建快捷指令的公开 API
/// （App Intents 只能暴露自家动作），引擎只能按名字跑
/// `shortcuts://run-shortcut?name=…`，名字对不上就会「未找到快捷指令」.
/// 详见 `CellularShortcutGuideView` 与 `CellularTunnelManager` 的注释.
struct CellularSupportView: View {
    /// 引导是否已看过（首次进入弹窗用；跳过也算看过，不再打扰）.
    private static let guideSeenKey = "TequilaDash.CellularGuideSeen"

    @AppStorage(CellularTunnelManager.enabledKey) private var enabled = false
    @AppStorage(CellularTunnelManager.turnOffShortcutKey) private var turnOffShortcut = ""
    @AppStorage(CellularTunnelManager.turnOnShortcutKey) private var turnOnShortcut = ""
    @AppStorage(CellularTunnelManager.turnOffBaseDelayKey)
    private var turnOffDelay = CellularTunnelManager.defaultBaseDelay
    @AppStorage(CellularTunnelManager.turnOnBaseDelayKey)
    private var turnOnDelay = CellularTunnelManager.defaultBaseDelay
    @AppStorage(Self.guideSeenKey) private var guideSeen = false

    @State private var showGuide = false

    /// v0.3.756：右上角「运行日志」面板.
    @State private var showLog = false

    /// v0.3.757：私有开关「写入权限」状态（实时观察服务发布）.
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

    /// 名字输入框：**读原始存储值**（可以为空），默认名只作占位符.
    ///
    /// v0.3.743：旧实现读「生效值」（留空即回落默认名），用户把输入框清空后立刻又被填回
    /// 默认名 —— 看上去就是「预填字段不能清空，除非什么都不填返回」。现在空 = 用默认名，
    /// 默认名写在占位符里；要恢复默认清空即可.
    private var offNameBinding: Binding<String> {
        Binding(get: { turnOffShortcut }, set: { turnOffShortcut = $0 })
    }

    private var onNameBinding: Binding<String> {
        Binding(get: { turnOnShortcut }, set: { turnOnShortcut = $0 })
    }

    /// 延时的预填：同样读生效值（已过 0...30 夹取），写回时再夹一次.
    private var offDelayBinding: Binding<Double> {
        Binding(
            get: { CellularTunnelManager.shared.turnOffBaseDelay },
            set: { turnOffDelay = CellularTunnelManager.sanitizeBaseDelay($0) }
        )
    }

    private var onDelayBinding: Binding<Double> {
        Binding(
            get: { CellularTunnelManager.shared.turnOnBaseDelay },
            set: { turnOnDelay = CellularTunnelManager.sanitizeBaseDelay($0) }
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
            } footer: {
                Text("自动模式被系统拒绝后自动改走快捷指令（普通自签 App 无法直改蜂窝，Gnoix 亦同）；私有实现模式被拒后如实失败，不回落.")
            }

            Section {
                Toggle("蜂窝刷新", isOn: $enabled)
            } header: {
                Text("总开关")
            } footer: {
                Text("刷新时按「开关方式」所选通道自动开关蜂窝数据.")
            }

            Section {
                nameRow(title: "开蜂窝快捷指令", placeholder: CellularTunnelManager.defaultTurnOnShortcut, text: onNameBinding)
                nameRow(title: "关蜂窝快捷指令", placeholder: CellularTunnelManager.defaultTurnOffShortcut, text: offNameBinding)
                NavigationLink {
                    CellularShortcutGuideView()
                } label: {
                    Label("创建指南与一键跳转", systemImage: "book")
                }
            } header: {
                Text("快捷指令")
            } footer: {
                Text("快捷指令 App 里的指令名，区分大小写. 仅「快捷指令」方式或「自动」回落时使用.")
            }

            Section {
                delayRow(title: "开蜂窝基础延时", value: onDelayBinding)
                delayRow(title: "关蜂窝基础延时", value: offDelayBinding)
            } header: {
                Text("基础延时")
            } footer: {
                Text("执行快捷指令后等待的秒数，范围 0 到 30.")
            }

            Section {
                Button {
                    resetDefaults()
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                }
                Button {
                    showGuide = true
                } label: {
                    Label("重新引导示范", systemImage: "questionmark.circle")
                }
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
        .onAppear {
            if !guideSeen { showGuide = true }
        }
        .sheet(isPresented: $showGuide, onDismiss: { guideSeen = true }) {
            NavigationStack {
                CellularShortcutGuideView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("跳过") { showGuide = false }
                        }
                    }
            }
        }
    }

    /// 名字行：左标题 + 右输入框（预填生效值，单行不换行）.
    private func nameRow(title: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .frame(maxWidth: 180)
        }
    }

    /// 延时行：数字输入 + 单位后缀；输入即夹取到 0...30（非有限值回落默认）.
    private func delayRow(title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            TextField("1.0", value: value, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
                .onChange(of: value.wrappedValue) { _, newValue in
                    let clamped = CellularTunnelManager.sanitizeBaseDelay(newValue)
                    if clamped != newValue { value.wrappedValue = clamped }
                }
            Text("秒")
                .foregroundStyle(.secondary)
        }
    }

    private func resetDefaults() {
        turnOffShortcut = ""
        turnOnShortcut = ""
        turnOffDelay = CellularTunnelManager.defaultBaseDelay
        turnOnDelay = CellularTunnelManager.defaultBaseDelay
        AppHaptics.success()
    }
}
