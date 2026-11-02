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
}
