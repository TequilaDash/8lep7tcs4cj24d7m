import SwiftUI
import UIKit
import UniformTypeIdentifiers

// 沙盒容器 · 页面
//
// 目录口径照 LiveContainer：Documents/SandboxApps/Applications/<app>.app 放包体，
// Documents/SandboxApps/Data/Application/<UUID> 放该应用的可写家目录（HOME / CFFIXED_USER_HOME）。
// 布局照 LCGridLayout 的实测口径（4 列起步、图标连续圆角比例 0.2237、左右各 12pt 边距），
// 但落到本仓设计系统：网格一律走 AppAdaptiveGrid，格子底色走 AppSurface.card，
// 不手搓 GridItem、不新增色板 token.
//
// 本阶段只做「容器管理」：导入 / 列表 / 详情 / 浏览文件 / 重置与删除。
// **不做进程内启动**（启动要复刻 LC 的 dlopen + LC_MAIN 跳转 + NSBundle/HOME hook，
// 属功能性改动，按 USER.md 第 8 条要先出方案审批），页面文案因此不承诺启动.

/// 容器应用图标缓存：从 Caches/SandboxContainerIcons/<bundleId>.png 读一次就常驻.
///
/// 与 JITAppIconLoader 同一诉求（网格里几十格同时解码），但来源是本机文件，
/// 因此不需要异步队列，读到了就塞进内存缓存.
final class SandboxIconLoader: @unchecked Sendable {
    static let shared = SandboxIconLoader()

    private let lock = NSLock()
    private var cache: [String: UIImage] = [:]

    /// 已有缓存直接返回（主线程安全：只读字典，命中即返回不可变 UIImage）.
    func cached(for bundleId: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache[bundleId]
    }

    /// 读磁盘并缓存（放后台线程调用）.读不到不写负缓存：图标是可再生资源，
    /// 用户重新导入或下次刷新就可能有了，缓存 nil 会让它永远显示占位图.
    func load(for bundleId: String) -> UIImage? {
        if let hit = cached(for: bundleId) { return hit }
        let url = SandboxContainerStore.iconFileURL(bundleId: bundleId)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        lock.lock()
        cache[bundleId] = image
        lock.unlock()
        return image
    }

    func forget(_ bundleId: String) {
        lock.lock()
        cache.removeValue(forKey: bundleId)
        lock.unlock()
    }
}

/// 容器应用图标（无图标时回落 SF Symbol 虚线方块，与 JITAppIconView 同形）.
struct SandboxAppIconView: View {
    let bundleID: String
    var size: CGFloat = 60

    @State private var icon: UIImage?

    var body: some View {
        Group {
            if let icon {
                Image(uiImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.tertiary)
                    .padding(size * 0.18)
            }
        }
        .frame(width: size, height: size)
        // 连续圆角：LCGridLayout 实测比例 0.2237，本仓 AppIcon 口径 8/36 ≈ 0.2222，取本仓值.
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: size * (8.0 / 36.0), style: .continuous))
        .task(id: bundleID) {
            guard icon == nil else { return }
            let loaded = await Task.detached(priority: .userInitiated, operation: {
                SandboxIconLoader.shared.load(for: bundleID)
            }).value
            if let loaded { icon = loaded }
        }
    }
}

/// 沙盒容器主页：hero 统计 + 网格 + 导入.
struct SandboxContainerView: View {
    @State private var apps: [SandboxApp] = []
    @State private var isLoading = false
    @State private var isImporting = false
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var deleteTarget: SandboxApp?

    /// 搜索框常驻（.always）——本页容器是 List，系统会把搜索框计入内容安全区，
    /// swift_searchbar_guard S1 因此放行；缩卡由 .avoidSearchZoom() 压制（HARD-RULES 30）.
    private var filteredApps: [SandboxApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.displayName.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }
    }

    private var totalBytes: Int64 { apps.reduce(0) { $0 + $1.sizeBytes } }

    /// 分块的**下标起点**（每 24 个一节）.
    ///
    /// 与 LaunchAppsView 同一诉求：整网格塞进一个 List 行时 LazyVGrid 会被全量物化，
    /// 进场瞬间几十格齐发 `.task` 会卡顿（2026-11-01 用户报告），所以照样分节.
    /// 但**不在 ForEach 里现算** `stride(from:to:by:)` + `min` + 区间下标：CI 两次实证
    /// （99f27c7 → :149:37、2140ad9 → :168:81）`unable to type-check this expression in
    /// reasonable time` —— 格子视图本体（NavigationLink + contextMenu + 多层修饰）本身很重，
    /// 再叠切片就让整条表达式进了推断爆炸区. 这里只暴露 Int 起点数组
    /// （`[[SandboxApp]]` 不是 Identifiable，不能直接当 ForEach 数据源），切片交给
    /// `chunk(at:)`，网格交给独立子视图 `SandboxAppGridRow`，三处各自单独过类型检查.
    private var chunkStarts: [Int] {
        var starts: [Int] = []
        var index = 0
        let total = filteredApps.count
        while index < total {
            starts.append(index)
            index += 24
        }
        return starts
    }

    private func chunk(at start: Int) -> [SandboxApp] {
        let list = filteredApps
        let end = Swift.min(start + 24, list.count)
        return Array(list[start..<end])
    }

    var body: some View {
        List {
            content
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppTheme.surfaceBase)
        .navigationTitle("沙盒容器")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索应用或 Bundle ID")
        .avoidSearchZoom()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    AppHaptics.tap()
                    showImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(isImporting)
                .accessibilityLabel("导入 IPA")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    AppHaptics.tap()
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading || isImporting)
                .accessibilityLabel("刷新")
            }
        }
        .documentPicker(isPresented: $showImporter,
                        allowedTypes: [UTType(filenameExtension: "ipa") ?? .data]) { urls in
            for url in urls { importOne(url) }
        }
        .confirmationDialog("删除 \(deleteTarget?.displayName ?? "") 的容器？",
                            isPresented: Binding(get: { deleteTarget != nil },
                                                 set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("删除容器", role: .destructive) {
                if let target = deleteTarget { remove(target) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("会同时删掉包体和它的可写目录，不可恢复.")
        }
        .overlay {
            if isImporting {
                AppBusyOverlay(title: "正在导入…", style: .card)
            }
        }
        .onAppear {
            if apps.isEmpty { Task { await reload() } }
        }
        .toastHost()
    }

    // MARK: - List 内容

    /// 整条 List 的内容. 每个分支各自是一个独立计算属性，`body` 里只留一次属性引用 ——
    /// CI 三次实证（99f27c7 → :149:37、2140ad9 → :168:81、8aedc22 → :136:14）只要分支里
    /// 出现「视图构造 + 多层 listRow 修饰」的组合，整条 `body` 就 `unable to type-check
    /// this expression in reasonable time`. 把每段抽出去之后推断面被切成 5 份，各自过.
    @ViewBuilder
    private var content: some View {
        heroSection
        stateSection
        gridSection
    }

    private var heroSection: some View {
        Section {
            heroCard.rowInList
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        if isLoading && apps.isEmpty {
            loadingRow
        } else if apps.isEmpty {
            emptyRow
        } else if filteredApps.isEmpty {
            noMatchRow
        }
    }

    private var loadingRow: some View {
        AppLoadingRow(title: "正在读取容器目录…", level: .page).rowInList
    }

    private var emptyRow: some View {
        AppStateSection(state: .empty("还没有容器应用",
                                      message: "点右上角「导入」选择一个未加密的 IPA. 加密包（App Store 直接下载的那种）装不进来.",
                                      icon: "square.stack.3d.up")).rowInList
    }

    private var noMatchRow: some View {
        AppStateSection(state: .empty("没有匹配的应用",
                                      message: "换名称或 Bundle ID 重试.",
                                      icon: "magnifyingglass")).rowInList
    }

    @ViewBuilder
    private var gridSection: some View {
        if !apps.isEmpty && !filteredApps.isEmpty {
            Section {
                gridHeader
                gridRows
                gridFooter
            }
        }
    }

    private var gridHeader: some View {
        AppSectionHeader("容器应用",
                         subtitle: "共 \(filteredApps.count) 个",
                         symbol: "app.grid.3x3",
                         tint: AppModule.store.tint)
            .padding(.horizontal, AppTheme.pageInset)
            .padding(.top, 4)
            .rowInList
    }

    private var gridRows: some View {
        ForEach(chunkStarts, id: \.self) { start in
            gridRow(at: start)
        }
    }

    private func gridRow(at start: Int) -> some View {
        SandboxAppGridRow(chunk: chunk(at: start),
                          onDelete: { app in deleteTarget = app },
                          onDetailChange: { Task { await reload() } })
            .padding(.horizontal, AppTheme.pageInset)
            .rowInList
    }

    private var gridFooter: some View {
        Text(gridFooterText)
            .font(AppFont.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppTheme.pageInset + 4)
            .padding(.bottom, 32)
            .rowInList
    }

    private var gridFooterText: String {
        "容器包体放在 Documents/SandboxApps/Applications，每个应用的可写目录独立放在 Data/Application. 覆盖导入会保留已生成的可写目录."
    }

    private var heroCard: some View {
        AppHeroHeader(
            title: "沙盒容器",
            subtitle: "把 IPA 装进独立容器目录，包体与可写目录分开管理.",
            symbol: "square.stack.3d.up.fill",
            stats: [
                AppStat("容器", apps.isEmpty ? "空" : "\(apps.count) 个"),
                AppStat("占用", apps.isEmpty ? "0 B" : IPADownloadLibrary.sizeText(totalBytes)),
                AppStat("可写目录", readyDataHomesText)
            ]
        )
        .padding(.vertical, 6)
    }

    private var readyDataHomesText: String {
        let ready = apps.filter { $0.hasDataHome }.count
        return "\(ready) / \(apps.count)"
    }

    // MARK: - 动作

    private func reload() async {
        isLoading = true
        let scanned = await Task.detached(priority: .userInitiated, operation: {
            SandboxContainerStore.scan()
        }).value
        apps = scanned
        isLoading = false
    }

    /// 删除容器（包体 + 可写目录）. 结果按 `RemoveResult` 真实分支上报，删不掉不许说「已删除」.
    private func remove(_ app: SandboxApp) {
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                SandboxContainerStore.remove(app)
            }.value
            switch outcome {
            case .removed:
                AppHaptics.success()
                SandboxIconLoader.shared.forget(app.id)
                await reload()
                ToastCenter.shared.show("已删除 \(app.displayName)", seconds: 3.0)
            case .notFound:
                await reload()
                ToastCenter.shared.show("容器已经不在了", seconds: 3.0)
            case .failed(let message):
                ToastCenter.shared.show("删除失败：\(message)", seconds: 4.0)
            }
        }
    }

    private func importOne(_ url: URL) {
        guard !isImporting else { return }
        isImporting = true
        Task {
            // 不传 progress：SandboxImportService 的回调是 @Sendable，从本页（View 结构体）
            // 传闭包进去会跨 actor 捕获 self，Swift 6 complete 并发下不合法. 遮罩只给一个总文案.
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try SandboxImportService.importIPA(at: url) }
            }.value
            isImporting = false
            switch outcome {
            case .success(let result):
                AppHaptics.success()
                await reload()
                let head = result.replaced
                    ? "已覆盖安装 \(result.app.displayName)"
                    : "已导入 \(result.app.displayName)"
                ToastCenter.shared.show(result.warning == nil
                    ? head
                    : head + "；" + (result.warning ?? ""), seconds: 3.4)
            case .failure(let error):
                ToastCenter.shared.show(error.localizedDescription, seconds: 4.0)
            }
        }
    }
}

// MARK: - 网格子视图

/// 一节网格（最多 24 格）.
///
/// 独立成类型只为把类型检查面切开：CI 两次实证 `AppAdaptiveGrid(items: chunk) { containerTile($0) }`
/// 与外层 List / ForEach / 修饰符写在同一个 `body` 里会 `unable to type-check this expression in
/// reasonable time`（99f27c7 → :149:37、2140ad9 → :168:81）. 放进自己的 `body` 后，
/// 外层只剩一个 `SandboxAppGridRow(...)` 调用，推断深度立刻回落.
struct SandboxAppGridRow: View {
    let chunk: [SandboxApp]
    var onDelete: (SandboxApp) -> Void = { _ in }
    var onDetailChange: () -> Void = {}

    var body: some View {
        AppAdaptiveGrid(items: chunk, minimum: 92, spacing: 12) { app in
            SandboxAppTile(app: app, onDelete: onDelete, onDetailChange: onDetailChange)
        }
    }
}

/// 网格里的一格：图标 + 名称 + 版本，点击进详情，长按删除.
///
/// 同上一条理由独立成类型 —— `NavigationLink` 的 destination 泛型 + `contextMenu` + 
/// `appPressable` 叠在一起就是最重的那一段.
struct SandboxAppTile: View {
    let app: SandboxApp
    var onDelete: (SandboxApp) -> Void
    var onDetailChange: () -> Void

    var body: some View {
        NavigationLink {
            SandboxAppDetailView(app: app, onChange: onDetailChange)
        } label: {
            tileLabel
        }
        .buttonStyle(.plain)
        .appPressable(scale: 0.94)
        .contextMenu {
            Button(role: .destructive) {
                onDelete(app)
            } label: {
                Label("删除容器", systemImage: "trash")
            }
        }
    }

    /// 图标 + 两行文字. 单独抽出来，`label:` 闭包就只是一次属性引用.
    private var tileLabel: some View {
        VStack(spacing: 8) {
            SandboxAppIconView(bundleID: app.id, size: 60)
            Text(app.displayName)
                .font(AppFont.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Text(app.bundleVersion ?? app.id)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
            .fill(AppSurface.card))
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }
}

// MARK: - 行内修饰

/// List 行三件套（无内缩 / 透明底 / 无分隔线）. 抽成一个扩展是为了让每个分支的
/// 表达式只剩「一次构造 + 一次属性引用」，把类型推断面压到最小（见 `content` 上方注释）.
extension View {
    var rowInList: some View {
        self
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
