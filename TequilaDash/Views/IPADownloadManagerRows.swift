// 从 TequilaDash/Views/IPADownloadManagerView.swift 拆出（原文件 1307 行）：下载中任务行 / 已下载条目行 / 来源徽标等行渲染成员体量过大，按职责拆到本文件；纯搬迁、零逻辑改动。

import SwiftUI

extension IPADownloadManagerView {

    // MARK: - 下载中那一行

    /// v0.3.394：**下载中**的行 —— 还没有本地文件（或正在下）。
    ///
    /// 参考图的信息密度：文件名 + 元信息（版本 · 来源 · 时间）+ 进度条 + 「已下/总量 · 速度」。
    /// 点这一行弹操作面板（面板里「覆盖安装 / 在线安装」会置灰 —— 本地还没包，见那张表里的注释）。
    func jobRow(_ job: IPADownloadCenter.Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                jobIcon(job)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name)
                        .font(AppFont.subheadlineEmphasis)
                        .lineLimit(2)
                    // 来源胶囊 + 元信息（版本 · 时间）：来源从灰色小字升级为**有色胶囊**，
                    // 让列表里一眼看出这条来自哪个源（见 `sourceTint` / `sourceBadge`）。
                    HStack(spacing: 6) {
                        sourceBadge(job.source.rawValue)
                        Text(jobMeta(job))
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                Text(job.displayStage)
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isEditing else { return }
                actionJob = job
            }

            // 进度：横向条 + 百分比（等宽数字，跳动时不会左右抖）
            HStack(spacing: 8) {
                ProgressView(value: min(1, max(0, job.overall)))
                    .tint(downloadAccent)
                Text("\(Int((min(1, max(0, job.overall)) * 100).rounded()))%")
                    .font(AppFont.numberSmall)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            // 「70.3 MB/271.7 MB · 3.9 MB/s」—— 分母与速度都没有时整行不出现
            let traffic = jobTraffic(job)
            if !traffic.isEmpty {
                Text(traffic)
                    .font(AppFont.numberSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            jobActions(job)
        }
        .padding(.vertical, 3)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                // 左滑「删除」= 取消这次下载并丢弃半成品；删除被拒（台账只读）/ 文件被占用时
                // 任务行会留下（见 `cancel` 的注释），这里按实际结果提示，不无条件当成功。
                let result = center.cancel(job.id)
                reload()
                if let result { reportRemoval(result) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 「下载中」的元信息：版本 · 时间（参考图的 `v153.8010.24  2026-09-14 12:06:43`）。
    ///
    /// v0.3.587：**来源**从这里移出，改由行内**来源胶囊**承担（`sourceBadge`）——
    /// 灰色小字里的来源扫一眼看不见，提成胶囊才能「区分」。其余（版本 / 时间）不变。
    func jobMeta(_ job: IPADownloadCenter.Job) -> String {
        var parts: [String] = []
        if let v = job.version, !v.isEmpty { parts.append("v\(v)") }
        parts.append(Self.stampFormatter.string(from: job.createdAt))
        return parts.joined(separator: " · ")
    }

    /// 「已下/总量 · 速度」。总量还没拿到（刚起步 / 服务器不给 `Content-Length`）时只显示已下。
    func jobTraffic(_ job: IPADownloadCenter.Job) -> String {
        var parts: [String] = []
        if job.totalBytes > 0 {
            parts.append("\(IPADownloadLibrary.sizeText(job.receivedBytes))"
                         + "/\(IPADownloadLibrary.sizeText(job.totalBytes))")
        } else if job.receivedBytes > 0 {
            parts.append(IPADownloadLibrary.sizeText(job.receivedBytes))
        }
        // 只有真在下载才显示速度：暂停时已清零，这里再判一次阶段，
        // 避免出现「已暂停」旁边还挂着 3.9 MB/s 这种自相矛盾的行。
        if job.phase == .downloading, job.speedBytesPerSecond > 0 {
            parts.append("\(IPADownloadLibrary.sizeText(Int64(job.speedBytesPerSecond)))/s")
        }
        return parts.joined(separator: " · ")
    }

    /// 「下载中」的行内动作：暂停/继续/重试、删除安装包、提取链接
    /// （v0.3.391 起下载过程中就能直接提取直链，不必先进面板）
    ///
    /// v0.3.398（③）：暂停/继续这个按钮改成**三态**。
    ///
    /// 原来只有两态（`paused → 继续`，**其它一律 → 暂停**），于是失败的任务显示成
    /// 「暂停」而且 `.disabled(!job.canPause)`（`canPause` 只认 `downloading`/`paused`）
    /// → 既看不出失败、也点不动，是个**死状态**（用户实测截图 2 就是这样）。
    /// 现在：`.paused → 继续`（可点）、`.downloading → 暂停`（看 `canPause`）、
    /// `.failed → 重试`（可点，走 `center.retry`）、`waiting`/`installing` → 暂停（灰）、
    /// **`.done` → 不显示**（用同宽 `.hidden()` 占位，避免后面两个按钮左右跳）。
    @ViewBuilder
    func jobToggleButton(_ job: IPADownloadCenter.Job) -> some View {
        if job.phase == .failed {
            Button {
                center.retry(job.id)
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(AppFont.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
        } else if job.phase == .done {
            // v0.3.398：已完成的条目不该挂一个灰「暂停」（点不动、也没意义）。
            // 用**同宽占位**（`.hidden()`）而不是直接不渲染 —— 否则后面的「删除安装包」「提取链接」
            // 会往左跳一格，正是用户之前抱怨的「整行图标左右位移」。
            Label("暂停", systemImage: "pause.fill")
                .font(AppFont.caption)
                .hidden()
        } else {
            Button {
                if job.phase == .paused {
                    center.resume(job.id)
                } else {
                    center.pause(job.id)
                }
            } label: {
                Label(job.phase == .paused ? "继续" : "暂停",
                      systemImage: job.phase == .paused ? "play.fill" : "pause.fill")
                    .font(AppFont.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(job.canPause ? Color.blue : Color.secondary)
            .disabled(!job.canPause)
        }
    }

    func jobActions(_ job: IPADownloadCenter.Job) -> some View {
        HStack(spacing: 14) {
            jobToggleButton(job)
            Button {
                // 旧代码无条件弹「已取消并删除该安装包」—— 台账只读 / 文件被占用时**没删成**，
                // 这是假成功。现在按 `cancel` 返回的实际结果提示（口径同 `reportRemoval`）。
                let result = center.cancel(job.id)
                if let result {
                    reportRemoval(result)
                } else {
                    // `nil` = 还没有落地文件（任务还在下载）→ 只是取消，没有删除动作。
                    ToastCenter.shared.show("已取消下载")
                }
            } label: {
                Label("删除安装包", systemImage: "trash")
                    .font(AppFont.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            Spacer(minLength: 0)
            // 还没拿到直链时按钮置灰（例如刚入队、或该来源确实不给直链）
            let hasLink = !(job.remoteURL ?? "").isEmpty
            Button {
                extractLinkOfActiveJob(job)
            } label: {
                Label("提取链接", systemImage: "link")
                    .font(AppFont.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(hasLink ? Color.teal : Color.secondary)
            .disabled(!hasLink)
        }
    }

    @ViewBuilder
    func jobIcon(_ job: IPADownloadCenter.Job) -> some View {
        if let s = job.iconURL ?? icons[job.bundleId ?? ""], let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default: monogram(job.name)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            monogram(job.name)
        }
    }

    // MARK: - 来源标识

    /// 每个**来源**一种颜色 —— 同一套配色同时给「行内来源胶囊」与页脚「来源」图例用，两处不会漂移。
    ///
    /// v0.3.587：来源此前只作为**灰色小字**混在元信息里（`jobMeta` / `subtitle`），扫一眼分不出哪条
    /// 来自哪个源。现把来源提成**行内彩色胶囊**（`sourceBadge`），让「区分」一眼可见。
    ///
    /// v0.3.588：各入口改成**只列自己的来源**（见 `filterSource`），胶囊仍**保留** —— 多来源入口
    /// （爱思免登录商店 = 爱思 / 牛蛙 / NB）靠它区分，单来源入口靠它一眼确认，并让行上的颜色
    /// 对得回页脚图例。
    ///
    /// 入参是 `source.rawValue` 口径的字符串：任务行传 `job.source.rawValue`，台账行传 `item.source`
    /// （台账侧是字符串、不是枚举，见 `IPADownloadItem.source`）。同一函数 ⇒ 两侧口径一致。
    /// 非枚举占位来源（「来源未知」/「本地」，见 `IPADownloadLibrary`）与任何未知值统一回落次级色。
    func sourceTint(_ raw: String) -> Color {
        if raw == IPADownloadCenter.Source.i4Free.rawValue { return .blue }
        if raw == IPADownloadCenter.Source.niuwa.rawValue { return .orange }
        if raw == IPADownloadCenter.Source.nb.rawValue { return .indigo }
        if raw == IPADownloadCenter.Source.thirdPartySource.rawValue { return .purple }
        // Apple ID / 来源未知 / 本地 / 任何未知值 —— 中性次级色（不抢眼，但仍在场）。
        return .secondary
    }

    /// 行内**来源胶囊** —— 复用既有 `PackageChip`（与本页版本 / 体积胶囊同款画法），
    /// 只是把来源从「灰色小字」升级成「有色胶囊」，让列表里每条都能一眼看出所属来源。
    func sourceBadge(_ raw: String) -> some View {
        PackageChip(text: raw, tint: sourceTint(raw), horizontalPadding: 5)
    }

    // MARK: - 已下载条目那一行

    /// v0.3.394：台账里的**已下载条目**行。原来挂在「已下载」分组下，现在与下载中的任务同列一个列表。
    func fileRow(_ item: IPADownloadItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // 点击区只覆盖「图标 + 文字」，右侧安装按钮各管各的，避免手势互相抢。
            // v0.3.378：点这里弹出操作面板（编辑模式下点行是勾选，不弹）。
            HStack(alignment: .center, spacing: 12) {
                iconView(item)

                // 三行信息：标题 / 版本 + 体积 + 包类型 / 来源与时间。
                // 版本、体积两个胶囊固定单行（`.fixedSize()`），其余文字一律「换行、不截断」：
                // 用户明确要求「可以换行显示但不能显示不全」。
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(AppFont.subheadlineEmphasis)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let v = item.version { PackageChip(text: "v\(v)", tint: .blue) }
                        PackageChip(text: item.sizeText, tint: .green)
                    }
                    // v0.3.363：包类型从胶囊同行里挪到**独立一行**。
                    // 原来和两个胶囊挤同一个 HStack，空间不够时被压成竖排窄列
                    // （真机截图里「加密 / 包 · / 带 / sinf」一列一个字的那个别扭样式）。
                    Text(item.kindText)
                        .font(AppFont.caption)
                        .foregroundStyle(kindTint(item))
                        .fixedSize(horizontal: false, vertical: true)
                    // 来源胶囊 + 副信息（bundleId · 时间 · 已安装）：与任务行同一种「来源可见」口径，
                    // 让列表里每条都能一眼看出所属来源（见 `sourceTint` / `sourceBadge`）。
                    HStack(spacing: 6) {
                        sourceBadge(item.source)
                        Text(subtitle(item))
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isEditing else { return }
                actionItem = item
            }

            // v0.3.381：按**文件名（含版本）**判本行的进行中状态 —— 只按 bundleId 会让
            // 同一应用的多版本条目一起显示「安装中」（用户实测 BUG）。
            // v0.3.388：把原来那条 44pt 横向进度条换成**圆形进度环 + 百分比**（覆盖安装与在线安装都有），
            // 高度仍是 44pt，不动行高、不挤掉右侧信息。
            if let progress = rowProgress(item) {
                let isOTA = otaRingIsActive(for: item)
                HStack(spacing: 8) {
                    InstallProgressRing(fraction: progress.fraction)
                    Text(progress.text)
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .fixedSize()
                .contentShape(Rectangle())
                // v0.3.396（D 项）：在线安装的环**点一下即收掉** —— 系统安装阶段 App 观测不到，
                // 一直转下去只是「卡住」的错觉。没有说明文字、没有额外按钮，点环本身就是那个动作。
                // 只有环**确实是 OTA 画出来的**才接这个手势（见 `otaRingIsActive`）：
                // 覆盖安装 / 下载中的环背后是下载中心的真任务，点一下绝不能把它们悄悄取消。
                //
                // ▸▸▸ v0.3.583（用户截图 IMG_6737）：**覆盖安装的环以前点了完全没反应**。
                // 旧手势只处理 `isOTA`；而「全能签」这类本地包走的是 RSD 覆盖安装
                // （`IPADownloadCenter.installLocal` → `installLocalIPA`），环由下载中心的
                // `.installing` 任务画出，`isOTA == false` ⇒ 点下去什么都不发生（用户抱怨的那一下）。
                //
                // 底层**无法取消安装**，所以这里**不假装能取消**，只把事实说清楚 ——
                // 依据：`AppStoreInstallService.installLocalIPA` 是**同步阻塞**的
                // （`IPAInstallService` 的 AFC 上传 `uploadFile` 逐块写 + installd 的
                // `Install`/`Upgrade` 命令），全程不检查 `Task.isCancelled`，也没有任何中止接口；
                // 一旦提交给 installd 就停不下来。故点击 = 一句明确说明（至少「有反应」且不撒谎）。
                .onTapGesture {
                    if isOTA {
                        otaProgress.reset()
                    } else if activeJob(for: item)?.phase == .installing {
                        ToastCenter.shared.show("安装已提交给系统，无法中止.")
                    }
                }
            } else {
                // v0.3.383：这一行上一次失败 → 红字标出**失败阶段**，**仍可点**（点了就是重试）。
                // 「下载失败」（文件可能不完整/不存在）与「安装失败」（文件是好的、卡在安装环节）
                // 对用户是两件事，不能都报「安装失败」——错标比不标更糟。
                // 不再静默变回「重装」按钮：用户点了安装、什么都没发生、按钮又变回去，他根本不知道失败了。
                //
                // 状态来源：这条失败记录活在 `IPADownloadCenter.jobs`（**内存**，`@Published`）里，
                // 不是磁盘台账字段（`IPADownloadItem` 没有失败字段）。它随进程存活，下拉刷新会
                // 清掉它（见 `refresh()`），所以徽标不会长期挂着 —— 用户不会一直以为「现在还是坏的」。
                let last = finishedJob(for: item)
                // 这不是「状态行文案」，而是「失败**阶段**徽标」：`displayStage` 对 `.failed` 只透出
                // `stageText`（「失败 / 文件不存在 / 未找到安装包 / 删除失败」），**给不出**「哪一段失败」；
                // 换成 `displayStage` 会把「下载失败 / 安装失败」这个区分丢掉（错标比不标更糟）。
                // 故**有意**保留按 `failureStage` 取，并在本行登记防复发脚本豁免（行内抑制 + 脚本 ALLOW 表）。
                let failText: String? = last?.phase == .failed
                    ? (last?.failureStage == .download ? "下载失败" : "安装失败")   // state-guard: allow
                    : nil
                let isFailed = failText != nil
                Button {
                    install(item)
                } label: {
                    Text(failText ?? (item.lastInstalledAt == nil ? "安装" : "重装"))
                        .font(AppFont.captionEmphasis)
                        .lineLimit(1)
                        .frame(minWidth: 40)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background((isFailed ? Color.red : Color.blue).opacity(0.14), in: Capsule())
                        .foregroundStyle(isFailed ? Color.red : Color.blue)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(.vertical, 3)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                // 左滑删除同样必须**看返回值**：台账只读（损坏）/ 文件被占用时删除会失败，
                // 旧代码丢弃了 `remove(_:)` 的返回值、无条件当成功 —— 用户以为删了，
                // `reload()` 后条目原样还在，只会以为「删除按钮坏了」。口径与 `delete(_:)` 一致。
                let result = IPADownloadLibrary.shared.remove(item)
                reload()
                reportRemoval(result)
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                install(item, downgrade: true)
            } label: {
                Label("降级安装", systemImage: "arrow.down.circle")
            }
            .tint(.orange)
        }
        // 长按安装包 → 「查看图标 / 提取图标」。菜单项与该行 `iconView` 用**同一个**图标地址；
        // 没有图标（地址为空）时整组置灰，不让用户点下去才发现没图可看.
        // 「保存图标」不在这里：进预览后长按图片即可（`ImageGalleryViewer` 自带），不重复一份.
        .contextMenu {
            let iconURL = item.iconURL ?? icons[item.bundleId ?? ""]
            // 取图日志按包的来源分板：三方软件源 ⇒ 「软件源」，其余 ⇒ 「下载」。
            // 该图标在「下载管理」里被查看，以前取图失败落「通用」、与来源无关（用户实测指正）。
            let iconLogCategory = logCategory(forSource: item.source)
            iconMenuItems(iconURL: iconURL,
                          fileNameBase: item.bundleId ?? item.title,
                          logCategory: iconLogCategory) {
                showIconPreview(iconURL, target: $previewTarget, logCategory: iconLogCategory)
            }
            .disabled((iconURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    func iconView(_ item: IPADownloadItem) -> some View {
        // 优先用记录里持久化的 iconURL，其次用按 bundleId 查回来的 icons 表。
        if let s = item.iconURL ?? icons[item.bundleId ?? ""], let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default: monogram(item.title.isEmpty ? (item.bundleId ?? "") : item.title)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            monogram(item.title.isEmpty ? (item.bundleId ?? "") : item.title)
        }
    }

    /// 没有图标时的首字母方块（参考 `PurchaseHistoryView.monogram`）：
    /// 虚框看着像「加载失败」，字母块看着是有意设计。
    /// v0.3.394：入参从 `IPADownloadItem` 改成**名称**，好让「下载中」那一行也能复用。
    func monogram(_ name: String) -> some View {
        let letter = String(name.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(AppTheme.accent.opacity(0.14))
            Text(letter.isEmpty ? "?" : letter)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
        }
        .frame(width: 48, height: 48)
    }

    /// v0.3.576 这里曾是本页私有 `static let dateFormatter`（缓存一次、复用 N 次）。
    /// 上一轮收敛到共享 `DateText` 时，`DateText` 的 formatter 是「按需构造」⇒ 一度变成**每行新建**，
    /// 是相对 v0.3.576 的**回退**（诊断 §2 表 #4）。
    /// `DateText` 现已把 formatter 改回**缓存**（`Engine/DateText.swift` 的 `nonisolated(unsafe) static let`）
    /// ⇒ 这里**保留** `DateText` 即可：性能与旧 `static let` **等价**（都是一次构造、N 次复用），
    /// 又保持全 App 日期口径单一。**无需**退回本页私有 formatter（那会重新引入一份可能漂移的 `MM-dd HH:mm`）。
    /// 口径：旧私有 formatter 未设 locale（设备默认），`DateText` 用 `en_US_POSIX`；纯数字格式两者输出一致，
    /// 后者更稳定。
    /// v0.3.587：**来源**从这里移出，改由行内**来源胶囊**承担（`sourceBadge`）——
    /// 灰色小字里的来源扫一眼看不见，提成胶囊才能「区分」。其余（bundleId / 时间 / 已安装）不变。
    func subtitle(_ item: IPADownloadItem) -> String {
        var parts: [String] = []
        if let b = item.bundleId, !b.isEmpty { parts.append(b) }
        parts.append(DateText.string(from: item.downloadedAt))
        if let t = item.lastInstalledAt {
            parts.append("已安装 \(DateText.string(from: t))")
        }
        return parts.joined(separator: " · ")
    }

    /// 包类型只在「有风险」时着色：缺 sinf 的加密包装不上，必须显眼。
    /// v0.3.568：`sinf 异常`（有 sinf 但结构写坏了）同样装不上，一并着色。
    func kindTint(_ item: IPADownloadItem) -> Color {
        guard item.isEncrypted == true else { return .secondary }
        return (item.hasSINF != true || item.sinfStructurallyValid == false) ? .orange : .secondary
    }

    /// 图例的一行：标签原文按列表里的着色，下面一句人话解释.
    func guideRow(_ label: String, _ tint: Color, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(AppFont.captionEmphasis)
                .foregroundStyle(tint)
            Text(detail)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// v0.3.388：这一行要不要显示**安装/下载进度环**，以及环里的分数（nil = 不确定态）与右侧文字。
    ///
    /// 两个来源，按「谁在动这一行」优先：
    /// 1. **在线安装（OTA）**：分数 = 本机服务器**已经发给系统的字节 / 包大小**（真实测量值）；
    ///    包发完 → `fraction = nil` → 转圈：**系统安装阶段 App 看不到任何进度**，
    ///    宁可转圈也不显示假百分比。
    /// 2. **覆盖安装 / 下载中**：用下载中心任务的 `overall`（链路 0~1，见 `Job.overall`）。
    ///    只有「排队等待」阶段是未开始，显示不确定态。
    func rowProgress(_ item: IPADownloadItem) -> (fraction: Double?, text: String)? {
        if otaRingIsActive(for: item) {
            switch otaProgress.stage {
            case .transferring: return (otaProgress.fraction, "在线安装")
            case .installing: return (nil, "安装中")
            case .idle: break
            }
        }
        guard let job = activeJob(for: item) else { return nil }
        // 阶段文案统一取 `job.displayStage`（唯一真源）—— 不再按 `phase` 各自拼「已暂停」/ `stageText`。
        // 这里只区分**进度是否已知**：`.waiting` 尚未开始 → 环走不确定态（`nil`），其余按 `overall`。
        switch job.phase {
        case .waiting: return (nil, job.displayStage)
        default: return (job.overall, job.displayStage)
        }
    }
}
