import Foundation
import UIKit
import CryptoKit

/// 获取 Anisette Data（Apple 设备认证数据）的 v3 流程实现.
/// 参考 GetMoreRam / SideStore 的 Anisette v3 协议，纯原生实现（无第三方依赖）.
///
/// - 若钥匙串中已有 `identifier` + `adiPb`（来自 SideStore 账户导入或上一次的成功配置），
///   直接走 `/v3/get_headers`.
/// - 否则执行一次完整的 WebSocket 配给（provisioning）流程，把 `adiPb` 存入钥匙串后再取 headers.
final class AnisetteProvider {
    /// Swift 6 并发检查：本类型非 Sendable。可变字段（clientInfo / userAgent / mdLu /
    /// deviceId / lastFailureStage）是**单次 anisette 流程内的临时状态**：由
    /// `fetchClientInfo` / `provision` 写、同一流程内的 `makeAppleRequest` / `fail` 读。
    /// 现有调用方（AppleDeveloperAPI / AppleIDLoginSheet / IPAInstallService）均以
    /// `await` 串行发起，不存在并发进入 —— 这是既有设计，本次迁移不改语义。
    nonisolated(unsafe) static let shared = AnisetteProvider()

    private let keychain = EscapeKeychain(service: "com.tequila.dash.memorylimit")
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        // v0.2.114：Anisette 服务器偶发无响应会导致整个页面卡在「正在加载团队…」.
        // 给该 session 下所有请求（含 WebSocket receive）统一设 30 秒无活动超时，
        // 作为单个请求显式 timeoutInterval 的兜底.
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// v0.3.662（task-13 发现9）：**把取数入口串行化**.
    ///
    /// 上面 :12-16 的注释原本断言「现有调用方均以 await 串行发起，不存在并发进入」——
    /// 该前提并不成立：`AppleDeveloperAPI` 的每个公开方法（fetchTeams / fetchAppIDs /
    /// fetchCertificates / submitSigningCertificate / revokeCertificate …）各自调用
    /// `makeHeaders` → `getAnisetteDataWithFallback`，而 AppleIDLoginSheet 也会并发发起。
    /// 这些调用共享同一份**无锁**可变状态（clientInfo / userAgent / mdLu / deviceId），
    /// 失败路径上的 `reset()` / `resetProvisioning()` 还会把它们清空 ——
    /// 交错时一方会读到另一方刚清掉的字段，`makeAppleRequest` 随即抛「缺少 client_info 字段」.
    ///
    /// 这里用一把异步信号量把**整个取数流程**串起来，使「串行」由代码保证而不是靠调用方自觉。
    /// 不改任何公开签名；等待上限与取数自身的超时预算对齐（避免自己也变成永久阻塞）。
    private let fetchGate = AsyncGate()

    /// 极简异步互斥（FIFO 不在语义要求内，够用即可）.
    /// 用 actor 持有状态 + 轮询等待，避免引入 AsyncSemaphore 之类的新依赖.
    private final class AsyncGate {
        private let lock = NSLock()
        private var busy = false
        /// 单次等锁上限：比单次取数硬超时（35s）更长，确保等待者不会比取数本身先放弃.
        ///
        /// v0.3.664（CI run 39128137548）：`NSLock.lock()` / `unlock()` 被 Foundation 标成
        /// `@available(*, noasync)` —— 在 async 函数里**直接调用**会编译失败
        /// （"instance method 'lock' is unavailable from asynchronous contexts"）。
        /// 所以把加解锁收进同步 helper，async 侧只调用同步函数，语义不变.
        private func acquireIfFree() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if busy { return false }
            busy = true
            return true
        }
        func tryAcquire(timeout: TimeInterval) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if acquireIfFree() { return true }
                if Date() >= deadline { return false }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        func release() {
            lock.lock()
            defer { lock.unlock() }
            busy = false
        }
    }

    private var url: URL? { URL(string: UserDefaults.standard.string(forKey: "AnisetteServer") ?? "https://ani.stikstore.app") }


    /// v0.3.310：把 `X-MMe-Client-Info` 里的客户端标识改写成 `com.apple.akd/1.0`.
    ///
    /// **依据**（AltStore classic 2026-09-10 提交 c558994「fix(anisette): restore Apple ID
    /// sign-in rejected by Apple's servers」）：Apple 认证边缘现在对**任何**
    /// `X-MMe-Client-Info` 里标识为 `com.apple.dt.Xcode` 的登录请求直接返回 503
    /// （发生在校验凭据之前，与账号无关）。修法就是把客户端标识改报成真正执行该请求的
    /// 守护进程 `akd`。公共 anisette 服务多还在用 Xcode 形态，故这里统一改写。
    ///
    /// v0.3.613：**用户自定义优先**。依据 SideSign PR #5「Fix 2FA failing」（2026-10-13
    /// merged）—— GSA 开始指纹识别 adi 库，既有 anisette 服务器生成的 headers 被拒
    /// （用户侧表现 `Code -80045`）；把 client info 换成 Android 形态可绕过。
    /// 判据会再变，故做成可编辑（设置 -> Anisette 服务器 -> 客户端标识），
    /// 与 SideStore 的 `customAnisetteClientInfo` 同款优先级（自定义 > 默认）.
    static func normalizedClientInfo(_ raw: String?) -> String {
        // 1) 用户在设置里填了自定义值 -> 直接用它，不做任何改写.
        if let custom = UserDefaults.standard.string(forKey: "CustomAnisetteClientInfo"),
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2) 否则按既有规则改写服务器返回值（兜底内置默认）.
        let device = UIDevice.current
        let fallback = "<\(device.model)> <iOS;\(device.systemVersion)> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        guard var text = raw, !text.isEmpty else { return fallback }
        if let r = text.range(of: "(com.apple.", options: .backwards) {
            text = String(text[text.startIndex..<r.lowerBound]) + "(com.apple.akd/1.0)>"
        } else if !text.contains("com.apple.") {
            text += " <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        }
        return text
    }

    // MARK: - 服务器分类与顺序（对齐 SideInstaller 56ecbf823 / edb277cd1）

    /// 已知运行 Apple macOS ADI 库的服务器主机（上游 macADIHosts）.
    static let macADIHosts: Set<String> = ["mac-ani.jkcoxson.com", "new.ani.sidestore.io"]

    /// 已知运行 Apple Windows ADI 库的服务器主机（上游 windowsADIHosts）.
    static let windowsADIHosts: Set<String> = ["ani.jkcoxson.com", "win.ani.sidestore.io", "ani2.stikstore.app"]

    /// 服务器运行的 ADI 库："mac" / "windows" / "android"（上游 AnisetteServer.library）.
    /// 已知主机命中；否则按地址子串判（上游按列表显示名判 "mac adi" / "windows"，
    /// 本仓内置列表条目是纯 URL、无显示名，退化为地址子串判据）；默认 android.
    static func adiLibrary(of address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = URL(string: trimmed)?.host?.lowercased() {
            if macADIHosts.contains(host) { return "mac" }
            if windowsADIHosts.contains(host) { return "windows" }
        }
        let key = trimmed.lowercased()
        if key.contains("mac adi") { return "mac" }
        if key.contains("windows") { return "windows" }
        return "android"
    }

    /// 按「上报设备」计 Apple 的 503 拒绝次数（上游 AppleRefusals）：
    /// mac 库服务器上报 Mac，其余（windows/android）上报 Windows PC.
    static var refusalByDevice: [String: Int] = [:]

    /// 清空 503 计数，进入取数流程时调用.
    static func clearRefusalLog() { refusalByDevice.removeAll() }

    static func deviceOf(_ address: String) -> String {
        adiLibrary(of: address) == "mac" ? "mac" : "windows"
    }

    static func refusalCount(for address: String) -> Int { refusalByDevice[deviceOf(address)] ?? 0 }

    /// 该地址上报的设备已被 Apple 拒绝 >=2 次（上游 rulesOut）.
    static func isRefusalRuledOut(_ address: String) -> Bool { refusalCount(for: address) >= 2 }

    /// 记录一次 Apple 拒绝.
    static func recordRefusal(for address: String) {
        refusalByDevice[deviceOf(address), default: 0] += 1
    }

    static func refusalTotal() -> Int { refusalByDevice.values.reduce(0, +) }

    static func isRefusalError(_ error: Error) -> Bool { error.localizedDescription.contains("503") }

    /// 剩余服务器（ordered 中 idx 之后）是否全部被拒（上游 endsSignIn 判据）.
    static func allRemainingRuledOut(after idx: Int, ordered: [String]) -> Bool {
        ordered.suffix(from: idx + 1).allSatisfy { isRefusalRuledOut($0) }
    }

    static func orderedIndex(of server: String, in ordered: [String]) -> Int {
        ordered.firstIndex(of: server) ?? 0
    }

    /// 规范化服务器地址（去首尾空白/尾斜杠/小写），用于去重比较.
    static func normalized(_ address: String) -> String {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while a.hasSuffix("/") { a.removeLast() }
        return a.lowercased()
    }

    /// 服务器尝试顺序（上游 candidates）：pick 优先，随后同库（非 android）、
    /// windows、非 mac，mac 最后，全程去重.
    static func orderedCandidates(pick: String, servers: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ address: String) {
            let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if !a.isEmpty, seen.insert(normalized(a)).inserted { out.append(a) }
        }
        add(pick)
        let pickLibrary = adiLibrary(of: pick)
        if pickLibrary != "android" {
            servers.filter { adiLibrary(of: $0) == pickLibrary }.forEach(add)
        }
        servers.filter { adiLibrary(of: $0) == "windows" }.forEach(add)
        servers.filter { adiLibrary(of: $0) != "mac" }.forEach(add)
        servers.forEach(add)
        return out
    }

    /// 当前 adiPb 是经哪台服务器配出（一库一身份的配对记录；上游 anisette_slots
    /// 的单身份形态：本仓 keychain 只存一份 identifier + adiPb）.
    static func pairingServer() -> String? {
        UserDefaults.standard.string(forKey: "AnisetteIdentityServer")
    }

    static func setIdentityServer(_ url: String) {
        UserDefaults.standard.set(url, forKey: "AnisetteIdentityServer")
    }
    private var clientInfo: String?

    private var userAgent: String?
    private var mdLu: String?
    private var deviceId: String?

    /// 最近一次失败的阶段（`provision` / `get_headers` / `client_info` / `入口`），
    /// 由 `fail()` 写入，供 `getAnisetteDataWithFallback` 决定"要不要换设备身份".
    /// v0.2.119：只有 provisioning 阶段被拒才需要换 identifier；取票据失败换服务器即可.
    private var lastFailureStage: String?

    // v0.3.260：本类不再服务于「App Store 下载」——该功能的 iTunes 认证已切
    // SAP-only（对齐上游 ipatool abd86cb），认证请求不含 anisette 头.本类保留
    // 仅为「IPA 侧载」的机器标识共享（sharedMachineIdentifier/sharedAdiPb →
    // isideload/Rust 侧），v3 服务器流程仅在侧载场景被消费.

    private init() {}

    /// 重置：signOut / 切换账号时调用.清空内存缓存并删除 keychain 里的
    /// identifier+adiPb，确保下一次登录重新走完整 provision 并重新生成 identifier.
    func reset() {
        clientInfo = nil
        userAgent = nil
        mdLu = nil
        deviceId = nil
        keychain.delete("identifier")
        keychain.delete("adiPb")
        // 身份销毁：清除一库一身份的配对记录（上游 Slots：服务器不再认这份身份）.
        UserDefaults.standard.removeObject(forKey: "AnisetteIdentityServer")
        LoginLogger.shared.log("… AnisetteProvider 重置（identifier/adiPb 已清除）", category: .appleID)
    }

    /// **只作废 provisioning 票据（adiPb）与内存缓存，保留设备身份 identifier.**
    ///
    /// v0.2.119 关键修复.此前 `getAnisetteDataWithFallback` 任何失败都调 `reset()`，
    /// 连 identifier（"虚拟机器"身份）一起删掉 —— 后果是：
    /// 1. Swift 侧每失败一次就换一台"虚拟机器"，Apple 端视为多设备 → 风控；
    /// 2. identifier 被删后 `sharedMachineIdentifier` 返回 nil，
    ///    `syncSharedAnisetteStateIfAvailable()` 直接 return，**不会更新 isideload 的
    ///    `anisette_state`**，Rust 侧继续用已被抛弃的旧身份 → 两套实现状态彻底分裂.
    ///    这正是「IPA 侧载一登录，证书管理/增加内存限制就卡」的传导链.
    ///
    /// 取票据（get_headers）失败绝大多数是单点服务器问题，换服务器重试即可，
    /// 不该为此丢弃一个已经正常工作的设备身份.
    func resetProvisioning() {
        clientInfo = nil
        userAgent = nil
        mdLu = nil
        deviceId = nil
        keychain.delete("adiPb")
        // 票据销毁：配对一并清除（上游 Slots：该服务器不再认这份身份）.
        UserDefaults.standard.removeObject(forKey: "AnisetteIdentityServer")
        LoginLogger.shared.log("… Anisette 票据作废（保留 identifier，仅重新 provision）", category: .appleID)
    }

    // MARK: - 共享机器标识（v0.2.117）

    /// keychain 里当前 identifier 的原始 16 字节（IPA 侧载/Rust 复用同一台
    /// "虚拟机器"用）；无或损坏时返回 nil.
    var sharedMachineIdentifier: Data? {
        guard let s = keychain.string(for: "identifier"),
              let d = Data(base64Encoded: s), d.count == 16 else { return nil }
        return d
    }

    /// keychain 里当前 adiPb 的原始字节（base64 字符串解码）；无则 nil.
    var sharedAdiPb: Data? {
        guard let s = keychain.string(for: "adiPb") else { return nil }
        return Data(base64Encoded: s)
    }

    /// 统一失败出口：写诊断日志并返回带真实原因的错误（不再用笼统的 invalidAnisetteData）.

    /// 统一失败出口：写诊断日志并返回带真实原因的错误（不再用笼统的 invalidAnisetteData）.
    private func fail(_ stage: String, _ detail: String) -> AppleAPIError {
        lastFailureStage = stage
        LoginLogger.shared.log("[失败] Anisette[\(stage)]: \(detail)", category: .appleID)
        return AppleAPIError.customError(code: -22421, message: "Anisette \(stage)失败: \(detail)")
    }

    /// v0.3.613：本机 Anisette 取数（ADI 引擎 + Unicorn AArch64 解释器）.
    ///
    /// 与远程 `fetchAnisetteV3` 的差别：**不经任何 anisette 服务器** ——
    /// 直接把 `identifier` + `adiPb` 交给 C++ 层，由 Unicorn 在本进程内解释执行
    /// ADI 引擎产出 headers。因此 machineID 不会因服务器侧变化而漂移
    /// （MJorb 记过的坑：`.so` 拿不到 -> 回退远程 -> machineID 漂移 -> Apple ID 失效）。
    private func fetchAnisetteLocal() async throws -> AnisetteData {
        let mgr = OnDeviceAnisetteManager.shared
        guard let identifierStr = keychain.string(for: "identifier"),
              let identifier = Data(base64Encoded: identifierStr),
              identifier.count == 16 else {
            throw fail("本机", "缺少或非法的 identifier（需 16 字节）")
        }
        guard let adiPbStr = keychain.string(for: "adiPb"),
              let adiPb = Data(base64Encoded: adiPbStr), !adiPb.isEmpty else {
            throw fail("本机", "缺少 adiPb")
        }
        // C 层只 mkdir 了 <provisioning>/<uuid>，父目录必须由 Swift 先建，
        // 否则全新安装时写入 adi.pb 会失败（审计发现：父目录从未创建）.
        try? FileManager.default.createDirectory(
            at: mgr.provisioningDirectory, withIntermediateDirectories: true)

        // v0.3.616：**身份组装与远程路径对齐**.
        //
        // 审计发现（P1）：C 层 `get_anisette_headers_uc` 不输出 device-id / client-info，
        // 且 `X-Apple-I-MD-LU` 硬编码为「63 个 0 + 1」（anisette_base.h 的占位）；
        // 而 `OnDeviceAnisetteClient.parseHeaders` 会拿 UIDeviceLike（identifierForVendor）
        // 兜底 ⇒ 同一个 identifier，本机与远程产出的 LU / deviceId / clientInfo 三者不同，
        // Apple 侧会看成两台不同设备.
        //
        // 修法：本机路径也先走 `fetchClientInfo()`（有内存缓存就**不联网**），
        // 再把与 `extractAnisetteData` 完全相同的三个字段作为 identity 传入 ——
        // 保证同一 identifier 在两条路径下产出**一致**的虚拟设备身份.
        // 注意 `AnisetteData` 的字段是 `let`，不能事后覆盖，必须**在构造时**传入.
        try await fetchClientInfo()
        let identity = OnDeviceAnisetteClient.AnisetteIdentity(
            localUserID: mdLu ?? "",
            deviceUniqueIdentifier: deviceId ?? "",
            deviceDescription: clientInfo.map(Self.normalizedClientInfo) ?? "")
        let anisette = try OnDeviceAnisetteClient.headers(
            identifier: identifier,
            adiPb: adiPb,
            libDirectory: mgr.engineDirectory,
            provisioningDirectory: mgr.provisioningDirectory,
            identity: identity)
        LoginLogger.shared.log(
            "[完成] 本机身份已对齐远程口径: lu=\(identity.localUserID.prefix(12))… dev=\(identity.deviceUniqueIdentifier.prefix(12))…",
            category: .appleID)
        return anisette
    }

    /// 构造带 Apple 设备头的请求（对齐 GetMoreRam `buildAppleRequest`）.
    /// gsa lookup / midStartProvisioning / midFinishProvisioning 都必须带这些头，
    /// 否则 Apple 返回 404（此前裸 GET 的根因）.
    private func makeAppleRequest(url: URL) throws -> URLRequest {
        guard let clientInfo, let userAgent, let mdLu, let deviceId else {
            throw fail("provision", "缺少 client_info 字段（未先 fetchClientInfo）")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(mdLu, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(deviceId, forHTTPHeaderField: "X-Mme-Device-Id")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        request.setValue(formatter.string(from: Date()), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(TimeZone.current.abbreviation(), forHTTPHeaderField: "X-Apple-I-TimeZone")
        return request
    }

    func getAnisetteData(refresh: Bool = false) async throws -> AnisetteData {
        // v0.3.613：本机 Anisette（ODA）接线；v0.3.616 修正开关判据.
        //
        // `remoteFallbackReason` 的契约：**nil = 可以走本机**（开关开 + 引擎就绪），
        // 非 nil = 回退远程的原因. 因此这里只有 nil 才尝试本机 —— 旧实现在
        // `.ready` 时返回「尚未接线」文案，导致开关打开反而永远走远程.
        //
        // 本机路径依赖 C++ 层（OnDeviceAnisetteClient -> anisette_core_uc.cpp ->
        // elf_loader_emulator.cpp -> Unicorn AArch64 解释器），见 OnDeviceAnisetteClient 顶部注释。
        if let reason = OnDeviceAnisetteManager.shared.remoteFallbackReason {
            LoginLogger.shared.log("[本机Anisette] 回退远程：\(reason)", category: .appleID)
        } else if let local = try? await fetchAnisetteLocal() {
            LoginLogger.shared.log("[完成] 本机 Anisette 取数成功（不走远程服务器）", category: .appleID)
            return local
        } else {
            LoginLogger.shared.log("[本机Anisette] 本机取数失败，回退远程", category: .appleID)
        }

        if refresh {
            // v0.3.166：refresh = 强制重签 provisioning 票据（作废 adiPb 保留 identifier）.
            // 背景：ani.846969.xyz 对同一 (identifier, adiPb) 缓存 get_headers 结果，
            // 旧实现 refresh 只清内存缓存 → 仍命中 keychain 的 identifier+adiPb →
            // 拿到与上次完全相同的 OTP（真机日志实锤：两次 refresh=true 返回同一
            // X-Apple-I-MD）→ Apple 边缘判定重放/已标记 → native/fast 301/404.
            // identifier 必须保留（v0.2.117 铁律：换 identifier = 换虚拟机器 = 风控）.
            resetProvisioning()
        }
        LoginLogger.shared.log("[开始] getAnisetteData(refresh=\(refresh)) url=\(url?.absoluteString ?? "nil")", category: .appleID)
        guard url != nil else { throw fail("入口", "Anisette 服务器地址为空") }
        if let identifier = keychain.string(for: "identifier"),
           let adiPb = keychain.string(for: "adiPb") {
            LoginLogger.shared.log("[完成] 命中已缓存 identifier+adiPb，直接 get_headers", category: .appleID)
            return try await fetchAnisetteV3(identifier: identifier, adiPb: adiPb)
        }
        LoginLogger.shared.log("… 无缓存凭证，走完整 WebSocket provision", category: .appleID)
        return try await provision()
    }

    // MARK: - 服务器轮换 + 失败重试

    /// 当前 Anisette 服务器地址（供日志/展示用）.
    var currentServer: String {
        UserDefaults.standard.string(forKey: "AnisetteServer") ?? "https://ani.stikstore.app"
    }

    /// 切换到内置服务器列表中的下一个（按优先级顺序：同库 → windows → 非 mac → mac），
    /// 并持久化到 `AnisetteServer`. 返回切换后的地址；列表为空时返回 nil.
    ///
    /// Swift 6：`MemoryLimitSettings.anisetteServers` 是主线程隔离的常量数组 ——
    /// 只在 `MainActor.run` 里取它（闭包无 self 捕获），其余逻辑留在调用方隔离域，
    /// 不再把 self 传进主 actor（修 sending 'self'）.
    ///
    /// 优先级顺序取自上游 `AnisetteServer.candidates`：先复用当前身份所在 ADI 库的
    /// 服务器，再走 windows，macOS-ADI 服务器最后尝试.
    @discardableResult
    private func rotateServer() async -> String? {
        let servers = await MainActor.run { MemoryLimitSettings.anisetteServers }
        guard !servers.isEmpty else { return nil }
        let current = currentServer
        let ordered = Self.orderedCandidates(pick: current, servers: servers)
        let next: String
        if let idx = ordered.firstIndex(of: current) {
            next = ordered[(idx + 1) % ordered.count]
        } else {
            // 当前服务器不在内置列表（用户自定义地址）：从优先级最高的内置服务器开始.
            next = ordered.count > 1 ? ordered[1] : servers[0]
        }
        UserDefaults.standard.set(next, forKey: "AnisetteServer")
        // 换服务器必须重取 client_info / user_agent（上游 set_url 清 client_info 缓存判据：
        // 防 A 服务器的 client info 配到 B 服务器）；mdLu / deviceId 由 identifier 派生、
        // 跨服务器稳定，保留.
        clientInfo = nil
        userAgent = nil
        LoginLogger.shared.log("… Anisette 服务器切换：\(current) → \(next)", category: .appleID)
        return next
    }

    /// 下一服务器与当前身份同库且 adiPb 仍有效 → 保留身份直接重试
    /// （上游判据：同一 ADI 库的身份互通，换同库服务器不重配、不换 identifier）.
    private func shouldKeepIdentity(for next: String?) -> Bool {
        guard let next,
              let paired = Self.pairingServer(),
              Self.adiLibrary(of: next) == Self.adiLibrary(of: paired),
              keychain.string(for: "adiPb") != nil else { return false }
        return true
    }

    /// **带重试与服务器轮换的入口**，登录 / 团队列表等场景应优先调用它.
    ///
    /// 背景：Anisette v3 的 provisioning 会被 Apple 或中间服务器明确拒绝，
    /// 典型如 `unknown session (-45025)`、`invalid Trust Key (-45003)`，
    /// 以及 WebSocket 中途 `Socket未连接`.这些**绝大多数是单个 Anisette 服务器
    /// 的问题**（与 Apple 的 trust key 不同步、被风控、或会话过期），换一个
    /// 服务器重试通常就能过.v0.2.114 加的超时只解决"卡死"，解决不了这类
    /// "服务器明确拒绝"，所以这里补上重试 + 轮换.
    ///
    /// 每次重试前会 `reset()`：清掉内存缓存与 keychain 里的 identifier/adiPb，
    /// 强制重新生成 identifier 并对新服务器走完整 provision，避免拿旧会话重试.
    /// 单次取数的硬超时（秒）——**小于**整体预算 75s，留出换服务器重试的余量.
    ///
    /// 取值依据：下面三条请求各自的显式 timeout 是 10s（client_info）/ 15s（get_headers）/
    /// 30s（WebSocket 与 gsa），最坏一次完整 provision ≈ 3~4 次串联，故 35s 是
    /// 「正常流程一定跑得完、卡死一定抓得住」的折中。它**不改变**任何成功路径的语义.
    private static let attemptTimeout: TimeInterval = 35

    /// 单次尝试的硬超时包装：超时会抛 `AppleAPIError`，由调用方走既有的换服务器重试.
    ///
    /// 为什么必须这样做：`getAnisetteData` 内部有 WebSocket 的
    /// `withCheckedThrowingContinuation`，它只在收到消息 / 出错时 resume；
    /// 服务器在握手后不再发消息时该 continuation 永不 resume，`await` 也就永不返回 ——
    /// 只靠「await 之后检查 elapsed」的外部预算是抓不住这种卡死的.
    private nonisolated static func withAttemptTimeout(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> AnisetteData
    ) async throws -> AnisetteData {
        try await withThrowingTaskGroup(of: AnisetteData.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AppleAPIError.customError(
                    code: -22421,
                    message: "Anisette 单次取数超过 \(Int(seconds)) 秒未返回（疑似服务器无响应）")
            }
            guard let first = try await group.next() else {
                throw AppleAPIError.customError(code: -22421, message: "Anisette 取数未返回")
            }
            group.cancelAll()
            return first
        }
    }

    func getAnisetteDataWithFallback(refresh: Bool = false, maxAttempts: Int = 3) async throws -> AnisetteData {
        // v0.3.662（task-13 发现9）：进入即抢占取数闸门，保证本流程专用的可变状态
        // (clientInfo / userAgent / mdLu / deviceId / lastFailureStage) 同一时刻只有一个写者.
        // 上限 60s：比最长一次流程（3 次尝试 × 35s 硬超时，实际受 75s 总预算约束）留出余量，
        // 但又给了「死等」一个确定终点，不会把新调用者永久挂在锁上.
        guard await fetchGate.tryAcquire(timeout: 60) else {
            throw AppleAPIError.customError(code: -22422, message: "等待上一个 Anisette 取数流程超时（60s），请稍后重试.")
        }
        defer { fetchGate.release() }
        let originalServer = currentServer
        let started = Date()
        // v0.2.116：整体时间预算.就算某个请求没被单条 timeout 拦住（例如 WebSocket
        // 在握手后长时间不发消息），超预算也直接放弃，绝不把 UI 永久留在 loading.
        let budget: TimeInterval = 75
        var lastError: Error?
        var attempt = 0
        let servers = await MainActor.run { MemoryLimitSettings.anisetteServers }
        let ordered = Self.orderedCandidates(pick: originalServer, servers: servers)
        // 本次流程的 503 按「上报设备」计数（上游 AppleRefusals 判据），进循环前清零.
        Self.clearRefusalLog()
        while attempt < maxAttempts {
            // 跳过已被 Apple 拒绝两次的服务器（按上报设备计；上游 rulesOut）.
            if Self.isRefusalRuledOut(currentServer) {
                attempt += 1
                let elapsed = Date().timeIntervalSince(started)
                guard attempt < maxAttempts, elapsed < budget else { break }
                LoginLogger.shared.log("… 跳过 Anisette 服务器 \(currentServer)（Apple 已拒绝其上报设备 \(Self.refusalCount(for: currentServer)) 次）", category: .appleID)
                if await rotateServer() == nil { break }
                continue
            }
            do {
                // v0.3.662（task-13 发现12）：**给单次取数加真正的硬超时**.
                //
                // 旧实现只在 `await` **返回之后**才检查 budget（见下方 `elapsed < budget`），
                // 于是「某一次 getAnisetteData 永不返回」时预算永远检查不到 ——
                // 最典型的是 `startProvisioningSession` 的 `withCheckedThrowingContinuation`
                // 只在 `receiveProvisioningMessages` 的 4 个分支里 resume，WebSocket 在握手后
                // 不再发消息时那个 continuation 会**永久挂住**。而本函数上方注释承诺
                // 「绝不把 UI 永久留在 loading」，旧代码做不到.
                //
                // 现在每次尝试都被一个独立的超时任务竞赛：超时即本任务抛错、
                // 交给下面的 catch 走「换服务器重试」与「还原服务器」逻辑.
                let data = try await Self.withAttemptTimeout(Self.attemptTimeout) {
                    try await Self.shared.getAnisetteData(refresh: refresh)
                }
                lastFailureStage = nil
                return data
            } catch {
                lastError = error
                attempt += 1
                let elapsed = Date().timeIntervalSince(started)
                guard attempt < maxAttempts, elapsed < budget else { break }
                // 按「上报设备」记录 Apple 的 503 拒绝（上游 AppleRefusals）：
                // Apple 对同一上报设备一视同仁地拒，两次后该设备对应的服务器全跳过.
                if Self.isRefusalError(error) {
                    Self.recordRefusal(for: currentServer)
                    if Self.refusalTotal() >= 2,
                       Self.allRemainingRuledOut(after: Self.orderedIndex(of: currentServer, in: ordered), ordered: ordered) {
                        LoginLogger.shared.log("… Apple 已拒绝 \(Self.refusalTotal()) 次（503），剩余服务器均被跳过，停止重试", category: .appleID)
                        break
                    }
                }
                let next = await rotateServer()
                let stage = lastFailureStage
                if stage == nil || stage == "provision" {
                    // stage == nil：错误不是 fail() 抛出的（如 URLSession 超时），
                    // 无法判断身份是否可用，退回原行为（换身份重来）最稳.
                    reset()
                } else if shouldKeepIdentity(for: next) {
                    // 下一服务器与当前身份同库：adiPb 仍可用，保留身份直接重试
                    // （上游判据：同一 ADI 库的身份互通，换同库服务器不重配）.
                    clientInfo = nil
                    userAgent = nil
                    LoginLogger.shared.log("… 下一服务器与当前身份同库，保留 adiPb 直接重试", category: .appleID)
                } else {
                    resetProvisioning()
                }
                LoginLogger.shared.log("[注意] Anisette 第 \(attempt)/\(maxAttempts) 次失败（阶段：\(stage ?? "未知")），换服务器重试", category: .appleID)
            }
        }
        // 全部失败：把服务器还原成用户原本配置的地址.
        // 否则失败过程中轮换到的坏服务器会被固化，之后每次进页面都先撞它.
        if currentServer != originalServer {
            UserDefaults.standard.set(originalServer, forKey: "AnisetteServer")
            LoginLogger.shared.log("… 已还原 Anisette 服务器为 \(originalServer)", category: .appleID)
        }
        let detail = (lastError as? AppleAPIError)?.errorDescription
            ?? lastError?.localizedDescription
            ?? "未知原因"
        LoginLogger.shared.log("[失败] Anisette 已尝试 \(maxAttempts) 个服务器仍失败（耗时 \(Int(Date().timeIntervalSince(started)))s）", category: .appleID)
        throw AppleAPIError.customError(
            code: -22421,
            message: "Anisette 连续 \(maxAttempts) 个服务器均失败（最后错误：\(detail)）.\n"
                + "可到「更多 → 设置 → Anisette 服务器」手动换一个，或稍后重试."
        )
    }

    // MARK: - V3: client_info

    private func fetchClientInfo() async throws {
        // 先检查 keychain 里的 identifier 是否仍有效. signOut 会删 identifier，
        // 但 AnisetteProvider 的内存缓存可能还在，此时必须重新生成 identifier，
        // 否则 provision 到 GiveIdentifier 时会从 keychain 读不到而报 -22421.
        let hasValidIdentifier: Bool = {
            guard let existing = keychain.string(for: "identifier") else { return false }
            guard let decoded = Data(base64Encoded: existing), decoded.count == 16 else { return false }
            return true
        }()

        if clientInfo != nil, userAgent != nil, mdLu != nil, deviceId != nil, hasValidIdentifier {
            return
        }

        guard let base = url else { throw fail("client_info", "服务器地址为空") }

        // client_info / user_agent 是设备描述，基本不变.只在内存缓存缺失时拉取.
        if clientInfo == nil || userAgent == nil {
            let clientInfoURL = base.appendingPathComponent("v3").appendingPathComponent("client_info")
            var clientInfoRequest = URLRequest(url: clientInfoURL)
            // v0.2.116：client_info 只是取设备描述字符串，正常几百毫秒就返回.
            // 服务器不可达时 30 秒太长，会让「正在加载团队…」转很久；缩到 10 秒，
            // 让失败快速暴露并进入换服务器重试.
            clientInfoRequest.timeoutInterval = 10
            let (data, response) = try await session.data(for: clientInfoRequest)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard http == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let ci = json["client_info"], let ua = json["user_agent"] else {
                let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                throw fail("client_info", "HTTP \(http) 响应异常: \(preview)")
            }
            clientInfo = ci
            userAgent = ua
            LoginLogger.shared.log("[完成] client_info OK: \(ci) / \(ua)", category: .appleID)
        } else if !hasValidIdentifier {
            LoginLogger.shared.log("… 内存缓存命中但 keychain identifier 已清除，重新生成", category: .appleID)
        }

        // identifier 必须以 base64 字符串存储（EscapeKeychain.string(for:) 用 UTF-8 解码，
        // 存原始字节会解码失败 → 登录报「Anisette数据无效或已过期」）.
        // 兼容清理：旧版本可能遗留了原始字节的坏数据，解码失败时重新生成.
        var identifier: String? = nil
        if hasValidIdentifier, let existing = keychain.string(for: "identifier") {
            identifier = existing
        }
        if identifier == nil {
            keychain.delete("identifier")
            var bytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw fail("identifier", "SecRandomCopyBytes 失败")
            }
            let newIdentifier = Data(bytes).base64EncodedString()
            keychain.set(newIdentifier, for: "identifier")
            identifier = newIdentifier
            LoginLogger.shared.log("… 重新生成 identifier（旧值缺失或损坏）", category: .appleID)
        }
        guard let identifier else { throw fail("identifier", "无法读取 identifier") }
        guard let decoded = Data(base64Encoded: identifier) else {
            throw fail("identifier", "identifier 不是合法 base64: \(identifier.prefix(12))…")
        }
        mdLu = Data(SHA256.hash(data: decoded)).map { String(format: "%02X", $0) }.joined()
        let uuid = decoded.withUnsafeBytes { $0.loadUnaligned(as: UUID.self) }
        deviceId = uuid.uuidString.uppercased()
        LoginLogger.shared.log("[完成] identifier=\(identifier.prefix(12))… mdLu=\(mdLu?.prefix(12) ?? "") deviceId=\(deviceId ?? "")", category: .appleID)
    }

    // MARK: - V3: get_headers

    func fetchAnisetteV3(identifier: String, adiPb: String) async throws -> AnisetteData {
        try await fetchClientInfo()
        guard let base = url else { throw fail("get_headers", "服务器地址为空") }
        var request = URLRequest(url: base.appendingPathComponent("v3").appendingPathComponent("get_headers"))
        request.httpMethod = "POST"
        // v0.2.116：get_headers 是一次简单 POST，15 秒足够；失败快才能快速换服务器.
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: ["identifier": identifier, "adi_pb": adiPb])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        LoginLogger.shared.log("[开始] get_headers POST \(base.appendingPathComponent("v3").appendingPathComponent("get_headers").absoluteString)", category: .appleID)
        let (data, response) = try await session.data(for: request)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1
        LoginLogger.shared.log("← get_headers HTTP \(http): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")", category: .appleID)
        return try await extractAnisetteData(data, response as? HTTPURLResponse, v3: true)
    }

    private func extractAnisetteData(_ data: Data, _ response: HTTPURLResponse?, v3: Bool) async throws -> AnisetteData {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw fail("get_headers", "响应不是 JSON: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        if v3, let result = json["result"] as? String, result == "GetHeadersError",
           let message = json["message"] as? String {
            LoginLogger.shared.log("[注意] get_headers 返回错误: \(message)", category: .appleID)
            if message.contains("-45061") {
                // 跨库/过期身份被 Apple 拒收（-45061）：记录配对诊断后删除重配.
                let paired = Self.pairingServer()
                keychain.delete("adiPb")
                LoginLogger.shared.log("… adiPb 已过期(-45061)，删除后重新 provision（当前：\(url?.absoluteString ?? "nil")，身份配对：\(paired ?? "无")）", category: .appleID)
                return try await provision()
            }
            throw AppleAPIError.customError(code: -1, message: "Anisette 服务器: \(message)")
        }

        var formatted: [String: String] = ["deviceSerialNumber": "0"]
        if let v = json["X-Apple-I-MD-M"] as? String { formatted["machineID"] = v }
        if let v = json["X-Apple-I-MD"] as? String { formatted["oneTimePassword"] = v }
        if let v = json["X-Apple-I-MD-RINFO"] as? String { formatted["routingInfo"] = v }
        else if let v = json["X-Apple-I-MD-RINFO"] as? Int { formatted["routingInfo"] = String(v) }

        if v3 {
            formatted["deviceDescription"] = Self.normalizedClientInfo(clientInfo)
            formatted["localUserID"] = mdLu ?? ""
            formatted["deviceUniqueIdentifier"] = deviceId ?? ""
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.calendar = Calendar(identifier: .gregorian)
            fmt.timeZone = TimeZone(secondsFromGMT: 0)
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            formatted["date"] = fmt.string(from: Date())
            formatted["locale"] = Locale.current.identifier
            formatted["timeZone"] = TimeZone.current.abbreviation() ?? "GMT"
        } else {
            if let v = json["X-MMe-Client-Info"] as? String { formatted["deviceDescription"] = Self.normalizedClientInfo(v) }
            if let v = json["X-Apple-I-MD-LU"] as? String { formatted["localUserID"] = v }
            if let v = json["X-Mme-Device-Id"] as? String { formatted["deviceUniqueIdentifier"] = v }
            if let v = json["X-Apple-I-Client-Time"] as? String { formatted["date"] = v }
            if let v = json["X-Apple-Locale"] as? String { formatted["locale"] = v }
            if let v = json["X-Apple-I-TimeZone"] as? String { formatted["timeZone"] = v }
        }

        guard let jsonData = try? JSONEncoder().encode(formatted),
              let anisette = try? JSONDecoder().decode(AnisetteData.self, from: jsonData) else {
            throw fail("get_headers", "Anisette 字段组装/解码失败: \(formatted.keys.sorted().joined(separator: ","))")
        }
        LoginLogger.shared.log("[完成] AnisetteData 组装成功: md=\(anisette.machineID.prefix(12))… otp=\(anisette.oneTimePassword.prefix(12))… rinfo=\(anisette.routingInfo)", category: .appleID)
        return anisette
    }

    // MARK: - V3: provisioning（首次使用、无 adi.pb 时）

    private func provision() async throws -> AnisetteData {
        LoginLogger.shared.log("[开始] provision 开始", category: .appleID)
        try await fetchClientInfo()
        let request = try makeAppleRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!)
        let (data, response) = try await session.data(for: request)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard http == 200,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]],
              let startStr = plist["urls"]?["midStartProvisioning"] as? String,
              let endStr = plist["urls"]?["midFinishProvisioning"] as? String,
              let startURL = URL(string: startStr), let endURL = URL(string: endStr) else {
            throw fail("provision", "gsa lookup 异常(HTTP \(http)): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        LoginLogger.shared.log("[完成] gsa lookup 拿到 mid 端点", category: .appleID)
        let adiPb = try await startProvisioningSession(startURL: startURL, endURL: endURL)
        guard let identifier = keychain.string(for: "identifier") else {
            throw fail("provision", "provision 后读取 identifier 失败")
        }
        // 先验证再入库（上游判据：配完先验证，烂服务器不会留下垃圾身份）.
        let headers = try await fetchAnisetteV3(identifier: identifier, adiPb: adiPb)
        keychain.set(adiPb, for: "adiPb")
        // 一库一身份：记录当前服务器与这份 adiPb 的配对（同库服务器可复用该身份）.
        Self.setIdentityServer(url?.absoluteString ?? "")
        LoginLogger.shared.log("… Anisette 身份已配对当前服务器 \(url?.absoluteString ?? "nil")", category: .appleID)
        return headers
    }

    private func startProvisioningSession(startURL: URL, endURL: URL) async throws -> String {
        guard let base = url else { throw fail("provision", "服务器地址为空") }
        var comps = URLComponents(url: base.appendingPathComponent("v3").appendingPathComponent("provisioning_session"), resolvingAgainstBaseURL: false)!
        if comps.scheme == "https" { comps.scheme = "wss" } else if comps.scheme == "http" { comps.scheme = "ws" }
        guard let wsURL = comps.url else { throw fail("provision", "WebSocket URL 构建失败") }
        var wsReq = URLRequest(url: wsURL)
        wsReq.timeoutInterval = 30
        LoginLogger.shared.log("[开始] WebSocket 连接 \(wsURL.absoluteString)", category: .appleID)
        let socket = session.webSocketTask(with: wsReq)
        socket.resume()
        return try await withCheckedThrowingContinuation { continuation in
            receiveProvisioningMessages(from: socket, startURL: startURL, endURL: endURL, continuation: continuation)
        }
    }

    private func receiveProvisioningMessages(from socket: URLSessionWebSocketTask,
                                             startURL: URL, endURL: URL,
                                             continuation: CheckedContinuation<String, Error>) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                LoginLogger.shared.log("[失败] WebSocket 接收失败: \(err.localizedDescription)", category: .appleID)
                continuation.resume(throwing: self.fail("provision", "WebSocket 接收失败: \(err.localizedDescription)"))
                socket.cancel(with: .normalClosure, reason: nil)
            case .success(let message):
                switch message {
                case .string(let str):
                    // Swift 6：Task（@Sendable）不能捕获非 Sendable 的 self ——
                    // 本类是 private init 的单例（self === Self.shared 恒成立），
                    // 改经静态访问进入流程，行为不变（修 sending 'self'）.
                    Task { [socket, str, startURL, endURL, continuation] in
                        do {
                            let done = try await Self.shared.handleProvisioningMessage(str, socket: socket,
                                                                                       startURL: startURL, endURL: endURL,
                                                                                       continuation: continuation)
                            if !done {
                                Self.shared.receiveProvisioningMessages(from: socket, startURL: startURL, endURL: endURL, continuation: continuation)
                            }
                        } catch {
                            continuation.resume(throwing: error)
                            socket.cancel(with: .normalClosure, reason: nil)
                        }
                    }
                default:
                    LoginLogger.shared.log("[失败] WebSocket 收到非文本消息", category: .appleID)
                    continuation.resume(throwing: self.fail("provision", "WebSocket 收到非文本消息"))
                    socket.cancel(with: .normalClosure, reason: nil)
                }
            }
        }
    }

    private func handleProvisioningMessage(_ str: String, socket: URLSessionWebSocketTask,
                                           startURL: URL, endURL: URL,
                                           continuation: CheckedContinuation<String, Error>) async throws -> Bool {
        guard let data = str.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? String else {
            throw fail("provision", "服务端消息无法解析: \(str.prefix(200))")
        }
        LoginLogger.shared.log("← WebSocket: \(str.prefix(200))", category: .appleID)
        switch result {
        case "GiveIdentifier":
            guard let identifier = keychain.string(for: "identifier") else { throw fail("provision", "GiveIdentifier 时无 identifier") }
            try await socket.send(.string(String(data: try JSONSerialization.data(withJSONObject: ["identifier": identifier]), encoding: .utf8)!))
            return false
        case "GiveStartProvisioningData":
            let spim = try await fetchProvisioningData(url: startURL, body: ["Header": [:], "Request": [:]])
            try await socket.send(.string(String(data: try JSONSerialization.data(withJSONObject: ["spim": spim]), encoding: .utf8)!))
            return false
        case "GiveEndProvisioningData":
            guard let cpim = json["cpim"] as? String else { throw fail("provision", "GiveEndProvisioningData 无 cpim") }
            let endData = try await fetchEndProvisioningData(url: endURL, cpim: cpim)
            try await socket.send(.string(String(data: try JSONSerialization.data(withJSONObject: endData), encoding: .utf8)!))
            return false
        case "ProvisioningSuccess":
            guard let adiPb = json["adi_pb"] as? String else { throw fail("provision", "ProvisioningSuccess 无 adi_pb") }
            LoginLogger.shared.log("[完成] provision 成功，adi_pb=\(adiPb.prefix(16))…", category: .appleID)
            socket.cancel(with: .normalClosure, reason: nil)
            continuation.resume(returning: adiPb)
            return true
        default:
            if result.contains("Error") || result.contains("Invalid") ||
               result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                let raw = json["message"] as? String ?? ""
                // -45025 unknown session / -45003 invalid Trust Key 都是**单个
                // Anisette 服务器**与 Apple trust 不同步或其会话过期，换服务器
                // 通常即可通过.这里打点说明，重试逻辑见 getAnisetteDataWithFallback.
                if raw.contains("-45025") || raw.contains("-45003") || raw.contains("-45061") {
                    LoginLogger.shared.log("… 该 Anisette 服务器被 Apple 拒绝（\(raw)），属可重试错误，将换服务器", category: .appleID)
                }
                throw fail("provision", "服务端返回 \(result): \(raw)")
            }
            return false
        }
    }

    private func fetchProvisioningData(url: URL, body: [String: Any]) async throws -> String {
        var req = try makeAppleRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        let (data, response) = try await session.data(for: req)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard http == 200,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]],
              let spim = plist["Response"]?["spim"] as? String else {
            throw fail("provision", "midStartProvisioning(HTTP \(http)): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        return spim
    }

    private func fetchEndProvisioningData(url: URL, cpim: String) async throws -> [String: String] {
        let body: [String: Any] = ["Header": [:], "Request": ["cpim": cpim]]
        var req = try makeAppleRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        let (data, response) = try await session.data(for: req)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard http == 200,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]],
              let ptm = plist["Response"]?["ptm"] as? String,
              let tk = plist["Response"]?["tk"] as? String else {
            throw fail("provision", "midFinishProvisioning(HTTP \(http)): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        return ["ptm": ptm, "tk": tk]
    }
}
