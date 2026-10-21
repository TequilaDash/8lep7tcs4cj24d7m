import SwiftUI

/// 崩溃报告的结构化摘要（Xrash 分区卡片语言）.
///
/// 数据全部来自 `Report`（Engine/CrashReport 已解析的模型），本视图不再解析 JSON.
/// 分区顺序按「先看结论、再看栈」排：异常信息 → 终止原因 → 崩溃线程 → 设备与进程 → 镜像 → 签名.
struct CrashReportSummaryView: View {
    let report: Report

    /// 崩溃线程（isTriggered 或 faultingThreadIndex 命中）优先，其余按原序.
    private var orderedThreads: [ReportThread] {
        guard let crash = report.crash else { return [] }
        let faulting = crash.faultingThreadIndex
        return crash.threads.sorted { lhs, rhs in
            let l = lhs.isTriggered || lhs.index == faulting
            let r = rhs.isTriggered || rhs.index == faulting
            if l != r { return l }
            return lhs.index < rhs.index
        }
    }

    private var faultingThread: ReportThread? {
        orderedThreads.first { $0.isTriggered || $0.index == report.crash?.faultingThreadIndex }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                kindCard
                if let crash = report.crash {
                    if let exception = crash.exception { exceptionCard(exception, crash: crash) }
                    if let termination = crash.termination { terminationCard(termination) }
                    if !crash.applicationInfo.isEmpty { applicationInfoCard(crash.applicationInfo) }
                    if !crash.lastExceptionBacktrace.isEmpty {
                        backtraceCard(crash.lastExceptionBacktrace, images: crash.images,
                                      title: "最后异常回溯")
                    }
                    if let thread = faultingThread, !thread.frames.isEmpty {
                        faultingThreadCard(thread, images: crash.images)
                    }
                    deviceCard(crash)
                    if crash.sharedCache != nil || !crash.images.isEmpty { imagesCard(crash) }
                    if let summary = crash.vmSummary, !summary.isEmpty { vmSummaryCard(summary) }
                    if crash.exception != nil { signatureCard(crash) }
                }
                if let jetsam = report.jetsam { CrashJetsamCard(jetsam: jetsam) }
                if let resource = report.resource { CrashResourceCard(resource: resource, report: report) }
                if let panic = report.panic { CrashPanicCard(panic: panic) }
                factsCard
            }
            .padding(AppSpacing.row)
        }
        .background(AppSurface.page)
    }

    // MARK: 类型与解释

    private var kindCard: some View {
        CrashSectionCard(title: "报告类型", systemImage: "doc.text.magnifyingglass") {
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                HStack(spacing: AppSpacing.tight) {
                    CrashBadge(text: CrashFormat.kindLabel(report.kind),
                               tint: kindTint)
                    if !report.header.bugType.isEmpty {
                        Text("bug_type \(report.header.bugType)")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let crash = report.crash {
                    Text(ReportExplainer.explanation(for: crash))
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let reason = report.reason {
                    Text(reason)
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var kindTint: Color {
        switch report.kind {
        case .crash: return AppTheme.danger
        case .jetsam: return AppTheme.pending
        case .panic: return AppTheme.danger
        case .hang: return AppTheme.pending
        case .resource: return AppTheme.accent
        case .analytics, .other: return AppTheme.accent
        }
    }

    // MARK: 异常信息

    private func exceptionCard(_ exception: ExceptionDetails, crash: CrashReport) -> some View {
        CrashSectionCard(title: "异常信息", systemImage: "bolt", tint: AppTheme.danger,
                         trailing: AnyView(CrashBadge(text: exception.typeAndSignal,
                                                      tint: AppTheme.danger, level: .tiny))) {
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                CrashFactRow(label: "类型", value: exception.type)
                if let signal = exception.signal {
                    CrashRowSeparator()
                    CrashFactRow(label: "信号", value: signal)
                }
                if let subtype = exception.subtype, !subtype.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "子类型", value: subtype, wraps: true)
                }
                if let codes = exception.codes, !codes.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "代码", value: codes, monospaced: true, wraps: true)
                }
                if let message = exception.message, !message.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "消息", value: message, wraps: true)
                }
            }
        }
    }

    // MARK: 终止原因

    private func terminationCard(_ termination: TerminationDetails) -> some View {
        CrashSectionCard(title: "终止原因", systemImage: "power", tint: AppTheme.pending) {
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                if let namespace = termination.namespace, !namespace.isEmpty {
                    CrashFactRow(label: "命名空间", value: namespace)
                }
                if let code = termination.code {
                    CrashRowSeparator()
                    CrashFactRow(label: "代码", value: CrashFormat.hex(code), monospaced: true)
                }
                if let indicator = termination.indicator, !indicator.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "指示符", value: indicator, wraps: true)
                }
                ForEach(Array(termination.reasons.enumerated()), id: \.offset) { _, reason in
                    CrashRowSeparator()
                    CrashFactRow(label: "描述", value: reason, wraps: true)
                }
                if let by = termination.byProcess, !by.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "发起进程",
                                 value: CrashFormat.process(by, pid: termination.byPID), wraps: true)
                }
            }
        }
    }

    // MARK: Application Specific Information

    private func applicationInfoCard(_ lines: [String]) -> some View {
        CrashSectionCard(title: "应用附加信息", systemImage: "text.append", tint: AppTheme.categorySettings,
                         trailing: AnyView(CrashBadge(text: "\(lines.count)", level: .tiny))) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if index < lines.count - 1 { CrashRowSeparator() }
                }
            }
        }
    }

    // MARK: 回溯

    private func backtraceCard(_ frames: [Frame], images: [BinaryImage], title: String) -> some View {
        CrashSectionCard(title: title, systemImage: "list.number", tint: AppTheme.categorySettings,
                         trailing: AnyView(CrashBadge(text: "\(frames.count) 帧", level: .tiny))) {
            CrashFrameList(frames: frames, images: images, startIndex: 0, limit: 12)
        }
    }

    private func faultingThreadCard(_ thread: ReportThread, images: [BinaryImage]) -> some View {
        CrashSectionCard(title: "崩溃线程", systemImage: "arrow.down.right",
                         tint: AppTheme.danger,
                         trailing: AnyView(CrashBadge(text: "Thread \(thread.index)",
                                                      tint: AppTheme.danger, level: .tiny))) {
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                if let name = thread.name, !name.isEmpty {
                    CrashFactRow(label: "名称", value: name, wraps: true)
                }
                if let queue = thread.queue, !queue.isEmpty {
                    CrashFactRow(label: "队列", value: queue, wraps: true)
                }
                CrashFrameList(frames: thread.frames, images: images, startIndex: 0, limit: 12)
                if thread.frames.count > 12 {
                    Text("其余 \(thread.frames.count - 12) 帧见「线程」页.")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 设备与进程

    private func deviceCard(_ crash: CrashReport) -> some View {
        CrashSectionCard(title: "设备与进程", systemImage: "iphone", tint: AppTheme.categorySettings) {
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                CrashFactRow(label: "机型",
                             value: crash.device.model ?? "—")
                if let os = CrashFormat.osVersion(crash) ?? report.header.osVersion {
                    CrashRowSeparator()
                    CrashFactRow(label: "系统", value: os)
                }
                CrashRowSeparator()
                CrashFactRow(label: "进程",
                             value: CrashFormat.process(crash.process.name, pid: crash.process.pid))
                if !crash.process.path.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "路径", value: crash.process.path, wraps: true)
                }
                if let bundleID = crash.process.bundleID ?? report.header.bundleID {
                    CrashRowSeparator()
                    CrashFactRow(label: "标识符", value: bundleID, wraps: true)
                }
                if let version = CrashFormat.version(crash.process) {
                    CrashRowSeparator()
                    CrashFactRow(label: "版本", value: version)
                }
                if let role = crash.process.role, !role.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "角色", value: role)
                }
                if let parent = crash.process.parentName, !parent.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "父进程",
                                 value: CrashFormat.process(parent, pid: crash.process.parentPID))
                }
                if let responsible = crash.process.responsibleName, !responsible.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "责任进程", value: responsible)
                }
                if crash.threads.count > 1 {
                    CrashRowSeparator()
                    CrashFactRow(label: "线程数", value: "\(crash.threads.count)")
                }
                if let uptime = CrashFormat.uptime(crash.device.uptime) {
                    CrashRowSeparator()
                    CrashFactRow(label: "运行时长", value: uptime)
                }
            }
        }
    }

    // MARK: 镜像

    private func imagesCard(_ crash: CrashReport) -> some View {
        CrashSectionCard(title: "二进制镜像", systemImage: "square.stack.3d.up", tint: AppTheme.categorySettings,
                         trailing: AnyView(CrashBadge(text: "\(crash.images.count)", level: .tiny))) {
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                CrashFactRow(label: "数量", value: "\(crash.images.count)")
                if let cache = crash.sharedCache {
                    CrashRowSeparator()
                    CrashFactRow(label: "共享缓存", value: CrashFormat.hex(cache.base), monospaced: true)
                    CrashRowSeparator()
                    CrashFactRow(label: "UUID", value: cache.uuid, monospaced: true, wraps: true)
                }
            }
        }
    }

    private func vmSummaryCard(_ summary: String) -> some View {
        CrashSectionCard(title: "虚拟内存摘要", systemImage: "memory", tint: AppTheme.categorySettings) {
            CrashMonoBlock(text: summary, lines: 8)
        }
    }

    // MARK: 签名

    private func signatureCard(_ crash: CrashReport) -> some View {
        CrashSectionCard(title: "崩溃签名", systemImage: "number", tint: AppTheme.categorySettings) {
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                CrashMonoBlock(text: ReportExplainer.signature(of: crash), lines: 4)
                Text("同签名的报告属同一缺陷，可在「聚类」中批量归组.")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 报告元数据

    private var factsCard: some View {
        CrashSectionCard(title: "报告字段", systemImage: "info.circle", tint: AppTheme.categorySettings) {
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                CrashFactRow(label: "Incident",
                             value: report.header.incidentID ?? "—", monospaced: true)
                if let incident = report.crash?.device.incidentID, incident != report.header.incidentID {
                    CrashRowSeparator()
                    CrashFactRow(label: "Body Incident", value: incident, monospaced: true)
                }
                CrashRowSeparator()
                CrashFactRow(label: "采集时间",
                             value: CrashFormat.date(report.crash?.device.captureDate
                                                     ?? report.header.timestamp) ?? "—")
                if let launch = CrashFormat.date(report.crash?.process.launchDate) {
                    CrashRowSeparator()
                    CrashFactRow(label: "启动时间", value: launch)
                }
                if let codeType = report.crash?.process.cpuType, !codeType.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "Code Type", value: codeType)
                }
                if let team = report.crash?.process.teamID, !team.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "Team ID", value: team)
                }
                if let signingID = report.crash?.process.codeSigningID, !signingID.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "签名标识", value: signingID, wraps: true)
                }
            }
        }
    }
}