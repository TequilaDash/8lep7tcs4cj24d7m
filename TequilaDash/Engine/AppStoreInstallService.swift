import Foundation
import UIKit

/// AppStore 商店 / 免登录源 —— IPA 下载与本地安装服务。
///
/// v0.3.315：第三方「分发源」与 itms-services OTA 链路已整体移除，这里只保留两件事：
///   · `downloadIPA`  —— 把远端的 IPA 下载到 `Documents/AppStoreDownloads/`
///   · `installLocalIPA` —— 经 RSD 隧道把本地 IPA 装到设备（按 cryptid 分流：
///     加密包用包内 `SC_Info/*.sinf` 作 `ApplicationSINF`，明文包走普通 Install）
enum AppStoreInstallService {

    enum InstallError: Error, LocalizedError {
        case badTemplate
        case requestFailed(String)
        /// v0.3.571：下载源域不在允许范围内（AppleID 通道要求落在 Apple 自有域）。
        case untrustedHost(String)
        /// v0.3.300：加密包缺少 `SC_Info/*.sinf`，installd 无法解密安装
        case missingSINF(bundleId: String?)
        /// v0.3.570：**无法判定**加密状态（主二进制读不出）且包内无 sinf —— 无法安全安装。
        ///
        /// 与 `missingSINF` 的区别：
        /// · `missingSINF` = **已确认加密**（cryptid≠0）却缺 sinf；
        /// · 本 case     = **连加密状态都判不出**（`.unknown`，主二进制读不出）。
        ///   此时既不能走 ApplicationSINF 通道（没有 sinf），也**不能按明文装** ——
        ///   未知可能是加密包，按明文装会「装不上 / 装后崩」。真明文包的主二进制读得出来，
        ///   判不出即不可信 ⇒ 明确拒绝，不冒险。
        case indeterminateEncryption(bundleId: String?)

        var errorDescription: String? {
            switch self {
            case .badTemplate: return "源模板拼出的地址无效"
            case .requestFailed(let m): return "源接口请求失败：\(m)"
            case .untrustedHost(let h):
                return "下载地址不在 Apple 自有域内（\(h)），已拒绝下载（防止下载源被篡改）."
            case .missingSINF(let bid):
                let who = bid.map { "（\($0)）" } ?? ""
                return "该 IPA\(who) 是加密包，但缺少 SC_Info/*.sinf，installd 无法解密安装，"
                     + "App Store 原始包需要由安装它的同一 Apple ID 在本机下载，才会带可用 sinf."
            case .indeterminateEncryption(let bid):
                let who = bid.map { "（\($0)）" } ?? ""
                return "无法判定该 IPA\(who) 的加密状态（主二进制读不出），且包内没有 SC_Info/*.sinf，"
                     + "无法安全安装：既不能按加密包走 ApplicationSINF 通道（缺 sinf），"
                     + "也不能按明文包安装（可能是加密包，装不上或装后闪退），"
                     + "请改用未加密（已解密 / 已重签）的包，或用带 sinf 的正版包."
            }
        }
    }

    static func downloadIPA(urlString: String,
                            suggestedName: String,
                            progress: ((Double) -> Void)? = nil,
                            // v0.3.571：可选的下载源域策略（AppleID 通道专用）。
                            //
                            // 传 nil（默认）= 不限制，爱思源（`d-app6.i4.cn`）等**非 Apple 域**调用方行为不变。
                            // AppleID 正版通道传 `StoreAuthenticationProtocol.isAppleHost`，把
                            // 「下载地址必须落在 Apple 自有域」这条**隐含前提真正强制**下来：
                            // 初始 URL 与**每一次 HTTP 重定向**都查（只查初始 URL 挡不住 302 换域）。
                            //
                            // 为什么这条前提值得强制：`SignatureInjector` 会拿**下载到的这个 IPA 自带**的
                            // `SC_Info/Manifest.plist` 当写入目标清单（vendor 侧有意不做路径校验，因为输入
                            // 本应来自 Apple 正版包）。若下载地址能被引到第三方域，那份 Manifest 就不可信，
                            // 进而可驱动任意 ZIP 条目名。本校验就是把那个「输入可信」前提锁死。
                            hostPolicy: ((String) -> Bool)? = nil,
                            // v0.3.583：可选的**传输控制面**（AppleID 通道专用）。
                            //
                            // 传 nil（默认）= 与从前完全一致（爱思等调用方不受影响）。
                            // AppleID 通道传一个 `IPADownloadControl`，`IPAFileDownloader` 会把
                            // 底层 `URLSessionDownloadTask` 登记进去 —— 于是下载中心的
                            // 暂停 / 继续 / 删除安装包能真正触达这条链（旧实现这条链没有任何句柄，
                            // 三个动作全是空操作，见 `IPADownloadControl` 的说明）。
                            control: IPADownloadControl? = nil,
                            // v0.3.659（task-3 D3）：可选的字节级进度。
                            //
                            // 为什么不改 progress：那个参数是 0~1 的百分比，下游（下载中心）只有它
                            // 就算不出「已下多少 MB / 共多少 MB / 当前速度」—— AppleID 通道在下载管理里
                            // 因此长期是「百分比在动、字节与速度恒为 0」。加一个默认 nil 的新参数，
                            // 其余 5 个调用点一行都不用改。
                            byteProgress: ((Int64, Int64) -> Void)? = nil,
                            onLog: ((String) -> Void)? = nil) async throws -> URL {
        guard let url = URL(string: urlString) else { throw InstallError.badTemplate }
        if let hostPolicy {
            guard url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(), hostPolicy(host) else {
                throw InstallError.untrustedHost(url.host ?? urlString)
            }
        }
        onLog?("[下载] 开始：\(urlString)")
        let dir = try downloadDirectory()
        let safe = suggestedName.replacingOccurrences(of: "/", with: "_")
        let dest = dir.appendingPathComponent(safe.hasSuffix(".ipa") ? safe : safe + ".ipa")
        try? FileManager.default.removeItem(at: dest)
        // v0.3.676（D1）：**起传输前**把「本次调用算出来的落盘目标」交给控制面。
        //
        // 这一步是 D1 的另一半：`dest` 只有本函数知道（文件名来自调用方给的 `suggestedName`，
        // 对 AppleID 通道而言是 Apple 回的 `bundleShortVersionString`），而取消路径
        // （`IPADownloadControl.abort()`）在「网络已下完、正在注入 sinf」这个窗口里必须拿到它，
        // 才删得掉这个已经落盘、还没写台账的包。`control == nil` 时（爱思等其它通道）无副作用。
        control?.recordDestination(dest)

        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        // v0.3.659（task-3 D2）：把外层 Task 的取消接到这台传输上。
        //
        // 旧实现只有一个裸 withCheckedThrowingContinuation：调用方的 Task 一被取消
        // （下载中心删任务 / 退出页面），这个 continuation 既不会 resume、传输也不会停 ——
        // detached 任务挂在原地，URLSession 却还在后台把几百 MB 拉完，拉完再落盘，
        // 留下一个「列表里没有、磁盘上有」的孤儿包。
        // abort() 早就会让 continuation 以 CancellationError 收尾（见其注释），
        // 缺的只是「谁来触发它」—— 这里补的就是这条线。
        let cancellation = DownloadCancellationBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let downloader = IPAFileDownloader(control: control, destination: dest,
                                                   hostPolicy: hostPolicy, progress: progress,
                                                   byteProgress: byteProgress,
                                                   completion: { result in
                    switch result {
                    case .success(let tmp):
                        do {
                            try? FileManager.default.removeItem(at: dest)
                            try FileManager.default.moveItem(at: tmp, to: dest)
                            cont.resume()
                        } catch {
                            // v0.3.662（task-8 发现5）：**搬运失败时 tmp 也要删**.
                            //
                            // moveItem 抛出（磁盘满 / 跨卷 / dest 被占用）时，tmp 是
                            // IPAFileDownloader 已经写好的**完整包**，而且它在
                            // `FileManager.default.temporaryDirectory` 下用的是 UUID 名字 ——
                            // 除了这里没有任何代码还能找到它。旧实现直接 resume(throwing)，
                            // 这个包就永久留在 tmp 里，直到系统自己清理.
                            try? FileManager.default.removeItem(at: tmp)
                            cont.resume(throwing: error)
                        }
                    case .failure(let err):
                        // v0.3.673（task-8 发现4b）：dest 在上面的 :91 被清过，此刻若它在，只可能是
                        // 本下载器 abort() 删掉之后又被搬回来的残物 —— 失败时由这里统一兜底删干净.
                        // 只删本函数自己算出来的 dest，不碰其它文件.
                        try? FileManager.default.removeItem(at: dest)
                        // v0.3.676（D1）：失败 ⇒ 这次调用的产物已不存在，把登记摘掉.
                        // **成功路径故意不摘**：`downloadIPA` 返回后调用方还要往 dest 里注入 sinf，
                        // 那段窗口里用户点「删除安装包」仍要靠这份登记才找得到文件（见 `abort()`）.
                        control?.recordDestination(nil)
                        cont.resume(throwing: err)
                    }
                })
                // 先登记再启动：在启动之前就到的取消意图由 register 补做 ——
                // 否则取消落在「登记」与「start」之间会丢失，continuation 永不收尾。
                cancellation.register(downloader)
                downloader.start(request: req)
            }
        } onCancel: {
            // 取消不是失败：abort() 自己会 resume 这个 continuation（CancellationError）。
            cancellation.cancel()
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        onLog?("[下载] 完成：\(size / 1024 / 1024) MB → \(dest.lastPathComponent)")
        progress?(1.0)
        return dest
    }

    /// 下载目录（`Documents/AppStoreDownloads`）
    static func downloadDirectory() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("AppStoreDownloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 把本地 IPA 装到设备 —— **复用既有 RSD 隧道安装能力**（`IPAInstallService`）。
    ///
    /// 按包的加密状态分两条通道（v0.3.300 修正，对齐 NB Signer / ideviceinstaller）：
    ///
    /// **① 加密包（App Store 原始包，`cryptid == 1`）**
    ///   提取 `SC_Info/<exe>.sinf` → 以 `PackageType: Customer` + `ApplicationSINF`
    ///   交给 installd。installd 用 sinf 向 Apple 请求**本设备**的解密密钥后解密安装。
    ///   前提：sinf 是为**本设备**生成的（用本机 Apple ID 下载得到的包）。
    ///   包里没有 sinf → 直接报错说明，不做无用功。
    ///
    /// **② 明文包（已重签名 / 已解密）**
    ///   直接 `installSignedIPA`（`PackageType: Application`）。
    ///
    /// `allowDowngrade = true` 时用 `Upgrade` 命令 —— installd 不拦降级，装历史版本用。
    ///
    /// v0.3.388：`progress` 回调的口径是**整条安装链的 0~1**：
    /// AFC 上传段 0~0.75（`IPAInstallService.uploadFile` 按字节统计）+ installd 段 0.75~1
    /// （系统自己回报的 0~100）。上传段以前没有任何回调，界面只能停在 0% 干等。
    /// 注意这是**声明式加权**（与下载中心既有的下载 75% / 安装 25% 同口径），不是系统的整体百分比。
    static func installLocalIPA(_ ipaPath: String,
                                allowDowngrade: Bool = false,
                                progress: (@Sendable (Double) -> Void)? = nil,
                                onLog: ((String) -> Void)? = nil) async throws {
        let svc = IPAInstallService.shared
        let ins = IPAPackageInspector.inspect(ipaPath: ipaPath)

        if let ins {
            onLog?("[检测] \(ins.bundleIdentifier ?? "-") \(ins.bundleVersion ?? "-") · \(ins.summary)")
        } else {
            onLog?("[检测] 无法读取包信息（加密状态无法判定，需凭包内 sinf 判断能否安装）")
        }

        // 加密状态三态（v0.3.570）：**只有确定是明文包**才走常规安装。
        // 加密或「无法判定」（主二进制读不出）都先看包内有没有 sinf；**没有 sinf 一律拒绝** ——
        // 否则「读不出加密状态」会被当成「未加密」，把加密包按明文装（装不上 / 装后崩，
        // 即用户最初报的症状）。真明文包的主二进制是读得出来的，判不出即不可信。
        let encryption = ins?.encryption ?? .unknown
        if encryption != .plaintext {
            if let sinf = IPAPackageInspector.extractSINF(ipaPath: ipaPath) {
                // 加密包 → ApplicationSINF 通道
                let meta = IPAPackageInspector.extractiTunesMetadata(ipaPath: ipaPath)
                let kindLabel = encryption == .encrypted
                    ? "加密包"
                    : "加密状态未知（主二进制读不出），但包内有 sinf"
                onLog?("[安装] \(kindLabel)：携带 ApplicationSINF（\(sinf.count) 字节）"
                       + (meta != nil ? " + iTunesMetadata" : "") + " 交给 installd 解密安装")
                try await Task.detached(priority: .userInitiated) {
                    try svc.installWithSINF(ipaPath,
                                            sinf: sinf,
                                            iTunesMetadata: meta,
                                            upgrade: allowDowngrade,
                                            progress: { p in progress?(p) })
                }.value
                onLog?("[安装] 完成")
                return
            }
            // 无 sinf ⇒ 走不了 ApplicationSINF 通道，按加密状态分别拒绝（**都不落到明文通道**）：
            //   · 明确加密 → missingSINF（缺 sinf）
            //   · 无法判定 → indeterminateEncryption（连加密状态都判不出，不能按明文装）
            if encryption == .encrypted {
                throw InstallError.missingSINF(bundleId: ins?.bundleIdentifier)
            }
            throw InstallError.indeterminateEncryption(bundleId: ins?.bundleIdentifier)
        }

        // 明文包（明确 cryptid==0）→ 常规安装
        try await Task.detached(priority: .userInitiated) {
            if allowDowngrade {
                try svc.upgradeSignedIPA(ipaPath, progress: { p in progress?(p) })
            } else {
                try svc.installSignedIPA(ipaPath, progress: { p in progress?(p) })
            }
        }.value
        onLog?("[安装] 完成")
    }

    /// 完整链路：源 → manifest → IPA → 下载 → RSD 隧道安装
    @discardableResult

    // MARK: - 工具

    /// `a.b.c` 取值
    private static func value(at path: String, in obj: Any) -> String? {        var cur: Any = obj
        for seg in path.split(separator: ".") {
            let key = String(seg)
            if let dict = cur as? [String: Any], let next = dict[key] {
                cur = next
            } else if let arr = cur as? [Any], let idx = Int(key), idx < arr.count {
                cur = arr[idx]
            } else {
                return nil
            }
        }
        if let s = cur as? String { return s }
        if let n = cur as? NSNumber { return n.stringValue }
        return nil
    }

    /// 解析形如 `{"X-Token":"abc"}` 的请求头
    private static func parseHeaders(_ raw: String) -> [String: String]? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let d = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (k, v) in obj { out[k] = (v as? String) ?? "\(v)" }
        return out.isEmpty ? nil : out
    }
}

/// AppleID 通道的**传输控制面** —— 把 `IPADownloadCenter` 的「暂停 / 继续 / 删除安装包」
/// 接到 `IPAFileDownloader` 的 `URLSessionDownloadTask` 上。
///
/// 为什么需要它：`startWithAppleID` 把字节传输委托给
/// `AppStoreLocalInstallService.download` → `AppStoreInstallService.downloadIPA`（内部是
/// `IPAFileDownloader`），这条链**不登记** `IPADownloadCenter.runners`
/// ⇒ 中心的 `pause` / `resume` / `cancel` 对它是**空操作**（`runners[id]` 恒为 nil）。
/// 历史两次「暂停无效」的修复（v0.3.398 `393651f` / v0.3.549 `0ee476d`）都只改了免登录直链
/// 通道的 `RemoteDownloader`，从未触及这里 —— 所以同一问题在 AppleID 通道上原样存在。
///
/// 本对象是那条链与中心之间的**唯一控制通道**：中心按 job id 建它、登记进 `appleIDControls`，
/// 再随 `download` 一路传到 `IPAFileDownloader`；下载器拿到 task 后 `attach(self)`。
/// 于是中心的三件事都能真正触达底层传输。
///
/// 线程模型：`pause` / `resume` / `abort` 从主 actor 调；`attach` 来自下载启动的那个任务。
/// 用一把 `NSLock` 收口，并标 `@unchecked Sendable` 以便跨隔离边界传递（Swift 6 严格并发）。
final class IPADownloadControl: @unchecked Sendable {

    private let lock = NSLock()
    /// 底层下载器（`attach` 时设入）。**strong**：下载器本身是 `downloadIPA` 里的临时对象，
    /// 靠 URLSession 以 delegate 身份持有；这里再持一份，保证「中心 → 控制面 → 下载器」
    /// 这条链在下载期间不断（下载器对控制面是 `weak`，不成环）。
    private var downloader: IPAFileDownloader?
    /// 在 `attach` **之前**就先到的意图 —— 用户可能在下载器建好之前就点了暂停 / 删除。
    private var pendingPause = false
    private var pendingAbort = false

    /// v0.3.676：本次下载**最终落盘的目标路径**（`downloadIPA` 里算出来的 `dest`）。
    ///
    /// 为什么记在这里：`dest` 的文件名是 `AppStoreLocalInstallService.download` 用 Apple 回的
    /// `bundleShortVersionString` 拼出来的（`<bundleID>-<version>.ipa`），与下载中心的
    /// `Job.version` **不是同一个来源**，中心按任务字段拼不出来；而真正删文件的那份
    /// `destination` 在 `IPAFileDownloader` 里是 private，控制面拿不到。
    /// 于是「网络已下完、`dest` 已落盘、正在注入 sinf」这个窗口里用户点「删除安装包」时，
    /// 中心与底层下载器**都不知道该删哪个文件**（下载器那一刻也已经 `finished` 了）。
    /// 现在由 `downloadIPA` 在起传输前登记，取消时 `abort()` 凭它删。
    ///
    /// 语义：登记的是「本次调用的产物路径」，**成功落盘后故意保留**（注入 sinf 的窗口还要用）；
    /// 失败 / 取消时由 `downloadIPA` 摘除。控制面按任务 id 建、任务收尾即从中心摘掉，
    /// 因此不会指到别人的文件上。
    private var destination: URL?

    /// v0.3.676：登记 / 摘除本次下载的落盘目标（`fileprivate`：只有同文件的 `downloadIPA` 会调）。
    fileprivate func recordDestination(_ url: URL?) {
        lock.lock()
        destination = url
        lock.unlock()
    }

    /// 下载器建好后把自己登记进来；此前若有暂停 / 取消意图，立刻补做。
    /// `fileprivate`：参数是文件私有的 `IPAFileDownloader`，只有同文件的下载器会调它。
    fileprivate func attach(_ d: IPAFileDownloader) {
        lock.lock()
        downloader = d
        let pause = pendingPause
        let abort = pendingAbort
        pendingPause = false
        pendingAbort = false
        lock.unlock()
        if abort { d.abort() } else if pause { d.pause() }
    }

    func pause() {
        lock.lock()
        guard let d = downloader else { pendingPause = true; lock.unlock(); return }
        lock.unlock()
        d.pause()
    }

    func resume() {
        lock.lock()
        let d = downloader
        lock.unlock()
        d?.resume()
    }

    func abort() {
        lock.lock()
        let d = downloader
        // v0.3.676（D1）：目标路径在这里先取出来 —— 下载器可能在「网络已下完」那一刻就已经
        // `finished` 了，它自己的 `abort()` 会因此提前返回（见下），清理只能由这边兜。
        let target = destination
        if d == nil { pendingAbort = true }
        lock.unlock()
        // ① 传输还在跑时，这条线才是主力：停 task、删半成品、让 continuation 以取消错误收尾。
        d?.abort()
        // ② 兜住「下载器已 finished、文件已落盘」那个窗口（本次修的缺陷）。
        //
        // `IPAFileDownloader.abort()` 首行是 `guard !finished`，而 `finish(.success(keep))`
        // 一执行完 `finished` 就是 true ⇒ 在「网络下载已完成、`downloadIPA` 正把 keep 搬成
        // `dest` / 之后 `AppStoreLocalInstallService` 正在注入 sinf」这段时间里，
        // 上面那句 `d?.abort()` 是**空操作**：行删了、dest 还在，注入完还会照常写台账。
        // 所以这里不依赖下载器的状态位，直接按登记过的 dest 再删一次
        // （文件不存在就是 no-op；删失败也不阻断 —— `downloadIPA` 的失败分支还有一次兜底）。
        //
        // 为什么由控制面来删而不是下载器：`dest` 的文件名由 Apple 回的
        // `bundleShortVersionString` 拼成（`<bundleID>-<version>.ipa`），下载中心按任务字段
        // 拼不出来，只能由 `downloadIPA` 在起传输前登记进来（见 `recordDestination`）。
        if let target { try? FileManager.default.removeItem(at: target) }
    }
}

/// v0.3.659（task-3 D2）：downloadIPA 的「外层 Task 取消 → 底层 abort()」转接器。
///
/// 为什么需要它：withTaskCancellationHandler 的 onCancel 闭包在**另一个上下文**里跑，
/// 抓不到才刚被创建的下载器（下载器要在 continuation 闭包里才拿得到）。
/// 所以用一个只做三件事的小对象当桥：登记下载器、记住「取消已经来了」、两个方向谁后到谁补做。
///
/// 线程模型：register 在下载启动的那条任务上；cancel 来自取消源。
/// 一把 NSLock 收口，标 @unchecked Sendable 以便进 onCancel 闭包（Swift 6 严格并发）。
private final class DownloadCancellationBox: @unchecked Sendable {

    private let lock = NSLock()
    private var downloader: IPAFileDownloader?
    private var cancelled = false

    /// 下载器建好后登记；若取消**已经**先到，立刻补一次 abort()。
    func register(_ d: IPAFileDownloader) {
        lock.lock()
        downloader = d
        let already = cancelled
        lock.unlock()
        if already { d.abort() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let d = downloader
        lock.unlock()
        d?.abort()
    }
}

/// v0.3.300：带进度的 IPA 文件下载器（`URLSessionDownloadTask` + delegate）
///
/// 用回调式下载而非 `URLSession.download(for:)`，目的只有一个：**拿到字节级进度**。
/// 每次实例化创建一个独立 `URLSession`（用完即释放），互不干扰，可在多个安装任务中并发使用。
///
/// v0.3.583：**补上「暂停 / 继续 / 取消」**。旧实现不持有 task 句柄、也没有任何暂停接口
/// ⇒ AppleID 通道的暂停 / 取消全是空操作。现在照 `RemoteDownloader`
/// （`IPADownloadCenter.swift`）的做法收口：持 task 句柄、用 `cancel(byProducingResumeData:)`
/// 暂停、用 `downloadTask(withResumeData:)` 续传、用 `cancel()` 取消。
private final class IPAFileDownloader: NSObject, URLSessionDownloadDelegate {

    private let onProgress: ((Double) -> Void)?
    /// v0.3.659（task-3 D3）：字节级进度（已下 / 总量）。非 nil 时每次 didWriteData 都回调，
    /// 让下载中心能算出字节数与瞬时速度（旧实现只透传 0~1 百分比）。
    private let onByteProgress: ((Int64, Int64) -> Void)?
    private let completion: (Result<URL, Error>) -> Void
    /// v0.3.571：非空时，每一次 HTTP 重定向的目标 host 都必须通过它（AppleID 通道传 Apple 域白名单）。
    /// nil = 不限制（爱思等非 Apple 源沿用旧行为）。
    private let hostPolicy: ((String) -> Bool)?
    /// 被本下载器拒绝跟随的重定向目标 host（用于给出可诊断的错误，而不是笼统的「HTTP 302」）。
    private var rejectedRedirectHost: String?
    /// 「删除安装包」时要清掉的落盘目标（`downloadIPA` 的 `dest`）。取消时一并删除 ——
    /// 旧实现删了行、文件与传输都还在，是**假成功**。
    private let destination: URL?

    /// v0.3.673（task-8 发现4b）：本次下载从系统临时目录搬出来的稳定副本（`ipa-<UUID>.part`）.
    ///
    /// `completion(.success(keep))` 之后，这个文件的所有权转移给调用方（`moveItem` 到
    /// `dest`）；但**在转移之前**任何一条失败路径（拒绝的跨域重定向、非 2xx、abort）
    /// 都必须在 `finish` 之前把它删掉，否则这份 UUID 命名的 GB 级包永远不会再被引用。
    /// 由 delegate 队列与主线程两条线碰，读写都在 `lock` 内.
    private var stagedPartial: URL?

    /// 在锁内「取走」已登记的分片文件 —— 返回非 nil 表示该文件由调用方负责删除或转移.
    private func takeStagedPartial() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let s = stagedPartial
        stagedPartial = nil
        return s
    }

    private var request: URLRequest?
    private var session: URLSession?
    /// v0.3.583：**持有 task 句柄** —— 这是能暂停 / 取消的前提（旧实现 `s.downloadTask(...)`
    /// 直接 resume，句柄丢掉，想停也停不了）。
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    private var finished = false
    private var paused = false
    /// 用户主动取消（删除安装包）。与暂停不同：要让 `downloadIPA` 的 continuation 以取消错误收尾。
    private var aborted = false

    /// 控制面（中心 → 本下载器）。`weak`：控制面由中心持有；本类不反向强持有，避免成环。
    private weak var control: IPADownloadControl?

    /// v0.3.549 同款：`paused` / `finished` / `task` / `resumeData` 会被 URLSession 的 delegate
    /// 队列与主 actor 上的 `pause` / `resume` / `abort` 两条线程碰，用一把锁收口。
    private let lock = NSLock()

    init(control: IPADownloadControl?,
         destination: URL?,
         hostPolicy: ((String) -> Bool)?,
         progress: ((Double) -> Void)?,
         byteProgress: ((Int64, Int64) -> Void)? = nil,
         completion: @escaping (Result<URL, Error>) -> Void) {
        self.control = control
        self.destination = destination
        self.hostPolicy = hostPolicy
        self.onProgress = progress
        self.onByteProgress = byteProgress
        self.completion = completion
        super.init()
    }

    func start(request: URLRequest) {
        // v0.3.659（task-3 D2）：已经取消过就不要再起传输。
        // 场景：取消意图在 register 之前到达（DownloadCancellationBox.register 已补做 abort），
        // 或者控制面在 attach 之前就收到了「删除安装包」（IPADownloadControl 的 pendingAbort）。
        // 不挡这一下，abort 之后仍会新建 session 并 resume —— 等于「删了还在下」。
        lock.lock()
        let dead = finished || aborted
        lock.unlock()
        guard !dead else { return }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        lock.lock()
        self.request = request
        session = s
        let t = s.downloadTask(with: request)
        task = t
        lock.unlock()
        // 先把控制面接上（用户可能在下载器建好前就点了暂停 / 删除），再真正开始传输。
        control?.attach(self)
        t.resume()
    }

    /// 暂停：`cancel(byProducingResumeData:)` 取消底层 task 并留下续传数据
    /// （对齐 `RemoteDownloader.pause`）。
    func pause() {
        lock.lock()
        guard !finished, !aborted, let t = task else { lock.unlock(); return }
        paused = true
        lock.unlock()
        // 注意：`cancel(byProducingResumeData:)` **可能同步执行回调**，必须在**不持锁**时调，
        // 否则回调里的 `lock.lock()` 会自锁死（同 `RemoteDownloader.pause` 的注释）。
        t.cancel(byProducingResumeData: { [weak self] data in
            guard let self else { return }
            self.lock.lock(); self.resumeData = data; self.lock.unlock()
        })
    }

    /// 继续：用 `resumeData` 建新 task 续传；服务器不支持 Range（拿不到 resumeData）时从头下。
    func resume() {
        lock.lock()
        guard !finished, !aborted else { lock.unlock(); return }
        paused = false
        let data = resumeData
        resumeData = nil
        let req = request
        let t: URLSessionDownloadTask?
        if let data {
            t = session?.downloadTask(withResumeData: data)
        } else {
            t = req.flatMap { session?.downloadTask(with: $0) }
        }
        task = t
        lock.unlock()
        t?.resume()
    }

    /// 取消：停掉传输、清掉半成品 / 目标文件、让 `downloadIPA` 以取消错误收尾。
    /// 用户「删除安装包」走这里 —— 旧实现对 AppleID 通道是空操作（行删了、传输照跑）。
    func abort() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        aborted = true
        paused = true
        let t = task
        let s = session
        session = nil
        lock.unlock()
        t?.cancel()
        s?.finishTasksAndInvalidate()
        if let destination { try? FileManager.default.removeItem(at: destination) }
        // v0.3.673（task-8 发现4b）：取消时可能已经搬出了 `ipa-<UUID>.part`，一并清掉.
        if let staged = takeStagedPartial() { try? FileManager.default.removeItem(at: staged) }
        // 让 `downloadIPA` 的 continuation 以取消错误收尾 —— 否则 detached 任务会一直挂在
        // 那个 continuation 上。取消**不是**失败：中心已先把 job 从 `jobs` 移除，
        // `startWithAppleID` 的 catch 会因「job 已不存在」而跳过失败处理。
        completion(.failure(CancellationError()))
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let s = session
        session = nil
        lock.unlock()
        s?.finishTasksAndInvalidate()
        completion(result)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // v0.3.583：**暂停 / 取消后不再上报进度**（对齐 `RemoteDownloader.didWriteData`）。
        // 暂停靠 `cancel(byProducingResumeData:)` 实现，取消是异步生效的 —— 在它落地前，
        // 已在网络上的数据包仍会送到这里；不看 `paused` 的话界面进度会在暂停后继续爬。
        lock.lock()
        let stop = paused || finished
        lock.unlock()
        guard !stop else { return }
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress?(min(1.0, max(0.0, p)))
        // v0.3.659（task-3 D3）：字节数一并给出，下载中心据此写 receivedBytes / totalBytes / 速度。
        onByteProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // v0.3.583：**暂停 / 取消期间落地的文件不算下载完成**（对齐 `RemoteDownloader`）。
        // 「暂停」与「刚好下完」可能撞在一起：`cancel(byProducingResumeData:)` 对**已完成**
        // 的任务是 no-op，而文件已经躺在 `location` 了 —— 不挡的话这次暂停等于没发生。
        lock.lock()
        let stop = paused || finished
        lock.unlock()
        if stop {
            try? FileManager.default.removeItem(at: location)
            return
        }
        // 先看有没有「被拒绝跟随的重定向」——那种情况下这个回调拿到的只是 3xx 响应体，
        // 不是 IPA。给出明确错误，别让它落到下面的状态码分支里报成笼统的「HTTP 302」。
        if let bad = rejectedRedirectHost {
            // v0.3.673（task-8 发现4b）：这条分支在 `keep` 搬出来**之前**就 return，必须把体删掉.
            //
            // 旧代码直接 `finish(.failure)` 就走了 —— 被拒绝跟随的重定向照样把 3xx 的
            // 响应体落成 `ipa-<UUID>.part`，那份体可能就是一个几百 MB 的错误页/登录页.
            // 它没有登记到 `stagedPartial`，所以只有这里能删.
            try? FileManager.default.removeItem(at: location)
            finish(.failure(AppStoreInstallService.InstallError.untrustedHost(bad)))
            return
        }
        // 系统在回调返回后即删除临时文件，必须先搬到稳定位置
        let keep = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipa-\(UUID().uuidString).part")
        do {
            try? FileManager.default.removeItem(at: keep)
            try FileManager.default.moveItem(at: location, to: keep)
        } catch {
            // v0.3.673：搬失败时 `location` 仍是我们的责任，系统此刻还没删它 —— 主动删，
            // 否则又回到「每次失败留一份完整包」.
            try? FileManager.default.removeItem(at: location)
            finish(.failure(error))
            return
        }
        // v0.3.673（task-8 发现4b）：登记所有权，让 abort() 也能清掉这份已搬好的文件.
        lock.lock()
        stagedPartial = keep
        lock.unlock()
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            // v0.3.662（task-8 发现4）：**失败分支必须把刚搬出来的 keep 删掉**.
            //
            // 上面 :543-547 已经把系统临时文件搬到了 `ipa-<UUID>.part` —— 不删的话，
            // 这个 UUID 命名的文件永远不会再被任何代码引用（下次下载会用新 UUID），
            // 于是**每一次 HTTP 非 2xx 的失败都留下一份完整的包体**。重定向到登录页/错误页时
            // 这个体量可以到 GB 级，几次之后就把 App 的 tmp 目录塞满.
            _ = takeStagedPartial()
            try? FileManager.default.removeItem(at: keep)
            finish(.failure(AppStoreInstallService.InstallError
                .requestFailed("下载 HTTP \(http.statusCode)")))
            return
        }
        // 所有权转移给调用方（downloadIPA 会把它 moveItem 到 dest）.
        _ = takeStagedPartial()
        finish(.success(keep))
    }

    /// v0.3.571：AppleID 通道要求下载（含重定向）落在 Apple 自有域。
    ///
    /// `hostPolicy == nil` 时**原样放行**（爱思等非 Apple 源行为不变）。
    /// 非 nil 时：目标必须仍是 https 且通过白名单，否则**拒绝跟随**（`completionHandler(nil)`）——
    /// URLSession 会把 3xx 当最终响应交给 `didFinishDownloadingTo`，那里据此报明确错误。
    /// 这样「初始 URL 是 Apple 域、但被 302 引到第三方」这条绕过也被堵住。
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let hostPolicy else {
            completionHandler(request)
            return
        }
        guard request.url?.scheme?.lowercased() == "https",
              let host = request.url?.host?.lowercased(), hostPolicy(host) else {
            rejectedRedirectHost = request.url?.host ?? "?"
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        let done = finished
        let isPaused = paused
        lock.unlock()
        if done { return }
        // v0.3.583：暂停靠 `cancel(byProducingResumeData:)` 实现，必然产生 `URLError.cancelled` ——
        // 那是暂停的一部分（`resume` 会用 resumeData 接着下），**不是**失败，直接丢弃。
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        if isPaused { return }
        // v0.3.673（task-8 发现4b）：搬好之后、交给调用方之前传输就断了（网络中断 / 连接被
        // 重置），文件已经完整躺在 `ipa-<UUID>.part` 里，而调用方永远拿不到这个 URL —— 必须
        // 在这里自己清掉，否则残留一份没人引用的整包.
        if let staged = takeStagedPartial() { try? FileManager.default.removeItem(at: staged) }
        if let error { finish(.failure(error)) }
    }
}
