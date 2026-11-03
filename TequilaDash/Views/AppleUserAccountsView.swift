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
    @State private var showDeviceSheet = false
    @State private var deviceResult: (ok: Bool, text: String)?

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
        .alert("退出全部账户？", isPresented: $showSignOutAllConfirm) {
            Button("退出全部", role: .destructive) { store.signOutAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有已保持的账户都会被移除，签名会话与保存的凭据一并清除.")
        }
        .alert("移除账户？", isPresented: Binding(
            get: { pendingRemove != nil },
            set: { if !$0 { pendingRemove = nil } })) {
            Button("移除", role: .destructive) {
                if let acc = pendingRemove { store.remove(acc.email) }
                pendingRemove = nil
            }
            Button("取消", role: .cancel) { pendingRemove = nil }
        } message: {
            if let acc = pendingRemove {
                Text("「\(acc.email)」将从账户列表移除；侧载与证书改用切换后的账户.")
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
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.success)
                        .accessibilityLabel("当前使用")
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
                }
                .sheet(isPresented: $showDeviceSheet) {
                    deviceRegisterSheet
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
            Button(role: .destructive) {
                pendingRemove = acc
            } label: {
                Label("移除", systemImage: "trash")
            }
        }
    }

    // MARK: - 注册设备（v0.3.749，SideStore 式预注册的手动入口）

    private func startDeviceRegistration() {
        guard !deviceWorking else { return }
        deviceWorking = true
        deviceResult = nil
        showDeviceSheet = true
        Task { @MainActor in
            let outcome: (Bool, String)
            do {
                let udid = try await IPAInstallService.shared.registerCurrentDevice()
                outcome = (true, "设备已注册到当前签名团队.\nUDID：\(udid)\n后续签名可直接取到描述文件.")
            } catch {
                outcome = (false, error.localizedDescription)
            }
            deviceResult = outcome
            deviceWorking = false
        }
    }

    private var deviceRegisterSheet: some View {
        VStack(spacing: AppSpacing.section) {
            if deviceWorking {
                InfoActionCard(icon: "arrow.triangle.2.circlepath",
                               title: "正在注册设备",
                               message: "把本机 UDID 写进 Apple 开发者团队，通常几秒完成.")
            } else if let result = deviceResult {
                InfoActionCard(icon: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill",
                               iconTint: result.ok ? AppTheme.success : AppTheme.danger,
                               title: result.ok ? "注册成功" : "注册异常",
                               message: result.text)
            }
            Button {
                showDeviceSheet = false
            } label: {
                Text("好")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TintedButtonStyle())
        }
        .padding(AppSpacing.section)
        .presentationDetents([.height(250)])
        .presentationDragIndicator(.visible)
    }
}
