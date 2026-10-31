import SwiftUI

/// 崩溃分析：通过「配对文件 + LocalDevVPN」隧道读取本机崩溃 / 诊断日志
/// （对应 iOS「设置 → 隐私与安全性 → 分析与改进」），支持查看内容、
/// Xrash 式分区分析（摘要 / 线程 / 镜像 / 经典全文 / 原文）、按文件名搜索、
/// 单份分享、批量选择（含全选）导出到本机与删除.
///
/// 写域说明：本文件只做列表与拉取；解析在 Engine/CrashReport/（原样搬入，只读），
/// 显示组件在 Views/CrashReport/.
struct CrashLogView: View {
    @State private var entries: [CrashLogService.Entry] = []
    @State private var currentDir: String?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selection = Set<String>()
    @State private var isEditing = false
    @State private var previewEntry: CrashLogService.Entry?
    @State private var previewText = ""
    @State private var previewLoading = false
    @State private var confirmDelete = false
    @State private var exporting = false
    /// 批量操作中（导出 / 删除）：显示进度，禁用重复操作.
    @State private var busy = false
    /// 进度文本（如「3 / 12」）.
    @State private var progressText: String?
    /// 行内搜索词（按文件名大小写不敏感匹配）.
    @State private var searchText = ""
    /// 行级分享：已拉取的单份日志文本与呈现开关.
    @State private var shareText = ""
    @State private var showShareSheet = false
    @State private var shareLoading = false
    /// 预览用的解析结果（ReportDecoder 失败为 nil，退回原文文本）.
    @State private var previewReport: Report?
    /// 崩溃签名缓存（文件路径 → 签名），由「聚类」扫描填充.
    @State private var signatures: [String: String] = [:]
    /// 扫描后的分组结果.
    @State private var clusters: [CrashCluster] = []
    /// 路径 → 同签名份数（行尾 ×N 徽标用，随 clusters 一起重建）.
    @State private var clusterCountByPath: [String: Int] = [:]
    /// 单次聚类扫描的上限份数（AFC 逐份拉取，超过后按名称取前 N 份）.
    private let clusterScanLimit = 60
    /// 聚类结果页呈现开关.
    @State private var showClusters = false
    /// 明暗模式：进度遮罩卡投影走 `AppShadow.raised`，需显式传入.
    @Environment(\.colorScheme) private var colorScheme

    private let service = CrashLogService.shared

    private var selectedEntries: [CrashLogService.Entry] {
        entries.filter { selection.contains($0.id) }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                if loading {
                    AppLoadingRow(title: "正在连接崩溃日志服务…", level: .block)
                } else if let errorMessage {
                    if PairingGate.isPairingError(errorMessage) {
                        PairingGuideCard(showsBackground: false, note: "崩溃分析还需要 LocalDevVPN 已连接.")
                            .listRowInsets(EdgeInsets())
                    } else {
                        // v0.3.683：区块级错误行统一到 AppErrorRow.
                        AppErrorRow(message: errorMessage, retry: { reload() })
                    }
                } else if entries.isEmpty {
                    AppStateSection(state: .empty("没有日志",
                                                  message: "设备上没有可读取的崩溃日志.",
                                                  icon: "doc.text"), wrapsSection: false)
                } else {
                    ForEach(visibleEntries) { entry in
                        row(entry)
                    }
                    if !entries.isEmpty && visibleEntries.isEmpty {
                        AppEmptyRow(title: "没有匹配的日志.")
                    }
                }
            } header: {
                Text(currentDir.map { "目录：\($0)" } ?? "目录：/")
            } footer: {
                if !loading && errorMessage == nil {
                    Text("对应「设置 → 隐私与安全性 → 分析与改进」.支持批量导出 / 删除.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .navigationTitle("崩溃分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                // v0.3.712（用户报）：非编辑态必须能看到「返回上一级目录」的向上箭头.
                // 原先它在 else 分支里，与刷新按钮同槽，某些 iOS 版本会把第二个图标挤掉.
                if isEditing {
                    Button("全选") { selectAll() }
                } else {
                    if currentDir != nil {
                        Button {
                            currentDir = nil
                            reload()
                        } label: {
                            Image(systemName: "arrow.up.left")
                        }
                        .accessibilityLabel("返回上一级目录")
                        .disabled(busy)
                    }
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新")
                    .disabled(busy)
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !entries.isEmpty && !busy {
                    Button {
                        clusterCrashes()
                    } label: {
                        Image(systemName: "square.3.layers.3d")
                    }
                    .accessibilityLabel("按崩溃签名聚类")
                    .disabled(isEditing)
                }
                if !entries.isEmpty && !busy {
                    Button(isEditing ? "完成" : "选择") {
                        withAnimation { isEditing.toggle() }
                        if !isEditing { selection.removeAll() }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isEditing {
                bottomBar
            }
        }
        .overlay {
            // v0.2.125：批量导出 / 删除进度遮罩（旧版无进度、且导出会闪退）.
            if busy {
                VStack(spacing: 12) {
                    ProgressView()
                    if let progressText {
                        Text(progressText)
                            .font(.subheadline.weight(.medium))
                    }
                    Text("正在处理…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                .appRaisedShadow(colorScheme)
            }
        }
        .sheet(item: $previewEntry) { entry in
            NavigationStack {
                Group {
                    if previewLoading {
                        AppLoadingRow(title: "正在拉取日志…", level: .page)
                    } else if let report = previewReport {
                        CrashReportAnalysisView(report: report, rawText: previewText)
                    } else if previewText.isEmpty {
                        Text("（空文件）")
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            Text(previewText)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .navigationTitle(entry.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { previewEntry = nil }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showClusters) {
            NavigationStack {
                CrashClusterListView(clusters: clusters) { entry in
                    showClusters = false
                    open(entry)
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { showClusters = false }
                    }
                }
            }
        }
        .confirmationDialog(
            "删除选中的 \(selectedEntries.count) 个日志？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteSelected() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复.")
        }
        .toastHost()
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索日志文件名")
        .avoidSearchZoom()
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [shareText])
        }
        .onAppear {
            if entries.isEmpty && errorMessage == nil { reload() }
        }
    }

    private var bottomBar: some View {
        HStack {
            Text("已选 \(selectedEntries.count) 项")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                exportSelected()
            } label: {
                Label("导出", systemImage: "square.and.arrow.down")
            }
            .disabled(selection.isEmpty || busy)
            .buttonStyle(TintedButtonStyle(tint: AppTheme.categorySettings))

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(selection.isEmpty || busy)
            .buttonStyle(TintedButtonStyle(tint: AppTheme.danger))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// 搜索过滤后的条目（按文件名大小写不敏感匹配；搜索词为空即全部条目）.
    private var visibleEntries: [CrashLogService.Entry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// 文件行副标题：大小 + 修改时间（list 时随 afc_get_file_info 一并取回）.
    private func rowDetail(_ entry: CrashLogService.Entry) -> String? {
        guard !entry.isDirectory else { return nil }
        var parts: [String] = [ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)]
        if let modified = entry.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    /// 行尾徽标：类型（按文件名判型，ReportFileName，不读文件内容）+ 同签名份数.
    @ViewBuilder
    private func rowBadge(_ entry: CrashLogService.Entry) -> some View {
        if CrashLogService.isCrashLogName(entry.name) {
            let kind = ReportFileName(entry.name).kind
            HStack(spacing: 4) {
                if let count = clusterCountByPath[entry.path], count > 1 {
                    SizePill(text: "×\(count)", tint: AppTheme.pending, level: .tiny)
                }
                SizePill(text: CrashFormat.kindLabel(kind),
                         tint: kindTint(kind),
                         level: .tiny)
            }
        }
    }

    /// 类型配色：崩溃 / 内核走 danger，内存 / 卡死走 pending，其余 accent.
    private func kindTint(_ kind: ReportKind) -> Color {
        switch kind {
        case .crash, .panic: return AppTheme.danger
        case .jetsam, .hang: return AppTheme.pending
        case .resource, .analytics, .other: return AppTheme.accent
        }
    }

    /// 行级分享：拉取单份日志原文并交给系统分享面板.
    private func share(_ entry: CrashLogService.Entry) {
        guard !isEditing, !busy, !shareLoading, !entry.isDirectory else { return }
        shareLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try service.pull(entry.path)
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16)
                    ?? ""
                DispatchQueue.main.async {
                    shareLoading = false
                    if text.isEmpty {
                        ToastCenter.shared.show("日志内容为空，无法分享.")
                    } else {
                        shareText = text
                        showShareSheet = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    shareLoading = false
                    ToastCenter.shared.show("无法打开：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 行

    private func row(_ entry: CrashLogService.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text.fill")
                .foregroundColor(entry.isDirectory ? AppTheme.accent : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline)
                    .lineLimit(1)
                if let detail = rowDetail(entry) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if !isEditing && !entry.isDirectory {
                rowBadge(entry)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditing else { return }
            open(entry)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !entry.isDirectory {
                Button {
                    share(entry)
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .tint(AppTheme.accent)
            }
        }
    }

    // MARK: - 数据

    private func reload() {
        loading = true
        errorMessage = nil
        // 切目录 / 删除后旧签名失效，行徽标一并清空.
        signatures.removeAll()
        clusters = []
        clusterCountByPath = [:]
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let list = try service.list(subdirectory: currentDir)
                DispatchQueue.main.async {
                    entries = list
                    loading = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "\(error.localizedDescription)"
                    loading = false
                }
            }
        }
    }

    private func open(_ entry: CrashLogService.Entry) {
        guard !busy else { return }
        // v0.2.127：AFC 视图能明确区分目录/文件 —— 目录直接进入，
        // 文件拉取预览（爱思同款，可进入 CrashReporter / DiagnosticLogs 子目录）.
        if entry.isDirectory {
            currentDir = entry.path
            reload()
            return
        }
        previewEntry = entry
        previewReport = nil
        previewText = ""
        previewLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try service.pull(entry.path)
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16) ?? "（二进制内容，无法显示）"
                // 解析走 Engine/CrashReport（ReportDecoder），失败退回原文文本.
                let report = try? ReportDecoder.decode(data, fileName: entry.name)
                // 全部 let，避免可变局部量被并发闭包捕获.
                let crashSnapshot = report?.crash
                let signature = crashSnapshot.flatMap { crash in
                    let value = ReportExplainer.signature(of: crash)
                    return value.isEmpty ? nil : value
                }
                DispatchQueue.main.async {
                    previewText = text
                    previewReport = report
                    previewLoading = false
                    if let signature {
                        signatures[entry.path] = signature
                        clusters = CrashClusterBuilder.build(signatures: signatures, entries: entries)
                        clusterCountByPath = CrashClusterBuilder.counts(byPath: clusters)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    previewEntry = nil
                    previewLoading = false
                    ToastCenter.shared.show("无法打开：\(error.localizedDescription)")
                }
            }
        }
    }

    private func selectAll() {
        let visible = visibleEntries
        let allSelected = !visible.isEmpty && visible.allSatisfy { selection.contains($0.id) }
        if allSelected {
            visible.forEach { selection.remove($0.id) }
        } else {
            visible.forEach { selection.insert($0.id) }
        }
    }

    /// 逐份「拉取 → 解析 → 取签名」（无 UI、无实例状态，后台队列调用）.
    /// 局部可变字典留在本函数内，不跨并发闭包.
    private nonisolated static func scanSignatures(_ targets: [CrashLogService.Entry],
                                        progress: (Int, Int) -> Void) -> [String: String] {
        let service = CrashLogService.shared
        var found: [String: String] = [:]
        for (offset, entry) in targets.enumerated() {
            progress(offset + 1, targets.count)
            guard let data = try? service.pull(entry.path),
                  let report = try? ReportDecoder.decode(data, fileName: entry.name),
                  let crash = report.crash else { continue }
            let signature = ReportExplainer.signature(of: crash)
            if !signature.isEmpty { found[entry.path] = signature }
        }
        return found
    }

    /// 批量聚类：逐份拉取 → ReportDecoder 解析 → ReportExplainer 签名，再按签名归组.
    /// AFC 每份都是一次 open/read/close 往返，因此只扫当前目录下可见的崩溃日志，上限 clusterScanLimit 份.
    private func clusterCrashes() {
        guard !busy else { return }
        let targets = visibleEntries
            .filter { !$0.isDirectory && CrashLogService.isCrashLogName($0.name) }
            .prefix(clusterScanLimit)
        guard !targets.isEmpty else {
            ToastCenter.shared.show("当前目录没有崩溃日志.")
            return
        }
        busy = true
        progressText = "0 / \(targets.count)"
        let scanned = Array(targets)
        DispatchQueue.global(qos: .userInitiated).async {
            let found = CrashLogView.scanSignatures(scanned) { step, total in
                DispatchQueue.main.async { progressText = "\(step) / \(total)" }
            }
            DispatchQueue.main.async {
                busy = false
                for (path, signature) in found { signatures[path] = signature }
                clusters = CrashClusterBuilder.build(signatures: signatures, entries: entries)
                clusterCountByPath = CrashClusterBuilder.counts(byPath: clusters)
                if clusters.isEmpty {
                    ToastCenter.shared.show("未能解析出崩溃签名.")
                } else {
                    showClusters = true
                }
            }
        }
    }

    private func exportSelected() {
        let targets = selectedEntries
        guard !targets.isEmpty, !busy else { return }
        busy = true
        exporting = true
        progressText = "0 / \(targets.count)"
        isEditing = false
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let paths = try service.export(entries: targets) { done, total in
                    DispatchQueue.main.async {
                        progressText = "\(done) / \(total)"
                    }
                }
                DispatchQueue.main.async {
                    busy = false
                    exporting = false
                    selection.removeAll()
                    ToastCenter.shared.show("已导出 \(paths.count) 个日志到 App 的 CrashLogs 目录（文件 App 可见）")
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    exporting = false
                    ToastCenter.shared.show("导出失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func deleteSelected() {
        let targets = selectedEntries
        guard !targets.isEmpty, !busy else { return }
        busy = true
        progressText = "0 / \(targets.count)"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let failed = try service.removeBatch(targets) { done, total in
                    DispatchQueue.main.async {
                        progressText = "\(done) / \(total)"
                    }
                }
                DispatchQueue.main.async {
                    busy = false
                    selection.removeAll()
                    ToastCenter.shared.show(failed == 0
                        ? "已删除 \(targets.count) 个日志"
                        : "已删除 \(targets.count - failed) 个，失败 \(failed) 个")
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    ToastCenter.shared.show("删除失败：\(error.localizedDescription)")
                }
            }
        }
    }
}
