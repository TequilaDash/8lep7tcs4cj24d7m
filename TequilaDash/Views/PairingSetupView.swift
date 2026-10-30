import SwiftUI

/// Shown when no pairing file is present: import + LocalDevVPN instructions.
struct PairingSetupView: View {
    @ObservedObject var viewModel: AppListViewModel
    @State private var showImporter = false
    @State private var importError: String?
    @State private var clipboardError: String?
    @State private var showWirelessPairing = false
    @State private var wirelessPin: String?
    @State private var wirelessStatus = "正在广播配对服务…"
    @State private var wirelessError: String?
    @State private var wirelessBroadcastErrorCode: Int?
    @State private var wirelessDeviceName: String?
    @State private var wirelessEngine: WirelessPairing?
    @AppStorage("keepAliveAudio") private var keepAliveAudio = false
    @AppStorage("keepAliveLocation") private var keepAliveLocation = false
    @State private var keepAlive = WirelessKeepAlive()

    // Observer tokens for `WirelessPairing`'s NSNotificationCenter callbacks.
    // We use notifications instead of block parameters because Swift's Clang
    // Importer silently drops bridged methods that have block parameters in
    // this toolchain (see WirelessPairing.h for details).
    @State private var wirelessPinObserver: NSObjectProtocol?
    @State private var wirelessCompleteObserver: NSObjectProtocol?
    @State private var wirelessBroadcastObserver: NSObjectProtocol?

    /// iOS 27 introduced in-app wireless pairing (the pairing code shows inside
    /// the app instead of via a system notification). Gate the wireless section on it.
    private var isIOS27OrLater: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    var body: some View {
        List {
            heroSection
            importSection
            stepsSection
            if isIOS27OrLater {
                wirelessSection
            } else {
                wirelessUnavailableSection
            }
            retrySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("配对文件导入")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showWirelessPairing) {
            wirelessSheetContent
                .onDisappear {
                    // Reliable teardown: cancel the heartbeat timer + stop
                    // the Bonjour publish + drop the engine so the listener
                    // and NSNetService release deterministically (otherwise
                    // Bonjour registration can linger after the sheet closes,
                    // causing the "broadcast a while then disappears" symptom).
                    wirelessEngine?.stop()
                    wirelessEngine = nil
                    keepAlive.stop()
                    cancelWirelessPairingCleanup()
                }
        }
        .pairingFilePicker(isPresented: $showImporter) { result in
            handlePairingPicker(result)
        }
        .onAppear(perform: registerWirelessObservers)
        .onDisappear(perform: unregisterWirelessObservers)
    }

    // MARK: - Sections

    /// 顶部说明块：品牌图标块 + 标题 + 配对状态.
    ///
    /// v0.3.721 重构：原先是 48pt 裸图标 + .title2 居中标题的「欢迎页」语汇，
    /// 与全仓二级页的 AppHeroHeader / AppBrandTile 语言不一致；改用
    /// AppHeroHeader 同款结构，并带上配对状态 stat，让用户进页第一眼就知道
    /// 现在到底有没有配对文件.
    private var heroSection: some View {
        Section {
            AppHeroHeader(
                title: "配对文件导入",
                subtitle: "TequilaDash 通过配对文件识别你的设备，走 LocalDevVPN 隧道读写应用与文件.",
                symbol: "key.horizontal.fill",
                stats: [
                    AppStat("配对状态", viewModel.hasPairingFile ? "已就绪" : "未导入"),
                    AppStat("可用方式", isIOS27OrLater ? "文件 / 剪贴板 / 无线" : "文件 / 剪贴板")
                ]
            )
            .padding(.vertical, 6)
        }
    }

    /// 导入区：两条导入通道收进同一个 Section，错误统一到一个错误槽.
    ///
    /// v0.3.721 重构：原先「导入文件」与「剪贴板导入」是两个 44pt 大按钮，
    /// 外加两条各自独立的 AppErrorRow；两条错误槽在界面上是两行灰字，
    /// 用户分不清是哪条通道失败的. 现在改成 List 原生行（与 PairingInstallView /
    /// IncreaseMemoryView 一致），错误只留一个槽，由 importErrorText 归并.
    private var importSection: some View {
        Section {
            // v0.3.724：两行都必须 `.buttonStyle(.plain)`. List 里裸 Button 会把整个 label
            // 的前景色换成 accent，于是 `.primary` 解析成深蓝、`.secondary` 解析成同色淡化的
            // 浅蓝（真机截图取样实测 #3B85F0 / #98BFE6）—— 这就是用户说的「一个深蓝一个浅蓝文本」.
            Button {
                showImporter = true
            } label: {
                importRow(title: "导入配对文件",
                          subtitle: "从「文件」中选取 pairingFile.plist 或 iLoader 文件.",
                          systemImage: "doc.badge.plus")
            }
            .buttonStyle(.plain)

            Button {
                importFromClipboard()
            } label: {
                importRow(title: "从剪贴板粘贴",
                          subtitle: "剪贴板里已是配对文件的文本内容.",
                          systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.plain)

            if let message = importErrorText {
                AppErrorRow(message: message)
            }
        } header: {
            Text("导入")
        } footer: {
            Text(pairingFooterText)
        }
    }

    /// 已导入但解析不了的配对文件是**最坏的一种状态**：页面显示「已检测到」，隧道却全线失败.
    /// v0.3.724：把 Rust 侧的解析结果并进脚注，坏文件当场说清原因.
    private var pairingFooterText: String {
        guard viewModel.hasPairingFile else {
            return "导入后无需重启，返回即可看到设备上的应用列表."
        }
        if let probe = TunnelContext.shared.pairingFileParseError {
            return "配对文件存在但无法解析：\(probe).请重新导入 RSD 远程配对文件."
        }
        return "已检测到配对文件.重新导入会覆盖现有配对身份，导入后无需重启."
    }

    private func importRow(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            // 这是通用「导入文件」动作，不是签名动作 —— 用签名粉（HSL 338°）在真机上读成
            // 「红色滥用」（v0.3.724 反馈）. 统一回品牌强调色，本页只留一个彩色.
            AppRowIcon(systemName: systemImage, tint: AppTheme.accent, symbolSize: 17, frameSize: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.bodyEmphasis)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    /// 三步准备：编号步骤改用行内编号圆点 + 标题 + 说明.
    ///
    /// v0.3.721 重构：原先复用 RootView 里的 SetupStep（28×28 圆底 + headline），
    /// 与 List 行高体系不匹配；现在编号圆点改用 AppTheme.accentSoft 淡底，
    /// 视觉与「导入」区同族.
    private var stepsSection: some View {
        Section {
            numberedStep(1, title: "安装 LocalDevVPN",
                        text: "从 App Store 安装 LocalDevVPN，保持设备 IP / 隧道 IP 为默认值（10.7.0.1），连接它并开启 Wi-Fi.")
            numberedStep(2, title: "获取配对文件",
                        text: "在 Windows 上用 iPASide 侧载生成 pairingFile.plist，也可在此直接导入.之后可拔线（走 LocalDevVPN，不走 USB）.")
            numberedStep(3, title: "加载应用",
                        text: "TequilaDash 随后列出你已安装的应用，可浏览或备份其数据.")
        } header: {
            Text("准备步骤")
        } footer: {
            Text("iOS 26.4 及更高版本需要远程配对密钥，iOS 18 只需 USB 信任部分.")
        }
    }

    private func numberedStep(_ number: Int, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(AppFont.captionEmphasis)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(AppTheme.accentSoft))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.bodyEmphasis)
                Text(text)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// iOS 27 无线配对入口（原先是页内卡片，现在收进 List 行）.
    private var wirelessSection: some View {
        Section {
            Button {
                startWirelessPairing()
            } label: {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "wifi", tint: AppTheme.categoryDevice, symbolSize: 17, frameSize: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iOS 27 无线配对")
                            .font(AppFont.bodyEmphasis)
                            .foregroundStyle(.primary)
                        Text("无需电脑，配对码直接显示在 App 内.")
                            .font(AppFont.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "lock.iphone")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.categoryDevice)
                }
                .contentShape(Rectangle())
            }
        } header: {
            Text("无线配对")
        } footer: {
            Text("点击后，在另一台设备的 设置 › 隐私与安全性 › 开发者模式 中选择「与 TequilaDash 配对」，并输入此处显示的配对码.")
        }
    }

    /// 低版本 iOS 的无线配对不可用说明（原先是整张卡片都不渲染，用户不知道有这个能力）.
    private var wirelessUnavailableSection: some View {
        Section {
            HStack(spacing: 12) {
                AppRowIcon(systemName: "info.circle", tint: AppTheme.pending, symbolSize: 17, frameSize: 30)
                Text("iOS 27 起支持无线配对（无需电脑）.当前系统版本请用文件或剪贴板导入.")
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private var retrySection: some View {
        Section {
            Button {
                viewModel.reload()
            } label: {
                HStack {
                    Label("重新加载应用列表", systemImage: "arrow.clockwise")
                    Spacer()
                }
            }
            .disabled(viewModel.isLoading)
        } footer: {
            Text("已导入配对文件但仍看不到应用时，先确认 LocalDevVPN 已连接，再点这里.")
        }
    }

    // MARK: - Derived state

    /// 两条导入通道的错误归并到一个槽：剪贴板错误优先（它是更近的一次操作），
    /// 其次是文件导入错误.
    private var importErrorText: String? {
        clipboardError ?? importError
    }

    /// 文件选择器的结果处理（从 body 里抽出，避免闭包过长挤占视图体）.
    private func handlePairingPicker(_ result: Result<Data, Error>) {
        switch result {
        case .success(let data):
            do {
                let contents: String
                if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
                    contents = utf8
                } else if let xml = try? PropertyListSerialization.data(
                    fromPropertyList: try PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                    format: .xml,
                    options: 0
                ), let text = String(data: xml, encoding: .utf8) {
                    contents = text
                } else {
                    throw NSError(
                        domain: "TequilaDash",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "无法读取该配对文件."]
                    )
                }
                try viewModel.importPairingFile(contents)
                importError = nil
                clipboardError = nil
                viewModel.reload()
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            // Don't treat user cancellation as an error surface.
            if (error as NSError).code == -4 { break }
            importError = error.localizedDescription
        }
    }


    /// Read a pairing file from the system pasteboard and import it.
    /// Reuses the same Data→String (plist fallback) parsing as the file importer.
    private func importFromClipboard() {
        guard let pasted = UIPasteboard.general.string,
              !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clipboardError = "剪贴板为空，或不含文本."
            return
        }
        guard let data = pasted.data(using: .utf8) else {
            clipboardError = "剪贴板内容无法解析为配对文件."
            return
        }
        do {
            try viewModel.importPairingFile(from: data)
            clipboardError = nil
            importError = nil
            viewModel.reload()
        } catch {
            clipboardError = error.localizedDescription
        }
    }

    /// Entry point for the iOS 27 device-initiated wireless pairing flow.
    ///
    /// Drives the real host-pairing engine (`si_run_host`, Rust, bridged via
    /// `WirelessPairing`): publishes the `_remotepairing-pairable-host._tcp`
    /// Bonjour service, shows the 6-digit PIN as an in-app card (mirroring
    /// SideInstaller's in-app PIN, not a system notification), and on success
    /// writes the resulting `RpPairingFile` to `Documents/pairingFile.plist`
    /// (the same path `TunnelContext` already loads), then reloads so the app
    /// picks up the new tunnel. The host's `alt_irk` is persisted in
    /// `UserDefaults` so an already-paired device keeps recognizing this host.
    private func startWirelessPairing() {
        wirelessPin = nil
        wirelessDeviceName = nil
        wirelessError = nil
        wirelessStatus = "正在广播配对服务（_remotepairing-pairable-host._tcp）…"
        showWirelessPairing = true

        // 若用户开启则启动后台保活，避免 Bonjour 注册被系统 SRP 回收.
        keepAlive.start(audio: keepAliveAudio, location: keepAliveLocation)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let outPath = docs.appendingPathComponent("pairingFile.plist").path
        let storedAltIrk = UserDefaults.standard.string(forKey: "wirelessHostAltIrk")

        let pairing = WirelessPairing()
        wirelessEngine = pairing // keep alive for the blocking background call
        pairing.start(
            withHostName: "TequilaDash",
            model: "Mac17,7",
            outPath: outPath,
            storedAltIrk: storedAltIrk ?? ""
        )
        // PIN and completion are delivered via NSNotificationCenter; the
        // observer handlers are wired up on `onAppear`.
    }

    /// Closes the wireless-pairing sheet. The underlying host listener keeps
    /// running until the device connects or the app is killed; the sheet only
    /// closes the UI.
    private func cancelWirelessPairing() {
        showWirelessPairing = false
    }

    /// Reset all transient wireless-pairing state. Called from the sheet's
    /// `.onDisappear` so the next time the user opens the sheet we get a
    /// clean UI (no stale PIN, no leftover error message).
    private func cancelWirelessPairingCleanup() {
        wirelessPin = nil
        wirelessError = nil
        wirelessBroadcastErrorCode = nil
        wirelessDeviceName = nil
        wirelessStatus = "正在广播配对服务…"
    }

    /// 后台保活开关卡片（移植自 StikPair）.
    private var keepAliveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("后台保活")
                .font(AppFont.subheadlineEmphasis)
                .foregroundStyle(.primary)

            Toggle("静默音频", isOn: $keepAliveAudio)
                .font(AppFont.subheadline)

            Toggle("位置更新", isOn: $keepAliveLocation)
                .font(AppFont.subheadline)

            Text("若广播过一会就消失，可开启其中一个或多个选项，让系统在后台继续保留本 App 的 Bonjour 注册.")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppMetrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(AppSurface.card)
        )
    }

    // MARK: - Wireless pairing sheet content

    /// Extracted from `.sheet(...)` so we can attach `.onDisappear` reliably.
    /// NSNetService registrations on iOS 18 have been observed to linger
    /// past the sheet's lifecycle; the cleanup hook in `.onDisappear` makes
    /// sure the heartbeat + Bonjour publish are torn down deterministically.
    private var wirelessSheetContent: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer(minLength: 8)
                if let error = wirelessError {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(AppTheme.danger)
                    Text("配对失败").font(AppFont.title3)
                    Text(error)
                        .font(AppFont.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("关闭") {
                        cancelWirelessPairing()
                    }
                    .buttonStyle(TintedButtonStyle(tint: AppTheme.categoryDevice))
                } else if let name = wirelessDeviceName {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(AppTheme.success)
                    Text("配对成功").font(AppFont.title3)
                    Text("已与 \(name) 建立无线配对.")
                        .font(AppFont.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("完成") {
                        cancelWirelessPairing()
                        viewModel.reload()
                    }
                    .buttonStyle(TintedButtonStyle(tint: AppTheme.categoryDevice, radius: AppRadius.button))
                } else if let pin = wirelessPin {
                    VStack(spacing: 10) {
                        Image(systemName: "lock.iphone")
                            .font(.system(size: 40))
                            .foregroundStyle(AppTheme.categoryDevice)
                        Text("请输入配对码").font(AppFont.headline)
                        Text(pin)
                            .font(.system(size: 44, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.categoryDevice)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                                    .fill(AppSurface.card)
                            )
                        Text("在另一台设备的 设置 › 隐私与安全性 › 开发者模式 中选择「与 TequilaDash 配对」，并输入上方配对码.")
                            .font(AppFont.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    // 进度态：菊花 + 状态文字垂直居中，keepAliveCard 贴底
                    //（v0.2.76 改：之前整个进度态一起被 Spacer 居中，
                    // keepAliveCard 较高把菊花+文字重心拉下，看起来偏下）.
                    Spacer(minLength: 8)
                    VStack(spacing: 12) {
                        // v0.3.699：整页加载态收口到 AppLoadingRow（.page 档：大圈 + 标题居中）.
                        AppLoadingRow(title: wirelessStatus, level: .page)
                        if let code = wirelessBroadcastErrorCode {
                            Text("广播未确认（错误码 \(code)）")
                                .font(AppFont.caption)
                                .foregroundStyle(AppTheme.pending)
                                .multilineTextAlignment(.center)
                        }
                    }
                    Spacer(minLength: 8)
                    keepAliveCard
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .navigationTitle("iOS 27 无线配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancelWirelessPairing() }
                }
            }
        }
    }

    // MARK: - Wireless pairing NSNotificationCenter bridge

    private func registerWirelessObservers() {
        let center = NotificationCenter.default
        guard wirelessPinObserver == nil else { return }
        wirelessPinObserver = center.addObserver(
            forName: Notification.Name("WirelessPairingDidShowPINNotification"),
            object: nil,
            queue: .main
        ) { [self] note in
            guard let pin = note.userInfo?["pin"] as? String else { return }
            self.wirelessPin = pin
            self.wirelessStatus = "请在另一台设备输入以下配对码："
        }
        wirelessCompleteObserver = center.addObserver(
            forName: Notification.Name("WirelessPairingDidCompleteNotification"),
            object: nil,
            queue: .main
        ) { [self] note in
            guard let info = note.userInfo else { return }
            let success = (info["success"] as? NSNumber)?.boolValue ?? false
            let deviceName = (info["deviceName"] as? String) ?? ""
            let hostAltIrk = (info["hostAltIrk"] as? String) ?? ""
            let errorMsg = (info["error"] as? String) ?? ""
            if success {
                if !hostAltIrk.isEmpty {
                    UserDefaults.standard.set(hostAltIrk, forKey: "wirelessHostAltIrk")
                }
                self.wirelessDeviceName = deviceName.isEmpty ? "设备" : deviceName
                self.wirelessBroadcastErrorCode = nil
                self.keepAlive.stop()
                // 落盘后立刻让 Rust 侧真解析一遍：设备写出不完整记录的实例是存在的，
                // 解析不过就当场报错，别等用户到隧道功能里才看到「missing field public_key」.
                if let probe = TunnelContext.shared.pairingFileParseError {
                    self.wirelessDeviceName = nil
                    self.wirelessError = "配对文件已写入但无法解析：\(probe)"
                }
            } else {
                self.wirelessError = errorMsg.isEmpty ? "配对失败，请重试." : errorMsg
            }
        }
        // Bonjour 广播失败（NSNetService didNotPublish）：
        // v0.2.76 之前只 NSLog，LiveContainer 共享应用 guest 等嵌入环境下
        // 静默失败让用户以为广播成功却搜不到——现在把错误码回报给 UI 提示.
        // v0.3.721 修：这段注册原本错放在 unregisterWirelessObservers() 末尾，
        // 每次 onDisappear 都会新增一个永不注销的观察者并覆盖旧 token（泄漏）.
        wirelessBroadcastObserver = center.addObserver(
            forName: Notification.Name("WirelessPairingDidFailBroadcastNotification"),
            object: nil,
            queue: .main
        ) { [self] note in
            if let code = note.userInfo?["code"] as? Int {
                self.wirelessBroadcastErrorCode = code
            }
        }
    }

    private func unregisterWirelessObservers() {
        let center = NotificationCenter.default
        if let t = wirelessPinObserver {
            center.removeObserver(t)
            wirelessPinObserver = nil
        }
        if let t = wirelessCompleteObserver {
            center.removeObserver(t)
            wirelessCompleteObserver = nil
        }
        if let t = wirelessBroadcastObserver {
            center.removeObserver(t)
            wirelessBroadcastObserver = nil
        }
    }
}
