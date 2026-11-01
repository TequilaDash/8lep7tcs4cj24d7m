import SwiftUI

/// 蜂窝隧道支持（二级页）—— 「更多 → Cellular 隧道支持」点进来.
///
/// 用户要求（2026-11-01）：一级页只留入口，开关与全部配置都搬到这里；
/// 首次进入自动弹创建引导（支持跳过），页内提供「重新引导示范」.
/// 字段对齐 SideStore 的 User Customizations → CELLULAR REFRESH：
/// 总开关 / 关·开快捷指令名 / 关·开基础延时 / 恢复默认.
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

    var body: some View {
        List {
            Section {
                Toggle("Cellular 隧道支持", isOn: $enabled)
            } header: {
                Text("总开关")
            } footer: {
                Text("关闭时引擎全部 no-op，行为与不开这个功能时完全一致.")
            }

            Section {
                TextField(CellularTunnelManager.defaultTurnOffShortcut, text: $turnOffShortcut)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField(CellularTunnelManager.defaultTurnOnShortcut, text: $turnOnShortcut)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                NavigationLink {
                    CellularShortcutGuideView()
                } label: {
                    Label("创建指南与一键跳转", systemImage: "book")
                }
            } header: {
                Text("快捷指令")
            } footer: {
                Text("名称必须与快捷指令 App 里完全一致（区分大小写），留空用默认名 TurnOffData / TurnOnData.")
            }

            Section {
                delayRow(title: "关蜂窝后等待", value: $turnOffDelay)
                delayRow(title: "开蜂窝后等待", value: $turnOnDelay)
            } header: {
                Text("基础延时")
            } footer: {
                Text("单位秒，范围 0-30.跑完快捷指令后等多久再探隧道；网络切换慢就调大，默认 1 秒.")
            }

            Section {
                Button {
                    showGuide = true
                } label: {
                    Label("重新引导示范", systemImage: "questionmark.circle")
                }
                Button {
                    resetDefaults()
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                }
            } footer: {
                Text("恢复默认会把两个名称清空（回到 TurnOffData / TurnOnData）并把延时改回 1 秒，不动总开关.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Cellular 隧道支持")
        .navigationBarTitleDisplayMode(.inline)
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
