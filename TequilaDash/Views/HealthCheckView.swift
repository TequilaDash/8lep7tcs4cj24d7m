import SwiftUI

/// v0.3.200：设备体检页 —— 执行 SecurityScanner 真实检测.
/// 得分通过 binding 回传主页灵动球（立即体检后主页分数同步刷新）.
struct HealthCheckView: View {
    /// 体检得分绑定（主页灵动球显示用）
    var score: Binding<Int>? = nil
    @State private var phase: Phase = .idle
    @State private var results: [SecurityCheckResult] = []
    @State private var currentCheckIndex = 0
    @State private var finalScore = 0

    enum Phase { case idle, scanning, done }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                switch phase {
                case .idle, .scanning:
                    scanProgressCard
                case .done:
                    scoreCard
                    resultsCard
                    // 淡蓝底（`TintedButtonStyle`），**不用纯蓝实底**；圆角对齐 TRApp 大按钮（12）
                    Button {
                        AppHaptics.tap()
                        startScan()
                    } label: {
                        Label("重新体检", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TintedButtonStyle(tint: AppTheme.categoryHealth, radius: AppRadius.button))
                }
            }
            .padding(.horizontal, AppTheme.pageInset)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.surfaceBase)
        .navigationTitle("设备体检")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if phase == .idle { startScan() }
        }
        // 实时：隧道就绪翻转（含进入页面时的当前值）自动补跑隧道项，无需退出重进.
        .onReceive(TunnelReadiness.shared.$isReady) { ready in
            if ready { recheckWhenTunnelReady() }
        }
    }

    // MARK: 扫描进度卡（灵动环 + 当前项）
    private var scanProgressCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(AppTheme.categoryHealth, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.25), value: progress)
                VStack(spacing: 2) {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(phase == .scanning ? currentCheckName : "准备体检…")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 160)
            Text("正在扫描 \(currentCheckIndex)/\(SecurityScanner.checkIDs.count)")
                .font(AppFont.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
            .fill(AppSurface.card))
    }

    private var progress: CGFloat {
        guard phase == .scanning else { return 0 }
        return CGFloat(currentCheckIndex) / CGFloat(max(SecurityScanner.checkIDs.count, 1))
    }
    private var currentCheckName: String {
        let names: [String: String] = [
            "urlscheme": "越狱商店 Scheme", "files": "可疑文件路径",
            "writable": "系统目录", "dyld": "注入库",
            "objc": "运行时类", "interpreters": "解释器",
            "symlink": "符号链接", "fork": "进程权限",
            "executables": "可疑可执行", "ports": "可疑端口",
            "env": "环境变量", "libraryNames": "逆向库",
            "mainExe": "主可执行文件", "taskPorts": "进程任务端口",
            "provisioning": "权限配置文件", "entitlements": "关键权限",
        ]
        let id = currentCheckIndex < SecurityScanner.checkIDs.count
            ? SecurityScanner.checkIDs[currentCheckIndex] : ""
        return names[id] ?? "…"
    }

    // MARK: 结果
    private var scoreCard: some View {
        VStack(spacing: 6) {
            Text("\(finalScore)")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .foregroundStyle(scoreColor)
            Text(scoreLabel)
                .font(AppFont.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
            .fill(AppSurface.card))
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("检测明细")
                .font(AppFont.headline)
                .padding(.bottom, 6)
            ForEach(results) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.iconName)
                        .foregroundStyle(item.color)
                        .frame(width: 24)
                        .appSymbol()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(AppFont.subheadlineEmphasis)
                        Text(item.detail)
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                AppHairline().opacity(item.id == results.last?.id ? 0 : 1)
            }
        }
        .padding(AppMetrics.cardPadding)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
            .fill(AppSurface.card))
    }

    // v0.3.626：改走统一 token（阈值 90/70 与原实现一致，但取色改为明暗自适应）。
    // 原实现用系统 .blue/.yellow/.orange（单值色，深色模式下对比度不足，违反规则 6）。
    private var scoreColor: Color { AppTheme.scoreColor(finalScore) }
    private var scoreLabel: String {
        switch finalScore {
        case 90...: return "设备很安全"
        case 70..<90: return "安全状况良好"
        default: return "发现风险项"
        }
    }

    // MARK: 扫描执行（逐项推进）
    private func startScan() {
        phase = .scanning
        currentCheckIndex = 0
        results = []
        let ids = SecurityScanner.checkIDs
        let scoreBinding = score
        // 规则 29/主线程纪律：检测项里有要建隧道的（provisioning），Task {} 写在 View 里
        // 会继承 MainActor —— 2026-10-31 真机实证卡死在 14/16 后被看门狗杀掉。
        // 所以整条扫描跑在 detached 任务里，只在每项完成后回主线程刷一次 UI。
        // 不加任何「每项节奏」sleep：项与项的真实耗时就是节奏。
        Task.detached(priority: .userInitiated) {
            var collected: [SecurityCheckResult] = []
            for id in ids {
                guard let result = Self.perform(id) else { continue }
                collected.append(result)
                let snapshot = collected
                await MainActor.run {
                    currentCheckIndex = snapshot.count
                    results = snapshot
                }
            }
            let final = max(0, 100 - collected.reduce(0) { $0 + $1.penalty })
            await MainActor.run {
                finalScore = final
                phase = .done
                scoreBinding?.wrappedValue = final
            }
        }
    }

    /// 单项执行（nonisolated：跑在调用方给的线程上，绝不上主线程）。
    nonisolated private static func perform(_ id: String) -> SecurityCheckResult? {
        switch id {
        case "urlscheme": return SecurityScanner.checkURLSchemes()
        case "files": return SecurityScanner.checkSuspiciousFiles()
        case "writable": return SecurityScanner.checkSystemDirsWritable()
        case "dyld": return SecurityScanner.checkDYLDInjection()
        case "objc": return SecurityScanner.checkSuspiciousObjCClasses()
        case "interpreters": return SecurityScanner.checkAccessibleInterpreters()
        case "symlink": return SecurityScanner.checkSuspiciousSymbolicLinks()
        case "fork": return SecurityScanner.checkFork()
        case "executables": return SecurityScanner.checkSuspiciousExecutables()
        case "ports": return SecurityScanner.checkSuspiciousPorts()
        case "env": return SecurityScanner.checkEnvironmentVariables()
        case "libraryNames": return SecurityScanner.checkSuspiciousLibraryNames()
        case "mainExe": return SecurityScanner.checkMainExecutableIntegrity()
        case "taskPorts": return SecurityScanner.checkExceptionPorts()
        case "provisioning": return SecurityScanner.checkProvisioningProfiles()
        case "entitlements": return SecurityScanner.checkEntitlements()
        default: return nil
        }
    }

    /// 实时复检：隧道就绪翻转的瞬间，正在扫/已扫完的页面自动补跑一次，
    /// 「待复检」的隧道项当场补上 —— 不用用户退出重进，也不需要定时器。
    private func recheckWhenTunnelReady() {
        guard TunnelReadiness.shared.isReady, phase != .scanning else { return }
        Task.detached(priority: .userInitiated) {
            guard let fresh = Self.perform("provisioning") else { return }
            await MainActor.run {
                guard let idx = results.firstIndex(where: { $0.id == "provisioning" }) else { return }
                results[idx] = fresh
                finalScore = max(0, 100 - results.reduce(0) { $0 + $1.penalty })
                score?.wrappedValue = finalScore
            }
        }
    }
}
