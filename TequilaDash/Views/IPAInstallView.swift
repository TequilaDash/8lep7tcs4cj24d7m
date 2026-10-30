import SwiftUI
import UniformTypeIdentifiers

/// IPA 侧载（汉化移植自 SideInstaller 的「安装」板块）.
///
/// 选择 IPA（本地导入 / URL 下载）→ 登录 Apple ID（含 2FA）→ 签名 →
/// 通过 LocalDevVPN 隧道安装到设备.导入走 SharedDocumentPicker 统一调用点
/// （LC/证书直装环境可靠）.
///
/// v0.3.723 重构：原实现是 List + 9 个 .insetGrouped 默认样式分区 ——
/// 除页头外零品牌视觉，且「选 IPA / 登录 / 安装」三个主步骤与
/// 「自动登录 / 进度 / 失败 / 完成」四个辅助分区**权重完全相同**，
/// 主流程没被视觉串起来，主操作按钮还埋在列表最末尾.
/// 现在改成 ScrollView + 卡片流（与 StorageDetailView 同一范式）：
///   1. 页头 AppHeroHeader（配对文件 / 登录态 / 待装包 三个关键状态一眼可见）
///   2. 配对引导卡（缺配对文件时才出现）
///   3. 「安装流程」卡：三步编号 + 每步当前进度
///   4. 「选择 IPA」卡：导入 / 直链下载 / 已下载列表
///   5. 「签名账号」卡：登录态三分支 + 自动登录开关
///   6. 状态卡：进度 / 失败 / 完成三选一（不再各占一个分区）
///   7. 主操作「签名并安装」固定在底部操作条（safeAreaInset）
struct IPAInstallView: View {
    @StateObject private var service = IPAInstallService.shared

    // IPA 源
    @State private var showImporter = false
    @State private var ipaURL: URL?
    @State private var ipaLink = ""
    @State private var isDownloading = false
    /// 直链输入面板是否展开（v0.3.723：默认收起，点「粘贴直链」才展开）.
    @State private var showLinkField = false
    /// 「已下载的 IPA」列表（Documents/Custom 目录）.
    @State private var savedIPAs: [SavedIPA] = []
    /// 待确认删除的 IPA.
    @State private var pendingDeleteIPA: SavedIPA?

    // Apple ID
    @State private var appleID = ""
    @State private var password = ""
    @State private var showPassword = false
    /// 正在用设置里保存的 Apple ID 自动登录.
    @State private var isAutoSigningIn = false

    // 2FA
    @State private var showTwoFactor = false
    @State private var twoFactorCode = ""
    /// 自动登录开关（持久化在 UserDefaults；默认开）
    @State private var autoSignInOn: Bool =
        UserDefaults.standard.object(forKey: "IPA.autoSignInEnabled") as? Bool ?? true
    /// 2FA 等待代际：每次弹窗自增；超时定时器只在代际未变时生效（防旧定时器误取消新等待）
    @State private var twoFactorGeneration = 0
    /// 手动登录进行中（区别于自动登录，进度文案不同）
    @State private var isManuallySigningIn = false
    @State private var twoFactorReply: ((String?) -> Void)?

    // 流程
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var step: Step = .idle
    @State private var installProgress: Double = 0
    /// v0.3.662（task-8 发现10）：本次安装的签名产物 .app 路径，装完/失败后删除.
    @State private var lastSignedAppPath: String?

    /// 一个已下载/导入的 IPA 文件.
    private struct SavedIPA: Identifiable {
        let url: URL
        let name: String
        let size: Int64
        let modified: Date?
        var id: String { url.path }
    }

    /// IPA 统一存放目录（对齐 SideInstaller 的 IPALibrary.customDir）.
    private var customDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Custom", isDirectory: true)
    }

    private enum Step {
        case idle, signingIn, signing, installing, done
        var text: String? {
            switch self {
            case .idle: return nil
            case .signingIn: return "正在登录 Apple ID…"
            case .signing: return "正在签名 IPA…"
            case .installing: return "正在安装到设备…"
            case .done: return "安装完成"
            }
        }
    }

    private var pairingFileExists: Bool {
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return false }
        return size > 0
    }

    private var ipaDisplayName: String {
        ipaURL?.lastPathComponent ?? ""
    }

    // MARK: - 布局骨架

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.section) {
                heroCard
                    .appAppear(index: 0)
                if !pairingFileExists {
                    // v0.3.245：配对引导卡独立板块（与其他功能页同一 PairingGuideCard 视觉）.
                    // ScrollView 场景要自带卡片底与手动 chevron（List 的 .insetGrouped 会自动给）.
                    PairingGuideCard(showsBackground: true,
                                     note: "IPA 侧载需要配对文件（签名安装依赖设备身份）.",
                                     showChevron: true)
                        .appAppear(index: 1)
                }
                flowCard
                    .appAppear(index: 2)
                sourceCard
                    .appAppear(index: 3)
                accountCard
                    .appAppear(index: 4)
                if hasStatus {
                    statusCard
                        .appAppear(index: 5)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, AppTheme.pageInset)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.surfaceBase)
        .navigationTitle("IPA 侧载")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        refreshStatus()
                    } label: {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                    }
                    Button {
                        autoSignInOn.toggle()
                        UserDefaults.standard.set(autoSignInOn, forKey: "IPA.autoSignInEnabled")
                    } label: {
                        Label("自动登录（用「设置」里的 Apple ID）",
                              systemImage: autoSignInOn ? "checkmark.circle.fill" : "circle")
                    }
                    if MemoryLimitSettings.shared.isLoggedIn {
                        Button {
                            autoSignInWithSavedCredentials()
                        } label: {
                            Label("从「设置」登录 Apple ID", systemImage: "person.badge.key.fill")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
        .safeAreaInset(edge: .bottom) { installBar }
        .documentPicker(isPresented: $showImporter, allowedTypes: [UTType(filenameExtension: "ipa") ?? .data]) { urls in
            if let url = urls.first {
                importIPA(from: url)
            }
        }
        .onAppear {
            // v0.3.116 修卡死：signIn 跑在 Task.detached（后台线程），
            // 此前直接在此改 @State → 主线程外更新 SwiftUI 状态 → 弹窗不出现
            // 且永久等待验证码 → 界面像卡住.改为切主线程更新，并加超时兜底.
            service.twoFactorPrompt = { reply in
                Task { @MainActor in
                    twoFactorGeneration += 1
                    let generation = twoFactorGeneration
                    twoFactorCode = ""
                    twoFactorReply = reply
                    showTwoFactor = true
                    // 5 分钟没人填就取消本次登录（防弹窗被忽略后永久挂起）.
                    Task.detached {
                        try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                        await MainActor.run {
                            guard generation == twoFactorGeneration, showTwoFactor else { return }
                            showTwoFactor = false
                            let pending = twoFactorReply
                            twoFactorReply = nil
                            pending?(nil)
                            errorMessage = "2FA 验证码等待超时，已取消自动登录（可在设置里重新登录 Apple ID）"
                        }
                    }
                }
            }
            refreshSavedIPAs()
            // v0.3.116：每次进入都尝试自动登录（设置里重新登录后切回即生效）.
            autoSignInWithSavedCredentials()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            autoSignInWithSavedCredentials()
        }
        .onDisappear {
            service.twoFactorPrompt = nil
        }
        .alert("删除已下载的 IPA？",
               isPresented: Binding(get: { pendingDeleteIPA != nil },
                                    set: { if !$0 { pendingDeleteIPA = nil } })) {
            Button("删除", role: .destructive) {
                if let item = pendingDeleteIPA {
                    deleteSavedIPA(item)
                }
                pendingDeleteIPA = nil
            }
            Button("取消", role: .cancel) { pendingDeleteIPA = nil }
        } message: {
            if let item = pendingDeleteIPA {
                Text("「\(item.name)」将被永久删除，此操作不可撤销.")
            }
        }
        .alert("来自\(IPAInstallService.twoFactorFeature)的 Apple ID 验证请求",
               isPresented: $showTwoFactor) {
            TextField("6 位验证码", text: $twoFactorCode)
                .keyboardType(.numberPad)
            Button("登录") {
                let pending = twoFactorReply
                twoFactorReply = nil
                showTwoFactor = false
                pending?(twoFactorCode)
            }
            Button("取消", role: .cancel) {
                let pending = twoFactorReply
                twoFactorReply = nil
                showTwoFactor = false
                pending?(nil)
            }
        } message: {
            Text("输入您的 2FA 验证码以登录")
        }
    }

    // MARK: - 卡片骨架

    /// ScrollView 页里的标准卡片：AppSectionHeader + 内容 + 卡片底.
    ///
    /// 与 StorageDetailView.sectionCard 同构（那里 tint 写死 categoryDevice，
    /// 本页各卡按语义取色：流程 = 品牌色 / 选包 = 下载色 / 账号 = 签名色）.
    @ViewBuilder
    private func sectionCard<Content: View>(title: String,
                                            icon: String,
                                            tint: Color,
                                            @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AppSectionHeader(title, symbol: icon, tint: tint)
                .padding(.bottom, 10)
            content()
        }
        .padding(AppMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
            .fill(AppSurface.card))
    }

    // MARK: - 页头

    /// 页头：品牌图标块 + 标题 + 三个关键状态 stat.
    ///
    /// v0.3.721 重构：原先是 Section 里手搓的「40pt 图标 + headline + caption」，
    /// 与全仓详情页的 AppHeroHeader 语言不一致，且进页看不出「配对文件有没有 /
    /// 登录没登录 / IPA 选没选」. 改用 AppHeroHeader 后这三件事一眼可见.
    private var heroCard: some View {
        AppHeroHeader(
            title: "IPA 侧载",
            subtitle: "签名并安装 IPA 到设备（需 Apple ID + 配对文件 + LocalDevVPN）.",
            symbol: "arrow.down.app.fill",
            stats: [
                AppStat("配对文件", pairingFileExists ? "已就绪" : "未导入"),
                AppStat("Apple ID", service.isSignedIn ? "已登录" : "未登录"),
                AppStat("待装 IPA", ipaURL == nil ? "未选择" : "已选择")
            ]
        )
        .padding(.vertical, 6)
    }

    // MARK: - 安装流程

    /// 三步编号行（照 PairingSetupView.numberedStep 的形态，多一个「已完成」勾选态）.
    private func numberedStep(_ number: Int,
                              title: String,
                              text: String,
                              done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? AppTheme.success.opacity(0.16) : AppTheme.accentSoft)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppTheme.success)
                } else {
                    Text("\(number)")
                        .font(AppFont.captionEmphasis)
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.bodyEmphasis)
                Text(text)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var flowCard: some View {
        sectionCard(title: "安装流程", icon: "list.number", tint: AppTheme.accent) {
            VStack(alignment: .leading, spacing: 10) {
                numberedStep(1,
                             title: "选择 IPA",
                             text: ipaURL == nil
                                 ? "从「文件」导入，或粘贴直链下载 .ipa."
                                 : ipaDisplayName,
                             done: ipaURL != nil)
                AppHairline()
                numberedStep(2,
                             title: "登录 Apple ID",
                             text: service.isSignedIn
                                 ? (service.teamSummary ?? "签名会话已就绪.")
                                 : "登录以获取签名证书与描述文件，支持两步验证.",
                             done: service.isSignedIn)
                AppHairline()
                numberedStep(3,
                             title: "签名并安装",
                             text: step == .done
                                 ? "已安装到设备."
                                 : "选包与登录都就绪后，点底部「签名并安装」.",
                             done: step == .done)
            }
        }
    }

    // MARK: - 选择 IPA

    /// 选择 IPA：虚线投放区（视觉主角）+ 折叠的直链面板 + 已下载清单.
    ///
    /// v0.3.723 改版：原来「一行导入入口 + 常驻直链输入框 + 发丝线 + 列表」是四段平铺，
    /// 与「签名账号」等卡完全同构，看不出这一步是在「挑一个文件」. 改成虚线投放区，
    /// 直链输入折到按钮后面，已下载清单降为次级分组.
    private var sourceCard: some View {
        sectionCard(title: "选择 IPA", icon: "doc.badge.plus", tint: AppTheme.categoryDownload) {
            VStack(alignment: .leading, spacing: 12) {
                dropZone
                if showLinkField {
                    linkPanel
                }
                if !savedIPAs.isEmpty {
                    savedIPAList
                }
            }
        }
    }

    /// 虚线投放区：未选包时是「大图标 + 提示 + 两个入口」，已选包时收成一条文件行.
    private var dropZone: some View {
        VStack(spacing: 12) {
            if let ipa = ipaURL {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "shippingbox.fill",
                               tint: AppTheme.categoryDownload,
                               symbolSize: 20,
                               frameSize: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ipa.lastPathComponent)
                            .font(AppFont.subheadlineEmphasis)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("已选为待安装的 IPA.")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button("更换") {
                        AppHaptics.tap()
                        showImporter = true
                    }
                    .font(AppFont.footnote)
                    .buttonStyle(.borderless)
                    .disabled(isRunning)
                }
            } else {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(AppTheme.categoryDownload)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(AppTheme.categoryDownload.opacity(0.12)))
                    .accessibilityHidden(true)

                VStack(spacing: 3) {
                    Text("还没有选择 IPA")
                        .font(AppFont.bodyEmphasis)
                    Text("支持 .ipa 文件，导入后会先拷贝到应用沙盒.")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button {
                        AppHaptics.tap()
                        showImporter = true
                    } label: {
                        Label("从文件导入", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TintedButtonStyle(tint: AppTheme.categoryDownload, radius: AppRadius.button))
                    .disabled(isRunning)

                    Button {
                        AppHaptics.tap()
                        showLinkField.toggle()
                    } label: {
                        Label("粘贴直链", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TintedButtonStyle(tint: AppTheme.accent, radius: AppRadius.button))
                    .disabled(isRunning)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.inner, style: .continuous)
                .fill(AppTheme.categoryDownload.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.inner, style: .continuous)
                .strokeBorder(AppTheme.categoryDownload.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }

    /// 直链下载面板：只在点了「粘贴直链」后展开，收起时不占版面.
    private var linkPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("粘贴 IPA 直链（http/https）", text: $ipaLink)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .submitLabel(.go)
                .onSubmit { downloadIPA() }
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button {
                    downloadIPA()
                } label: {
                    if isDownloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("下载", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(TintedButtonStyle(tint: AppTheme.categoryDownload))
                .disabled(ipaLink.isEmpty || isRunning || isDownloading)

                Button("收起") {
                    showLinkField = false
                }
                .font(AppFont.footnote)
                .buttonStyle(.borderless)

                Spacer(minLength: 0)
            }

            if isDownloading {
                AppLoadingRow(title: "正在下载 IPA…", level: .inline)
            }
        }
    }

    /// 已下载清单：带计数的小标题 + 行，行间发丝线.
    private var savedIPAList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("本地文件")
                    .font(AppFont.captionEmphasis)
                    .foregroundStyle(.secondary)
                Text("\(savedIPAs.count)")
                    .font(AppFont.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)

            ForEach(Array(savedIPAs.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    AppHairline()
                }
                savedIPARow(item)
            }
        }
    }

    /// 已下载的 IPA 一行：左侧整块可点（选中 / 取消），右侧独立删除按钮.
    ///
    /// ScrollView 里没有 .onDelete（那是 List 的滑动手势），所以删除改成显式按钮；
    /// 选择动作放在内层 Button 上，避免与删除按钮的点击区域互相吞掉.
    private func savedIPARow(_ item: SavedIPA) -> some View {
        let selected = ipaURL?.path == item.url.path
        return HStack(spacing: 8) {
            Button {
                AppHaptics.tap()
                // 再次点击已选项 = 取消选择（ipaURL 置空，勾选消失）.
                if selected {
                    ipaURL = nil
                } else {
                    ipaURL = item.url
                }
                ipaLink = ""
                errorMessage = nil
                successMessage = nil
            } label: {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: selected ? "checkmark.circle.fill" : "shippingbox.fill",
                               tint: selected ? AppTheme.success : AppTheme.categoryDownload,
                               symbolSize: 17,
                               frameSize: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(AppFont.subheadlineEmphasis)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 8) {
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                            if let modified = item.modified {
                                Text(modified.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRunning)

            Button {
                AppHaptics.tap()
                pendingDeleteIPA = item
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("删除 \(item.name)")
            .disabled(isRunning)
        }
        .padding(.vertical, 8)
    }

    // MARK: - 签名账号

    private var accountCard: some View {
        sectionCard(title: "签名账号", icon: "person.crop.circle.badge.checkmark", tint: AppTheme.categorySign) {
            VStack(alignment: .leading, spacing: 10) {
                if service.isSignedIn {
                    HStack(spacing: 12) {
                        AppRowIcon(systemName: "checkmark.seal.fill", tint: AppTheme.success, symbolSize: 17, frameSize: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已登录")
                                .font(AppFont.bodyEmphasis)
                            Text(service.teamSummary ?? "签名会话已就绪.")
                                .font(AppFont.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Button("退出") {
                            service.signOut()
                            appleID = ""
                            password = ""
                        }
                        .font(AppFont.footnote)
                        .buttonStyle(.borderless)
                    }
                } else if isAutoSigningIn || isManuallySigningIn {
                    // 区块级加载收敛到共享 AppLoadingRow：
                    // 原来手写的「圈 + 标题 + 说明」与组件形态一一对应.
                    AppLoadingRow(title: isManuallySigningIn ? "正在登录 Apple ID…"
                                                            : "正在用「设置」里的 Apple ID 自动登录…",
                                  detail: "如需两步验证，会自动弹出验证码输入框.",
                                  level: .inline)
                } else {
                    // v0.3.118：邮箱恒为明文（邮箱不是机密；旧实现错误地跟随密码的
                    // showPassword，导致小眼睛把两栏都变星号）
                    TextField("Apple ID 邮箱", text: $appleID)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.next)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        Group {
                            if showPassword {
                                TextField("密码", text: $password)
                            } else {
                                SecureField("密码", text: $password)
                            }
                        }
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .submitLabel(.go)
                        .onSubmit { manualLogin() }          // v0.3.118：回车即登录
                        .textFieldStyle(.roundedBorder)
                        Button {
                            showPassword.toggle()
                        } label: {
                            // 图标 = 当前显示状态：eye=明文可见，eye.slash=已隐藏
                            Image(systemName: showPassword ? "eye" : "eye.slash")
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showPassword ? "隐藏密码" : "显示密码")
                    }
                    Button {
                        manualLogin()
                    } label: {
                        Label("登录", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TintedButtonStyle(tint: AppTheme.categorySign, radius: AppRadius.button))
                    .controlSize(.large)
                    .disabled(appleID.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)

                    Text("登录用于获取签名证书与描述文件，2FA 验证码在安装时弹出.")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // v0.3.118：自动登录开关/从设置登录独立成区（不再和输入框挤在一起）.
                // 重构后并入本卡尾部，仍只在「未登录且没有正在登录」时出现.
                if !service.isSignedIn && !isAutoSigningIn && !isManuallySigningIn {
                    AppHairline()
                    Toggle("自动登录（用「设置」里的 Apple ID）", isOn: $autoSignInOn)
                        .onChange(of: autoSignInOn) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "IPA.autoSignInEnabled")
                        }
                    if MemoryLimitSettings.shared.isLoggedIn {
                        Button {
                            autoSignInWithSavedCredentials()
                        } label: {
                            Label("从「设置」登录 Apple ID", systemImage: "person.badge.key.fill")
                                .font(AppFont.footnote)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Label("「更多 → 设置」里还没有保存 Apple ID", systemImage: "info.circle")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 状态

    private var hasStatus: Bool {
        step.text != nil || errorMessage != nil || successMessage != nil
    }

    /// 进度 / 失败 / 完成三选一，收敛在同一张卡里（原来是三个互不关联的分区）.
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let stepText = step.text {
                AppLoadingRow(title: stepText,
                              detail: step == .installing ? "进度 \(Int(installProgress * 100))%" : nil,
                              level: .inline)
            }
            if let error = errorMessage {
                HStack(alignment: .top, spacing: 12) {
                    AppRowIcon(systemName: "info.circle", tint: AppTheme.pending, symbolSize: 18, frameSize: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("安装没有完成")
                            .font(AppFont.subheadlineEmphasis)
                        Text(error)
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let success = successMessage {
                HStack(alignment: .top, spacing: 12) {
                    AppRowIcon(systemName: "checkmark.seal.fill", tint: AppTheme.success, symbolSize: 18, frameSize: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("安装完成")
                            .font(AppFont.subheadlineEmphasis)
                        Text(success)
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(AppMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
            .fill(AppSurface.card))
    }

    // MARK: - 底部操作条

    /// 可安装判据与原实现逐字一致（只多一个 trim 归一），不引入新的行为拦截.
    private var canInstall: Bool {
        !isRunning
            && ipaURL != nil
            && (service.isSignedIn
                || !(appleID.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty))
    }

    /// 底部提示：只在「还差什么」时给一句，全齐了就不啰嗦.
    private var installHint: String? {
        if ipaURL == nil {
            return "先选一个 IPA."
        }
        if !pairingFileExists {
            return "还没有配对文件，先到「更多 → 配对文件导入」."
        }
        if !service.isSignedIn
            && (appleID.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty) {
            return "先登录 Apple ID 或填好凭据."
        }
        return nil
    }

    private var installBar: some View {
        VStack(spacing: 6) {
            Button {
                startInstall()
            } label: {
                HStack(spacing: 8) {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Text(isRunning ? "正在处理…" : "签名并安装")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(TintedButtonStyle(tint: AppTheme.categorySign, radius: AppRadius.button))
            .controlSize(.large)
            .disabled(!canInstall)

            if let hint = installHint {
                Text(hint)
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, AppTheme.pageInset)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - 选包与下载

    private func downloadIPA() {
        guard let url = URL(string: ipaLink.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else {
            errorMessage = "链接无效：请输入 http/https 开头的 IPA 直链."
            return
        }
        isDownloading = true
        Task {
            do {
                let temp = try await download(url: url)
                let fm = FileManager.default
                try fm.createDirectory(at: customDir, withIntermediateDirectories: true)
                let target = customDir.appendingPathComponent(url.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                try fm.moveItem(at: temp, to: target)
                ipaURL = target
                ipaLink = ""
                refreshSavedIPAs()
            } catch {
                errorMessage = "下载失败：\(error.localizedDescription)"
            }
            isDownloading = false
        }
    }

    private func importIPA(from url: URL) {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: customDir, withIntermediateDirectories: true)
            let name = url.deletingPathExtension().lastPathComponent + ".ipa"
            let target = customDir.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: url, to: target)
            ipaURL = target
            ipaLink = ""
            errorMessage = nil
            successMessage = nil
            refreshSavedIPAs()
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    private func refreshSavedIPAs() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: customDir.path) else {
            savedIPAs = []
            return
        }
        let items: [SavedIPA] = names.compactMap { name in
            guard name.lowercased().hasSuffix(".ipa") else { return nil }
            let url = customDir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { return nil }
            return SavedIPA(url: url, name: name, size: size,
                            modified: attrs[.modificationDate] as? Date)
        }
        savedIPAs = items.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    private func deleteSavedIPA(_ item: SavedIPA) {
        try? FileManager.default.removeItem(at: item.url)
        if ipaURL?.path == item.url.path {
            ipaURL = nil
        }
        refreshSavedIPAs()
    }

    private func download(url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(http) else {
            throw NSError(domain: "IPAInstall", code: http,
                          userInfo: [NSLocalizedDescriptionKey: "服务器返回 HTTP \(http)"])
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    /// 手动刷新界面状态（右上角刷新按钮 / 日志输出完后调用）：
    /// 重新扫描已存 IPA、刷新登录态与局域网信息.
    private func refreshStatus() {
        refreshSavedIPAs()
        // 重新尝试登录/恢复会话（内部幂等：已登录则直接返回）
        autoSignInWithSavedCredentials()
        SSHServerService.shared.refreshNetworkInfo()
    }

    // MARK: - 自动登录（复用「更多 → 设置」的 Apple ID）

    /// 复用「更多 → 设置」已保存的 Apple ID，**不重复登录/2FA**：
    /// 1) 优先用 dsid + authToken 恢复 isideload 签名会话（免登录免 2FA）；
    /// 2) 恢复失败（token 过期等）才回退用邮箱+密码完整登录（可能弹 2FA）.
    /// 自动登录总开关（设置里可关；默认开）
    private var autoSignInEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "IPA.autoSignInEnabled") as? Bool ?? true }
    }

    /// 手动登录：用输入框里的 Apple ID + 密码（2FA 走弹窗）.
    /// 成功后持久化凭据，下次自动登录/免 2FA 恢复可用.
    private func manualLogin() {
        let id = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let pw = password
        guard !service.isSignedIn, !id.isEmpty, !pw.isEmpty, !isRunning else { return }
        guard !isAutoSigningIn, !isManuallySigningIn, !service.isWarmingUp else { return }
        isManuallySigningIn = true
        errorMessage = nil
        Task {
            do {
                let ani = MemoryLimitSettings.shared.anisetteServer
                try await Task.detached(priority: .userInitiated) {
                    try IPAInstallService.shared.signIn(appleID: id, password: pw, anisetteURL: ani)
                }.value
                let dsid = service.lastSessionDSID ?? ""
                let authToken = service.lastSessionAuthToken ?? ""
                await MainActor.run {
                    MemoryLimitSettings.shared.saveSessionCredentials(
                        email: id, password: pw, dsid: dsid, authToken: authToken)
                }
            } catch {
                await MainActor.run {
                    errorMessage = "登录失败：\(error.localizedDescription)"
                }
            }
            await MainActor.run { isManuallySigningIn = false }
        }
    }

    private func autoSignInWithSavedCredentials() {
        guard !service.isSignedIn, !isRunning else { return }
        // v0.3.116：用户明确要求可禁用自动登录（会触发 2FA 打断操作）
        guard autoSignInEnabled else { return }
        // warmUp（App 启动后台恢复）正在执行：不重复联网，等它完成——
        // 完成时 @Published isSignedIn 变化会自动刷新页面（v0.2.106 去重）.
        guard !service.isWarmingUp else { return }
        let settings = MemoryLimitSettings.shared
        guard settings.isLoggedIn, !settings.appleID.isEmpty else { return }
        let id = settings.appleID
        let ani = settings.anisetteServer
        isAutoSigningIn = true
        Task {
            do {
                // 路径 1：已有 dsid/authToken → 免 2FA 恢复会话.
                // （预热已失败过则跳过——token 大概率过期，白等一次注定失败的请求）
                // v0.2.112：读 isideload 专用键；dsid/authToken 属于 Swift 认证
                // 引擎（证书管理/增加内存用），两套 Anisette 机器标识不同不能混用.
                if !service.sessionRestoreFailed,
                   let dsid = settings.sideloadDSID, let authToken = settings.sideloadAuthToken,
                   !dsid.isEmpty, !authToken.isEmpty {
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try IPAInstallService.shared.signInWithSession(
                                email: id, dsid: dsid, authToken: authToken, anisetteURL: ani)
                        }.value
                        isAutoSigningIn = false
                        return
                    } catch {
                        // token 失效，回退完整登录.
                    }
                }
                // 路径 2：邮箱+密码完整登录（2FA 走弹窗）.
                let pw = settings.password(forHistory: id) ?? ""
                guard !pw.isEmpty else {
                    isAutoSigningIn = false
                    return
                }
                try await Task.detached(priority: .userInitiated) {
                    try IPAInstallService.shared.signIn(appleID: id, password: pw, anisetteURL: ani)
                }.value
                // 完整登录成功 → 持久化本次拿到的 dsid/authToken，
                // 下次进入（含 App 重启后 warmUp）即可免登录恢复.
                let dsid = service.lastSessionDSID ?? ""
                let authToken = service.lastSessionAuthToken ?? ""
                await MainActor.run {
                    MemoryLimitSettings.shared.saveSessionCredentials(
                        email: id, password: pw, dsid: dsid, authToken: authToken)
                }
            } catch {
                errorMessage = "自动登录失败：\(error.localizedDescription)"
            }
            isAutoSigningIn = false
        }
    }

    // MARK: - 安装流程

    /// v0.3.662（task-8 发现10）：**签名产物 .app 目录用完必须删**.
    ///
    /// IPAInstallService.signIPA（Engine/IPAInstallService.swift:447）返回的是 Rust 侧
    /// 在沙盒里新建的**已签名 .app 目录**，本 View 之前只把它当路径用、安装完 / 失败后
    /// 都不删 —— 每次安装都在设备上多留一份与 IPA 同等体积的解包产物（几百 MB 的
    /// 游戏包尤其明显），长期累积会撑爆应用沙盒.
    ///
    /// 只删本次 signIPA 真正返回的那个目录（lastSignedAppPath），不扫目录、不删别人
    /// 的产物；删失败也不影响安装结果（签名产物本来就是一次性的）.
    private func cleanupSignedProduct() {
        guard let path = lastSignedAppPath else { return }
        lastSignedAppPath = nil
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        // 防御：只删 .app 目录，绝不删到用户选中的原始 .ipa/解包目录.
        guard path.hasSuffix(".app") else { return }
        try? fm.removeItem(atPath: path)
    }

    private func startInstall() {
        guard !isRunning, let ipa = ipaURL else { return }
        isRunning = true
        errorMessage = nil
        successMessage = nil
        step = .idle
        installProgress = 0

        let id = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let pw = password
        let anisetteURL = MemoryLimitSettings.shared.anisetteServer

        Task {
            do {
                // 1. 登录（如未登录）
                if !service.isSignedIn {
                    step = .signingIn
                    try await Task.detached(priority: .userInitiated) {
                        try IPAInstallService.shared.signIn(appleID: id, password: pw, anisetteURL: anisetteURL)
                    }.value
                    // 登录成功 → 把邮箱/密码 **以及** 本次登录拿到的 dsid +
                    // xcode.auth token 一起持久化（v0.2.111，isideload fork 暴露）.
                    // 之后 warmUp / 自动登录都能用这两个值免登录免 2FA 恢复.
                    let dsid = service.lastSessionDSID ?? ""
                    let authToken = service.lastSessionAuthToken ?? ""
                    await MainActor.run {
                        MemoryLimitSettings.shared.saveSessionCredentials(
                            email: id, password: pw, dsid: dsid, authToken: authToken)
                    }
                }
                // 2. 签名
                step = .signing
                let signedPath = try await Task.detached(priority: .userInitiated) {
                    try IPAInstallService.shared.signIPA(ipaPath: ipa.path)
                }.value
                // v0.3.662（task-8 发现10）：先记下，成功/失败后由 cleanupSignedProduct() 删.
                lastSignedAppPath = signedPath
                // 3. 安装
                step = .installing
                try await Task.detached(priority: .userInitiated) {
                    try IPAInstallService.shared.install(signedAppPath: signedPath) { p in
                        DispatchQueue.main.async {
                            self.installProgress = p
                        }
                    }
                }.value
                step = .done
                successMessage = "「\((signedPath as NSString).lastPathComponent)」已安装到设备."
            } catch {
                step = .idle
                errorMessage = error.localizedDescription
            }
            // v0.3.723 修：原实现在 Task **之外**同步调用 cleanupSignedProduct()，
            // 那一刻 lastSignedAppPath 还是 nil ⇒ 从来没删过任何签名产物（注释写「无论成功失败
            // 都清掉」，代码却什么也没做）. 现在挪到 Task 内部收尾，成功/失败都会执行.
            cleanupSignedProduct()
            isRunning = false
        }
    }
}
