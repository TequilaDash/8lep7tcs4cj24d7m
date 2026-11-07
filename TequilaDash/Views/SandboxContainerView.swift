import SwiftUI
import UIKit

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

    var body: some View {
        List {
            Section {
                heroCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if isLoading && apps.isEmpty {
                AppLoadingRow(title: "正在读取容器目录…", level: .page)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if apps.isEmpty {
                AppStateSection(state: .empty("还没有容器应用",
                                              message: "点右上角「导入」选择一个未加密的 IPA. 加密包（App Store 直接下载的那种）装不进来.",
                                              icon: "square.stack.3d.up"))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if filteredApps.isEmpty {
                AppStateSection(state: .empty("没有匹配的应用",
                                              message: "换名称或 Bundle ID 重试.",
                                              icon: "magnifyingglass"))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                Section {
                    AppSectionHeader("容器应用",
                                     subtitle: "共 \(filteredApps.count) 个",
                                     symbol: "app.grid.3x3",
                                     tint: AppModule.store.tint)
                        .padding(.horizontal, AppTheme.pageInset)
                        .padding(.top, 4)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    // 分块行：与 LaunchAppsView 同一处理 —— 整网格一行时 LazyVGrid 在 List 行内
                    // 会被全量物化，进场瞬间几十格齐发 .task 会卡顿.
                    ForEach(Array(stride(from: 0, to: filteredApps.count, by: 24)), id: \.self) { start in
                        let chunk = Array(filteredApps[start..<min(start + 24, filteredApps.count)])
                        AppAdaptiveGrid(items: chunk, minimum: 92, spacing: 12) { app in
                            containerTile(app)
                        }
                        .padding(.horizontal, AppTheme.pageInset)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    Text("容器包体放在 Documents/SandboxApps/Applications，每个应用的可写目录独立放在 Data/Application. 覆盖导入会保留已生成的可写目录.")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AppTheme.pageInset + 4)
                        .padding(.bottom, 32)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
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

    /// 网格里的一格：图标 + 名称 + 版本，点击进详情，长按删除.
    private func containerTile(_ app: SandboxApp) -> some View {
        NavigationLink {
            SandboxAppDetailView(app: app) { Task { await reload() } }
        } label: {
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
        .buttonStyle(.plain)
        .appPressable(scale: 0.94)
        .contextMenu {
            Button(role: .destructive) {
                deleteTarget = app
            } label: {
                Label("删除容器", systemImage: "trash")
            }
        }
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

