import SwiftUI

/// v0.3.303：免登录下载商店（爱思 PC 端源）
///
/// 与「AppStore 商店」的区别：**完全不需要登录 Apple ID，也不需要配置分发源**。
/// 数据与安装包都来自爱思 PC 端在用的公开接口（`app4.i4.cn` + `d-app6.i4.cn`），
/// 服务端存放的即为已签名 IPA（`isSignOK == "1"`）。
///
/// 流程：榜单/搜索 → 拿 `path` → `d-app6.i4.cn/soft/<path>` 下载 IPA
/// → `AppStoreInstallService.installLocalIPA`（RSD 隧道 + AFC + installation_proxy）。
///
/// v0.3.364：列表项可点进 `I4StoreFreeDetailView`（详情走 `appinfo.xhtml`），
/// 详情里列出爱思历史版本，安装旧版仍走同一条下载链路。
///
/// v0.3.406：**牛蛙源补上详情页与下载** —— 列表项可点进 `NiuwaStoreDetailView`，
/// 行右侧的「获取」（v0.3.408 前叫「安装」）走 `startNiuwaDownload(_:region:)`
/// （先取直链，再交给 `IPADownloadCenter`）。
struct I4StoreFreeView: View {

    /// v0.3.382：免登录商店的**来源**（接口一 = 爱思，接口二 = 牛蛙）
    ///
    /// v0.3.414：新增**第三来源 NB**（NB Pro）。
    ///
    /// v0.3.540：**修正对 NB 的误判**。此前以为「NB 没有榜单、也没有搜索，常规搜索就是转调爱思」——
    /// 这是只看了一个来源就外推的结论，实际是错的：
    ///   · **NB 有榜单** —— 逐条比对确认它就是 **Apple 官方排行榜**（RSS），
    ///     `NBStoreRankClient` 直接接 Apple，不再假装没有；
    ///   · **NB 有搜索** —— 走 **Apple 官方 search**，区域随 `regionRaw` 走，
    ///     所以美区能搜到美区应用、国区能搜到国区全部上架应用；
    ///   · 原来「借爱思搜索」的做法已删 —— 爱思是中国区商店，借它必然「美区空、国区少」。
    ///
    /// NB 与 Apple 的分工：**榜单/搜索的元数据用 Apple**（NB 自己也是转发的），
    /// **安装包仍然由 NB 通道取**（`NBStoreClient`，Apple RSS 不给包）。
    enum StoreSource: String, CaseIterable, Identifiable {
        case i4 = "爱思"
        case niuwa = "牛蛙"
        case nb = "NB"

        var id: String { rawValue }
    }

    /// v0.3.382：牛蛙源的分区（客户端硬编码中国/美国/香港三档）
    var region: NiuwaStoreClient.NiuwaRegion { NiuwaStoreClient.NiuwaRegion(rawValue: regionRaw) ?? .cn }

    @State var source: StoreSource = .i4
    @State var regionRaw = "cn"
    @State private var rank: I4PCStoreClient.Rank = .recommend
    /// v0.3.540：NB 源的榜单分组（走 Apple RSS，与爱思那份是两套数据）.
    @State private var nbRank: NBStoreRankClient.Rank = .freeApps
    @State private var apps: [I4PCStoreClient.I4App] = []
    /// v0.3.540：NB 源榜单结果（Apple RSS）.
    @State private var nbRankItems: [NBStoreRankClient.RankItem] = []
    @State private var loading = true
    @State var errorText: String?
    @State private var keyword = ""
    @State private var searchResults: [I4PCStoreClient.I4App] = []
    @State var searching = false
    /// v0.3.382：牛蛙源的搜索结果（与爱思结果并存，切来源不必重打）
    @State private var niuwaSearchResults: [NiuwaStoreClient.NiuwaApp] = []
    /// v0.3.406：正在「取直链」的那一行（牛蛙要先打一发 `/appstore/download` 才有直链）。
    /// 存 bundleId 而不是 Bool：同一时刻只允许一行在取，且要能对上具体是哪一行。
    @State var niuwaFetching: String?

    /// v0.3.414：NB 源的取包结果。
    ///
    /// NB 没有列表接口，一次查询只对应一个 trackId，所以这里存的是**单个**结果，
    /// 而不是像前两源那样的数组。`nbTrackID` 记下它是哪个 ID 的包（下载时要上报）。
    @State var nbPackage: NBStoreClient.NBPackage?
    @State var nbTrackID = ""
    @State var nbFetching = false
    /// v0.3.540：NB 源的搜索结果（Apple 官方 search，区域随 `regionRaw` 走）.
    ///
    /// 与 `searchResults`（爱思）**刻意分开** —— 两者数据源完全不同，
    /// 混用一个数组会让「切来源后残留上一个源的条目」，
    /// 而 NB 的行必须走 NB 取包（不能用爱思的 `ipaURL`）.
    @State private var nbSearchResults: [NBStoreRankClient.RankItem] = []

    /// v0.3.549：NB 源**下架**搜索结果。
    ///
    /// 与 `nbSearchResults` 分开存：两者数据源、字段、可做的动作都不同 ——
    /// 下架项取包要走「内嵌 `appStoreData` → 缺则 `getAppHistoryList` 回退」这条专用链路，
    /// 混在一个数组里会让「这一行该走哪条链路」变成靠猜。分开存则行类型本身就决定了链路
    /// （见 `nbOffSaleRow`）。
    @State private var nbOffSaleResults: [NBStoreClient.OffSaleApp] = []

    /// v0.3.596：正在「取包」的那条下架行（存 `OffSaleApp.id`）。
    ///
    /// ## 为什么必须有（用户报「点了获取没有反应」）
    /// `installOffSale` 要先 `await NBStoreClient.offSalePackage(...)` 把包取回来，
    /// **之后**才 `startNBDownload` 建下载任务。而右侧控件（`trailingControl`）只在
    /// `center.activeJob(...)` 非空时才显示进度 —— 取包这段**没有任何视觉反馈**。
    /// 实测这一段耗时：单发 `getAppHistoryList` ≈ 1.7s；带版本回退最多 6 次 ≈ 14s
    /// （服务端卡住时每次最长 15s 超时 ⇒ 最坏近 90s）⇒ 用户看到的就是「点了没反应」。
    /// 现在取包期间这一行右侧显示「获取中…」菊花，取完（成功/失败）即清。
    @State var offSaleFetchingID: Int?

    /// v0.3.545：NB 源的**上架 / 下架**筛选（对应 NB 助手的 `DXSTOffSaleController`）。
    ///
    /// ## 怎么判定「下架」
    /// 反编译 NB 助手确认它有独立的下架应用页（`DXSTOffSaleController` +
    /// `DXSTOffSaleDetailController` + `DXSTOffSaleHistoryListController`）。
    /// 取包走 `/nb/app-downgrade`：搜索响应里内嵌 `appStoreData` 时直接用它，
    /// 没有时回退 `nb9527_getAppHistoryList`（`appID` + 可选 `appVerId`）——
    /// **对下架 App 实测可用**（见 `NBStoreClient.offSalePackage(from:country:)`）。
    ///
    /// ## 所以「筛」这个动作怎么做
    /// 应用列表来自 Apple RSS/search，这两条**只回上架应用**，天然没有下架项。
    /// 因此这里的筛选是**开关式的行为切换**，不是对已有数组做过滤：
    /// - `.onSale`（默认）：行为完全不变；
    /// - `.offSale`：把搜索/列表里的每个 trackId 拿去 `lookup` 探一次，
    ///   用 `NBStoreClient.offSalePackage` 取包 —— 也就是说这条路能装到
    ///   App Store 已经搜不到的老应用。
    ///
    /// 注意： 刻意**不建本地库**：NB 那边下架列表是本地 SQLite 表 `load_list` 缓存的，
    /// 我们没有必要复刻一份会过期的缓存；状态以实时探测为准。
    enum AppStateFilter: String, CaseIterable, Identifiable {
        case onSale = "上架"
        case offSale = "下架"

        var id: String { rawValue }
    }

    @State var appStateFilter: AppStateFilter = .onSale

    /// v0.3.305：已下载数量（进入页面时读一次磁盘台账）
    @State var downloadedCount = 0
    /// 统一下载中心（免登录源与 Apple ID 共用）
    @ObservedObject var center = IPADownloadCenter.shared

    /// v0.3.399：行长按「查看图标」的全屏预览。
    ///
    /// **复用** AppleID 商店详情页那套 `ImageGalleryViewer`（同一个类型，见 `ImagePreviewSupport.swift`），
    /// 不在这里另写一个只显示一张图的查看器 —— 长按存图也因此白得。
    /// v0.3.408：图数组收进 `ImagePreviewTarget`（页面上不再留 `previewImages`）。
    @State var previewTarget: ImagePreviewTarget?

    private var isSearchMode: Bool { !keyword.trimmingCharacters(in: .whitespaces).isEmpty }

    /// v0.3.382：搜索框提示随来源变（牛蛙要多说一句区域）
    ///
    /// v0.3.538：NB 源两种输入都收 —— 关键词或 App Store 链接 / 数字 ID。
    /// v0.3.540：关键词这一路已改用 Apple 官方搜索（区域随上方区域选择走）.
    private var searchPrompt: String {
        switch source {
        case .i4:    return "搜索应用（无需登录）"
        case .niuwa: return "搜索应用（无需登录 · \(region.title)）"
        case .nb:    return "搜应用名（\(regionRaw.uppercased())区），或填 App Store ID"
        }
    }

    var body: some View {
        List {
            downloadManagerSection
            sourceSection
            if isSearchMode {
                searchSection
            } else {
                // v0.3.540：NB 源也有榜单了（Apple RSS）—— 不再是「没有榜单」那句话.
                if source == .i4 || source == .nb { rankSection }
                listSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("免登录下载")
        .navigationBarTitleDisplayMode(.inline)
        // v0.3.367：用户要求顶栏搜索**常驻**（下滑也能搜），对齐主页「应用」板块的 .always。
        .searchable(text: $keyword,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: searchPrompt)
        .avoidSearchZoom()
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: rank) { _, _ in Task { await load() } }
        // v0.3.540：NB 榜切换分组要重拉（走的是 Apple RSS，与爱思那份数据无关）.
        .onChange(of: nbRank) { _, _ in Task { await load() } }
        // v0.3.382：切来源 / 切区域都要重新取数（搜索态重搜，列表态重载）
        //
        // v0.3.414：切到 NB 时**先清掉上一个来源的结果** —— NB 的结果行只在
        // `source == .nb` 时渲染，但 `nbPackage` 本身不清会串到下一次查询。
        // v0.3.540：`nbSearchResults` 同理（它是 Apple 搜索的结果，与爱思的 `searchResults` 分开存）.
        .onChange(of: source) { _, newValue in
            if newValue == .nb {
                nbPackage = nil
                nbTrackID = ""
                errorText = nil
            }
            nbSearchResults = []
            if isSearchMode { runSearch() } else { Task { await load() } }
        }
        .onChange(of: regionRaw) { _, _ in
            // v0.3.414：NB 源也要响应区域切换（它的 `country` 参数随之变）
            // v0.3.540：NB 的榜单/搜索现在都跟 `country` 走，所以区域变了必须重取.
            guard source == .niuwa || source == .nb else { return }
            if isSearchMode { runSearch() } else { Task { await load() } }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
            }
        }
        .toastHost()
        .fullScreenCover(item: $previewTarget) { target in
            // v0.3.408：`urls` 从 target 里读
            ImageGalleryViewer(urls: target.urls, startIndex: target.index)
        }
        .task {
            // v0.3.658（task-3 D6）：只要个数 ⇒ 用目录列举，别再走 items()（会逐条开 IPA 包）。
            downloadedCount = IPADownloadLibrary.shared.downloadedFileCount
            if apps.isEmpty { await load() }
        }
    }

    // MARK: - v0.3.382 来源 / 区域

    /// **来源**：爱思（接口一）/ 牛蛙（接口二）；选牛蛙时下面多一行**区域**三档
    private var sourceSection: some View {
        Section {
            Picker("来源", selection: $source) {
                ForEach(StoreSource.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)

            // v0.3.414：NB 源也有区域（ID 反编译确认 `country` 参数，`DXSTSegmentController` 就是它的控件）
            if source == .niuwa || source == .nb {
                Picker("区域", selection: $regionRaw) {
                    ForEach(NiuwaStoreClient.NiuwaRegion.allCases) { r in
                        Text(r.title).tag(r.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            // v0.3.545：NB 源的**上架 / 下架**（对应 NB 助手的 DXSTOffSaleController）。
            // 只在 NB 源出现 —— 爱思/牛蛙没有这条链路，不给它们摆一个按不动的开关。
            if source == .nb {
                Picker("状态", selection: $appStateFilter) {
                    ForEach(AppStateFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        // v0.3.545：**修「分组栏目上方有一块空白」**。
        //
        // 原来这里是 `.listRowInsets(top:6, leading:0, bottom:6, trailing:0)`
        // 配 `.listRowBackground(Color.clear)`，用意是「让分段控件贴边、不要卡片背景」。
        // 但这两个一起用会把这一行从 `insetGrouped` 的卡片布局里摘出去：
        // 卡片背景被清空后，Section 的 header 与第一行之间会**按卡片间距留一段空白**，
        // 视觉上就是「分组栏上方空一块、跟下面的榜单对不齐」。
        //
        // 改回 insetGrouped 的标准行内边距（左右各 16），保留卡片背景，
        // 上下只留很小的呼吸 —— 分段控件本来就有自己的内边距，不需要再顶出去。
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    // MARK: - v0.3.305 下载管理入口

    /// 已下载安装包的管理入口（列表 + 安装 + 删除），顶在最上面方便随时进
    private var downloadManagerSection: some View {
        Section {
            NavigationLink {
                // v0.3.588：爱思免登录商店的「下载管理」**只列本页三个免登录来源**
                // （爱思 / 牛蛙 / NB）的下载 —— 第三方软件源 / Apple ID 通道的下载不再混进本页。
                IPADownloadManagerView(filterSource: [.i4Free, .niuwa, .nb])
            } label: {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "shippingbox.fill", tint: AppTheme.categoryDownload,
                               symbolSize: 18, frameSize: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下载管理").font(.subheadline.weight(.medium))
                        Text("管理已下载的 IPA 并安装").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    if downloadedCount > 0 {
                        Text("\(downloadedCount)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// 已下载数量（进入页面时读一次磁盘台账）
    // MARK: - 榜单选择

    private var rankSection: some View {
        Section {
            // v0.3.540：两个来源的榜单是**两套数据**（爱思自己的服务端 / Apple RSS），
            // 分组取值也不同，所以用各自的 Picker，不硬凑成一个.
            //
            // v0.3.545：两处 `listRowInsets` + `listRowBackground(Color.clear)` 都去掉 ——
            // 与 `sourceSection` 同一个毛病（清掉卡片背景后 header 与内容之间会留一段空白）。
            // 保持 insetGrouped 的默认行边距即可。
            if source == .nb {
                // v0.3.549：下架态下榜单单不存在 —— 不摆一个选了也没用的下拉.
                if appStateFilter == .onSale {
                    Picker("分组", selection: $nbRank) {
                        ForEach(NBStoreRankClient.Rank.allCases) { r in
                            Text(r.title).tag(r)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } else {
                Picker("分组", selection: $rank) {
                    ForEach(I4PCStoreClient.Rank.allCases) { r in
                        Text(r.title).tag(r)
                    }
                }
                .pickerStyle(.segmented)
            }
        } footer: {
            Text(source == .nb
                 ? "榜单来自 Apple 官方排行榜（与 NB 助手同一来源）.点「获取」由 NB 通道取包."
                 : "数据来自爱思 PC 端同款公开接口，安装包由服务端提供（已签名），无需登录 Apple ID.")
                .font(.caption2)
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var listSection: some View {
        if loading {
            Section {
                AppLoadingRow(title: "正在获取列表…", level: .block)
            }
        } else if let errorText {
            Section {
                // v0.3.683：区块级错误行统一到 AppErrorRow.
                AppErrorRow(message: errorText)
            }
        } else if source == .niuwa {
            // v0.3.382：牛蛙源只有搜索，不做榜单（接口文档里只有 /appstore/search + /download）
            Section {
                Text("牛蛙源请用上方搜索框按关键词找应用")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else if source == .nb {
            // v0.3.549：**下架态下不摆榜单**。
            //
            // 榜单来自 Apple RSS，那里面**没有下架应用** —— 在下架态继续显示榜单，
            // 等于用一批在架应用冒充下架结果（用户报的「下架应用搜索完全没用」就是这一类观感）。
            // 下架库只能搜，没有榜单，所以这里如实说明，把入口指到搜索框。
            if appStateFilter == .offSale {
                Section {
                    Text("下架应用请用搜索框按名字查找")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else if nbRankItems.isEmpty {
                Section {
                    InfoActionCard(icon: "list.number",
                                   title: "该榜单暂时没有数据",
                                   message: "榜单来自 Apple 官方排行，这个区域当前没有返回数据.换个区域或稍后再试.")
                }
            } else {
                Section("\(nbRank.title)榜 · \(nbRankItems.count) 款") {
                    ForEach(nbRankItems) { item in
                        nbRankRow(item)
                    }
                }
            }
        } else if apps.isEmpty {
            Section {
                InfoActionCard(icon: "square.grid.2x2",
                               title: "该分组暂时没有数据",
                               message: "这个分组在当前区域没有内容.换一个分组或区域试试.")
            }
        } else {
            Section("\(rank.title) · \(apps.count) 款") {
                ForEach(apps) { app in
                    row(app)
                }
            }
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        if searching {
            Section {
                AppLoadingRow(title: "搜索中…", level: .block)
            }
        } else if source == .i4 {
            if searchResults.isEmpty {
                AppStateSection(state: .empty("没有找到匹配的应用",
                                              message: "换个关键词试试.",
                                              icon: "magnifyingglass"))
            } else {
                Section("搜索结果 · \(searchResults.count) 款") {
                    ForEach(searchResults) { app in
                        row(app)
                    }
                }
            }
        } else if source == .niuwa {
            if niuwaSearchResults.isEmpty {
                AppStateSection(state: .empty("没有找到匹配的应用",
                                              message: "换个关键词试试.",
                                              icon: "magnifyingglass"))
            } else {
                Section("搜索结果 · \(niuwaSearchResults.count) 款") {
                    ForEach(niuwaSearchResults) { app in
                        row(app)
                    }
                }
            }
        } else {
            // NB 源三种结果形态：
            //   · 「下架」态 → NB 自己的下架库（`nbOffSaleResults`，v0.3.549）
            //   · 输入是 ID/链接 → 单个取包结果（`nbPackage`）
            //   · 输入是关键词   → Apple 官方搜索的候选列表（`nbSearchResults`），
            //                      点「获取」走 NB 取包（v0.3.540：不再借爱思）
            if appStateFilter == .offSale {
                // 下架库是**独立的**：它的条目不能走 Apple 那套行（字段与链路都不同）。
                if nbOffSaleResults.isEmpty {
                    Section {
                        InfoActionCard(icon: "magnifyingglass",
                                       title: "下架库里没有匹配的应用",
                                       message: "换个关键词试试，或确认当前区域是否选对.")
                    }
                } else {
                    Section("下架应用 · \(nbOffSaleResults.count) 款") {
                        ForEach(nbOffSaleResults) { app in
                            nbOffSaleRow(app)
                        }
                    }
                }
            } else if let pkg = nbPackage {
                Section("App Store ID \(nbTrackID)") {
                    nbRow(trackID: nbTrackID, package: pkg)
                }
            } else if nbFetching {
                Section {
                    AppLoadingRow(title: "正在取包…", level: .block)
                }
            } else if !nbSearchResults.isEmpty {
                Section("搜索结果 · \(nbSearchResults.count) 款") {
                    ForEach(nbSearchResults) { item in
                        nbRankRow(item)
                    }
                }
            } else {
                Section {
                    Text("搜应用名，或粘贴 App Store 链接 / 填数字 ID")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 加载

    private func load() async {
        loading = true
        errorText = nil
        // v0.3.540：NB 源现在也有榜单了（Apple RSS）—— 只有牛蛙源是真的没有榜单接口.
        if source == .nb {
            do {
                nbRankItems = try await NBStoreRankClient.fetch(rank: nbRank, country: regionRaw)
            } catch {
                nbRankItems = []
                errorText = "NB 榜单加载失败：\(error.localizedDescription)"
            }
            loading = false
            return
        }
        // v0.3.382：牛蛙源没有榜单接口 —— 不请求，仅在列表处提示走搜索
        guard source == .i4 else {
            loading = false
            return
        }
        do {
            apps = try await I4PCStoreClient.list(rank: rank)
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func runSearch() {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else {
            searchResults = []
            niuwaSearchResults = []
            nbSearchResults = []
            nbOffSaleResults = []
            return
        }
        searching = true
        let src = source
        let reg = region
        Task {
            switch src {
            case .i4:
                do {
                    searchResults = try await I4PCStoreClient.search(keyword: kw)
                } catch {
                    searchResults = []
                    ToastCenter.shared.show("搜索失败：\(error.localizedDescription)")
                }
            case .niuwa:
                do {
                    niuwaSearchResults = try await NiuwaStoreClient.search(keyword: kw, region: reg)
                } catch {
                    niuwaSearchResults = []
                    // ▸ v0.3.387：失败原因必须**留在界面上**。
                    // 只弹一个一闪而过的 toast 的话，用户看到的就是「列表全空、什么也不知道」，
                    // 这一轮就是这么丢掉真机证据的（用户只反馈「界面都是空的」）。
                    // `StoreError.server` 的 description 已带 `nwcore_code` 与 `nwcore_messages`。
                    errorText = "牛蛙源搜索失败：\(error.localizedDescription)"
                    ToastCenter.shared.show("搜索失败")
                }
            case .nb:
                // v0.3.540：**不再借爱思的搜索接口**。
                //
                // 用户反馈「美区一个搜索不到、国区还那么点软件」—— 根因就是这里原来
                // 调的是 `I4PCStoreClient.search`，而爱思是**中国区商店**：
                // 它的库里没有美区应用（美区空），国区也只覆盖它自己收录的那点量。
                //
                // 现在按输入形态分流：
                //   · 数字 ID / App Store 链接 → 直接走 NB 取包（原行为）
                //   · 纯文字关键词           → 走 **Apple 官方 search**（区域跟着 `regionRaw` 走）
                // 这样美区能搜到美区商店的应用，国区能搜到国区商店的全部上架应用。
                //
                // v0.3.549：**「下架」必须走 NB 自己的搜索**。
                //
                // 用户反馈「NB 源选美区下架的应用根本搜索不到，你这下架应用搜索完全没用」——
                // 真因就在这一支：以前无论选上架还是下架，走的都是同一条 Apple search，
                // 而 Apple 的 search/RSS **只回在架应用**（实测 `term=stikdebug&country=us`
                // 回的是 TestFlight / GitHub / Debug Anywhere 这批在架应用，正是截图里那几行）——
                // 所以「下架」这个筛选在数据源上根本不曾生效，是个空开关。
                //
                // 下架库只有 NB 服务端有（`nb9527_searchOffSaleApp`，见 `NBStoreClient`）。
                // 数字 ID 这一支在下架态下也走下架接口 —— 下架应用只能这样取包。
                if appStateFilter == .offSale {
                    // 下架态：一律走 NB 下架搜索（输入是 ID 或名字都一样，接口只吃 `kw`）。
                    do {
                        nbOffSaleResults = try await NBStoreClient.searchOffSaleApp(keyword: kw)
                    } catch {
                        nbOffSaleResults = []
                        // 同取包：`code=7` 走面向用户文案，不外泄内部码。
                        errorText = NBStoreClient.packageFailure(from: error)?.userMessage
                            ?? "NB 下架搜索失败：\(error.localizedDescription)"
                        ToastCenter.shared.show("搜索失败")
                    }
                } else if nbParseTrackIDOnly(kw) != nil || kw.lowercased().contains("apple.com") {
                    await runNBFetch(kw)
                } else {
                    do {
                        nbSearchResults = try await NBStoreRankClient.search(keyword: kw, country: regionRaw)
                    } catch {
                        nbSearchResults = []
                        errorText = "NB 源搜索失败：\(error.localizedDescription)"
                        ToastCenter.shared.show("搜索失败")
                    }
                }
            }
            searching = false
        }
    }

}
