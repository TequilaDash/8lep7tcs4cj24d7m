import SwiftUI
import UIKit

/// 本模块的强调色 —— `systemTeal` 是 UIKit 语义色，随明暗模式自动调整，
/// 深浅两端都满足可读性；保留「青」的视觉身份（不是系统蓝）。
/// 不能用虚拟定位页的 `LocusTheme.accent`：那是硬编码 sRGB，压在浅色底上对比度只有 1.6:1–3.6:1。
let downloadAccent = Color(uiColor: .systemTeal)

/// v0.3.305：IPA 下载管理 —— 管理已下载的安装包并直接安装.
///
/// 列表来自 `Documents/AppStoreDownloads`（免登录下载 / App Store 下载都落在这里），
/// 与磁盘实时对齐：手动放进该目录的 IPA 也会出现在列表里。
///
/// 安装复用既有 RSD 隧道能力（`AppStoreInstallService.installLocalIPA`）：
/// 加密包走 `PackageType: Customer` + 包内 `SC_Info/*.sinf`，明文包走常规安装。
///
/// v0.3.378：点任意一行弹出操作面板（`IPADownloadActionsSheet`）。
struct IPADownloadManagerView: View {

    /// 本入口允许显示的**来源集合**。`nil`（默认）= 全量（既有「下载管理」行为，任何来源都列）；
    /// 非 `nil` 时**只列**来源落在集合内的任务与台账（来源是 `Source` 枚举，可多选）。
    ///
    /// v0.3.588（用户纠正上一轮的方向）：用户原话「你不能把别的地方下载的东西区分开来吗 比如第三方
    /// 软件源下载的东西 你跑去AppStore商店下载管理列表出现」—— 要的是**每个入口只显示自己来源的东西**
    /// （「看不到」），不是上一轮做的「看得出」。故三个入口各传自己的来源集合：
    /// · AppStore 商店详情页 ⇒ `[.appleID]`（该页只走 Apple ID 通道）；
    /// · 爱思免登录商店 ⇒ `[.i4Free, .niuwa, .nb]`（该页三个免登录来源）；
    /// · 软件源管理 ⇒ `[.thirdPartySource]`。
    /// 台账里**未登记来源**（「来源未知」等非枚举值，见 `IPADownloadLibrary`）不属任何具体来源
    /// ⇒ **各入口都不显示**（见 `allowsLedgerSource(_:)`）。它仍留在磁盘（文件 App）与全量入口里。
    ///
    /// 标题**统一为「下载管理」**（不随来源改名 —— 它只是同一个下载管理的来源过滤视图）。
    /// 复用同一套下载中心/台账/UI（D1=A，不新建第二个下载管理器）。
    ///
    /// v0.3.578：**过滤时**在列表顶部补**一行来源说明**（`sourceFilterNoteSection`）——
    /// 免得过滤视图的「下载管理 (18)」被误读成「全部下载只有 18」（另一个入口是另一个计数口径）。
    ///
    /// v0.3.587：来源此前只是灰色小字，扫一眼看不见。**每条行**都带一个**有色来源胶囊**
    /// （`sourceBadge`），无论哪个入口进来都能一眼确认每条属于哪个源（本轮的过滤改动**保留**它）。
    ///
    /// 非 private 且有默认值 ⇒ 可直接用成员逐一初始化器 `IPADownloadManagerView(filterSource:)`。
    var filterSource: Set<IPADownloadCenter.Source>? = nil

    @State private var items: [IPADownloadItem] = []
    /// 正在弹操作面板的条目
    @State var actionItem: IPADownloadItem?
    /// v0.3.387：正在弹操作面板的**下载中任务**（还没落台账，包不成条目）。
    /// 用途：下载过程也能「提取下载链接」—— 那行的直链只在 `Job.remoteURL` 上。
    @State var actionJob: IPADownloadCenter.Job?
    /// bundleId → 图标 URL。历史记录里没持久化 `iconURL`（真机 `ipa_downloads.json` 实测没有该字段），
    /// 进入页面时按 bundleId 查回来补上；查不到就退回字母块。
    @State var icons: [String: String] = [:]
    @State private var selection = Set<String>()
    /// 长按安装包 → 「查看图标」打开的全屏预览。图数组随 target 一起写（`ImagePreviewTarget`），
    /// 页面上不再单独留一份预览数组 —— 两次独立写入会让弹窗读到旧的空数组.
    @State var previewTarget: ImagePreviewTarget?
    /// v0.3.383：右上角「在线安装设置」sheet（GitHub Token）
    @State private var showOnlineInstallSettings = false
    /// 右上角「日志」入口的呈现状态。
    ///
    /// 用 `.sheet` 而非 push：复用的既有日志页 `LoginLogView` 自带 `NavigationStack` +
    /// 「完成」按钮（它是为 sheet 设计的）—— 再 push 一层会嵌出第二套导航栏、与系统返回箭头重复。
    /// 这与软件源页的日志入口（`SignSourceListView.swift` 的 `.sheet(isPresented:)`）**同一种呈现方式**。
    @State private var showLog = false
    /// v0.3.382：在列表里出现**多于一次**的 bundleId。
    /// 用途：行状态判定时，若某个任务的版本还未知（只能按 bundleId 认行），
    /// 而这些行共享同一个 bundleId，就**宁可都不显示**进行中/失败 —— 不能显示错（见 activeJob 注释）。
    @State private var duplicatedBundleIds: Set<String> = []
    @ObservedObject var center = IPADownloadCenter.shared
    /// v0.3.388：在线安装（OTA）的进度 —— 唯一真实来源是**本机服务器已发给系统的字节数**
    /// （系统进入安装阶段后 App 观测不到，那时显示不确定态，见 `OnlineInstallProgress`）。
    @ObservedObject var otaProgress = OnlineInstallProgress.shared
    @Environment(\.editMode) private var editMode
    var isEditing: Bool { editMode?.wrappedValue == .active }

    /// v0.3.394：「下载中」那一行用的时间戳 —— 参考图是 `2026-09-14 12:06:43`（带秒）
    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // MARK: - 日志入口

    /// 本页「日志」入口只筛的日志分类 —— **「下载」专属**（与软件源页只筛「软件源」对称）。
    ///
    /// 为什么不用 `.appStore`：下载链路（`IPADownloadCenter` / `AppStoreLocalInstallService` /
    /// 下载与安装）当前全部写 `.appStore`，而 `.appStore` **同时还装**着商店浏览 / 版本历史 /
    /// 账号管理等非下载日志 —— 只筛 `.appStore` 会把这些一起带进来，板块就不纯了；而且复用页的
    /// 「清空」会按同一分类清除（`clearCategories`），拿 `.appStore` 当下载板块还会连累商店板块。
    /// 本页要的是「下载管理**自己**的日志板块」，故新增 `.download` 分类、把下载链路的写入点
    /// 单独归拢（清单见简报 §④）。
    ///
    /// 依赖（本文件**不定义**）：`LoginLogger.Category.download` 由另一位同事在
    /// `TequilaDash/Services/AppleAuth/LoginLogger.swift` 的枚举里新增（该文件不在本文件范围）；
    /// 落盘前本行无法编译 —— 这是刻意保留的跨人依赖（由协调人转交）。
    private var downloadLogCategories: [LoginLogger.Category] { [.download] }

    /// 本入口是否挂右上角「下载日志」入口。
    ///
    /// v0.3.588：改成**按来源推导**（原来是 `filterSource == nil` 才挂）。因为本轮起三个入口都带了
    /// 来源集合（不再有 `nil` 入口），若仍按 `nil` 判断，AppStore / 爱思免登录商店的日志入口会**一起消失**。
    /// 判据：本入口的来源里**至少有一个**的下载日志写 `.download`（见 `logCategory(forSource:)`）。
    /// 只筛第三方软件源时全部来源写 `.signSource` ⇒ 返回 `false`，不挂（软件源有自己的唯一日志入口）；
    /// `nil`（全量）时挂。
    private var showsDownloadLog: Bool {
        guard let set = filterSource else { return true }
        return set.contains { logCategory(forSource: $0.rawValue) == .download }
    }

    var body: some View {
        // 只有进入「编辑」才允许勾选（否则点一下就会被选中）
        List(selection: Binding(get: { isEditing ? selection : [] },
                                set: { if isEditing { selection = $0 } })) {
            // 来源说明（仅过滤视图显示）；`filterSource == nil` 时整块不渲染.
            sourceFilterNoteSection
            summarySection
            mergedSection
            labelGuideSection
        }
        .listStyle(.insetGrouped)
        // 刷新走下拉；右上角不设刷新按钮（用户要求）；返回箭头由系统提供，不重复自绘.
        // v0.3.578：包一层 async —— `reload()` 是**同步**读台账、调用即返回，直接塞进 `.refreshable`
        // 会让系统指示器**还没转起来就被收掉**（用户看不出「刷新过了」，见 `refresh()` 注释）.
        .refreshable { await refresh() }
        .navigationTitle(listTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showOnlineInstallSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .appSymbol()
                }
                .accessibilityLabel("在线安装设置")
            }
            // 「日志」入口 —— 复用**既有**日志页 `LoginLogView`（不新建第二套日志页），
            // 用与软件源页**完全相同**的做法：同一个 `LoginLogView`、同一种「传分类数组预筛 +
            // 传同分类做按板块清空」的机制，只是分类换成「下载」。见 body 末尾的 `.sheet`。
            //
            // ⚠️ 本入口是否挂「下载日志」由 `showsDownloadLog` 决定：只筛**第三方软件源**时不挂
            // （即从「软件源管理」右上角进入的那个「下载管理」）。用户要求「软件源只需要一个
            // 日志板块，只留一个软件源日志」：软件源板块已经有它自己的唯一日志入口
            // （`SignSourceListView` 左上角「软件源日志」，只读 `.signSource`），而软件源侧下载的
            // 日志本就写 `.signSource`（见 `IPADownloadCenter.logCategory(for:)`）⇒ 在这个软件源
            // 子页里再挂一个「下载日志」就是同一功能里的第二个日志板块。其余入口（AppStore 商店 /
            // 爱思免登录商店）的下载写 `.download`，仍挂本入口 —— 那是下载板块自己的日志，与
            // 软件源板块互不相干。
            //
            // 为什么放**右上角**（而软件源页按用户要求放左上角）：本页是**二级 push** 进来的
            // （`HomeView` → `SignSourceListView` → 本页），左上角恒为系统返回箭头 —— 在左上角
            // 再加一项会与返回箭头挤占 / 重叠，破坏返回手势的视觉与命中区。右上角本轮已清空
            // （刷新按钮已按用户要求删除），把日志入口放这里既不抢返回箭头、也不与齿轮 / 编辑冲突。
            if showsDownloadLog {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showLog = true
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                            .appSymbol()
                    }
                    .accessibilityLabel("下载日志")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            // 刷新走下拉（见 body 上的 `.refreshable`）；右上角不设刷新按钮（用户要求）.
            // 返回箭头由系统提供（本页 push 进来时左上角自带），不重复自绘.
        }
        .toastHost()
        .sheet(isPresented: $showOnlineInstallSettings) {
            OnlineInstallSettingsSheet()
        }
        // 右上角「日志」入口 → 复用既有日志页 `LoginLogView`，只显示「下载」这一类
        // （`categories: [.download]` 按分类预筛），清空也只清这一类（`clearCategories: [.download]`），
        // 不穿透商店 / 登录 / 软件源等其它板块 —— 与软件源页日志入口**同一种写法**（见该页 `.sheet`）。
        // 标题用「下载日志」而不是页内默认的「登录诊断日志」，免得页头张冠李戴（该页已支持 `title:`）。
        .sheet(isPresented: $showLog) {
            LoginLogView(categories: downloadLogCategories,
                         title: "下载日志",
                         clearCategories: Set(downloadLogCategories))
        }
        .sheet(item: $actionItem) { item in
            IPADownloadActionsSheet(
                item: item,
                iconURL: item.iconURL ?? icons[item.bundleId ?? ""],
                onOverwriteInstall: { install(item) },
                onDelete: { delete(item) })
        }
        .sheet(item: $actionJob) { job in
            // v0.3.394：下载中的任务**不再是「只留一行」的裁剪面板** —— 参考图是「展开 ipa 详情」，
            // 所以全部动作都显示，只把「覆盖安装 / 在线安装」置灰（本地还没有包文件，见面板内注释）。
            // 「删除」在这个模式下 = 取消这次下载并丢弃半成品，所以必须真的接上闭包，
            // 否则用户点了确认却什么都没发生（比置灰更糟）。
            IPADownloadActionsSheet(
                item: pendingItem(job),
                iconURL: icons[job.bundleId ?? ""] ?? job.iconURL,
                onOverwriteInstall: {},
                onDelete: {
                    // 按**实际结果**提示：删除被拒（台账只读）/ 文件被占用时不能默默当成功。
                    let result = center.cancel(job.id)
                    reload()
                    if let result { reportRemoval(result) }
                },
                // v0.3.413：只有**真的还在进行中**才把「覆盖安装 / 在线安装」置灰。
                // 以前这里写死 `true` —— 于是一个**已完成**的任务行（若因去重时序残留）
                // 点开会显示"下载中"，与行上的「已完成 100%」自相矛盾（用户截图）。
                //
                // `isPendingDownload` 的语义是「占用中」（`phase.isBusy`），只用来**置灰**；
                // 右侧标的**状态字**另取 `job.displayStage`（唯一真源）—— 否则暂停任务
                // （`isBusy` 也为 true）会被标成「下载中」，与行上「已暂停」同屏矛盾（审计发现）。
                isPendingDownload: job.phase.isBusy,
                pendingStageText: job.displayStage)
        }
        // 长按安装包 → 「查看图标」→ 全屏预览。长按图片「保存到相册」由 `ImageGalleryViewer` 自带
        //（二次确认 → `MediaSaver`，无权限自动回落 `Documents/AppIcons`），这里只负责把 target 递进去.
        .fullScreenCover(item: $previewTarget) { target in
            ImageGalleryViewer(urls: target.urls, startIndex: target.index,
                               logCategory: target.logCategory)
        }
        // v0.3.394（用户硬要求）：**装完不用退出这一页就能自己刷新**。
        //
        // 行内容来自磁盘台账（不是 `@Published`），所以「安装中 → 安装/重装」这一步
        // 必须重新读一次台账才会出现。`finishedTick` 由下载中心在**任务换阶段**时 +1
        // （见 `IPADownloadCenter.update`），一个任务只有 2~3 次，不会把磁盘读爆；
        // 而 `jobs` 每个进度回调都变，跟着它重读会读爆 —— 这是选它的原因。
        .onChange(of: center.finishedTick) { _, _ in
            reload()
        }
        .task {
            reload()
            await loadIcons()
        }
    }

    /// 标题带总数（形如「下载管理 (5)」）；一条都没有时不带数字。
    private var listTitle: String {
        let count = mergedRows.count
        // 标题统一为「下载管理」：`filterSource` 仍用于**过滤**（见 `mergedRows` / `reload`），
        // 但不再影响标题 —— 软件源来源只是同一个下载管理的过滤视图，不必另起一个名字.
        return count == 0 ? "下载管理" : "下载管理 (\(count))"
    }

    // MARK: - 合并列表

    /// v0.3.394：合并列表的一行 —— 要么是下载中心**进行中的任务**，要么是台账里的**已下载条目**。
    private enum ListRow: Identifiable {
        case job(IPADownloadCenter.Job)
        case file(IPADownloadItem)

        var id: String {
            switch self {
            case .job(let job): return "job-\(job.id.uuidString)"
            case .file(let item): return "file-\(item.fileName)"
            }
        }

        /// 批量删除只作用于 file 行 —— 把 `ListRow` 还原成 `remove(fileNames:)` 期望的**原始文件名**。
        ///
        /// 为什么要有它：`selection` 里存的是 `ListRow.id`（`"file-<文件名>"`），
        /// 旧代码直接把它当原始文件名传给 `remove(fileNames:)` ⇒ 一个都匹配不上 ⇒ 静默删不掉。
        /// job 行返回 nil（下载中任务不参与批量删除，见 `mergedSection` 里的 `.selectionDisabled(true)`）。
        var fileNameForDeletion: String? {
            if case .file(let item) = self { return item.fileName }
            return nil
        }
    }

    /// v0.3.394（用户要求）：**只有一个列表**，不再分「下载中 / 已下载」两个分组。
    ///
    /// 组成 = 进行中的任务 + 台账条目。**去重**：某任务的落地文件名
    /// （`localFileName`，还没落地时用预测名 `expectedFileName`）已经在台账里 → 不单独列它，
    /// 由台账那一行承担显示（那一行会用 `rowProgress` 画出同一个任务的进度环）。
    /// 不去重的话，包刚落盘的那一刻会被列成两行 —— 同一份文件出现两次。
    ///
    /// 排序：进行中的在最上面（未完成的先看到），然后是刚结束（失败的那条还能重试），
    /// 最后按下载时间倒序 —— 与参考图「新动静在上面」一致。
    private var mergedRows: [ListRow] {
        // 来源过滤：`filterSource == nil` 时原样用全部任务（全量入口行为不变）。
        // 任务一定带 `Source` 枚举，直接按集合判；`items` 已在 `reload()` 里按同一集合过滤，故去重口径一致。
        let allJobs = filterSource.map { set in center.jobs.filter { set.contains($0.source) } } ?? center.jobs
        let orphanJobs = allJobs.filter { job in
            // ▸▸▸ v0.3.413 真机 bug 修复（用户截图）：「显示已完成 100%，但没有安装按钮」。
            //
            // 根因：下载完成的那一刻，台账**已经写盘**，但页面 `items` 是**上一次 reload 的
            // 快照**，`finishedTick` 的 reload 可能还没跑到。这一刻用 `items` 去重会失败，
            // 于是同一个包被列成两行：
            //   · 「任务行」（`jobRow`）—— **只画进度条，永远不画「安装」按钮**；
            //   · 「台账行」（`fileRow`）—— 有「安装」按钮。
            // 用户点那行「已完成」时走的是任务行 → `actionJob` → `isPendingDownload: true`
            // → 「覆盖安装 / 在线安装」被置灰标「下载中」（第二张图就是这个面板）。
            //
            // 修法：**已成功完成、且文件已落盘**（`localFileName != nil`）的 job
            // 一律不再单独成行 —— 由台账行承担显示（`items()` 会扫磁盘补登记，一定会出现）。
            // 这样彻底摆脱「内存快照 vs 磁盘台账」的时序依赖。
            //
            // 为什么不像以前那样直接查磁盘台账：`IPADownloadLibrary.items()` 里带
            // `IPAPackageInspector.inspect`（要解 IPA 包），每次渲染都调会卡界面。
            // 失败的任务**必须保留**（用户要能重试），所以只过滤 `.done`。
            if job.phase == .done, job.localFileName != nil { return false }
            // v0.3.579：去重口径从「只比一个名字」改成 `isRepresented` 多键判同。
            // 旧口径拿 `job.localFileName ?? job.expectedFileName` 对 `item.fileName`，
            // 而 `expectedFileName` 是**按请求版本预测**的名字，与落盘真实名（Apple 回包版本 /
            // 磁盘扫描名）可能对不上 ⇒ 同一个包被列成两行（用户截图 IMG_6692：
            // `VPN cat` 同时出现「下载中 75%」和「本地」）。多键判同见 `isRepresented(_:by:)`。
            return !items.contains { isRepresented(job, by: $0) }
        }
        let busy = orphanJobs.filter { $0.phase.isBusy }.map(ListRow.job)
        let settled = orphanJobs.filter { !$0.phase.isBusy }.map(ListRow.job)
        let files = items.sorted { $0.downloadedAt > $1.downloadedAt }.map(ListRow.file)
        return busy + settled + files
    }

    /// 「进行中的任务」与「台账条目」是否描述**同一个包**（是 → 任务不再单独成行）。
    ///
    /// 旧口径只比一个名字：`job.localFileName ?? job.expectedFileName` 对 `item.fileName`。
    /// 但 `expectedFileName` 是**按我们请求的版本预测**出来的（`<bundleId|name>-<version>.ipa`），
    /// 而台账 `fileName` 是**落盘时的真实文件名**（Apple 回包里的版本号 / 磁盘扫描得到的名字）
    /// —— 两者对不上时（用户截图 IMG_6692），同一个包会被列成两行（一行 job、一行台账）。
    ///
    /// 这里改成**多键判同**，任一命中即视为同一个包：
    /// 1. **文件名**：`localFileName`（落地后的真实名）或 `expectedFileName`（未落地的预测名）
    ///    等于台账 `fileName`；
    /// 2. **下载直链**：`job.remoteURL` == 台账 `sourceURL`（下载时与落盘时都写进台账的同一条链接
    ///    —— 这条对「预测名与真实名不一致」最有效，因为链接与名字、版本号都无关）；
    /// 3. **bundleId**（**版本无关**，但仅当该 bundleId 在台账里**唯一**时）——
    ///    专门覆盖「预测名与落盘名因版本号不同而对不上」这一根因。
    ///    该 bundleId 在台账里出现多行（同一 App 多版本）时不合并，
    ///    避免把不同版本行错误并成一行（宁可分开，不能显示错）。
    ///    **无 `bundleId` 时**（第三方软件源整源常无 `bundleIdentifier`）退回**行键**兜底：
    ///    `job.rowKey`（即该行 `downloadURL`）与台账 `sourceURL` 比对 —— 行键同样是
    ///    「版本无关、逐行唯一」的身份，补上键 3 在无 bundleId 时的空缺。
    ///
    /// ⚠️ 键 3 **只对进行中（`phase.isBusy`）的任务生效**：失败任务要能被用户看到并重试，
    /// 不参与这个版本无关的合并（失败态的展示仍走 `finishedJob(for:)` 的旧口径）。
    private func isRepresented(_ job: IPADownloadCenter.Job, by item: IPADownloadItem) -> Bool {
        if job.localFileName == item.fileName { return true }
        if job.expectedFileName == item.fileName { return true }
        if let url = job.remoteURL, !url.isEmpty, url == item.sourceURL { return true }
        if job.phase.isBusy {
            if let bid = job.bundleId, !bid.isEmpty {
                // 有 bundleId：按 bundleId 判同（要求它在台账里唯一，避免并掉多版本行）。
                if bid == item.bundleId, !duplicatedBundleIds.contains(bid) { return true }
            } else if let rk = job.rowKey, !rk.isEmpty, rk == item.sourceURL {
                // 无 bundleId 的兜底键（见上方文档注释）：第三方软件源整源常无 `bundleIdentifier`，
                // 此时 bundleId 分支恒失效 —— 退回行键（该行 `downloadURL`）与台账直链比对。
                return true
            }
        }
        return false
    }

    @ViewBuilder
    private var mergedSection: some View {
        Section {
            if mergedRows.isEmpty {
                emptyRow
            } else {
                // 不挂 `.onDelete`：那会在编辑态给每一行渲染一个红色 ⊖ 移除标，
                // 与 `List(selection:)` 的选择圆圈**并排重复**（用户嫌突兀）。
                // 单条删除走**左滑**（各行 `.swipeActions`，与 `onDelete` 无关）；
                // 批量删除走概览卡的「选择 + 删除(N)」按钮 —— 所以不需要 onDelete 的 ⊖ 标.
                ForEach(mergedRows) { row in
                    switch row {
                    case .job(let job):
                        // 下载中的任务**不参与批量删除**：它有行内「暂停/继续/重试 + 删除安装包」
                        // 与左滑取消，语义是「取消这次下载」，与「删除已下载的包」不是一件事，
                        // 混进一个「删除(N)」会误导。`.selectionDisabled(true)` 同时收掉编辑态的选择圆圈
                        // （iOS 17+，本仓部署目标 18.0）。
                        jobRow(job)
                            .selectionDisabled(true)
                    case .file(let item):
                        fileRow(item)
                    }
                }
            }
        }
    }

    private var emptyRow: some View {
        // 空状态改用 DesignSystem 的 `AppEmptyState`（118pt 浅蓝圆 + 青绿字形 + 俏皮副标题），
        // 替换原先手写的 `VStack` + 小号 `shippingbox` 图标.
        AppEmptyState(
            icon: "shippingbox",
            secondaryIcon: nil,
            title: "还没有下载过安装包",
            message: "从软件源下载的安装包会出现在这里.")
            .listRowBackground(Color.clear)
    }

    /// 下载中任务：把该任务的直链**直接**复制走（不经过操作面板）。
    ///
    /// 用户原话：「下载的进度条也没提取下载链接的按钮 我让你加在进度条也不加」——
    /// 所以这里做成**行内按钮**，而不是「让这一行可点、再进面板找」。
    func extractLinkOfActiveJob(_ job: IPADownloadCenter.Job) {
        guard let raw = job.remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            ToastCenter.shared.show("还没拿到直链")
            return
        }
        UIPasteboard.general.string = raw
        // 分类改为 `.download`（下载专属）—— 本文件自己的下载面板日志也归到「下载」板块，
        // 否则它留在 `.appStore` 会漏出这个板块（见 `downloadLogCategories` 的取舍说明）。
        LoginLogger.shared.log("[下载面板] 提取下载链接（下载中任务）：\(String(raw.prefix(64)))…",
                               category: .download)
        ToastCenter.shared.show("链接已复制")
    }

    /// 「这个包从哪来」→ 取图日志板块：三方软件源 ⇒ 「软件源」，其余 ⇒ 「下载」。
    /// 与 `IPADownloadCenter.logCategory(for:)` 同一口径（那个是 private，视图侧自持一份）。
    func logCategory(forSource raw: String) -> LoginLogger.Category {
        raw == IPADownloadCenter.Source.thirdPartySource.rawValue ? .signSource : .download
    }

    /// 台账条目的来源是否属于本入口。
    ///
    /// · `filterSource == nil`（全量入口）⇒ 全显示；
    /// · 台账 `source` 是字符串（`IPADownloadItem.source`），能转成 `Source` 枚举就按集合判；
    /// · **转不成枚举**（「来源未知」等未登记值）⇒ **不属任何具体入口**，各入口都**不显示** ——
    ///   它没有被归到「别的地方」，但也没法确认属于本入口；按本仓「显示错 > 显示少」的口径，
    ///   宁可不在窄入口里列它，也不把一条来路不明的包塞进「仅显示第三方软件源」这种列表里
    ///   （那会让顶部来源说明与列表自相矛盾）。它仍留在磁盘（文件 App）与全量入口里，不会真丢。
    private func allowsLedgerSource(_ raw: String) -> Bool {
        guard let set = filterSource else { return true }
        guard let source = IPADownloadCenter.Source(rawValue: raw) else { return false }
        return set.contains(source)
    }

    /// 来源集合 → 界面文案（按固定顺序拼「 / 」，避免 `Set` 顺序不定导致文案抖动）。
    private func sourceNamesText(_ set: Set<IPADownloadCenter.Source>) -> String {
        let order: [IPADownloadCenter.Source] = [.appleID, .i4Free, .niuwa, .nb, .thirdPartySource]
        return order.filter { set.contains($0) }.map(\.rawValue).joined(separator: " / ")
    }

    // MARK: - 概览

    /// v0.3.578：**来源过滤说明**（只在过滤视图显示）—— 用**一行次要文字**消除标题歧义。
    ///
    /// 为什么需要它：标题统一成「下载管理」后，各入口**只列自己来源**的任务（见 `filterSource`），
    /// 标题却都叫「下载管理」⇒ 不同入口计数口径不同却看不出区别（用户会困惑「为什么这里 18、那里 50」）。
    /// 这里点明本入口列的是哪些来源，**不改标题**（用户明确要求标题就叫「下载管理」）。
    ///
    /// `filterSource == nil`（全量入口）时**整块不渲染** —— 连 Section 都不产生.
    @ViewBuilder
    private var sourceFilterNoteSection: some View {
        if let set = filterSource {
            Section {
                Text("仅显示\(sourceNamesText(set))的任务.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 编辑态当前勾选、且**确实可删**的**原始文件名**（`remove(fileNames:)` 期望的口径）。
    ///
    /// 为什么用 `mergedRows` 反查，而不是给 `ListRow.id` 去 `"file-"` 前缀：
    /// · ID 是「渲染快照」的产物，台账/任务一变（例如下载完成、`reload()` 后行被去重）
    ///   旧 ID 就落空；反查天然把过期选择过滤掉，不会误删、也不会把 N 算多；
    /// · job 行在这里返回 nil（见 `ListRow.fileNameForDeletion`），所以计数只统计文件行.
    private var selectedFileNames: Set<String> {
        Set(mergedRows.filter { selection.contains($0.id) }
                       .compactMap { $0.fileNameForDeletion })
    }

    /// v0.3.394：这张卡只说**磁盘占用**。原来第一行是「N 个安装包」，
    /// 而「N」现在由标题（「下载管理 (N)」）承担，两个 N 含义还不一样（台账数 vs 列表行数）
    /// 放在一屏里会像 bug，所以这里去掉了。
    private var summarySection: some View {
        Section {
            HStack(spacing: 12) {
                AppRowIcon(systemName: "shippingbox.fill", tint: .blue, symbolSize: 20, frameSize: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("本地安装包")
                        .font(AppFont.subheadlineEmphasis)
                    Text("共占用 \(IPADownloadLibrary.sizeText(items.reduce(0) { $0 + max(0, $1.sizeBytes) }))")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !selectedFileNames.isEmpty {
                    // 修复（用户：编辑-删除无法正常删除安装包）：
                    // 旧代码把 `selection`（`ListRow.id`，形如 `"file-xxx.ipa"`）直接当**原始文件名**
                    // 传给 `remove(fileNames:)` ⇒ 一个都匹配不上 ⇒ 静默删不掉（左滑走的是另一条路，故正常）。
                    // 这里改用 `selectedFileNames` 把 ID 还原成原始文件名；并**检查返回值**按实际结果提示.
                    Button("删除(\(selectedFileNames.count))") {
                        let result = IPADownloadLibrary.shared.remove(fileNames: selectedFileNames)
                        selection.removeAll()
                        reload()
                        reportRemoval(result)
                    }
                    .buttonStyle(TintedButtonStyle(tint: AppTheme.danger))
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 标签说明

    /// v0.3.571：**标签说明** —— 补上「标签口径」的界面说明缺口（用户需求 #6 / #7 / #8）。
    ///
    /// 用户看不懂三件事：「明文包」怎么变少了、「带 sinf（未校验）」是什么、「来源未知」是什么。
    /// 这三件都只是**说明没写**，不是判定错 —— 所以这里**一个字都不动判定逻辑**，
    /// 尤其「未校验」绝不能改成「带 sinf」（那会让标签给出的确定性超过实际掌握）。
    /// 放在列表**下方**（而不是给每行加长按）：行点击已被「操作面板」占用，图例更省事也更全.
    private var labelGuideSection: some View {
        Section {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Text("加密状态")
                        .font(AppFont.captionEmphasis)
                    guideRow("明文包", .secondary, "明文包未加密，可直接安装.")
                    guideRow("加密包 · 带 sinf", .secondary, "已校验：包内 sinf 结构完整，可直接安装.")
                    guideRow("加密包 · 带 sinf（未校验）", .secondary, "存疑：sinf 存在，但未校验过结构（无记录，或格式未知）.")
                    guideRow("加密包 · 缺 sinf", .orange, "安装包缺失 sinf，需补 sinf.")
                    guideRow("加密包 · sinf 异常", .orange, "sinf 存在，但结构异常/未知可能无法安装.")
                    guideRow("未检测", .secondary, "尚未读到包内加密状态，重进本页会重新检测.")

                    Divider()

                    Text("来源")
                        .font(AppFont.captionEmphasis)
                    // v0.3.587：图例的**颜色与行内来源胶囊一致**（同一 `sourceTint`），
                    // 这样这张图例同时是「来源配色表」，用户能把行上的胶囊对回来源名。
                    Text("颜色与列表行上的来源胶囊一致.")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                    guideRow("Apple ID", sourceTint(IPADownloadCenter.Source.appleID.rawValue), "从 App Store 商店下载.")
                    guideRow("来源未知", .secondary, "盘上有、台账未登记的下载产物，未能确认来源.")
                    guideRow("爱思免登录", sourceTint(IPADownloadCenter.Source.i4Free.rawValue), "爱思源下载，服务端已签名.")
                    guideRow("NB免登录", sourceTint(IPADownloadCenter.Source.nb.rawValue), "NB 源下载.")
                    guideRow("牛蛙免登录", sourceTint(IPADownloadCenter.Source.niuwa.rawValue), "牛蛙源下载.")
                    guideRow("第三方软件源", sourceTint(IPADownloadCenter.Source.thirdPartySource.rawValue), "从自加软件源下载.")
                }
                .padding(.vertical, 4)
            } label: {
                Text("标签说明")
                    .font(AppFont.subheadline)
            }
        } footer: {
            Text("点开看每种标签的含义.")
        }
    }

    // MARK: - 数据与安装

    func reload() {
        syncSourceURLs()
        let allItems = IPADownloadLibrary.shared.items()
        // 来源过滤：`filterSource == nil` 时原样用全部台账（全量入口行为不变）。
        // 台账 `source` 是字符串，经 `allowsLedgerSource` 转枚举判集合（未登记来源各入口都显示）。
        items = filterSource == nil ? allItems : allItems.filter { allowsLedgerSource($0.source) }
        // 同一个 bundleId 在列表里出现两次以上 → 记下来：任务版本未知时不允许按 bundleId 认行。
        // 必须用**过滤后**的 items 计算，否则软件源页里本不显示的其它来源条目会把 bundleId 记成「重复」，
        // 导致进度认行失败（`activeJob` 的 `allowBundleIdFallback`）。
        duplicatedBundleIds = Set(
            Dictionary(grouping: items.compactMap { $0.bundleId }, by: { $0 })
                .filter { $0.value.count > 1 }
                .keys)
    }

    /// v0.3.578：下拉刷新的 async 包装 —— 让系统指示器**真的转得出来**。
    ///
    /// 根因：`reload()` 是**同步**读台账（`IPADownloadLibrary.shared.items()`），调用即返回。
    /// `.refreshable` 的闭包是 `async`，但同步闭包会让这次「刷新」瞬间完成 ⇒ 指示器**还没转就被收掉**，
    /// 用户以为没刷新（复核 §3-D）。
    ///
    /// 做法：`reload()` 之后**刻意**等一个最短可见时长（0.5s）。这是 iOS 上让刷新反馈可见的常规做法，
    /// **不是伪造耗时**：真实读盘就在上一句发生，若真实刷新更慢，总时长会自然超过 0.5s ——
    /// 这里只兜住「刷新太快、看不见」这一种情况。`Task.sleep` 是**挂起**不是阻塞，主线程照常响应，不会卡顿.
    @MainActor
    private func refresh() async {
        // 下拉刷新 = 「重读磁盘台账」+「丢掉内存里那些**一次性**的结束记录」。
        //
        // 为什么必须丢：行上的「安装失败」徽标（`fileRow` 里的 `failText`）来自
        // `finishedJob(for:)` → `IPADownloadCenter.lastFinishedJob`，也就是 `center.jobs`
        // 这条**内存**数组里一条 `phase == .failed` 的记录（`Job.failureStage` 决定显示
        // 「安装失败」还是「下载失败」）。`reload()` 只重读磁盘台账
        // （`IPADownloadLibrary.shared.items()`），**碰不到** `center.jobs` ——
        // 所以旧实现里下拉刷新对「安装失败」徽标毫无作用（用户原话：上滑刷新状态不会刷新，
        // 状态还持久化）。失败是一次性事件，刷新即视为用户已确认、该清掉：
        // 清掉后 `finishedJob(for:)` 返回 nil ⇒ 徽标消失，按钮按台账现算回「安装 / 重装」。
        //
        // 只清「已结束」的记录：`clearFinished()` = `jobs.removeAll { !$0.phase.isBusy }`，
        // 进行中的下载 / 安装（busy）一律不动，不会被这次刷新打断。
        center.clearFinished()
        reload()
        // 0.5s 最短可见时长（刻意，理由见上）.
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    /// 本行当前正在进行的任务（文件名优先；bundleId 只有在列表里唯一时才允许用来认行）
    func activeJob(for item: IPADownloadItem) -> IPADownloadCenter.Job? {
        center.activeJob(fileName: item.fileName,
                         bundleId: item.bundleId,
                         version: item.version,
                         name: item.title,
                         allowBundleIdFallback: !bundleIdIsDuplicated(item))
    }

    /// 本行最近一次结束的任务（判「这一行装失败了」用，口径与 `activeJob(for:)` 一致）
    func finishedJob(for item: IPADownloadItem) -> IPADownloadCenter.Job? {
        center.lastFinishedJob(fileName: item.fileName,
                               bundleId: item.bundleId,
                               version: item.version,
                               name: item.title,
                               allowBundleIdFallback: !bundleIdIsDuplicated(item))
    }

    /// 该行的 bundleId 是否在列表里有多行
    private func bundleIdIsDuplicated(_ item: IPADownloadItem) -> Bool {
        guard let bid = item.bundleId, !bid.isEmpty else { return false }
        return duplicatedBundleIds.contains(bid)
    }

    /// v0.3.396（D 项）：这一行的进度环是不是**在线安装**画出来的。
    ///
    /// 只有它才允许「点一下收掉」：覆盖安装 / 下载中的环背后是下载中心的任务（`activeJob`），
    /// 点一下绝不能把它们悄悄取消 —— 取消有取消自己的入口（左滑删除 / 行内「删除安装包」）。
    func otaRingIsActive(for item: IPADownloadItem) -> Bool {
        otaProgress.isActive && otaProgress.matches(fileName: item.fileName, bundleId: item.bundleId)
    }

    /// v0.3.378：把下载中心任务里记着的**来源直链**回填进台账并落盘。
    /// **v0.3.386 起**该直链是操作面板「**提取下载链接**」的取值（IPA 包原链接）；
    /// 「复制下载链接」另取包内 `iTunesMetadata.itemId`，与本台账无关。
    /// **v0.3.387 起**直链已在下载时（`IPADownloadCenter`）就写台账，这里**只剩幂等兜底**。
    private func syncSourceURLs() {
        for job in center.jobs {
            guard let name = job.localFileName,
                  let url = job.remoteURL, !url.isEmpty else { continue }
            IPADownloadLibrary.shared.updateSourceURL(fileName: name, url: url)
        }
    }

    /// v0.3.387：把「下载中」的任务包成一个**只读条目**喂给操作面板。
    ///
    /// 下载中的任务还没落台账（本地无文件），所以**没有安装时间**，面板里依赖文件的行会置灰
    /// （见 `IPADownloadActionsSheet.isPendingDownload`）。关键是这几个取值把任务上现有的东西
    /// 原样带进去：
    /// · `sourceURL` ← `job.remoteURL`：面板「提取下载链接」读的就是它 → **下载过程也能提取直链**；
    /// · `storeItemId` ← `job.storeItemId`：面板「复制商店链接」**台账优先**，所以下载中就能复制；
    /// · `sizeBytes` ← `job.totalBytes`：下载中已经拿到 `Content-Length` 时，面板头部的体积才是真的。
    /// 文件名用 `job.localFileName ?? job.expectedFileName`（与下载中心落地的名字同源）。
    private func pendingItem(_ job: IPADownloadCenter.Job) -> IPADownloadItem {
        IPADownloadItem(fileName: job.localFileName ?? job.expectedFileName,
                        displayName: job.name,
                        bundleId: job.bundleId,
                        version: job.version,
                        sizeBytes: job.totalBytes,
                        downloadedAt: job.createdAt,
                        iconURL: job.iconURL,
                        source: job.source.rawValue,
                        sourceURL: job.remoteURL,
                        storeItemId: job.storeItemId,
                        packageName: nil,
                        isEncrypted: nil,
                        hasSINF: nil,
                        lastInstalledAt: nil)
    }

    /// v0.3.378：删除一个安装包（文件 + 台账），操作面板调用。
    ///
    /// v0.3.571（一致性修复）：**按实际结果**提示，不再无条件弹「已删除安装包」。
    /// 台账只读（损坏）时删除被拒 —— 文件与台账都没动，此时若还说「已删除」就是**假成功**：
    /// 用户以为删掉了，重进列表条目还在，反而以为是「删除按钮坏了」。
    private func delete(_ item: IPADownloadItem) {
        let result = IPADownloadLibrary.shared.remove(item)
        reload()
        reportRemoval(result)
    }

    /// 按 `remove(fileNames:)` / `remove(_:)` 的实际结果提示 —— 批量删除与单条删除**同一口径**。
    ///
    /// 为什么要检查返回值：删除是「文件 + 台账」两件事，台账只读时两件都做不了。
    /// 旧批量删除代码丢弃了返回值、无条件当成功 ⇒ **假成功**（这正是本 bug 藏很久没被发现的原因）：
    /// 用户以为删了，`reload()` 后条目却原样还在.
    func reportRemoval(_ result: IPADownloadLibrary.RemoveResult) {
        switch result {
        case .removed:
            ToastCenter.shared.show("已删除安装包")
        case .rejectedReadOnly:
            // 说清**原因**与后果，别只丢一句「失败」。
            ToastCenter.shared.show("未删除安装包：下载台账文件损坏，本次改动未保存")
        case .fileRemovalFailed:
            ToastCenter.shared.show("未删除安装包：文件无法删除（可能被占用）")
        }
    }

    /// 补齐列表图标：历史记录没存 `iconURL`，按 bundleId 逐个查 App Store。
    /// 整体串行、同一 bundleId 只查一次（Gmail 有两条记录）、失败静默跳过 ——
    /// 图标只是锦上添花，不能让缺失影响列表渲染。
    @MainActor
    private func loadIcons() async {
        // v0.3.360：查到就**落盘**（`IPADownloadLibrary.updateIconURL`），否则每次进页面都要重发
        // 一轮 lookup。单次最多补 30 条，超出的留到下次，避免条目多时变成请求风暴。
        var queried = Set<String>()
        var budget = 30
        for item in items {
            guard budget > 0 else { break }
            guard item.iconURL == nil else { continue }
            guard let bid = item.bundleId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bid.isEmpty else { continue }
            guard icons[bid] == nil, queried.insert(bid).inserted else { continue }
            budget -= 1
            if let hit = try? await AppStoreService.lookup(bundleId: bid),
               let icon = hit.iconSmallURL ?? hit.iconURL {
                icons[bid] = icon
                IPADownloadLibrary.shared.updateIconURL(fileName: item.fileName, url: icon)
            }
        }
    }

    /// 安装/重装/降级安装 —— 统一交给下载中心（进度统一展示、可取消）
    func install(_ item: IPADownloadItem, downgrade: Bool = false) {
        let filePath = IPADownloadLibrary.shared.path(for: item)
        guard FileManager.default.fileExists(atPath: filePath) else {
            ToastCenter.shared.show("文件不存在：\(item.fileName)")
            // v0.3.383：文件类失败也要落到行上（红字「下载失败」），别只弹个转瞬即逝的 toast
            center.recordFileFailure(fileName: item.fileName, displayName: item.title,
                                     bundleId: item.bundleId, version: item.version,
                                     iconURL: item.iconURL, reason: "文件不存在")
            reload()
            return
        }
        _ = IPADownloadCenter.shared.installLocal(fileName: item.fileName,
                                                 displayName: item.title,
                                                 bundleId: item.bundleId,
                                                 version: item.version,
                                                 iconURL: item.iconURL)
        ToastCenter.shared.show(downgrade ? "正在降级安装…" : "正在安装…")
    }
}
