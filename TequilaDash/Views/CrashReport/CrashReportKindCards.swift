import SwiftUI

/// JetsamEvent（内存压力杀进程）专门摘要：大进程 + 前若干占用最高进程.
struct CrashJetsamCard: View {
    let jetsam: JetsamReport

    /// 占用最高者优先展示；被杀进程（reason 非空）在行尾标注.
    var limit: Int = 12

    private var sorted: [JetsamProcess] {
        jetsam.processes.sorted { $0.residentPages > $1.residentPages }
    }

    private var killed: [JetsamProcess] {
        sorted.filter { ($0.reason?.isEmpty == false) || !$0.states.isEmpty }
    }

    private var visible: ArraySlice<JetsamProcess> { sorted.prefix(limit) }

    var body: some View {
        CrashSectionCard(title: "内存压力事件", systemImage: "memory", tint: AppTheme.pending,
                         trailing: AnyView(CrashBadge(text: "\(jetsam.processes.count) 进程", level: .tiny))) {
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                CrashFactRow(label: "最大进程", value: jetsam.largestProcess ?? "—")
                CrashRowSeparator()
                CrashFactRow(label: "页大小", value: CrashFormat.hex(jetsam.pageSize), monospaced: true)
                CrashRowSeparator()
                CrashFactRow(label: "被标记者", value: "\(killed.count)")
                if !visible.isEmpty {
                    CrashRowSeparator()
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.offset) { index, process in
                            HStack(alignment: .top, spacing: AppSpacing.tight) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(process.name)
                                        .font(AppFont.footnote)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let reason = process.reason, !reason.isEmpty {
                                        Text(reason)
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.pending)
                                            .lineLimit(1)
                                    } else if !process.states.isEmpty {
                                        Text(process.states.joined(separator: " / "))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 6)
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(CrashFormat.megabytes(pages: process.residentPages,
                                                               pageSize: jetsam.pageSize))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.primary)
                                    if let pid = process.pid {
                                        Text("pid \(pid)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                            if index < visible.count - 1 { CrashRowSeparator() }
                        }
                        if jetsam.processes.count > limit {
                            CrashRowSeparator()
                            Text("其余 \(jetsam.processes.count - limit) 个进程未列出，完整清单见「原文」.")
                                .font(AppFont.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                        }
                    }
                }
            }
        }
    }
}

/// 资源报告（cpu_resource / diskwrites_resource / wakeups_resource）专门摘要.
struct CrashResourceCard: View {
    let resource: ResourceReport
    let report: Report

    var body: some View {
        CrashSectionCard(title: "资源超限", systemImage: "gauge.with.dots.needle.67percent", tint: AppTheme.pending) {
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                CrashFactRow(label: "事件", value: resource.event)
                if let crash = report.crash, let exception = crash.exception {
                    CrashRowSeparator()
                    CrashFactRow(label: "异常", value: exception.typeAndSignal)
                }
                if let crash = report.crash, !crash.process.name.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "进程",
                                 value: CrashFormat.process(crash.process.name, pid: crash.process.pid))
                }
                if let crash = report.crash, let os = CrashFormat.osVersion(crash) {
                    CrashRowSeparator()
                    CrashFactRow(label: "系统", value: os)
                }
                Text("资源报告记录的是超限采样，线程与镜像见「线程」「镜像」页.")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 内核崩溃（panic-full）专门摘要：panicString 首行 + 产品与版本，全文可展开.
struct CrashPanicCard: View {
    let panic: PanicReport

    @State private var showFull = false

    private var firstLine: String {
        panic.panicString.split(separator: "\n").first.map(String.init) ?? panic.panicString
    }

    private var remainder: String {
        let lines = panic.panicString.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return "" }
        return lines.dropFirst().joined(separator: "\n")
    }

    var body: some View {
        CrashSectionCard(title: "内核崩溃", systemImage: "cpu", tint: AppTheme.danger) {
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                CrashMonoBlock(text: firstLine)
                if let product = panic.product, !product.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "产品", value: product)
                }
                if let build = panic.build, !build.isEmpty {
                    CrashRowSeparator()
                    CrashFactRow(label: "版本", value: build, monospaced: true)
                }
                if !remainder.isEmpty {
                    CrashRowSeparator()
                    Button {
                        showFull.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text(showFull ? "收起调用栈" : "展开调用栈")
                            Image(systemName: showFull ? "chevron.up" : "chevron.down")
                        }
                        .font(AppFont.caption)
                        .foregroundStyle(AppTheme.accent)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showFull {
                        CrashMonoBlock(text: remainder)
                    }
                }
            }
        }
    }
}
