import Foundation

/// 设备瘦身 —— 爱思助手 8.0「设备瘦身」功能移植（主页板块）.
///
/// ## 口径来源（逆向 `C:\Program Files\i4Tools8`，2026-09-11）
/// · **空间占用 7 项** = `idm_info.dll` 的 `ios_get_detailed_disk_usage` →
///   lockdown 域 `com.apple.disk_usage`（系统 = `TotalSystemCapacity`、
///   总量 = `TotalDiskCapacity`、剩余 = `AmountRestoreAvailable` 类），
///   再叠加「应用」（instproxy `StaticDiskUsage` 求和）/「照片」/「音视频」/「U盘」。
///   真机校验：系统 7.85 GB、应用 23.98~24 GB 与爱思面板一致；「其他」为余量口径。
/// · **清理分组** = 系统缓存文件 / 用户日志 / 其他临时文件 / 较大应用（> 500 MB）。
/// · **较大应用**（爱思真机截图）：表格「应用名称 / 应用大小 / 文档大小 / 操作」，
///   勾选 = 重装（清掉文稿与数据）；`(资源缺失无法重装)` = 本地没有可重装的包。
///   设备侧旁证 `/iTunes_Control/iTunes/stopremovewhitelist.acc` 的
///   `bundleIds = [com.ownbook.notes, rn.notes.best]` 说明它会重装第三方 App 但放行自家移动端。
///
/// ## 性能（v0.3.314 重写）
/// 之前一次进入要遍历媒体分区 **三遍**（空间占用 + 缓存项 + 日志），而 AFC 的
/// `listDirectory` 对每个条目都要单独 `afc_get_file_info`（≈2 万次往返）→ 慢。
/// 现改为**单次遍历**同时算出全部所需数值，并把结果**落盘缓存**（含时间戳），
/// 再次进入秒开；只有点「重新扫描」才真正重走。
///
/// ## 可达面（免越狱，iOS 27 实测）
/// AFC 根 = `/var/mobile/Media`；`house_arrest` 的 `VendContainer` 在 iOS 27 被拒、
/// `VendDocuments` 只到各 App 的 `Documents`；`/var/mobile/Library/Logs` 不可达。
/// → 只清理媒体分区内**可再生**的缓存/缩略图，白名单之外一律不碰。
enum DeviceSlimService {

    // MARK: - 空间占用

    struct UsageSlice: Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        let colorHex: UInt32
    }

    struct SpaceUsage {
        var total: Int64 = 0
        var free: Int64 = 0
        var deviceName: String = ""
        var capacityText: String = ""
        var slices: [UsageSlice] = []
        var scannedAt: Date?
        /// v0.3.673：本组数字**不完整**的原因（nil = 完整）.
        /// 旧实现把「应用大小只量到一部分」「扫描时有目录读不出」全部折叠成
        /// 与完整结果完全相同的形状，界面无从区分「真的就这么小」与「没量到」.
        var incompleteReason: String?

        var used: Int64 { max(0, total - free) }
    }

    // MARK: - 可清理项

    enum GroupKind: String, CaseIterable, Identifiable {
        case systemCache = "系统缓存文件"
        case userLog = "用户日志"
        case tempFiles = "其他临时文件"
        case bigApps = "较大应用"

        var id: String { rawValue }

        var subtitle: String {
            switch self {
            case .systemCache, .tempFiles: return "删除冗余的系统、用户"
            case .userLog: return "日志文件及过期的临时文件"
            case .bigApps: return "通过批量重装应用"
            }
        }

        /// 「较大应用」用重装（不是勾选删除），所以不走「可释放空间」统计
        var selectable: Bool { self != .bigApps }

        var icon: String {
            switch self {
            case .systemCache: return "internaldrive.fill"
            case .userLog: return "doc.text.fill"
            case .tempFiles: return "clock.arrow.circlepath"
            case .bigApps: return "app.badge.fill"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id: String          // 缓存项 = 设备路径；较大应用 = bundleId
        let name: String
        let detail: String?
        let bytes: Int64        // 缓存项 = 占用；较大应用 = 合计（应用+文档）
        let kind: GroupKind
        let deletable: Bool
        // 较大应用专用
        var appSize: Int64 = 0
        var docSize: Int64 = 0
        var version: String = ""
        var ipaFileName: String?   // 免登录下载库里已有的包（nil = 本地没有）
        /// 免登录源里能不能下到（nil = 还没探测）—— 恢复爱思的「资源缺失无法重装」判定
        var sourceAvailable: Bool? = nil
        var isRisky: Bool = false  // 聊天类：重装会丢聊天记录
    }

    struct Group: Identifiable {
        let kind: GroupKind
        var items: [Item]
        var id: String { kind.rawValue }
        var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    struct CleanResult {
        var freed: Int64 = 0
        var deleted: Int = 0
        var failures: [String] = []
        /// 删除成功、但**删之前没能计量**的条目数.
        ///
        /// v0.3.661：这些条目的字节数既不是 0 也无法得知，不能并入 `freed`
        /// （否则页面会显示「已释放 0 字节」而文件其实删掉了，用户会反复重试）。
        /// 页面应单独说明「其中 N 项未能统计大小」。
        var unmeasured: Int = 0
    }

    struct ReinstallResult {
        var ok: [String] = []
        var failures: [String] = []
    }

    /// 重装阶段（进度条文案）
    enum ReinstallStage: String {
        case locating = "查找安装包"
        case downloading = "下载中"
        case installing = "安装中"
    }

    /// 重装进度（index 从 1 开始）
    struct ReinstallProgress {
        let index: Int
        let total: Int
        let name: String
        let stage: ReinstallStage
        let fraction: Double    // 当前这一个的整体进度 0~1
    }

    // MARK: - 白名单与常量

    static let pathPhotoThumbnails = "/PhotoData/Thumbnails"
    static let pathPhotoCaches = "/PhotoData/Caches"
    static let pathSharedAlbumCaches = "/PhotoData/PhotoCloudSharingData/Caches"

    /// 系统缓存文件 = 可再生缓存目录。
    /// `/Downloads` 是 Safari 的下载记录数据库（`downloads.28.sqlitedb` + `-wal`/`-shm`），
    /// 体积随 WAL 波动（实测 369.25 KiB，爱思面板曾显示 361.20 KB）——爱思的清理项里也有它。
    static var systemCachePaths: [(String, String)] {
        [(pathPhotoThumbnails, "照片缩略图"),
         (pathPhotoCaches, "照片库缓存"),
         (pathSharedAlbumCaches, "共享相簿缓存"),
         ("/Downloads", "下载记录缓存")]
    }

    static let tempPaths: [(String, String)] = [
        ("/Deferred", "延迟处理暂存"),
        ("/Sync", "同步中转暂存"),
        ("/PublicStaging", "公共暂存区"),
        ("/Airlock", "隔空投送暂存"),
    ]

    static let bigAppThreshold: Int64 = 500 * 1024 * 1024

    /// 重装会丢聊天记录的 App（爱思标注「谨慎选择」）
    static let riskyBundleIds: Set<String> = [
        "com.tencent.xin", "com.tencent.mqq", "com.tencent.tim", "com.tencent.ww",
    ]

    static let photoDirs = ["/DCIM", "/PhotoData"]
    static let mediaDirs = ["/Music", "/Radio", "/Recordings"]
    static let usbDir = "/虚拟U盘"

    private static let logPattern = ["log", "ips", "crash", "diag", "panic"]

    /// 需要单独统计的子路径（缓存项 / 临时项）
    private static var watchedSubpaths: [String] {
        systemCachePaths.map(\.0) + tempPaths.map(\.0)
    }

    // MARK: - 格式化（对齐爱思：二进制单位、两位小数）

    static func formatBytes(_ bytes: Int64) -> String {
        let b = Double(max(0, bytes))
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        if b >= gb { return String(format: "%.2f GB", b / gb) }
        if b >= mb { return String(format: "%.2f MB", b / mb) }
        if b >= kb { return String(format: "%.2f KB", b / kb) }
        return String(format: "%.2f B", b)
    }

    // MARK: - 快照（单次遍历 + 落盘缓存）

    struct Snapshot: Codable {
        var totals: [String: Int64] = [:]     // 路径 → 字节
        var fileCounts: [String: Int] = [:]
        var logs: [LogHit] = []
        var takenAt: Date = .distantPast
        /// v0.3.673：**读不出来的子树**. 旧实现在 DFS 里 `try? listDirectory` 失败
        /// 就 `continue`，被跳过的整棵子树既不计入 totals、也不留任何痕迹 ——
        /// 快照随后被缓存 10 分钟，于是「空间占用」各分片与可清理项列表都按
        /// 「这就是全部」呈现，用户看到的是一个偏小却毫无标注的数字.
        /// 现在把读不出的目录记下来：扫描结果可以被明确标成「不完整」.
        /// 用 Optional 是为了让旧版本写下的缓存文件仍能解码（缺键 = nil）.
        var unreadablePaths: [String]? = nil

        /// v0.3.694：**因为触顶而被跳过的目录数**. 与 `unreadablePaths` 区分开：
        /// 那些是「读不出」，这里是「能读但按上限没读」，两者的界面提示与对策不同.
        /// 同样用 Optional，让旧版本写下的缓存文件仍能解码（缺键 = nil）.
        var limitSkippedDirectories: Int? = nil
    }

    struct LogHit: Codable { var path: String; var bytes: Int64 }

    private static var snapshotURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/device_slim_snapshot.json")
    }

    /// v0.3.673：作废磁盘快照（删除失败不再静默吞掉）.
    ///
    /// 为什么要单独一个函数：旧实现两处都写 `try? FileManager.default.removeItem`，
    /// 删不掉时缓存文件仍然有效，下一次 `cachedSnapshot()` 会把刚刚被清理掉的项
    /// 原样再列一遍 —— 「删了还在这里」. 现在失败要写日志，至少可回溯.
    private static func invalidateSnapshot(reason: String) {
        do {
            try FileManager.default.removeItem(at: snapshotURL)
        } catch {
            // 文件本来就不存在 = 正常（没有缓存可作废），不算失败.
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSFileNoSuchFileError { return }
            LoginLogger.shared.log(
                "[设备瘦身] \(reason)：作废快照缓存失败（下次进页面可能仍显示旧数据）："
                + "\(error.localizedDescription)"
            )
        }
    }

    /// 读缓存快照；`maxAge` 秒内视为新鲜（默认 10 分钟）
    static func cachedSnapshot(maxAge: TimeInterval = 600) -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snap = try? decoder.decode(Snapshot.self, from: data) else {
            // v0.3.673：**坏缓存要清掉**. 旧写法 `try?` 解不开就返回 nil，
            // 文件却永远留在原地 —— 每次进页面都重试同一份坏 JSON，白付一次读盘，
            // 且没有任何线索. 删掉它，让下一次 buildSnapshot 写一份新的.
            invalidateSnapshot(reason: "缓存解码失败")
            return nil
        }
        guard Date().timeIntervalSince(snap.takenAt) <= maxAge else { return nil }
        return snap
    }

    /// v0.3.694：**扫描上限**（防性能悬崖）. 本函数从 "/" 穷举，每访问一个目录就是
    /// 一次 AFCService.listDirectory —— 设备上目录上万时会把 AFC 通道长时间占满，
    /// 「设备瘦身」页一直转圈，别的功能也拿不到通道；而旧实现**没有任何上限**，
    /// 顶不顶得住完全取决于设备实际目录数（事先不可知）.
    /// 现在给「已展开目录数」和「深度」各设一个远高于真实用量、但能兜住的硬上限；
    /// 触顶不静默截断，而是记数并让界面标注「本轮数字只是下界」.
    private static let snapshotMaxDepth = 64
    private static let snapshotMaxDirectories = 20_000

    /// **单次遍历**媒体分区：同时算出空间占用各分区、缓存项、临时项、日志项.
    static func buildSnapshot(progress: ((String) -> Void)? = nil) throws -> Snapshot {
        var snap = Snapshot()
        let watched = watchedSubpaths
        let firstLevels = Set(photoDirs + mediaDirs + [usbDir])
        var logs: [LogHit] = []
        var budget = 0
        // v0.3.673：读不出的子树（见 Snapshot.unreadablePaths）.
        var unreadable: [String] = []
        // v0.3.694：因为触顶被跳过的目录数（见 Snapshot.limitSkippedDirectories）.
        var limitSkipped = 0

        progress?("正在扫描设备文件…")
        try AFCService.shared.batch { client in
            // 迭代式 DFS（显式栈，避免深递归）
            var stack: [(path: String, depth: Int)] = [("/", 0)]
            // v0.3.694：已展开（listDirectory 过）的目录数，用于兜住性能悬崖.
            var listedDirectories = 0
            while let node = stack.popLast() {
                // v0.3.694：先查上限再干活 —— 触顶立即收工，栈里没展开的一并计成跳过.
                guard listedDirectories < Self.snapshotMaxDirectories else {
                    limitSkipped += stack.count + 1
                    LoginLogger.shared.log(
                        "[设备瘦身] 目录数触顶（上限 \(Self.snapshotMaxDirectories) 个），"
                        + "本轮数字只是下界，停止下探."
                    )
                    break
                }
                // v0.3.673：**读不出就记下来**，不再静默跳过.
                // 旧写法 `try? … else { continue }` 让整棵子树凭空消失，
                // 而本函数的结果会被缓存 10 分钟并驱动所有分片数字.
                let entries: [AFCService.Entry]
                do {
                    entries = try AFCService.listDirectory(client: client, path: node.path)
                } catch {
                    unreadable.append(node.path)
                    if unreadable.count <= 5 {
                        LoginLogger.shared.log(
                            "[设备瘦身] 目录读不出（该子树未计入，统计会偏小）：\(node.path)"
                            + " — \(error.localizedDescription)"
                        )
                    }
                    continue
                }
                listedDirectories += 1
                budget += entries.count
                for entry in entries {
                    let p = entry.path
                    if entry.isDirectory {
                        // 目录自身不累加；继续下探（全部下探——数值要准）
                        // v0.3.694：深度触顶就不再入栈（超深目录树是性能悬崖的另一半）.
                        if node.depth + 1 > Self.snapshotMaxDepth {
                            limitSkipped += 1
                            continue
                        }
                        stack.append((p, node.depth + 1))
                        continue
                    }
                    let size = entry.size
                    snap.fileCounts["/*"] = (snap.fileCounts["/*"] ?? 0) + 1
                    // 一级目录
                    let comps = p.split(separator: "/", omittingEmptySubsequences: true)
                    if let first = comps.first {
                        let key = "/" + first
                        snap.totals[key] = (snap.totals[key] ?? 0) + size
                        if firstLevels.contains(key) {
                            snap.fileCounts[key] = (snap.fileCounts[key] ?? 0) + 1
                        }
                    }
                    // 关注的子路径（缓存/临时）
                    for w in watched where p.hasPrefix(w + "/") {
                        snap.totals[w] = (snap.totals[w] ?? 0) + size
                        snap.fileCounts[w] = (snap.fileCounts[w] ?? 0) + 1
                    }
                    // 日志类文件（只扫非照片内容区，控量）
                    if logs.count < 60, budget < 60000,
                       !p.hasPrefix("/DCIM/"), !p.hasPrefix("/PhotoData/") {
                        let lower = entry.name.lowercased()
                        if logPattern.contains(where: { lower.contains($0) }) {
                            logs.append(LogHit(path: p, bytes: size))
                        }
                    }
                }
            }
        }
        logs.sort { $0.bytes > $1.bytes }
        snap.logs = Array(logs.prefix(40))
        snap.unreadablePaths = unreadable.isEmpty ? nil : unreadable
        snap.limitSkippedDirectories = limitSkipped > 0 ? limitSkipped : nil
        // v0.3.694：触顶只在日志里说是不够的 —— 用户看不到「数字偏小」，
        // 所以 usage()/scan() 也会把它带成「不完整」提示（见下）.
        if limitSkipped > 0 {
            LoginLogger.shared.log(
                "[设备瘦身] 扫描触顶（本轮数字只是下界）：目录数上限 \(Self.snapshotMaxDirectories) 个 / "
                + "深度上限 \(Self.snapshotMaxDepth) 层，另有 \(limitSkipped) 个目录未展开."
            )
        }
        snap.takenAt = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // v0.3.673：**缓存写失败不再静默**. 旧写法 `if let data = try? encode { try? write }`
        // 把编码/写盘两处失败都吞掉 —— 页面照常显示数字，用户以为快照是最新的，
        // 下一次进页面又读到上一次的旧快照. 现在写不进去就留日志（不中断扫描，
        // 本轮数字仍然可用，只是没有缓存）.
        do {
            let data = try encoder.encode(snap)
            try data.write(to: snapshotURL)
        } catch {
            LoginLogger.shared.log("[设备瘦身] 快照缓存写入失败（本轮数字仍可用，下次需重扫）：\(error.localizedDescription)")
        }
        return snap
    }

    // MARK: - 应用列表读取（快路径 + 可选大小增强）

    /// 一次应用读取的结果.
    struct AppReadResult {
        var apps: [FileSharingApp] = []
        /// 快路径（`get_apps`）是否拿到数据 —— false = 真拿不到，页面应显示错误态 + 重试
        var usable = false
        /// **是否真的拿到了可用的大小**（v0.3.401 起不再看「增强回填了几条」）——
        /// false = 没有精确大小，只能按可得信息出数据（「应用」分片会偏小、
        /// 「较大应用」判不出「> 500MB」），页面据此提示「应用大小不可用」.
        /// 背景：带属性 Lookup 已把大小字段移出请求（为解决它卡 ~25 秒的回归），
        /// 而 iOS 侧**没有 AFC 等价通道**能补应用大小（house_arrest 只到数据容器）.
        var sizeComplete = false
        /// 快路径失败的真实原因（`usable == false` 时才有值）.
        ///
        /// v0.3.661：原来 `.failed(message)` 与 `.timedOut` 都是「usable=false」，
        /// 页面统一显示「应用读取超时」+ 重试。但两者自救动作完全不同：
        ///   · 超时 → 等一会儿重试**有意义**；
        ///   · 没配对文件 / LocalDevVPN 没连 / house_arrest 未授权 → 重试 100 次也不会成功，
        ///     用户得去修配对或连 VPN。折成同一句会把人的动作引错。
        var failureReason: String? = nil
    }

    /// v0.3.378：设备瘦身页读取已装应用（空间占用的「应用」分片 / 「较大应用」分组）.
    ///
    /// 改成「快路径 + 可选增强」（真机 16:30 日志的教训：原先直接等带属性 Lookup →
    /// 每轮都「应用列表读取超时，本轮按空处理」→「应用」分片恒 0、「较大应用」恒空，
    /// 用户看到的是「功能坏了」）：
    ///   1. **快路径 `get_apps`**（真机 333 应用 2.5 秒级）→ 保证一定有应用列表；
    ///   2. **可选增强**（带属性 Lookup，独立 15 秒；v0.3.379 由 8 秒提到 15——后台可选、
    ///      不阻塞首屏，且单飞保证同一时刻只有一条在飞）→ 补 appSize/docSize，
    ///      「应用」分片与「较大应用」才有意义；失败就退化为「没有精确大小」；
    ///   3. **结果缓存 30 秒**：`loadUsage` 与 `bigApps` 在同一轮页面加载里共用一份，
    ///      不再重复开隧道；
    ///   4. 只有**快路径也失败**时才回空数组，并置问题文案 → 页面显示
    ///      「应用读取超时」+ 重试，**不显示成静默空列表**.
    /// 注意：大小的可得性分两种（v0.3.406 起）——
    ///   - **应用大小** `appSize`：只能来自第 2 步的带属性 Lookup（`StaticDiskUsage`，
    ///     v0.3.406 加回请求；`get_apps` 从来不带）。取不到时「应用」分片与「较大应用」
    ///     会退化，页面必须明确提示「应用大小不可用」（判据见 sizeComplete）.
    ///   - **文档大小** `docSize`（`DynamicDiskUsage`）：**不再从请求里拿**（疑为「带属性 Lookup
    ///     卡 ~25 秒」的元凶，见 FileSharingService / installation_proxy.rs 注释）——
    ///     v0.3.408 起改走**本机通道**按需量：`containerPath`（`Container` 键；v0.3.600 起
    ///     带属性 Lookup 也返回，见 `FileSharingApp.containerPath`）
    ///     + `SandboxEscape` + `FileService.countTree`，与「空间回收」页同一套，
    ///     每轮后台补一批、跨轮累积。落地与代价见 `startDocSizePass`.
    private static func readAppsForSlim() -> AppReadResult {
        appReadLock.lock()
        if let cache = appReadCache, Date().timeIntervalSince(cache.at) < 30 {
            let cached = cache.result
            appReadLock.unlock()
            return cached
        }
        appReadLock.unlock()

        var result = AppReadResult()
        // ① 快路径：**带属性 Lookup**（额度 ≥ 10s 时 `listAppsWithFileSharing(timeout:)` 的主路径
        //    就是它，失败/超时才降级 `get_apps`；见 FileSharingService
        //    `listAppsWithAttributesWithFallback`）。它同时给出 `appSize`（StaticDiskUsage）
        //    与 `containerPath`（Container，v0.3.600 起）—— 后者是下面文档大小通道的入口，
        //    所以这一条命令必须能拿到 `Container`，否则 docSize 恒 0（v0.3.600 修的正是它）.
        switch FileSharingService.listAppsWithFileSharing(timeout: 20) {
        case .ok(let found):
            result.apps = found
            // v0.3.666：`usable` 的判据是「**读到了**」，不是「读到非空」.
            //
            // `.ok` 只会在 `try work()` 真的成功时出现（见 FileSharingService
            // :630-634 / :223-268，降级链全失败是抛错走 `.failed`），所以空数组
            // 意味着设备上**确实一个应用都没有** —— 那是事实，不是失败.
            // 旧判据 `usable = !found.isEmpty` 把它归进「不可用」，而 `.ok` 分支
            // 又不设 failureReason，于是 :402-404 落到「原因未知」，等于把
            // 「真的 0 条」折成「读失败，原因不明」，与本次修复的判据正好相反.
            result.usable = true
            LoginLogger.shared.log("[设备瘦身] 快路径（带属性 Lookup → get_apps 降级）：\(found.count) 条")
        case .failed(let message):
            LoginLogger.shared.log("[设备瘦身] 快路径失败：\(message)")
            // v0.3.661：**留住真实原因**，页面据此给不同的自救方向（见 AppReadResult.failureReason）.
            result.failureReason = message.trimmingCharacters(in: .whitespacesAndNewlines)
        case .timedOut:
            LoginLogger.shared.log("[设备瘦身] 快路径超时（排队与执行分开计）")
            result.failureReason = "超时"
        }
        // ①' v0.3.408：拿到列表就**立刻**发起「文档大小」（本机通道）——它要真的把每个应用
        //     的容器文件树走一遍，所以放在这里与后面（最长 15 秒的带属性 Lookup + 空间快照）
        //     **重叠**，不额外占首屏时间；`bigApps()` 取到什么算什么，见 `startDocSizePass`.
        startDocSizePass(result.apps)
        // ② 可选增强：带属性 Lookup（独立 15 秒、失败就不补；额度见 lookupAppAttributes 默认参数）
        let enhanced = FileSharingService.lookupAppAttributes()
        if enhanced.isEmpty {
            LoginLogger.shared.log("[设备瘦身] 大小增强未取到：本轮没有精确大小（「应用」分片偏小、「较大应用」判不出）")
        } else {
            let byId = Dictionary(enhanced.map { ($0.bundleId, $0) }, uniquingKeysWith: { first, _ in first })
            var patched = 0
            for index in result.apps.indices {
                guard let e = byId[result.apps[index].bundleId] else { continue }
                if result.apps[index].appSize == nil { result.apps[index].appSize = e.appSize }
                if result.apps[index].docSize == nil { result.apps[index].docSize = e.docSize }
                if result.apps[index].appleId == nil { result.apps[index].appleId = e.appleId }
                patched += 1
            }
            // v0.3.401（补修）：`sizeComplete` 改成按「**是否真的拿到大小**」判定.
            // 原来按「回填了几条」（`patched > 0`）判定 —— 只要带属性增强返回了列表就算
            // 成功；而本版已把 StaticDiskUsage / DynamicDiskUsage 移出请求（为解决
            // 「带属性 Lookup 卡 ~25 秒」），于是 `patched` 仍 > 0 但 appSize 全为 nil：
            // 页面不给「应用大小不可用」，而 bigApps 的 `total > threshold` 会把全部
            // 应用跳过（`appSize/docSize` 都是 0）→ 「应用」分片 /「较大应用」**静默为空**.
            // 现在要求「至少有一个应用真的带上了 appSize」，否则如实报「大小不可用」.
            // 注：iOS 侧**没有 AFC 等价通道**能补应用大小（house_arrest 只到数据容器），
            // 所以去掉这两个字段就等于「应用大小整体不可用」，必须让页面说清楚.
            let sizedApps = result.apps.filter { $0.appSize != nil }.count
            let sizedDocs = result.apps.filter { $0.docSize != nil }.count
            result.sizeComplete = sizedApps > 0
            LoginLogger.shared.log(
                "[设备瘦身] 大小增强回填 \(patched) 条，其中真的带 appSize \(sizedApps) 条"
                + " / 带 docSize \(sizedDocs) 条（sizeComplete=\(result.sizeComplete)）"
            )
            // v0.3.408：**没有 appSize 的那批到底是什么**（真机：334 条里只有 125 条有大小）——
            // 一次真机日志即可判定要不要管：`ApplicationType=System/HiddenSystemApp` 的应用
            // 本来就被 `bigApps()` 排除，若这批几乎全是系统应用，「125/334」就不再是缺陷。
            // 只有「三方 + 有安装路径」那部分才是「较大应用」漏判的真实来源。
            let missing = result.apps.filter { $0.appSize == nil }
            let missingSystem = missing.filter { isSystemApp($0) }.count
            let missingNoPath = missing.filter { ($0.path ?? "").isEmpty }.count
            LoginLogger.shared.log(
                "[设备瘦身] 无 appSize 的 \(missing.count) 条中：系统应用 \(missingSystem) 条"
                + " / 三方 \(missing.count - missingSystem) 条 / 无安装路径 \(missingNoPath) 条"
            )
        }

        appReadLock.lock()
        if !result.usable {
            // v0.3.661：按**真实原因**分文案，不再一律「应用读取超时」.
            // 判据：只有真的是超时才说超时；其它（无配对文件 / VPN 未连 / house_arrest
            // 未授权 / AFC 报错）都把原始信息透出，并明确「重试无效，需先修 X」。
            let raw = (result.failureReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                appReadIssueFlag = "应用列表读取失败（原因未知）"
            } else if raw == "超时" || raw.localizedCaseInsensitiveContains("timeout")
                        || raw.localizedCaseInsensitiveContains("超时") {
                appReadIssueFlag = "应用读取超时，请稍后重试"
            } else if raw.localizedCaseInsensitiveContains("配对") {
                appReadIssueFlag = "读不到应用列表：缺少配对文件（重试无效，请先导入配对文件）—— \(raw)"
            } else if raw.localizedCaseInsensitiveContains("VPN")
                        || raw.localizedCaseInsensitiveContains("隧道")
                        || raw.localizedCaseInsensitiveContains("49152") {
                appReadIssueFlag = "读不到应用列表：隧道未建立（重试无效，请先在「本地隧道」里连上 LocalDevVPN）—— \(raw)"
            } else {
                appReadIssueFlag = "读不到应用列表：\(raw)"
            }
        } else if result.apps.isEmpty {
            // v0.3.666：**读到了，但确实是 0 条** —— 不能报「应用大小不可用」.
            //
            // 空列表时 sizeComplete 必然是 false（没东西可回填），若不加这一支，
            // 页面会对着一台真的没装第三方应用的设备说「应用大小不可用」，
            // 把「事实为空」又折成了一句故障提示.
            appReadIssueFlag = nil
        } else if !result.sizeComplete {
            appReadIssueFlag = "应用大小不可用"
        } else {
            appReadIssueFlag = nil
        }
        appReadCache = (result, Date())
        let issue = appReadIssueFlag
        appReadLock.unlock()
        if let issue { LoginLogger.shared.log("[设备瘦身] 本轮问题：\(issue)（已在页面提示 + 提供重试）") }
        return result
    }

    private static let appReadLock = NSLock()
    /// Swift 6 并发检查：`appReadCache` / `appReadIssueFlag` 的**全部**读写都在上面的
    /// `appReadLock` 内（见 `readAppsForSlim` / `consumeAppReadIssue` / `invalidateAppReadCache`），
    /// 因此这两个静态变量本身线程安全。
    nonisolated(unsafe) private static var appReadCache: (result: AppReadResult, at: Date)?
    /// 本轮需要向用户说明的问题（nil = 一切正常）——页面取走后清零，避免跨轮残留.
    nonisolated(unsafe) private static var appReadIssueFlag: String?

    /// 取走并清零本轮的问题文案（页面在数据落地后调用一次）.
    static func consumeAppReadIssue() -> String? {
        appReadLock.lock(); defer { appReadLock.unlock() }
        let value = appReadIssueFlag
        appReadIssueFlag = nil
        return value
    }

    /// v0.3.673：取走「空间占用数字不完整」的原因（页面在 usage 落地后调用一次）.
    ///
    /// 为什么单独一条通道：`SpaceUsage.incompleteReason` 是**数据自带的**说明，
    /// 页面即使不读它也不会错；但「扫描时有目录读不出」属于**本轮扫描**的事实，
    /// 与 usage 一起给出最直观. 取走即清零，避免跨轮残留.
    nonisolated(unsafe) private static var usageIssueFlag: String?
    private static let usageIssueLock = NSLock()

    static func consumeUsageIssue() -> String? {
        usageIssueLock.lock(); defer { usageIssueLock.unlock() }
        let value = usageIssueFlag
        usageIssueFlag = nil
        return value
    }

    /// 用户点「重试」时先丢掉缓存，否则 30 秒内会直接拿到上一次的失败结果.
    static func invalidateAppReadCache() {
        appReadLock.lock(); defer { appReadLock.unlock() }
        appReadCache = nil
        appReadIssueFlag = nil
    }

    // MARK: - v0.3.408：文档大小的本机通道

    private static let docSizeLock = NSLock()
    /// Swift 6 并发检查：`docSizeCache` / `docSizeInFlight` 的**全部**读写都在上面的
    /// `docSizeLock` 内（见 `cachedDocSize` / `startDocSizePass` 的量取任务），本身线程安全。
    /// 量过的 `docSize`（bundleId → 字节 + 量到的时刻）。**跨轮保留** ——
    /// 「较大应用」的文档大小因此一轮比一轮全，而不是每轮都从头发一遍.
    nonisolated(unsafe) private static var docSizeCache: [String: (bytes: Int64, at: Date)] = [:]
    /// 正在量的 bundleId（`readAppsForSlim` 缓存刚失效时，两个调用方可能同时发起）.
    nonisolated(unsafe) private static var docSizeInFlight: Set<String> = []

    /// 单轮最多量几个应用；单个应用最多看几个节点（20k 是「空间回收」的口径，这里更保守）.
    private static let docSizePassMaxApps = 60
    private static let docSizeMaxNodesPerApp = 12_000
    /// 量到的值保留 10 分钟：文档会变，但没必要每轮重走一遍文件树.
    private static let docSizeCacheTTL: TimeInterval = 600

    /// 量到过的文档大小（读不到 / 过期 → nil，调用方按 0 处理，与从前一致）.
    static func cachedDocSize(_ bundleId: String) -> Int64? {
        docSizeLock.lock(); defer { docSizeLock.unlock() }
        guard let hit = docSizeCache[bundleId] else { return nil }
        guard Date().timeIntervalSince(hit.at) < docSizeCacheTTL else { return nil }
        return hit.bytes
    }

    /// 系统应用（instproxy `ApplicationType` 口径，与 `InstalledApp.isSystem` 同款）.
    private static func isSystemApp(_ app: FileSharingApp) -> Bool {
        app.applicationType == "System" || app.applicationType == "HiddenSystemApp"
    }

    /// 单轮待量的一个应用。用 struct 而不是元组：`Task.detached` 的闭包要 `@Sendable`，
    /// 具名类型的 Sendable 语义最明确.
    private struct DocSizeTarget: Sendable {
        let bundleId: String
        let path: String
    }

    /// **文档大小（`docSize`）的落地点**（v0.3.408）.
    ///
    /// ## 为什么必须有它
    /// `docSize` 以前恒为 0，因为它的来源字段 `DynamicDiskUsage` **根本不在请求里**
    ///（`FileSharingService.attributeRequestFields` 与 Rust 的 `attrs` 都只有
    /// `StaticDiskUsage`）—— 不是"请求了没人填"，是**从来没请求过**。
    /// 于是「较大应用」的判据 `appSize + docSize` 里那一半恒等于 0：
    /// **App 本体不大、文档却几十 GB 的应用（微信、游戏）永远进不了这个分组**，
    /// 用户看到的就是「没有扫到文档的」。
    ///
    /// ## 为什么不把 `DynamicDiskUsage` 加回请求
    /// 它是「带属性 Lookup 卡 ~25 秒」的头号嫌疑（见 `FileSharingService` 注释），
    /// 为了补一个大小把它引回来不值 —— 那会让整个「应用管理 / 文档浏览 / 设备瘦身」
    /// 一起变慢，代价远大于收益.
    ///
    /// ## 为什么不用 house_arrest + AFC
    /// `house_arrest_vend_documents` **要求应用开启文档共享**（`UIFileSharingEnabled`）——
    /// 用户报的那批应用（微信、游戏）恰恰没开，那条路覆盖不到它们.
    ///（`FileSharingService.computeDocumentsSize` 走的就是那条路，且它的调用点
    /// `FileSharingAppsView.computeDocumentSizes()` 至今是死代码 —— 也正因如此从没生效过.）
    ///
    /// ## 实际通道：本机沙盒扩展 + 递归求和（与「空间回收」页同一套）
    /// `escape.withHandle(for: 容器路径)` 消费沙盒扩展 → `files.countTree` 递归求和.
    /// 只要 instproxy 给了 `Container`（`get_apps` 默认响应自带；带属性 Lookup 自
    /// v0.3.600 起也在请求里，见 `FileSharingApp.containerPath`）就能量 ——
    /// 不需要应用配合，也不需要额外隧道.
    /// 量的是**整个数据容器**（Documents + Library + tmp），与 `DynamicDiskUsage` 的口径一致
    ///（不是只量 Documents）.
    ///
    /// ## 代价（如实说明）
    /// · 走的是**本机 syscall**（不是 USB 隧道），但确实要 stat 一遍文件树，所以有上限：
    ///   单应用 ≤ `docSizeMaxNodesPerApp` 个节点、单轮 ≤ `docSizePassMaxApps` 个应用；
    /// · 全程在 `Task.detached(.utility)` 上跑、**不阻塞首屏**：从快路径拿到列表就发起，
    ///   与后面的带属性 Lookup（最长 15 秒）和空间快照**重叠**，通常等在它后面的是现成结果；
    /// · 量的结果**跨轮累积**（10 分钟有效），所以第一轮多半只覆盖一部分，
    ///   多进几次「设备瘦身」/ 点一次刷新就补齐 —— 日志里每轮都打覆盖数，别猜.
    private static func startDocSizePass(_ apps: [FileSharingApp]) {
        let measurable = apps.filter { !isSystemApp($0) && ($0.containerPath?.isEmpty == false) }
        let pending = measurable.filter { cachedDocSize($0.bundleId) == nil }

        docSizeLock.lock()
        let picked = pending
            .filter { !docSizeInFlight.contains($0.bundleId) }
            .prefix(docSizePassMaxApps)
            .map { DocSizeTarget(bundleId: $0.bundleId, path: $0.containerPath ?? "") }
        for entry in picked { docSizeInFlight.insert(entry.bundleId) }
        let done = docSizeCache.count
        docSizeLock.unlock()

        guard !picked.isEmpty else {
            LoginLogger.shared.log(
                "[设备瘦身] 文档大小：本轮无需补（已量 \(done)/\(measurable.count) 个可量的应用）"
            )
            return
        }
        LoginLogger.shared.log(
            "[设备瘦身] 文档大小：本轮量 \(picked.count) 个应用（本机通道；此前累计 \(done) 个，"
            + "可量 \(measurable.count) 个）"
        )
        Task.detached(priority: .utility) {
            var measured = 0
            var failed = 0
            for entry in picked {
                let startedAt = Date()
                let bytes = measureContainerBytes(entry.path)
                // Swift 6：NSLock 的 lock/unlock 在 async 上下文不可用，改用作用域加锁
                // `withLock`（临界区内没有 await，语义与原来的 lock/unlock 完全一致）。
                let nowDone = docSizeLock.withLock { () -> Int in
                    if let bytes {
                        docSizeCache[entry.bundleId] = (bytes, Date())
                        measured += 1
                    } else {
                        failed += 1
                    }
                    docSizeInFlight.remove(entry.bundleId)
                    return docSizeCache.count
                }
                let seconds = String(format: "%.2f", Date().timeIntervalSince(startedAt))
                LoginLogger.shared.log(
                    "[设备瘦身] 文档大小 \(entry.bundleId)："
                    + (bytes.map { formatBytes($0) } ?? "量不到")
                    + "（用时 \(seconds)s；累计 \(nowDone)/\(measurable.count)）"
                )
            }
            LoginLogger.shared.log(
                "[设备瘦身] 文档大小本轮结束：量到 \(measured) 个 / 量不到 \(failed) 个"
                + "（剩下的下一轮继续）"
            )
        }
    }

    /// 单个应用数据容器的递归占用（字节）；`nil` = 这次没量到（沙盒扩展被拒 / 容器不在）.
    private static func measureContainerBytes(_ containerPath: String) -> Int64? {
        guard !containerPath.isEmpty else { return nil }
        let escape = SandboxEscape()
        let files = FileService()
        do {
            return try escape.withHandle(for: containerPath) { _ in
                guard files.isDirectory(at: containerPath) else { return nil }
                let counted = try files.countTree(at: containerPath,
                                                  maxNodes: docSizeMaxNodesPerApp)
                return counted.bytes
            }
        } catch {
            return nil
        }
    }

    // MARK: - 空间占用

    static func loadUsage(snapshot: Snapshot? = nil,
                          progress: ((String) -> Void)? = nil) throws -> SpaceUsage {
        var usage = SpaceUsage()
        // v0.3.673：「剩余容量」是否真的读到了（false = 按 0 呈现，需在界面上说明）.
        var freeUnknown = false
        let snap = try snapshot ?? buildSnapshot(progress: progress)

        // v0.3.673：**读不到容量就报错，不要报 0**. 旧写法 `try? … ?? [:]` 把
        // lockdown 读取失败折成空字典，于是 total/free 全落 0：环形图空、图例全 0、
        // 标题写着「已用 0 B / 总量 0 B」—— 一台 256GB 的手机会被显示成一台空手机，
        // 而用户没有任何线索知道这是"没读到". 现在把失败原文抛出去，页面按读取失败
        // 呈现并给「重试」（DeviceSlimView 的 catch 已就绪）.
        let du: [String: Any]
        do {
            du = try DeviceInfoService.lockdownDomainDict("com.apple.disk_usage")
        } catch {
            throw NSError(domain: "DeviceSlim", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "读取设备容量失败：\(error.localizedDescription)",
            ])
        }
        func num(_ key: String) -> Int64? {
            if let n = du[key] as? Int { return Int64(n) }
            if let n = du[key] as? NSNumber { return n.int64Value }
            return nil
        }
        guard let total = num("TotalDiskCapacity") ?? num("TotalDataCapacity"), total > 0 else {
            // 域字典读到了但没有容量键 —— 同样是「没读到」，不能当 0 用.
            throw NSError(domain: "DeviceSlim", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "读取设备容量失败：disk_usage 未返回 TotalDiskCapacity",
            ])
        }
        usage.total = total
        let system = num("TotalSystemCapacity") ?? 0
        // v0.3.673：**剩余容量没读到也不能按 0 报**. 三个键全缺时 free = 0，
        // 差额会被 other = total - ... - 0 全部吞掉 ——「剩余 0 B、其他巨大」是纯假象.
        let free = num("AmountRestoreAvailable") ?? num("AmountDataAvailable") ?? num("TotalDataAvailable")
        usage.free = free ?? 0
        if free == nil {
            freeUnknown = true
            LoginLogger.shared.log("[设备瘦身] disk_usage 缺 AmountRestoreAvailable / AmountDataAvailable / TotalDataAvailable：「剩余」按 0 呈现，差额落在「其他」")
        }
        if num("TotalSystemCapacity") == nil {
            // 「系统」分片会偏小、差额被算进「其他」—— 留痕，别让 0 冒充测得值.
            LoginLogger.shared.log("[设备瘦身] disk_usage 缺 TotalSystemCapacity：「系统」分片按 0 呈现，差额落在「其他」")
        }

        var apps: Int64 = 0
        // v0.3.378：快路径（get_apps）保底出数据，不再「超时按空处理」；
        // 精确大小依赖可选增强，取不到时该分片会偏小，页面以「应用大小不可用」明确说明.
        let appRead = readAppsForSlim()
        for app in appRead.apps where app.applicationType != "System" {
            apps += app.appSize ?? 0
        }
        // v0.3.673：**部分和不能当全量**. 没有 appSize 的应用被按 0 累加，
        // 于是「应用」分片是一个下界，差额全部被下面的 other 兜走 ——
        // 图上看起来"应用很小、其他很大"，其实是没量到. 现在把这种状态标出来.
        var partial = false
        if !appRead.usable {
            partial = true
        } else if !appRead.sizeComplete, !appRead.apps.isEmpty {
            partial = true
            LoginLogger.shared.log(
                "[设备瘦身] 应用大小不完整：\(appRead.apps.count) 条里只有 "
                + "\(appRead.apps.filter { $0.appSize != nil }.count) 条带大小，"
                + "「应用」分片是下界，差额计入「其他」"
            )
        }

        let photos = photoDirs.reduce(Int64(0)) { $0 + (snap.totals[$1] ?? 0) }
        let media = mediaDirs.reduce(Int64(0)) { $0 + (snap.totals[$1] ?? 0) }
        let usb = snap.totals[usbDir] ?? 0
        let other = max(0, usage.total - system - apps - photos - media - usb - usage.free)

        usage.slices = [
            UsageSlice(id: "system", label: "系统", bytes: system, colorHex: 0x2F80ED),
            UsageSlice(id: "apps", label: "应用", bytes: apps, colorHex: 0x2D9CDB),
            UsageSlice(id: "photos", label: "照片", bytes: photos, colorHex: 0x9B51E0),
            UsageSlice(id: "media", label: "音视频", bytes: media, colorHex: 0xF2C94C),
            UsageSlice(id: "usb", label: "U盘", bytes: usb, colorHex: 0x27AE60),
            UsageSlice(id: "other", label: "其他", bytes: other, colorHex: 0xF2994A),
            UsageSlice(id: "free", label: "剩余", bytes: usage.free, colorHex: 0xBDBDBD),
        ]
        usage.scannedAt = snap.takenAt
        // v0.3.673：把「这个数字不完整」带到界面上，而不是只在日志里.
        // 两个来源：① 应用大小只量到一部分（partial）；② 扫描时有目录读不出.
        let unreadable = snap.unreadablePaths ?? []
        var notes: [String] = []
        if partial { notes.append("应用大小不完整") }
        if freeUnknown { notes.append("剩余容量未读到") }
        if !unreadable.isEmpty { notes.append("\(unreadable.count) 个目录读不出") }
        // v0.3.694：触顶与「读不出」是两回事，分开说（数字同样偏小，但原因与对策不同）.
        if let limitSkipped = snap.limitSkippedDirectories, limitSkipped > 0 {
            notes.append("\(limitSkipped) 个目录未展开")
        }
        usage.incompleteReason = notes.isEmpty ? nil : notes.joined(separator: " / ")
        usageIssueLock.lock()
        usageIssueFlag = usage.incompleteReason
        usageIssueLock.unlock()

        let machine = sysctlString("hw.machine") ?? "iPhone"
        usage.deviceName = DeviceCatalog.name(machine)
        usage.capacityText = "\(decimalCapacity(usage.total)) · \(usage.deviceName)"
        return usage
    }

    private static func decimalCapacity(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let gb = Double(bytes) / 1_000_000_000
        if let standard = [16.0, 32, 64, 128, 256, 512, 1024, 2048].first(where: { gb <= $0 * 1.02 }) {
            return "\(Int(standard))GB"
        }
        return String(format: "%.0fGB", gb)
    }

    // MARK: - 扫描（复用同一快照）

    static func scan(snapshot: Snapshot? = nil,
                     progress: ((String) -> Void)? = nil) throws -> [Group] {
        let snap = try snapshot ?? buildSnapshot(progress: progress)
        var groups: [Group] = []

        // v0.3.673：**「没量到」与「量到 0」分开**. 旧实现 `?? 0` + `guard bytes > 0`
        // 把两种完全不同的情况并成"这一项不显示"：目录读不出（或本轮被跳过）时，
        // 可清理项会静默消失，用户看到的是"这台设备没缓存"，而不是"这次没扫到".
        let unreadable = snap.unreadablePaths ?? []
        var skippedUnmeasured = 0
        var systemItems: [Item] = []
        for (path, why) in systemCachePaths {
            guard let bytes = snap.totals[path] else {
                skippedUnmeasured += 1
                continue
            }
            guard bytes > 0 else { continue }
            systemItems.append(Item(id: path, name: why,
                                    detail: cacheDetail(path, snap),
                                    bytes: bytes, kind: .systemCache, deletable: true))
        }
        groups.append(Group(kind: .systemCache, items: systemItems))

        let logItems = snap.logs.map {
            Item(id: $0.path, name: itemName($0.path), detail: "日志文件",
                 bytes: $0.bytes, kind: .userLog, deletable: true)
        }
        groups.append(Group(kind: .userLog, items: logItems))

        var tempItems: [Item] = []
        for (path, why) in tempPaths {
            // v0.3.673：同「系统缓存」—— 没量到 ≠ 0 字节.
            guard let bytes = snap.totals[path] else {
                skippedUnmeasured += 1
                continue
            }
            guard bytes > 0 else { continue }
            tempItems.append(Item(id: path, name: why,
                                  detail: cacheDetail(path, snap),
                                  bytes: bytes, kind: .tempFiles, deletable: true))
        }
        groups.append(Group(kind: .tempFiles, items: tempItems))

        groups.append(Group(kind: .bigApps, items: bigApps()))
        // v0.3.694：触顶同样属于「这份列表不完整」，要一起说.
        let limitSkipped = snap.limitSkippedDirectories ?? 0
        if skippedUnmeasured > 0 || !unreadable.isEmpty || limitSkipped > 0 {
            LoginLogger.shared.log(
                "[设备瘦身] 扫描不完整：\(skippedUnmeasured) 个候选路径没量到，"
                + "\(unreadable.count) 个目录读不出"
                + (limitSkipped > 0 ? "，\(limitSkipped) 个目录未展开" : "")
                + "（可清理项列表可能偏少）"
            )
        }
        return groups
    }

    /// 较大应用（> 500 MB）：连同「免登录下载库里有没有可重装的包」一起算.
    static func bigApps() -> [Item] {
        let library = IPADownloadLibrary.shared.items()
        var byBundle: [String: IPADownloadItem] = [:]
        for item in library {
            guard let bid = item.bundleId, !bid.isEmpty else { continue }
            // 同一 bundleId 有多份包时取**最新**的那份
            if let old = byBundle[bid], old.downloadedAt >= item.downloadedAt { continue }
            byBundle[bid] = item
        }

        var out: [Item] = []
        // v0.3.673：文档大小未知的应用条数（见循环内说明）.
        var unmeasuredDocCount = 0
        // v0.3.378：快路径（get_apps）保底出数据；没有精确大小时（增强未成功）
        // 该分组判不出「> 500MB」，页面以「应用大小不可用」明确说明，而不是静默变空.
        let appRead = readAppsForSlim()
        for app in appRead.apps {
            guard app.applicationType != "System" else { continue }
            let appSize = app.appSize ?? 0
            // v0.3.408：文档大小取**本机通道**量到的结果（`DynamicDiskUsage` 不在请求里，
            // 见 `startDocSizePass`）。还没量到的按 0 算 —— 与从前一字不差，不是回退.
            // v0.3.673：**但"没量到"必须可分辨**. `cachedDocSize` 返回 nil 有两种含义
            // （还没量 / 量失败），旧写法一律 `?? 0`，于是「较大应用」的判定
            // `total > bigAppThreshold` 会把文档很重的应用漏掉，界面也不说为什么.
            // 现在把"文档大小未知"的应用条数写进日志，让漏判可被看见.
            let measuredDoc = app.docSize ?? cachedDocSize(app.bundleId)
            let docSize = measuredDoc ?? 0
            if measuredDoc == nil { unmeasuredDocCount += 1 }
            let total = appSize + docSize
            guard total > bigAppThreshold else { continue }
            var available: Bool? = nil
            if byBundle[app.bundleId] != nil {
                available = true
            } else {
                available = SourcePackageLocator.cachedAvailability(bundleId: app.bundleId)
            }
            out.append(Item(id: app.bundleId, name: app.name,
                            detail: nil, bytes: total, kind: .bigApps, deletable: false,
                            appSize: appSize, docSize: docSize, version: app.version,
                            ipaFileName: byBundle[app.bundleId]?.fileName,
                            sourceAvailable: available,
                            isRisky: riskyBundleIds.contains(app.bundleId)))
        }
        if unmeasuredDocCount > 0 {
            LoginLogger.shared.log(
                "[设备瘦身] 较大应用判定：\(unmeasuredDocCount) 个应用的文档大小尚未量到（按 0 计），"
                + "这部分应用若文档很重会被漏判"
            )
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// 缓存行副标题：设备上的目录名 + 文件数（用来对照爱思面板）
    private static func cacheDetail(_ path: String, _ snap: Snapshot) -> String {
        let leaf = itemName(path)
        let count = snap.fileCounts[path] ?? 0
        return leaf == path ? "\(count) 个文件" : "\(leaf) · \(count) 个文件"
    }

    private static func itemName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// 探测「免登录源里有没有这些应用」，回填 `sourceAvailable`（爱思的「资源缺失无法重装」）。
    /// 值为 nil = 该项这次没查成（**不是**资源缺失，UI 不应拦）。
    static func probeSourceAvailability(_ targets: [(bundleId: String, name: String)],
                                        progress: ((Int, Int) -> Void)? = nil) async -> [String: Bool?] {
        await SourcePackageLocator.probe(bundleIds: targets, progress: progress)
    }

    /// 「重新检测」：清空探测缓存后重探（源里新上架 / 之前网络失败时用）
    static func refreshSourceAvailability(_ targets: [(bundleId: String, name: String)],
                                          progress: ((Int, Int) -> Void)? = nil) async -> [String: Bool?] {
        SourcePackageLocator.clearCache()
        return await SourcePackageLocator.probe(bundleIds: targets, progress: progress)
    }

    // MARK: - 清理（缓存项）

    static func clean(items: [Item],
                      progress: ((Int, Int) -> Void)? = nil) throws -> CleanResult {
        var result = CleanResult()
        let targets = items.filter { $0.deletable && $0.kind != .bigApps }
        guard !targets.isEmpty else { return result }

        try AFCService.shared.batch { client in
            for (index, item) in targets.enumerated() {
                progress?(index + 1, targets.count)
                // 删除前先量一次：删完路径就没了，那时再量只会得到 0。
                //
                // 原实现删完又量了一次（`measure(...).bytes`），而 `measure` 在路径不存在时
                // 返回 (0, 0) —— 于是 `max(0, before - after)` 变成 `max(0, before - 0)`。
                // 当 before 也读失败（同样是 0）时，`freed` 恒为 0：
                // 用户看到「已释放 0 字节」，但文件其实已经删掉了 —— 会以为功能失效并反复清理。
                // v0.3.661：`measure` 现在可空 —— 量不到就是「不知道」，不是 0。
                let before = measure(client: client, path: item.id)?.bytes
                if let ffiError = item.id.withCString({ afc_remove_path_and_contents(client, $0) }) {
                    let message = ffiError.pointee.message.map { String(cString: $0) } ?? "rc=\(ffiError.pointee.code)"
                    idevice_error_free(ffiError)
                    result.failures.append("\(item.name)：\(message)")
                    continue
                }
                // 删成功即视为释放了 before 字节，不再二次测量（路径已不存在）。
                // 量不到时**不累加**（之前的写法会把「量不到」当 0 加进 freed，
                // 结果是「已释放 0 字节」而文件已经没了），只记一个 unmeasured 计数。
                if let before {
                    result.freed += before
                } else {
                    result.unmeasured += 1
                }
                result.deleted += 1
            }
        }
        // 数值已变，作废缓存.
        // v0.3.673：**作废失败要留痕**. 旧写法 `try?` 吞掉失败，缓存文件仍在，
        // 下次进页面（10 分钟内）又把刚删掉的项原样列出来 —— 用户以为删除没生效.
        invalidateSnapshot(reason: "清理完成")
        // v0.3.675：`clean` 返回 `CleanResult`，上面两行只是副作用调用 —— 少 `return` 时
        // swiftc 报 `missing return in static method expected to return 'DeviceSlimService.CleanResult'`（CI run 39139842642 实测）.
        return result
    }

    // MARK: - 重装（较大应用）

    /// 卸载 + 重装（**会清掉该 App 的文稿与数据**）。
    ///
    /// 本地「免登录下载」库里没有该包时，**现场去免登录源按 bundleId 找并下载**
    /// ——这正是爱思的做法（它的包不落本地，重装时从自己服务端取）。
    /// 源里也找不到才判定为「资源缺失」。
    static func reinstall(items: [Item],
                          progress: (@Sendable (ReinstallProgress) -> Void)? = nil) async -> ReinstallResult {
        var result = ReinstallResult()
        let targets = items.filter { $0.kind == .bigApps }
        for (index, item) in targets.enumerated() {
            // Swift 6：report 会被下面两个 @Sendable 的 progress 闭包捕获 ——
            // 标 @Sendable，并且只捕获 Sendable 的快照（进度回调、序号、总数、名称），
            // 不再捕获可能非 Sendable 的 `item` / `targets`（原写法触发
            // SendableClosureCaptures，CI 实测 :797）。语义不变。
            let progressHandler = progress
            let itemIndex = index + 1
            let itemTotal = targets.count
            let itemName = item.name
            @Sendable func report(_ stage: ReinstallStage, _ fraction: Double) {
                progressHandler?(ReinstallProgress(index: itemIndex, total: itemTotal,
                                                   name: itemName, stage: stage, fraction: fraction))
            }
            do {
                // ① 本地已有包就直接用；否则去源里找
                var fileName = item.ipaFileName
                var localPath = fileName.map { IPADownloadLibrary.shared.path(forFileName: $0) } ?? ""
                if fileName == nil || !FileManager.default.fileExists(atPath: localPath) {
                    report(.locating, 0)
                    guard let hit = await SourcePackageLocator.find(bundleId: item.id, name: item.name) else {
                        result.failures.append("\(item.name)：源里没有找到该应用")
                        continue
                    }
                    let saved = try await AppStoreInstallService.downloadIPA(
                        urlString: hit.ipaURL,
                        suggestedName: "\(item.id)-\(hit.version ?? "x").ipa",
                        progress: { p in
                            DispatchQueue.main.async { report(.downloading, p * 0.6) }
                        },
                        onLog: { LoginLogger.shared.log("[瘦身] \($0)", category: .i4Store) })
                    fileName = saved.lastPathComponent
                    localPath = saved.path
                    await MainActor.run {
                        IPADownloadLibrary.shared.record(fileURL: saved,
                                                         displayName: item.name,
                                                         bundleId: item.id,
                                                         version: hit.version,
                                                         iconURL: nil,
                                                         source: "爱思免登录")
                    }
                }
                guard let fileName, FileManager.default.fileExists(atPath: localPath) else {
                    result.failures.append("\(item.name)：安装包不可用")
                    continue
                }
                // ② 卸载 → 装回
                report(.installing, 0.6)
                try UninstallService.shared.uninstall(bundleId: item.id)
                try await AppStoreInstallService.installLocalIPA(
                    localPath,
                    progress: { p in
                        DispatchQueue.main.async { report(.installing, 0.6 + p * 0.4) }
                    },
                    onLog: { LoginLogger.shared.log("[瘦身] \($0)", category: .i4Store) })
                IPADownloadLibrary.shared.markInstalled(fileName: fileName)
                result.ok.append(item.name)
            } catch {
                result.failures.append("\(item.name)：\(error.localizedDescription)")
            }
        }
        invalidateSnapshot(reason: "重装完成")
        return result
    }

    // MARK: - 辅助

    /// 量一个路径的字节数 / 文件数.
    ///
    /// v0.3.661：**改为可空**。原来 stat 失败直接 `return (0, 0)`，调用方无从分辨
    /// 「真的是 0 字节」与「压根没量到」：`clean()` 里会把量失败当成 0 累加进
    /// `result.freed`，用户看到「已释放 0 字节」而文件其实已被删掉 —— 与该方法上方
    /// :760-765 已经修过的「删完再量」缺陷是同一个坑的另一半。
    /// 现在失败返回 nil，由调用方决定「未计量」怎么呈现（不冒充 0）。
    static func measure(client: OpaquePointer, path: String) -> (bytes: Int64, files: Int)? {
        var info = AfcFileInfo()
        let rc = path.withCString { afc_get_file_info(client, $0, &info) }
        if let rc {
            let code = Int(rc.pointee.code)
            idevice_error_free(rc)
            LoginLogger.shared.log("[设备瘦身] 计量失败（不按 0 字节计）：\(path) code=\(code)")
            return nil
        }
        defer { afc_file_info_free(&info) }
        let isDir = info.st_ifmt.map { String(cString: $0) == "S_IFDIR" } ?? false
        if !isDir { return (Int64(info.size), 1) }

        var bytes: Int64 = 0
        var files = 0
        var stack = [path]
        while let current = stack.popLast() {
            // v0.3.666：**任何一级子目录读失败都不能返回部分和**.
            //
            // 旧写法 `try? ... else { continue }` 会把「这一层没读成」悄悄跳过，
            // 函数照样返回一个 (bytes, files) —— 但它只是**已遍历部分**的和，
            // 调用方 `clean()`（:773-787）无法分辨，会原样加到 result.freed 上，
            // 于是用户看到一个确定的「已释放 X 字节」，实际漏算了整棵子树.
            // 这与本方法 :875-879 刚修掉的「stat 失败返回 0」是同一个判据：
            // 量不到就说量不到（nil），不拿部分结果冒充完整结果.
            let entries: [AFCService.Entry]
            do {
                entries = try AFCService.listDirectory(client: client, path: current)
            } catch {
                LoginLogger.shared.log(
                    "[设备瘦身] 计量中断（子目录读不到，不返回部分和）：\(current)"
                    + " code=\(error.localizedDescription)"
                )
                return nil
            }
            for entry in entries {
                if entry.isDirectory { stack.append(entry.path) }
                else { bytes += entry.size; files += 1 }
            }
        }
        return (bytes, files)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
