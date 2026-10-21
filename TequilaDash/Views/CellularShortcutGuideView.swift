import SwiftUI

/// 蜂窝快捷指令创建引导 —— 「设置 → Cellular隧道支持」里点进来的二级页。
///
/// ## 为什么是引导创建，而不是自动安装（v0.3.654 修正文案）
///
/// 动作库里**确实有**「设定蜂窝数据」（`is.workflow.actions.cellulardata.set`，
/// 参数 `OnValue: Bool`）—— pfgithub/scpl 的 `OutActions.json` 与 `Shortcuts 2.2.json`
/// 都收录了该动作（`SASettingSetCellularData` / `WFSiriAccessResource`）。
/// 早期本页写「只能用飞行模式代替」是错的，已改正；不能自动装的卡点在分发环节。
///
/// v0.3.599 试过 `shortcuts://import-shortcut?...&silent=true` 静默导入，
/// **真机实测失败**：URL 无效 + 强制跳转到快捷指令 App（v0.3.616 撤销）。
///
/// 源码对照（两个参考项目都读了）：
/// · LiveContainer 自己的代码里蜂窝 / 快捷指令相关命中 **0**，刷新整个外包给 SideStore；
/// · SideStore `Core/Shortcuts/CellularRefreshManager.swift` 只按名字调
///   `shortcuts://run-shortcut?name=TurnOffData`，**不创建也不引导创建**
///   （issue #1393 / #1413 / #1191 全是用户抱怨找不到指令）。
///
/// ⇒ 两个参考项目都要求用户自建；Apple 官方文档只承诺
///   `shortcuts://import-shortcut?url=…`（指向 icloud.com 链接），
///   第三方实测本机 HTTP / 自签 HTTPS 均被拒（"the specified shortcut URL is invalid"），
///   `shortcuts sign` 在 macOS 14.6 也已坏掉 ⇒ **无可靠代建通道**。
///   所以本页做的是**把创建成本降到最低**，而不是伪造一个「已自动安装」。
struct CellularShortcutGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed: Set<String> = []

    var body: some View {
        List {
            Section {
                InfoActionCard(
                    icon: "bolt.badge.plus",
                    iconTint: AppTheme.categorySettings,
                    title: "创建两个快捷指令",
                    message: "蜂窝网络下，iOS 会限制回环 VPN 访问本机服务，所以要先临时关掉蜂窝数据."
                        + "用快捷指令 App 里的「设定蜂窝数据」动作（开关蜂窝号码同效），"
                        + "Apple 不允许第三方代建，所以下面两步要你手动做一次，之后永久生效."
                )
            }

            Section {
                stepRow(index: 1,
                        name: "TurnOffData",
                        action: "设定蜂窝数据 → 关",
                        hint: "建隧道前跑它")
                stepRow(index: 2,
                        name: "TurnOnData",
                        action: "设定蜂窝数据 → 开",
                        hint: "用完恢复网络")
            } header: {
                Text("需要创建")
            } footer: {
                Text("名称必须完全一致（区分大小写）—— 引擎按名字调用，写错就会提示「未找到快捷指令」."
                     + "iOS 不允许第三方代建快捷指令，所以这一步必须你手动做；建好后点下面的「我已创建」记住，不会再提示.")
            }

            Section {
                Button { openCreateShortcut(name: "TurnOffData") } label: {
                    Label("去创建 TurnOffData", systemImage: "arrow.up.forward.app")
                }
                Button { openCreateShortcut(name: "TurnOnData") } label: {
                    Label("去创建 TurnOnData", systemImage: "arrow.up.forward.app")
                }
            } header: {
                Text("一键跳转")
            } footer: {
                Text("会跳到系统「快捷指令」App 的新建页（Apple 不允许静默创建)."
                     + "新建时添加「设定蜂窝数据」动作，再把指令命名为上面给出的名字.")
            }

            Section {
                Button {
                    CellularShortcutInstaller.markShortcutInstalled("TurnOffData")
                    CellularShortcutInstaller.markShortcutInstalled("TurnOnData")
                    confirmed = ["TurnOffData", "TurnOnData"]
                    AppHaptics.success()
                } label: {
                    Label("我已创建完成", systemImage: "checkmark.circle.fill")
                }
                .disabled(confirmed.count == 2)
            } header: {
                Text("完成后")
            } footer: {
                Text("点过后引擎就不再拦截跳转；若其实没建，建隧道时仍会跳过关蜂窝并如实记录日志."
                     + "如需重置提示，到「设置 → Cellular隧道支持」关掉再打开即可.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("蜂窝快捷指令")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stepRow(index: Int, name: String, action: String, hint: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(AppFont.bodyEmphasis)
                Text(action)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                Text(hint)
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if confirmed.contains(name) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.success)
            }
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func openCreateShortcut(name: String) {
        guard let url = CellularShortcutInstaller.createShortcutURL(name: name) else { return }
        UIApplication.shared.open(url)
    }
}
