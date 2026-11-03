//
//  PurchaseHistoryView.swift
//  TequilaDash
//
//  「已购列表」—— 某个已登录 Apple ID 在 App Store 里的购买记录（DMAP）。
//  支持按 名称 / Bundle ID / App ID 搜索，并按「上架 / 下架」分段筛选；
//  每条可点进详情、可直接下载（含已下架应用 —— 只要买过）。
//  下架应用的图标与详情来自 NB 下架库收录的快照（公开 lookup 对它们天然回空）。
//

import SwiftUI
import UIKit

struct PurchaseHistoryView: View {

    let email: String

    @Environment(\.dismiss) private var dismiss

    @State private var apps: [OwnedApp] = []
    @State private var icons: [Int64: String] = [:]
    /// 已购里有、Apple lookup 查不到 ⇒ 判为已下架（判据见 `loadIcons`）。
    @State private var delistedIds: Set<Int64> = []
    @State private var keyword = ""
    @State private var segment: FilterSegment = .all
    @State private var loading = false
    @State private var errorText: String?
    @ObservedObject private var center = IPADownloadCenter.shared

    /// 「上架 / 下架」筛选。判据同行内「已下架」胶囊 —— 都读 `delistedIds`。
    private enum FilterSegment: String, CaseIterable, Identifiable {
        case all = "全部"
        case onSale = "上架"
        case delisted = "下架"

        var id: String { rawValue }
    }

    private var filtered: [OwnedApp] {
        var list = apps
        switch segment {
        case .all: break
        case .onSale: list = list.filter { !delistedIds.contains($0.id) }
        case .delisted: list = list.filter { delistedIds.contains($0.id) }
        }
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { list = list.filter { $0.matches(key) } }
        return list
    }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    Section {
                        // v0.3.700：区块级加载行收口到 AppLoadingRow（.block 档）.
                        AppLoadingRow(title: "读取已购列表…", level: .block)
                    }
                } else if let errorText {
                    Section {
                        // v0.3.683：区块级错误行统一到 AppErrorRow.
                        AppErrorRow(message: errorText, retry: { Task { await load() } })
                    }
                } else if apps.isEmpty {
                    Section {
                        Text("Apple 未返回已购记录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Picker("筛选", selection: $segment) {
                            ForEach(FilterSegment.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color(.systemGroupedBackground))
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    Section {
                        if filtered.isEmpty {
                            Text(segment == .delisted ? "没有已下架的应用" : "没有匹配的应用")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(filtered) { app in
                                row(app)
                            }
                        }
                    } header: {
                        Text(summaryText)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $keyword, prompt: "名称 / Bundle ID / App ID")
            .avoidSearchZoom()
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("已购列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                }
            }
            .refreshable { await load() }
        }
        .task { if apps.isEmpty { await load() } }
        .toastHost()
    }

    private var summaryText: String {
        let total = apps.count
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty || segment != .all { return "匹配 \(filtered.count) / \(total)" }
        if delistedIds.isEmpty { return "共 \(total) 个已购应用" }
        return "共 \(total) 个已购应用 · \(delistedIds.count) 个已下架"
    }

    // MARK: - 行

    private func row(_ app: OwnedApp) -> some View {
        // 左段可点进详情（下架应用也能进 —— 详情页会走 NB 下架库补全，见 `AppStoreDetailView`）；
        // 右侧「下载」按钮留在 NavigationLink **外面**，否则整行都归导航、按钮点不动。
        HStack(spacing: 12) {
            NavigationLink {
                AppStoreDetailView(item: storeItem(for: app),
                                   delisted: delistedIds.contains(app.id),
                                   accountEmail: email)
            } label: {
                HStack(spacing: 12) {
                    icon(for: app)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(app.name.isEmpty ? app.bundleId : app.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if delistedIds.contains(app.id) {
                                // Step 3 批 6-C：手写胶囊收编到共享 `SizePill` 的 `.compact` 档（caption2 + 6 / 2）；
                                // 字重 `.semibold` 与档位默认一致，底色 15% 用覆盖项钉住（默认 12%）.
                                SizePill(text: "已下架",
                                         tint: AppTheme.pending,
                                         level: .compact,
                                         fillOpacity: 0.15)
                            }
                        }
                        Text(subtitle(app))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if !app.version.isEmpty {
                        Text(app.version)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            downloadButton(app)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                UIPasteboard.general.string = app.bundleId
                ToastCenter.shared.show("已复制 Bundle ID")
            } label: {
                Label("复制 Bundle ID", systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = app.idText
                ToastCenter.shared.show("已复制 App ID")
            } label: {
                Label("复制 App ID", systemImage: "number")
            }
            // v0.3.749：失败原因以前只在「下载管理」页能看到，而已购是从 sheet 进来的、
            // 那个页根本不在导航里 ⇒ 长按把原因给出来，用户不用自己找页面.
            if let last = center.lastFinishedJob(bundleId: app.bundleId.isEmpty ? nil : app.bundleId,
                                                 name: app.name), last.phase == .failed {
                Divider()
                Text("上次未成功：\((last.error ?? "未知原因").prefix(140))")
                    .font(.caption)
            }
        }
    }

    /// 已购条目 → AppleID 通道下载。已购（含已下架）都能下：许可在账号里，Apple 仍发直链。
    private func downloadButton(_ app: OwnedApp) -> some View {
        let bid = app.bundleId.isEmpty ? nil : app.bundleId
        let busy = center.activeJob(bundleId: bid, name: app.name) != nil
        // v0.3.749（用户：「点下载没反应」）：任务毫秒级就 .failed 时，旧写法只看 activeJob ⇒
        // 行立刻变回「下载」胶囊，再加一句无条件的「已开始下载」，感知就是「点了啥也没发生」.
        // `jobs` 是 @Published ⇒ 阶段翻转当场重算 body，不需要任何人为等待窗口（规则 29）.
        let last = center.lastFinishedJob(bundleId: bid, name: app.name)
        let failed = !busy && last?.phase == .failed
        return Button {
            download(app)
        } label: {
            if busy {
                ProgressView().controlSize(.mini).frame(width: 32)
            } else if failed {
                // 中性琥珀（不是错误红 —— 红色只留给破坏性动作，规则 28）；原因在长按菜单里.
                SizePill(text: "未成功",
                         tint: AppTheme.pending,
                         level: .regular,
                         fillOpacity: 0.14)
            } else {
                // Step 3 批 6-C：手写胶囊收编到共享 `SizePill` 的 `.regular` 档（caption + 10 / 5）；
                // 字重 `.semibold` 与档位默认一致，底色 14% 用覆盖项钉住（默认 12%）.
                SizePill(text: "下载",
                         tint: AppTheme.categoryStore,
                         level: .regular,
                         fillOpacity: 0.14)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(failed ? "上次未成功，长按查看原因" : "下载")
    }

    private func download(_ app: OwnedApp) {
        IPADownloadCenter.shared.startWithAppleID(item: storeItem(for: app), email: email)
        // v0.3.749：这句原来无条件承诺「已开始下载」，而失败在异步链里 —— 属于假 Toast.
        // 任务确实已同步建出来，所以只说「已加入下载」；成败由行内胶囊当场反映.
        ToastCenter.shared.show("已加入下载")
    }

    /// 已购条目 → 商店条目：详情页与下载都吃同一个 `AppStoreItem`（图标已知就带上）。
    private func storeItem(for app: OwnedApp) -> AppStoreItem {
        AppStoreItem(id: app.idText,
                     name: app.name.isEmpty ? app.bundleId : app.name,
                     bundleId: app.bundleId.isEmpty ? nil : app.bundleId,
                     version: app.version.isEmpty ? nil : app.version,
                     iconURL: icons[app.id])
    }

    /// 副标题：`App ID · Bundle ID`（有购买日期再补一段）
    private func subtitle(_ app: OwnedApp) -> String {
        var parts: [String] = []
        parts.append(app.idText)
        if !app.bundleId.isEmpty { parts.append(app.bundleId) }
        if let date = app.purchaseDate {
            parts.append(DateText.string(from: date, style: .day))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func icon(for app: OwnedApp) -> some View {
        let side: CGFloat = 36
        if let urlString = icons[app.id], let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                monogram(app)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
        } else {
            monogram(app)
        }
    }

    private func monogram(_ app: OwnedApp) -> some View {
        let letter = String((app.name.isEmpty ? app.bundleId : app.name).prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                .fill(AppTheme.categoryStore.opacity(0.14))
            Text(letter.isEmpty ? "?" : letter)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.categoryStore)
        }
        .frame(width: 36, height: 36)
    }

    // MARK: - 加载

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        errorText = nil
        do {
            let list = try await PurchaseHistoryService.ownedApps(email: email)
            apps = list
            LoginLogger.shared.log("[已购] \(email) 共 \(list.count) 条", category: .appStore)
        } catch {
            errorText = error.localizedDescription
            LoginLogger.shared.log("[已购] \(email) 失败：\(error.localizedDescription)",
                                   category: .appStore)
        }
        loading = false
        await loadIcons()
    }

    /// 图标只是锦上添花：批量 lookup，失败就退回字母块。
    /// 顺带判定「已下架」：**已购里有、Apple lookup 查不到** ⇒ 该 App 已下架
    /// （对齐 ipatool 的 `ErrAppNotFound`：下架应用在公开 lookup 里天然缺席，但已购许可还在，仍能下）。
    /// 只对「确实查回来过」的批次下结论 —— 整批空多半是接口/网络不可用，不能据此误标已下架。
    private func loadIcons() async {
        let ids = apps.map { $0.idText }
        guard !ids.isEmpty else { delistedIds = []; return }
        var table: [Int64: String] = [:]
        var delisted = Set<Int64>()
        // 步长与 lookupBatch 内部一致（40），保证「一批 = 一次 lookup」，成败可判。
        for chunk in stride(from: 0, to: ids.count, by: 40) {
            let slice = Array(ids[chunk ..< min(chunk + 40, ids.count)])
            guard let items = try? await AppStoreService.lookupBatch(ids: slice) else { continue }
            guard !items.isEmpty else { continue }   // 整批没查到：不下「已下架」结论
            var found = Set<Int64>()
            for item in items {
                guard let id = Int64(item.id) else { continue }
                found.insert(id)
                if let icon = item.iconSmallURL ?? item.iconURL { table[id] = icon }
            }
            delisted.formUnion(Set(slice.compactMap { Int64($0) }).subtracting(found))
        }
        // 下架应用在公开 lookup 里天然缺席 ⇒ 上面这批拿不到它们的图标。改去 NB 下架库
        // 按名字反查，用收录时留下的 `iconPath` 补上（认不出身份的不写，宁可留字母块）。
        let pending = apps.filter { delisted.contains($0.id) }
        if !pending.isEmpty {
            for (id, url) in await PurchaseHistoryService.offSaleIcons(for: pending) where table[id] == nil {
                table[id] = url
            }
        }
        if !table.isEmpty { icons = table }
        delistedIds = delisted
    }
}
