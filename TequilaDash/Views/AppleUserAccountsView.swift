import SwiftUI

/// 「Apple ID 账户」二级管理页（v0.3.745 账户体系重做）.
///
/// 多账户保持 + 一键切换当前账户 + 添加（复用 AppleIDLoginSheet 真实认证）+
/// 退出单个/全部.IPA 侧载、证书、商店链等消费方全部跟随「当前账户」.
struct AppleUserAccountsView: View {
    @StateObject private var store = AppleUserAccountStore.shared
    @State private var showAddSheet = false
    @State private var showSignOutAllConfirm = false
    /// 待确认移除的账户.
    @State private var pendingRemove: AppleUserAccount?
    /// v0.3.749：当前账户右滑「注册设备」（SideStore 式预注册手动入口）.
    @State private var deviceWorking = false
    @State private var deviceResult: DeviceRegistrationResult?
    @State private var reloginAccount: AppleUserAccount?
    @State private var signOutOptions = AppleAccountSignOutOptions()
    /// 二次确认对话框（防 Form 整行误触直接删户）.
    @State private var confirmRemove = false
    /// v0.3.756：列表身份代数——移除/退出 sheet 关闭后 +1，强制 List 重建，
    /// 兜底 destructive swipe + sheet 组合的幽灵行渲染缺陷（台账数据从未变过，纯显示层）.
    @State private var listEpoch = 0

    private struct DeviceRegistrationResult: Identifiable {
        let id = UUID()
        let ok: Bool
        let text: String
    }

    var body: some View {
        List {
            currentSection
            accountsSection
        }
        .navigationTitle("Apple ID 账户")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("添加账户", systemImage: "person.badge.plus")
                    }
                    if store.hasAccounts {
                        Button(role: .destructive) {
                            signOutOptions = .init()
                            showSignOutAllConfirm = true
                        } label: {
                            Label("退出全部账户", systemImage: "person.badge.minus")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AppleIDLoginSheet()
        }
        .sheet(item: $reloginAccount) { account in
            AppleIDLoginSheet(initialEmail: account.email)
        }
        .sheet(item: $deviceResult) { result in
            deviceRegisterSheet(result)
        }
        .sheet(isPresented: $showSignOutAllConfirm, onDismiss: { listEpoch += 1 }) {
            signOutSheet(account: nil)
        }
        .sheet(item: $pendingRemove, onDismiss: { listEpoch += 1 }) { account in
            signOutSheet(account: account)
        }
    }

    private func signOutSheet(account: AppleUserAccount?) -> some View {
        let hasOtherAccounts = account != nil && store.accounts.count > 1
        return NavigationStack {
            Form {
                Section {
                    Text(account == nil ? "退出全部已保持的账户. 退出后需重新登录才能侧载与管理证书."
                         : "移除该账户的登录凭据；其他账户和商店下载账户不受影响.")
                        .foregroundStyle(.secondary)
                }
                Section(header: Text("保留本地资料"), footer: Text(hasOtherAccounts
                    ? "这些资料由多个账户共享，仍有账户时全部保留."
                    : "取消勾选仅清理本地资料，不向 Apple 吊销证书. 设备标识始终保留.")) {
                    Toggle("保留签名证书", isOn: $signOutOptions.keepCertificate)
                    Toggle("保留 Anisette 资料", isOn: $signOutOptions.keepAnisetteData)
                    Toggle("保留 Anisette 请求头设置", isOn: $signOutOptions.keepAnisetteHeaders)
                }
                Section {
                    Text("当前项目没有独立的 SideSign 请求头设置，退出时不会创建或删除此类资料.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button(role: .destructive) {
                        LoginLogger.shared.log("[账户] 移除页点按删除键：\(account?.email ?? "全部账户")，等待二次确认")
                        confirmRemove = true
                    } label: {
                        Text(account == nil ? "退出全部账户" : "移除账户")
                            .font(AppFont.bodyEmphasis)
                            .foregroundStyle(AppTheme.danger)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog(
                        account == nil ? "确定退出全部账户？" : "确定移除 \(account?.email ?? "")？",
                        isPresented: $confirmRemove,
                        titleVisibility: .visible
                    ) {
                        Button(account == nil ? "退出全部账户" : "移除账户", role: .destructive) {
                            LoginLogger.shared.log("[账户] 二次确认通过，执行移除：\(account?.email ?? "全部账户")")
                            if let account { store.remove(account.email, options: signOutOptions) }
                            else { store.signOutAll(options: signOutOptions) }
                            pendingRemove = nil
                            showSignOutAllConfirm = false
                            listEpoch += 1
                        }
                        Button("取消", role: .cancel) {
                            LoginLogger.shared.log("[账户] 二次确认取消：\(account?.email ?? "全部账户")，未做任何操作")
                        }
                    } message: {
                        Text("移除后需重新登录才能侧载与管理证书.")
                    }
                }
            }
            .navigationTitle("退出登录")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { LoginLogger.shared.log("[账户] 移除页打开：\(account?.email ?? "全部账户")（当前共 \(store.accounts.count) 个账户）") }
            .onDisappear { LoginLogger.shared.log("[账户] 移除页关闭：\(account?.email ?? "全部账户")") }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { pendingRemove = nil; showSignOutAllConfirm = false }
                }
            }
        }
    }

    // MARK: - 分区

    private var currentSection: some View {
        Section(header: Text("当前账户"),
                footer: Text("IPA 侧载、开发证书等功能统一使用当前账户；切换后自动换用对应凭据.")) {
            if let acc = store.activeAccount {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "person.crop.circle.badge.checkmark",
                               tint: AppTheme.accent, symbolSize: 17, frameSize: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(acc.accountName?.isEmpty == false ? acc.accountName! : acc.email)
                            .font(AppFont.bodyEmphasis)
                        if acc.accountName?.isEmpty == false {
                            Text(acc.email)
                                .font(AppFont.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if deviceWorking {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("正在注册设备")
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AppTheme.success)
                            .accessibilityLabel("当前使用")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // v0.3.749：保险起见给手动注册入口——预注册在登录/切户时已尽力
                    // 做过，这里再点一次是幂等的（Rust 侧命中已注册直接返回）.
                    Button {
                        startDeviceRegistration()
                    } label: {
                        Label("注册设备", systemImage: "iphone")
                    }
                    .tint(AppTheme.accent)
                    .disabled(deviceWorking)
                }
            } else {
                Button {
                    // v0.3.746：未登录时的页内入口保留（此时右上角菜单也被隐藏），
                    // 已登录后去掉这行——添加入口只留右上角菜单，页面不再重复.
                    showAddSheet = true
                } label: {
                    HStack(spacing: 12) {
                        AppRowIcon(systemName: "person.crop.circle.badge.xmark",
                                   tint: Color(uiColor: .secondaryLabel), symbolSize: 17, frameSize: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("未登录")
                                .font(AppFont.bodyEmphasis)
                                .foregroundStyle(.primary)
                            Text("点按登录 Apple ID，侧载与证书即可使用.")
                                .font(AppFont.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var accountsSection: some View {
        Section(header: Text("已保持的账户（\(store.accounts.count)）"),
                footer: Text("登录过的账户会保持在这里，随时一键切换；切换不会重新登录.")) {
            ForEach(store.accounts) { acc in
                accountRow(acc)
            }
            .id(listEpoch)
            if store.accounts.isEmpty {
                Text("还没有保持的账户.")
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ acc: AppleUserAccount) -> some View {
        let isActive = acc.id == store.activeEmail
        HStack(spacing: 12) {
            AppRowIcon(systemName: "person.crop.circle",
                       tint: isActive ? AppTheme.accent : Color(uiColor: .secondaryLabel),
                       symbolSize: 17, frameSize: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(acc.email)
                    .font(AppFont.body)
                    .lineLimit(1)
                Text(isActive ? "使用中" : "点按切换到此账户")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isActive {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityLabel("当前账户")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive { store.switchActive(to: acc.email) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                reloginAccount = acc
            } label: {
                Label("重新登录", systemImage: "person.badge.key")
            }
            // v0.3.756：不再用 destructive 角色——destructive swipe + sheet 组合
            // 在 List 上有幽灵行渲染缺陷（用户实测「没点移除账户却被隐藏」），
            // 普通按钮 + danger 着色外观完全一致，且不触发该缺陷.
            Button {
                signOutOptions = .init()
                pendingRemove = acc
            } label: {
                Label("移除", systemImage: "trash")
            }
            .tint(AppTheme.danger)
        }
    }

    // MARK: - 注册设备（v0.3.749，SideStore 式预注册的手动入口）

    private func startDeviceRegistration() {
        guard !deviceWorking else { return }
        deviceResult = nil
        deviceWorking = true
        // 注册结果就绪才呈现；sheet挂在稳定页面而非会变化的账户行.
        Task { @MainActor in
            let outcome: (Bool, String)
            do {
                let udid = try await IPAInstallService.shared.registerCurrentDevice()
                outcome = (true, "设备已注册到当前签名团队.\nUDID：\(udid)\n后续签名可直接取到描述文件.")
            } catch {
                outcome = (false, error.localizedDescription)
            }
            deviceResult = DeviceRegistrationResult(ok: outcome.0, text: outcome.1)
            deviceWorking = false
        }
    }

    private func deviceRegisterSheet(_ result: DeviceRegistrationResult) -> some View {
        VStack(spacing: AppSpacing.section) {
            InfoActionCard(icon: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill",
                           iconTint: result.ok ? AppTheme.success : AppTheme.pending,
                           title: result.ok ? "注册成功" : "注册异常",
                           message: result.text)
            Button {
                deviceResult = nil
            } label: {
                Text("好")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TintedButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppSpacing.section)
        .presentationDetents([.height(250)])
        .presentationDragIndicator(.visible)
    }
}
