import SwiftUI

/// 设备瘦身（爱思助手 8.0「设备瘦身」移植）—— 主页板块.
///
/// 版式对齐爱思：设备头 + **环形图与图例同一张卡**（v0.3.314 修掉之前的"割裂感"）
/// + 备份警告 + 已选统计 + 分组（系统缓存文件 / 用户日志 / 其他临时文件 / 较大应用）
/// + 「较大应用」按爱思做成**应用名称 / 应用大小 / 文档大小 / 操作**表，勾选 = 重装.
///
/// 视图只做渲染，行与分组全部走纯数据（`DeviceSlimService.Group` / `Item`），
/// 避免把大量 `@ViewBuilder` 分组堆进一个 body（v0.3.307 设备信息页闪退的根因）.
struct DeviceSlimView: View {

    private enum Phase: Equatable {
        case loading, scanning, ready, cleaning, reinstalling, finished
    }

    fileprivate struct ChartSegment: Identifiable {
        let id: String
        let start: Double
        let end: Double
        let colorHex: UInt32
    }

    @State private var phase: Phase = .loading
    @State private var usage: DeviceSlimService.SpaceUsage?
    @State private var groups: [DeviceSlimService.Group] = []
    @State private var selection: Set<String> = []            // 缓存项
    @State private var reinstallSelection: Set<String> = []   // 较大应用（重装）
    @State private var statusText = "正在分析您的设备空间占用情况…"
    @State private var confirmClean = false
    @State private var confirmReinstall = false
    @State private var resultText: String?
    @State private var errorText: String?
    /// v0.3.378：非致命提示（例如「应用大小不可用」——数据仍可用，只是不精确）
    @State private var sizeNote: String?
    @State private var fromCache = false
    @State private var reinstallProgress: DeviceSlimService.ReinstallProgress?
    /// 「较大应用」的源可用性是否正在检测（检测期间不允许勾选，避免误判）
    @State private var probingAvailability = false

    // MARK: - 派生数据

    private var selectableItems: [DeviceSlimService.Item] {
        groups.filter { $0.kind.selectable }.flatMap(\.items)
    }
    private var selectedItems: [DeviceSlimService.Item] {
        selectableItems.filter { selection.contains($0.id) }
    }
    private var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    private var bigAppItems: [DeviceSlimService.Item] {
        groups.first { $0.kind == .bigApps }?.items ?? []
    }
    /// 是否可勾选重装：
    /// · `true`  源里确认能下到（或本地已有包）→ 可勾
    /// · `false` 源里**确认没有** → 「资源缺失无法重装」，禁用
    /// · `nil`   这次没查成（网络/接口失败）→ 不算缺失，可勾；真装的时候会再查一次
    private func canReinstall(_ item: DeviceSlimService.Item) -> Bool {
        item.sourceAvailable != false && !(probingAvailability && item.sourceAvailable == nil)
    }

    private var reinstallableApps: [DeviceSlimService.Item] {
        bigAppItems.filter { canReinstall($0) }
    }
    private var reinstallTargets: [DeviceSlimService.Item] {
        bigAppItems.filter { reinstallSelection.contains($0.id) && canReinstall($0) }
    }

    /// 源里确认缺失的款数（用来决定要不要显示「重新检测」）
    private var missingSourceCount: Int { bigAppItems.filter { $0.sourceAvailable == false }.count }
    private var unknownSourceCount: Int { bigAppItems.filter { $0.sourceAvailable == nil }.count }
    /// v0.3.708：文档大小**未量到**的款数（`docSize` 按 0 占位，不是真的 0）.
    private var docUnknownCount: Int { bigAppItems.filter { !$0.docSizeKnown }.count }
    private var reinstallDocBytes: Int64 {
        reinstallTargets.reduce(0) { $0 + $1.docSize }
    }

    private var isBusy: Bool {
        phase == .loading || phase == .scanning || phase == .cleaning || phase == .reinstalling
    }

    private var chartSegments: [ChartSegment] {
        guard let usage, usage.total > 0 else { return [] }
        let sum = usage.slices.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        guard sum > 0 else { return [] }
        var acc = 0.0
        var out: [ChartSegment] = []
        for slice in usage.slices {
            let frac = Double(max(0, slice.bytes)) / Double(sum)
            out.append(ChartSegment(id: slice.id, start: acc, end: acc + frac, colorHex: slice.colorHex))
            acc += frac
        }
        return out
    }

    // MARK: - Body

    var body: some View {
        List {
            overviewSection
            warningBanner
            actionSection
            ForEach(groups) { group in
                groupSection(group)
            }
            if let errorText {
                Section {
                    // v0.3.630：改用 AppErrorRow（自带「重试」按钮，且取色统一为 pending 橙）。
                    // 原先是红字 + 旁边一个独立按钮，与 AppErrorRow 的形态重复。
                    AppErrorRow(message: errorText, retry: {
                        DeviceSlimService.invalidateAppReadCache()
                        Task { await runScan(force: true) }
                    })
                }
            }
            if let sizeNote {
                Section {
                    Label(sizeNote, systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(AppTheme.pending)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设备瘦身")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("确定开始瘦身？", isPresented: $confirmClean, titleVisibility: .visible) {
            Button("删除选中的 \(selectedItems.count) 项", role: .destructive) { startClean() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将永久删除选中的缓存与临时文件，预计释放 \(DeviceSlimService.formatBytes(selectedBytes)).")
        }
        .confirmationDialog("确定重装选中的 \(reinstallTargets.count) 款应用？",
                            isPresented: $confirmReinstall, titleVisibility: .visible) {
            Button("卸载并重装", role: .destructive) { startReinstall() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("卸载重装会清除这些应用的文稿与数据，约 \(DeviceSlimService.formatBytes(reinstallDocBytes))，且无法恢复.")
        }
        .toastHost()
        .task { await bootstrap() }
    }

    // MARK: - 1. 环形图 + 图例（同一张卡）

    private var overviewSection: some View {
        Section {
            if let usage {
                HStack(spacing: 14) {
                    Image(systemName: "iphone.gen3").font(.title2).foregroundStyle(AppTheme.categoryClean)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(usage.deviceName).font(.headline)
                        Text(usage.capacityText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)

                VStack(spacing: 10) {
                    DeviceSlimDonut(segments: chartSegments)
                        .frame(width: 168, height: 168)
                    Text("已用 \(DeviceSlimService.formatBytes(usage.used)) / 总量 \(DeviceSlimService.formatBytes(usage.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                ForEach(usage.slices) { slice in
                    legendRow(slice)
                }
            } else {
                AppLoadingRow(title: "正在读取空间占用…", level: .block)
            }
        } header: {
            HStack {
                Text("空间占用情况")
                Spacer(minLength: 0)
                if let at = usage?.scannedAt {
                    Text(scanStamp(at))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func scanStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "上次扫描 hh:mm"
        return formatter.string(from: date)
    }

    private func legendRow(_ slice: DeviceSlimService.UsageSlice) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color(slimHex: slice.colorHex)).frame(width: 9, height: 9)
            Text(slice.label).font(.subheadline)
            Spacer(minLength: 0)
            Text(DeviceSlimService.formatBytes(slice.bytes))
                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    // MARK: - 2. 警告

    private var warningBanner: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(AppTheme.pending).font(.footnote)
                Text("瘦身前请备份好重要数据，谨防数据丢失")
                    .font(.footnote).foregroundStyle(AppTheme.pending)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 3. 状态与操作

    private var actionSection: some View {
        Section {
            if phase == .reinstalling, let p = reinstallProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("\(p.index)/\(p.total) \(p.name)")
                            .font(.subheadline).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(p.stage.rawValue)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(1, max(0, p.fraction)))
                    Text("重装中请勿断开设备")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } else if isBusy {
                AppLoadingRow(title: statusText, level: .block)
            } else {
                HStack {
                    Text("已选 \(selectedItems.count) 项")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("可释放 \(DeviceSlimService.formatBytes(selectedBytes)) 空间")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(selectedBytes > 0 ? AppTheme.danger : .secondary)
                        .monospacedDigit()
                }

                Button {
                    confirmClean = true
                } label: {
                    Text(phase == .finished ? "再次瘦身" : "开始瘦身")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TintedButtonStyle(tint: AppTheme.categoryClean, radius: AppRadius.button))
                .disabled(selectedItems.isEmpty)

                Button {
                    Task { await runScan(force: true) }
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise").font(.subheadline)
                }
            }

            if let resultText {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(AppTheme.success)
                    Text(resultText).font(.footnote)
                    Spacer(minLength: 0)
                }
            }
        } footer: {
            Text(scanFooter).font(.caption2)
        }
    }

    private var scanFooter: String {
        if isBusy { return "正在处理…" }
        if fromCache { return "缓存结果，点「重新扫描」刷新" }
        return selectableItems.isEmpty ? "没有可清理项" : "共 \(selectableItems.count) 项可清理"
    }

    // MARK: - 4. 分组

    private func groupSection(_ group: DeviceSlimService.Group) -> some View {
        Section {
            if group.items.isEmpty {
                Text(group.kind == .userLog ? "本机未发现可清理的日志" : "未发现可清理项")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if group.kind == .bigApps {
                ForEach(group.items) { item in
                    bigAppRow(item)
                }
                if !reinstallTargets.isEmpty {
                    Button {
                        confirmReinstall = true
                    } label: {
                        Label("重装选中的 \(reinstallTargets.count) 款（可清理 \(DeviceSlimService.formatBytes(reinstallDocBytes))）",
                              systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.danger)
                    }
                        .buttonStyle(.plain)
                }
                // 有「确认缺失」或「没查成」的行时给出重检入口（不是爱思有、是免越狱下网络会抖）
                if missingSourceCount + unknownSourceCount > 0 {
                    Button {
                        Task { await recheckAvailability() }
                    } label: {
                        Label(probingAvailability ? "正在检测…" : "重新检测可重装性",
                              systemImage: "arrow.clockwise")
                            .font(.subheadline)
                            .foregroundStyle(probingAvailability ? Color.secondary : AppTheme.success)
                    }
                    .disabled(probingAvailability)
                }
            } else {
                ForEach(group.items) { item in
                    cacheRow(item)
                }
            }
        } header: {
            groupHeader(group)
        } footer: {
            if !group.items.isEmpty, group.kind == .bigApps {
                Text(bigAppsFooter).font(.caption2)
                // v0.3.708：**独立的说明行**，不并进上面那句 —— 上面那句已被源可用性
                // 占了三个分号分支，把文档未知也塞进去会让两种原因混成一句.
                if let docUnknownNote {
                    Text(docUnknownNote).font(.caption2).foregroundStyle(AppTheme.pending)
                }
            }
        }
    }

    private var bigAppsFooter: String {
        var text = "勾选 = 卸载重装（清除该应用的文稿与数据）"
        if missingSourceCount > 0 { text += "；\(missingSourceCount) 款源里没有包" }
        if unknownSourceCount > 0 { text += "；\(unknownSourceCount) 款未检测成功" }
        return text
    }

    /// v0.3.708：文档大小未量到的说明（nil = 全部已量到）.
    ///
    /// 这些款是按「文档大小未知」收进列表的：它们可能本来不到 500 MB，
    /// 也可能文档很重、只是本轮没量到 —— 数字栏显示「文档 —」，这里给出原因.
    private var docUnknownNote: String? {
        docUnknownCount > 0
            ? "\(docUnknownCount) 款文档大小未量到，按「文档 —」显示，未计入应用大小阈值判定"
            : nil
    }

    private func groupHeader(_ group: DeviceSlimService.Group) -> some View {
        HStack(spacing: 8) {
            Image(systemName: group.kind.icon).font(.caption).foregroundStyle(AppTheme.categoryClean)
            Text(group.kind.rawValue)
            Spacer(minLength: 0)
            if group.kind == .bigApps {
                Text("共 \(group.items.count) 款 已选择重装 \(reinstallTargets.count) 款 可清理 \(DeviceSlimService.formatBytes(reinstallDocBytes)) 应用文档")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            } else if !group.items.isEmpty {
                Text("共 \(group.items.count) 项，已选择 \(DeviceSlimService.formatBytes(selectedBytesFor(group)))")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func selectedBytesFor(_ group: DeviceSlimService.Group) -> Int64 {
        group.items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    private func cacheRow(_ item: DeviceSlimService.Item) -> some View {
        let on = selection.contains(item.id)
        return Button {
            if on { selection.remove(item.id) } else { selection.insert(item.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.body).foregroundStyle(on ? AppTheme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline).lineLimit(1)
                    if let detail = item.detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(DeviceSlimService.formatBytes(item.bytes))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    /// 较大应用行（爱思表格：应用名称 / 应用大小 / 文档大小 / 操作）
    private func bigAppRow(_ item: DeviceSlimService.Item) -> some View {
        let on = reinstallSelection.contains(item.id)
        let actionable = canReinstall(item)
        return Button {
            guard actionable else { return }
            if on { reinstallSelection.remove(item.id) } else { reinstallSelection.insert(item.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: actionable ? (on ? "checkmark.square.fill" : "square") : "square")
                    .font(.body)
                    .foregroundStyle(actionable ? (on ? AppTheme.accent : .secondary) : AppTheme.unselected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text("应用 \(DeviceSlimService.formatBytes(item.appSize))")
                        Text("·")
                        // v0.3.708：未量到时显示「文档未量到」，不把占位 0 显示成 0.00 B.
                        Text(item.docSizeKnown
                             ? "文档 \(DeviceSlimService.formatBytes(item.docSize))"
                             : "文档未量到")
                        if item.sourceAvailable == false {
                            Text("资源缺失无法重装").foregroundStyle(AppTheme.pending)
                        } else if probingAvailability && item.sourceAvailable == nil {
                            Text("检测中…").foregroundStyle(.secondary)
                        } else if item.isRisky {
                            Text("谨慎选择").foregroundStyle(AppTheme.pending)
                        } else if item.sourceAvailable == nil {
                            Text("源里未查到，可重试").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(item.docSizeKnown
                     ? DeviceSlimService.formatBytes(item.docSize)
                     : "—")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(!actionable)
    }

    // MARK: - 流程

    private func bootstrap() async {
        // 先用缓存秒开，再按需刷新
        if let cached = DeviceSlimService.cachedSnapshot() {
            await apply(snapshot: cached, fromCache: true)
        }
        await runScan(force: false)
    }

    private func apply(snapshot: DeviceSlimService.Snapshot, fromCache: Bool) async {
        do {
            let value = try await Task.detached(priority: .userInitiated) {
                try DeviceSlimService.loadUsage(snapshot: snapshot)
            }.value
            usage = value
            let scanned = try await Task.detached(priority: .userInitiated) {
                try DeviceSlimService.scan(snapshot: snapshot)
            }.value
            groups = scanned
            selection = Set(scanned.filter { $0.kind.selectable }.flatMap(\.items).map(\.id))
            self.fromCache = fromCache
            phase = .ready
            // v0.3.378：应用数据读取结果说明（读完后取走，避免跨轮残留）.
            //   ① 「应用读取超时」= 快路径也没拿到 → 错误态 + 「重试」；
            //   ② 「应用大小不可用」= 列表有数据、只是没有精确大小 →
            //      橙色提示（不是错误），「应用」分片偏小 / 「较大应用」判不出.
            switch DeviceSlimService.consumeAppReadIssue() {
            // v0.3.708：**不能精确匹配**. 产出端（DeviceSlimService.readAppsForSlim）
            // 写的是「应用读取超时，请稍后重试」，精确等于「应用读取超时」永不成立 ——
            // 超时会被下面 `case let note?` 折成橙色说明，丢掉这里专为它准备的
            // 错误态 + 「重试」（AppErrorRow 的 retry 会 invalidateAppReadCache 后重扫）.
            case let issue? where issue.hasPrefix("应用读取超时"):
                errorText = issue
                sizeNote = nil
            case let note?:
                errorText = nil
                sizeNote = note
            default:
                errorText = nil
                sizeNote = nil
            }
            // v0.3.705：空间占用数字本身的不完整说明（usage 落地后取走一次，避免跨轮残留）.
            // 与上面的 appRead 提示共用 sizeNote 通道，不另开状态.
            // v0.3.708：抽成方法 —— usageIssue 只在 apply 里取走一次（与刚落地的 usage /
            // groups 同一份快照），runScan 不再重复消费，数字与说明同源.
            mergeUsageIssueNote()
            await probeAvailability()
        } catch {
            errorText = "读取失败：\(error.localizedDescription)"
        }
    }

    /// v0.3.708：取走「本轮数字不完整」的原因并追加到 sizeNote（取走即清零，只显示最后一次）.
    /// 只在 apply 里调用 —— 与刚落地的 usage / groups 同一份快照，数字与说明同源.
    private func mergeUsageIssueNote() {
        guard let usageIssue = DeviceSlimService.consumeUsageIssue() else { return }
        let count = usageIssue.components(separatedBy: " / ").count
        let summary = "有 \(count) 类数据未能读取: \(usageIssue). 以下数字不含这些项."
        sizeNote = sizeNote.map { $0 + " · " + summary } ?? summary
    }

    /// 回填「免登录源里有没有」——决定「较大应用」能不能勾选重装（爱思同款判定）
    private func probeAvailability(recheck: Bool = false) async {
        let pending = bigAppItems
            .filter { $0.sourceAvailable == nil }
            .map { (bundleId: $0.id, name: $0.name) }
        guard !pending.isEmpty else { return }
        probingAvailability = true
        defer { probingAvailability = false }
        let result = recheck
            ? await DeviceSlimService.refreshSourceAvailability(pending)
            : await DeviceSlimService.probeSourceAvailability(pending)
        mergeAvailability(result)
    }

    /// 「重新检测」：连**已判定缺失**的也重查（源里可能新上架，或上次是网络失败）
    private func recheckAvailability() async {
        guard !bigAppItems.isEmpty else { return }
        probingAvailability = true
        defer { probingAvailability = false }
        let all = bigAppItems.map { (bundleId: $0.id, name: $0.name) }
        let result = await DeviceSlimService.refreshSourceAvailability(all)
        mergeAvailability(result)
        ToastCenter.shared.show("已重新检测 \(all.count) 款应用")
    }

    /// 合并探测结果；`nil`（这次没查成）不写入，保持原状以免越查越少
    private func mergeAvailability(_ result: [String: Bool?]) {
        guard !result.isEmpty else { return }
        groups = groups.map { group in
            guard group.kind == .bigApps else { return group }
            var updated = group
            updated.items = group.items.map { item in
                var copy = item
                if let value = result[item.id], let ok = value {
                    copy.sourceAvailable = ok
                }
                return copy
            }
            return updated
        }
    }

    private func runScan(force: Bool) async {
        if !force, let cached = DeviceSlimService.cachedSnapshot() {
            await apply(snapshot: cached, fromCache: true)
            return
        }
        phase = .scanning
        statusText = "正在扫描设备…"
        errorText = nil
        resultText = nil
        // v0.3.708：**sizeNote 一起清** —— 它是「上一轮数字不完整」的说明，且会被下一轮
        // apply 里的 usageIssue 追加（consumeUsageIssue 取走即清零，只保留最后一次）；
        // 不清就会让旧快照的说明挂在新快照的数字旁边.
        sizeNote = nil
        do {
            let snap = try await Task.detached(priority: .userInitiated) {
                try DeviceSlimService.buildSnapshot { message in
                    Task { @MainActor in statusText = message }
                }
            }.value
            await apply(snapshot: snap, fromCache: false)
        } catch {
            phase = .ready
            errorText = "扫描失败：\(error.localizedDescription)"
        }
    }

    /// v0.3.708：把「本次动作自身的失败」并到已有的 errorText 上，不覆盖.
    /// 重扫会把上一句 errorText 清掉、也可能写入新的（扫描失败 / 应用读取超时），
    /// 动作失败原因不能因此消失 —— 两句都留着.
    private func mergeErrorText(_ text: String) -> String {
        guard let existing = errorText, !existing.isEmpty else { return text }
        return existing + "\n" + text
    }

    private func startClean() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        phase = .cleaning
        statusText = "正在删除…"
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try DeviceSlimService.clean(items: targets) { index, total in
                        Task { @MainActor in statusText = "正在删除 \(index)/\(total)…" }
                    }
                }.value
                // v0.3.708：**先重扫，再把结果文案落地**. runScan 会清掉 resultText /
                // errorText（避免上一轮的结果与这一轮的新数字并列），写在它前面的文案
                // 在同一帧就被清掉 —— 用户做完瘦身一句确认都看不到.
                await runScan(force: true)
                phase = .finished
                // v0.3.661：把「未能统计大小」单独说出来。
                // 这些条目已删成功但删前量不到字节数，若并进 freed 会显示成「已释放 0 字节」，
                // 用户会以为没生效而反复清理 —— 必须与「0 字节」区分开。
                resultText = "本次共释放空间 \(DeviceSlimService.formatBytes(result.freed))"
                    + (result.unmeasured > 0 ? "（另有 \(result.unmeasured) 项已删除但未能统计大小）" : "")
                    + (result.failures.isEmpty ? "" : "（\(result.failures.count) 项失败）")
                if !result.failures.isEmpty {
                    errorText = mergeErrorText(result.failures.prefix(3).joined(separator: "\n"))
                }
            } catch {
                phase = .ready
                errorText = "瘦身失败：\(error.localizedDescription)"
            }
        }
    }

    private func startReinstall() {
        let targets = reinstallTargets
        guard !targets.isEmpty else { return }
        phase = .reinstalling
        statusText = "正在卸载并重装…"
        Task {
            // Swift 6：回调以 `@Sendable` 显式标注 → 非 MainActor 隔离，消除
            // 「sending MainActor 闭包给 nonisolated 方法」的诊断（与 AppStore 批次
            // b8123f5 的 `{ @Sendable line in … }` 同型）；捕获的 self（View 结构体）
            // 与 ReinstallProgress 均为 Sendable，语义不变.
            let result = await DeviceSlimService.reinstall(items: targets) { @Sendable p in
                Task { @MainActor in reinstallProgress = p }
            }
            // v0.3.708：**先重扫，再落地文案**（同 startClean）—— 写在 runScan 前面的
            // resultText / errorText 会被它清掉.
            reinstallSelection.removeAll()
            reinstallProgress = nil
            await runScan(force: true)
            phase = .finished
            // v0.3.708（R8）：**卸载成功、装回失败**的款单独说 —— 它们此刻已经不在设备上，
            // 与「源里没有包」「安装包不可用」（原应用仍在）不是同一种后果：用户要的是
            // 「手动重装」，不是「重试」.
            let gone = result.uninstalledOnly
            let failed = result.failures
            if result.ok.isEmpty && !failed.isEmpty && gone.isEmpty {
                errorText = mergeErrorText(failed.prefix(3).joined(separator: "\n"))
            } else {
                resultText = "已重装 \(result.ok.count) 款"
                    + (gone.isEmpty ? "" : "；\(gone.count) 款已卸载但未能装回（需手动重装）")
                    + (failed.isEmpty ? "" : "（\(failed.count) 款失败）")
                let detail = (failed + gone).prefix(3).joined(separator: "\n")
                if !detail.isEmpty { errorText = mergeErrorText(detail) }
            }
        }
    }
}

// MARK: - 环形图

private struct DeviceSlimDonut: View {
    let segments: [DeviceSlimView.ChartSegment]

    var body: some View {
        ZStack {
            Circle().stroke(Color(.systemGray5), lineWidth: 24)
            ForEach(segments) { segment in
                DonutArc(start: segment.start, end: segment.end)
                    .stroke(Color(slimHex: segment.colorHex),
                            style: StrokeStyle(lineWidth: 24, lineCap: .butt))
            }
        }
    }
}

private struct DonutArc: Shape {
    let start: Double
    let end: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard end > start else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(start * 360 - 90),
                    endAngle: .degrees(end * 360 - 90),
                    clockwise: false)
        return path
    }
}

private extension Color {
    init(slimHex hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
