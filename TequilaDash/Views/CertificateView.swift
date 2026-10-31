import SwiftUI
import UniformTypeIdentifiers

/// 证书管理（汉化移植自 SideInstaller 的 CertsView）.
///
/// 列出并吊销 Apple ID 的 iOS 开发证书.纯开发者门户 API 调用，
/// 不涉及设备 / 配对 / 隧道，因此不依赖 LocalDevVPN 与本地网络权限.
struct CertificateView: View {
    @StateObject private var manager = CertificateManager.shared
    @StateObject private var settings = MemoryLimitSettings.shared
    /// v0.3.131：自动撤销开关/白名单（统一撤销接口的管控项）
    @StateObject private var certStore = DeveloperCertStore.shared
    @State private var showLogin = false
    /// 待确认吊销的证书.
    @State private var pendingRevoke: DeveloperCertificate?
    /// 批量选择模式.
    @State private var selecting = false
    @State private var selected: Set<String> = []
    /// 批量吊销确认.
    @State private var showBatchRevokeConfirm = false

    // v0.3.152 p12 导入（同源证书方案：导入主程序同款证书）
    @State private var showP12Picker = false
    @State private var showP12Password = false
    @State private var p12Password = ""
    @State private var pendingP12Data: Data?
    @State private var p12Message: String?
    // v0.3.155 删除已导入证书（LC 同款）
    @State private var showRemoveCertConfirm = false

    var body: some View {
        List {
            if !settings.isLoggedIn {
                loginStatusRow
            }
            // v0.3.131：自动撤销（统一撤销接口的管控开关）+ 白名单（仅一个）、（白名单与 SideStore/AltStore 标识的证书放行）遇 7460 情况使用
            Section(header: Text("自动撤销"), footer: Text("配额满时自动吊销旧证书.")) {
                Toggle("自动撤销证书", isOn: $certStore.autoRevokeEnabled)
                TextField("白名单", text: $certStore.revokeWhitelist)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            if settings.isLoggedIn {
                teamSection
                // 团队栏自己已展示失败原因，这里只在团队加载成功后补全局错误，
                // 避免同一条消息在页面上出现两次.
                if let error = manager.lastError, manager.teamState == .loaded {
                    Section {
                        InfoActionCard(
                            icon: manager.lastErrorIsSessionExpired ? "person.badge.key.fill" : "xmark.circle.fill",
                            iconTint: manager.lastErrorIsSessionExpired ? AppTheme.pending : AppTheme.danger,
                            title: manager.lastErrorIsSessionExpired ? "需要重新登录" : "出错了",
                            message: error
                        )
                    }
                }
                if manager.teamState == .loaded {
                    if manager.isWorking && manager.certs.isEmpty {
                        Section {
                            // 区块级加载收敛到共享 AppLoadingRow（.block 档）.
                            AppLoadingRow(title: "正在加载证书…", level: .block)
                        }
                    } else if manager.hasLoaded && manager.certs.isEmpty {
                        emptySection
                    } else if !manager.certs.isEmpty {
                        Section {
                            ForEach(manager.certs) { cert in
                                certRow(cert)
                                    // 左划：加入白名单（未在白名单时）
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        whitelistAddAction(cert)
                                    }
                                    // 右划：移出白名单（在白名单时）
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        whitelistRemoveAction(cert)
                                    }
                            }
                        } header: {
                            Text("\(manager.certs.count) 个证书")
                        }
                    }
                }
            }
            // v0.3.157：本地签名证书（p12）独立分组——登录与否都显示，与 Apple 侧证书列表区分
            localSigningSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("证书管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if settings.isLoggedIn && !manager.certs.isEmpty {
                    Button(selecting ? "取消" : "选择") {
                        selecting.toggle()
                        if !selecting { selected.removeAll() }
                    }
                    .disabled(manager.isWorking)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if selecting {
                    Button(allSelected ? "取消全选" : "全选") {
                        if allSelected {
                            selected.removeAll()
                        } else {
                            selected = Set(manager.certs.map(\.id))
                        }
                    }
                    .disabled(manager.isWorking)
                } else if settings.isLoggedIn {
                    Button {
                        manager.loadCerts()
                    } label: {
                        if manager.isWorking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(manager.isWorking)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            p12ImportFooter
        }
        .onChange(of: showP12Picker) { _, shown in
            guard shown else { return }
            SharedDocumentPicker.present(allowedTypes: [.data]) { urls in
                guard let url = urls.first,
                      let data = try? Data(contentsOf: url) else {
                    p12Message = "[失败] p12 文件读取失败"
                    return
                }
                pendingP12Data = data
                p12Password = ""
                showP12Password = true
            } onCancelled: {
                showP12Picker = false
            }
        }
        .alert("p12 密码", isPresented: $showP12Password) {
            TextField("导出时设置的密码", text: $p12Password)
            Button("导入") {
                guard let data = pendingP12Data else { return }
                let result = certStore.importP12(data: data, password: p12Password)
                p12Message = result.ok ? "[完成] \(result.message)" : "[失败] \(result.message)"
                pendingP12Data = nil
            }
            Button("取消", role: .cancel) { pendingP12Data = nil }
        } message: {
            Text("p12 导出时设置的密码.与主程序（LC/SideStore）同一签名模块.")
        }
        .alert("删除本地签名证书？", isPresented: $showRemoveCertConfirm) {
            Button("删除", role: .destructive) {
                let result = certStore.removeLocalCert()
                p12Message = result.ok ? "[完成] \(result.message)" : "[失败] \(result.message)"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅删除本地证书文件（签名随之不可用），不向 Apple 吊销.证书仍占账号名额，腾名额请用吊销.")
        }
        .sheet(isPresented: $showLogin) {
            AppleIDLoginSheet()
        }
        .onAppear {
            manager.autoLoad()
        }
        .onChange(of: settings.appleID) { _, _ in
            // 新登录 / 切换账号：清空旧团队的证书，重新拉团队列表.
            manager.reset()
            manager.autoLoad()
        }
        .alert("吊销所选证书？", isPresented: $showBatchRevokeConfirm) {
            Button("吊销", role: .destructive) {
                let targets = manager.certs.filter { selected.contains($0.id) }
                manager.batchRevoke(targets)
                selected.removeAll()
                selecting = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将吊销已选 \(selected.count) 张证书.相关应用将在所有设备上停止启动，且无法撤销.")
        }
        .alert("吊销这张证书？", isPresented: Binding(
            get: { pendingRevoke != nil },
            set: { if !$0 { pendingRevoke = nil } }
        )) {
            Button("吊销", role: .destructive) {
                if let cert = pendingRevoke { manager.revoke(cert) }
                pendingRevoke = nil
            }
            Button("取消", role: .cancel) { pendingRevoke = nil }
        } message: {
            if let cert = pendingRevoke {
                Text("「\(cert.displayName)」将被吊销.相关应用将在所有设备上停止启动，且无法撤销.")
            }
        }
    }

    // MARK: - 登录状态行

    /// 页顶登录状态一行，也是本页唯一的登录入口（硬规则 28 第 4 条同源原则）.
    ///
    /// 原来这里是一个 hero 大块头：图标 + 「证书管理」标题 + 说明 + 登录按钮，与导航标题
    /// （:88「证书管理」）信息重复，登录入口还在工具条与未登录卡片里各出现一次.现在删掉 hero，
    /// 已登录时页面状态由「开发者团队」栏自己表达，未登录时只留这一行.

    private var loginStatusRow: some View {
        Section {
            HStack(spacing: AppSpacing.row) {
                Image(systemName: "person.badge.key.fill")
                    .foregroundStyle(AppTheme.pending)
                Text("尚未登录")
                    .font(.subheadline)
                Spacer()
                Button("登录") { showLogin = true }
            }
        } footer: {
            Text("登录后可查看并吊销账号开发证书.登录需两步验证，凭据仅存本机钥匙串.")
        }
    }

    // MARK: - 开发者团队（v0.2.112：对齐「增加内存限制」的团队栏）

    /// 团队选择器.与「增加内存限制」保持同一套展示语言：
    /// 加载中 → 进度；失败 → 红字 + 重试；成功 → Picker（单团队时补一行说明）.
    private var teamSection: some View {
        Section {
            switch manager.teamState {
            case .idle:
                // v0.2.120：`.idle` 以前和 `.loading` 渲染成同一个转圈，
                // 导致"压根没发起请求"被误认为"正在加载"，用户永远等不到结果.
                // 现在 `.idle` 明确显示未加载 + 给一个「加载」按钮.
                HStack {
                    // 硬规则 1：不用黄色感叹号。原为 exclamationmark.circle + .orange，
                    // 改为 info.circle + AppTheme.pending（语义相同，形态合规，且取色明暗自适应）。
                    Image(systemName: "info.circle").foregroundStyle(AppTheme.pending)
                    Text("尚未加载团队")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("加载") { manager.loadTeams() }
                }
                .onAppear { manager.loadTeams() }
            case .loading:
                // 区块级加载收敛到共享 AppLoadingRow（.block 档）.
                AppLoadingRow(title: "正在加载团队…", level: .block)
            case .failed(let message):
                // v0.3.683：区块级错误行统一到 AppErrorRow（红字标题 "加载失败" 由图标语义承担）.
                AppErrorRow(message: message, retry: { manager.loadTeams() })
            case .loaded:
                if manager.teams.isEmpty {
                    // v0.3.677：裸 Text 空态 → 统一三态组件 AppStateSection。
                    // 这里确实是「空列表」：团队已加载成功、但账号下 0 个团队（不是错误态）。
                    AppStateSection(state: .empty("账号下没有可用团队",
                                                  message: "该 Apple ID 名下没有开发者团队；创建后重新加载.",
                                                  icon: "person.2.slash"), wrapsSection: false)
                } else {
                    Picker("选择团队", selection: $manager.selectedTeamID) {
                        ForEach(manager.teams) { team in
                            Text(team.name).tag(team.identifier)
                        }
                    }
                    .onChange(of: manager.selectedTeamID) { _, _ in
                        manager.loadCerts()
                    }
                    if manager.teams.count == 1, let only = manager.teams.first {
                        Text("\(only.name)（\(only.identifier)）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("开发者团队")
        }
    }

    // MARK: - 批量选择

    /// 是否已全选（批量模式用）.
    private var allSelected: Bool {
        !manager.certs.isEmpty && selected.count == manager.certs.count
    }

    // MARK: - 空状态

    private var emptySection: some View {
        Section {
            // 中性空态（判据 E5）：图标取 InfoActionCard 默认 AppTheme.accent，不写行级 tint.
            InfoActionCard(
                icon: "checkmark.seal",
                title: "没有证书",
                message: "这个 Apple ID 下没有可吊销的 iOS 开发证书."
            )
        }
    }

    // MARK: - 证书行

    /// 是否命中白名单（序列号精确匹配）
    private func isWhitelisted(_ cert: DeveloperCertificate) -> Bool {
        !certStore.revokeWhitelist.isEmpty && cert.serialNumber == certStore.revokeWhitelist
    }

    // v0.3.152：底部安全区（现仅批量吊销栏；p12 已移至列表内独立分组 v0.3.157）
    @ViewBuilder
    private var p12ImportFooter: some View {
        VStack(spacing: 0) {
            if selecting {
                batchRevokeBar
            }
        }
        .background(.bar)
    }

    @ViewBuilder
    private func p12MessageText(_ msg: String) -> some View {
        let isOK = msg.hasPrefix("[完成]")
        Text(msg)
            .font(.caption)
            .foregroundStyle(isOK ? AppTheme.success : AppTheme.pending)
            .padding(.horizontal)
    }

    @ViewBuilder
    private var batchRevokeBar: some View {
        HStack {
            Text("已选 \(selected.count) 项")
                .font(.subheadline)
            Spacer()
            Button("吊销", role: .destructive) {
                showBatchRevokeConfirm = true
            }
            .disabled(selected.isEmpty || manager.isWorking)
        }
        .padding()
        .background(.bar)
    }

    // v0.3.157：本地签名证书（p12）独立分组.作用：模块/文件真证书签名用的
    // 本地证书（导入的 p12 或登录自动签发），与上方 Apple 侧证书列表（吊销对象）区分.
    @ViewBuilder
    private var localSigningSection: some View {
        Section {
            if certStore.hasCert {
                Label(certStore.localCertSummary, systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundColor(AppTheme.success)
            } else {
                Label("未设置本地签名证书", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundColor(AppTheme.pending)
            }
            Button {
                showP12Picker = true
            } label: {
                Label("导入 p12 证书", systemImage: "square.and.arrow.down")
            }
            if certStore.hasCert {
                Button(role: .destructive) {
                    showRemoveCertConfirm = true
                } label: {
                    Label("删除已导入证书（仅本地）", systemImage: "trash")
                }
            }
            if let msg = p12Message {
                p12MessageText(msg)
            }
        } header: {
            Text("签名证书（p12）")
        } footer: {
            Text("用于模块/文件真证书签名.identifier 需与主程序一致（自动处理），TeamID 匹配即可.导入的 p12 会替换本地证书文件，不吊销 Apple 侧证书.")
        }
    }

    // v0.3.152：白名单 swipeActions 拆出（body type-check 超时修复）
    @ViewBuilder
    private func whitelistAddAction(_ cert: DeveloperCertificate) -> some View {
        if cert.serialNumber != certStore.revokeWhitelist {
            Button {
                certStore.revokeWhitelist = cert.serialNumber
            } label: {
                Label("加入白名单", systemImage: "checkmark.seal")
            }
            .tint(AppTheme.accent)
        }
    }

    @ViewBuilder
    private func whitelistRemoveAction(_ cert: DeveloperCertificate) -> some View {
        if cert.serialNumber == certStore.revokeWhitelist {
            Button {
                certStore.revokeWhitelist = ""
            } label: {
                Label("移出白名单", systemImage: "xmark.seal")
            }
            .tint(AppTheme.pending)
        }
    }

    /// 批量模式下切换单张证书的选中态（行、勾选圈两处点击共用）.
    private func toggleSelection(_ cert: DeveloperCertificate) {
        if selected.contains(cert.id) {
            selected.remove(cert.id)
        } else {
            selected.insert(cert.id)
        }
    }

    /// 证书行：固定图标列 + 统一内容列 + 行尾状态列（round8 结构性整改）.
    ///
    /// 整改前图标、标题块、明细块各自为政（spacing 10 / 12 / 3 / 4 混用、白名单与已过期
    /// 两枚胶囊不同档），吊销还是占满整行的大按钮.现在列宽与间距全部走 AppSpacing 与共享组件.
    private func certRow(_ cert: DeveloperCertificate) -> some View {
        let revoking = manager.revokingID == cert.id
        let isSelected = selected.contains(cert.id)
        return VStack(alignment: .leading, spacing: AppSpacing.row) {
            // 三列结构（round8）：固定图标列 → 统一内容列 → 行尾状态列.
            // 图标列用 AppRowIcon 默认 30 宽底，保证跨行左边界一致；间距只取 AppSpacing 档位.
            HStack(alignment: .top, spacing: AppSpacing.row) {
                if selecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.unselected)
                        .onTapGesture { toggleSelection(cert) }
                }
                AppRowIcon(systemName: "seal.fill",
                           tint: cert.isExpired ? AppTheme.pending : AppTheme.success)
                VStack(alignment: .leading, spacing: AppSpacing.tight) {
                    Text(cert.displayName)
                        .font(.subheadline.weight(.semibold))
                    if let machine = cert.machineLabel {
                        Label(machine, systemImage: "desktopcomputer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: AppSpacing.tight)
                VStack(alignment: .trailing, spacing: AppSpacing.tight) {
                    if isWhitelisted(cert) {
                        // v0.3.131：白名单胶囊（自动撤销时放行）.
                        // round8：本页状态胶囊统一 SizePill 的 `.compact` 档、不带覆盖项，
                        // 取色只用 success / pending / danger.白名单=放行保留，取 success.
                        SizePill(text: "白名单", tint: AppTheme.success, level: .compact)
                    }
                    if cert.isExpired {
                        SizePill(text: "已过期", tint: AppTheme.pending, level: .compact)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if selecting { toggleSelection(cert) }
            }

            if cert.expiration != nil || !cert.serialNumber.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.tight) {
                    if let expiry = cert.expiration {
                        Label("到期 \(expiry.formatted(date: .abbreviated, time: .omitted))",
                              systemImage: "calendar")
                    }
                    if !cert.serialNumber.isEmpty {
                        Label(cert.serialNumber, systemImage: "number")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !selecting {
                // round8：吊销从「占满整行的大按钮」降为行尾小按钮，确认对话框照旧保留.
                HStack(spacing: AppSpacing.tight) {
                    Spacer()
                    Button(role: .destructive) {
                        pendingRevoke = cert
                    } label: {
                        HStack(spacing: AppSpacing.tight) {
                            if revoking {
                                ProgressView().controlSize(.mini)
                                Text("吊销中")
                            } else {
                                Image(systemName: "trash")
                                Text("吊销")
                            }
                        }
                        .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(revoking || manager.isWorking || manager.revokingID != nil)
                }
            }
        }
        .padding(.vertical, AppSpacing.tight)
    }
}
