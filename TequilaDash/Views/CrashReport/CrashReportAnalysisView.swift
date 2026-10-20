import SwiftUI

/// 崩溃分析的多页容器：摘要 / 线程 / 镜像 / 经典全文 / 原文.
///
/// 「经典全文」= 上游 `CrashTextRenderer` 的 `.crash` 版式，已符号化的字段直接复用；
/// 「原文」= 文件原始文本（现有预览口径不变）.
struct CrashReportAnalysisView: View {
    let report: Report
    /// 原文文本（拉取到的字节解码结果），解析失败时仍要能看.
    let rawText: String

    @State private var page: Page = .summary

    enum Page: String, CaseIterable {
        case summary = "摘要"
        case threads = "线程"
        case images = "镜像"
        case classic = "全文"
        case raw = "原文"
    }

    /// 无镜像 / 无线程的报告（analytics、纯文本）不给对应页签.
    private var availablePages: [Page] {
        Page.allCases.filter { page in
            switch page {
            case .summary: return true
            case .threads: return !(report.crash?.threads.isEmpty ?? true)
            case .images: return !(report.crash?.images.isEmpty ?? true)
            case .classic: return report.crash != nil || report.jetsam != nil || report.panic != nil
            case .raw: return !rawText.isEmpty
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("分析视图", selection: $page) {
                ForEach(availablePages, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppSpacing.row)
            .padding(.top, 8)
            .padding(.bottom, AppSpacing.tight)

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.section) {
                    content
                }
                .padding(AppSpacing.row)
            }
        }
        .background(AppSurface.page)
        .onAppear {
            if !availablePages.contains(page) { page = .summary }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .summary:
            CrashReportSummaryView(report: report)
        case .threads:
            if let crash = report.crash {
                CrashSectionCard(title: "线程", systemImage: "point.3.connected.trianglepath.dotted",
                                 trailing: AnyView(CrashBadge(text: "\(crash.threads.count) 个",
                                                              level: .tiny))) {
                    CrashThreadsPanel(crash: crash)
                }
                if !crash.lastExceptionBacktrace.isEmpty {
                    CrashSectionCard(title: "最后异常回溯", systemImage: "list.number") {
                        CrashFrameList(frames: crash.lastExceptionBacktrace, images: crash.images)
                    }
                }
            } else {
                Text("报告未包含线程堆栈.")
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
            }
        case .images:
            if let crash = report.crash {
                CrashSectionCard(title: "二进制镜像", systemImage: "square.stack.3d.up",
                                 trailing: AnyView(CrashBadge(text: "\(crash.images.count)",
                                                              level: .tiny))) {
                    CrashImagesPanel(images: crash.images)
                }
                if let cache = crash.sharedCache {
                    CrashSectionCard(title: "共享缓存", systemImage: "square.stack") {
                        VStack(alignment: .leading, spacing: AppSpacing.tight) {
                            CrashFactRow(label: "基址", value: CrashFormat.paddedHex(cache.base),
                                         monospaced: true)
                            CrashRowSeparator()
                            CrashFactRow(label: "大小", value: CrashFormat.hex(cache.size),
                                         monospaced: true)
                            CrashRowSeparator()
                            CrashFactRow(label: "UUID", value: cache.uuid, monospaced: true, wraps: true)
                        }
                    }
                }
            } else {
                Text("报告未包含镜像清单.")
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
            }
        case .classic:
            CrashSectionCard(title: "经典崩溃报告", systemImage: "doc.plaintext") {
                CrashMonoBlock(text: ReportRenderer.crashText(report))
            }
        case .raw:
            CrashSectionCard(title: "原始文件", systemImage: "doc") {
                CrashMonoBlock(text: rawText)
            }
        }
    }
}
