import SwiftUI

/// 退出只清凭据；可选清理均为本地资产，不吊销Apple证书.
struct AppleAccountSignOutOptions {
    var keepCertificate = true
    var keepAnisetteData = true
    var keepAnisetteHeaders = true
}

// MARK: - 多账户台账（v0.3.745 账户体系重做）

/// 一个已登录并保持的 Apple ID 账户.
///
/// 双链会话各自独立（v0.2.112 的铁律仍然有效）：
/// - swiftdsid/swiftAuthToken = Swift 认证引擎会话（证书管理/增加内存等用）；
/// - sideloadDSID/sideloadAuthToken = 历史侧载会话字段（v0.3.750 起签名
///   直接复用设置身份，仅保留字段兼容旧台账）.
struct AppleUserAccount: Codable, Identifiable, Equatable {
    /// 邮箱（小写）即 id.
    var id: String { email.lowercased() }
    var email: String
    /// 登录密码（明文，与 keychain 同一安全边界：应用沙盒 + 数据保护）.
    var password: String
    var swiftDSID: String?
    var swiftAuthToken: String?
    var sideloadDSID: String?
    var sideloadAuthToken: String?
    var accountName: String?
    var addedAt: Date
    var lastUsedAt: Date
}

/// 多账户台账：登录过的账户全部保持，一键切换当前账户.
///
/// 存储 = Documents/Tequila/AppleUserAccounts.json（台账只存会话凭据，
/// Anisette 机器数据仍在 keychain，跟 MemoryLimitSettings 同一策略）.
/// 当前账户 = UserDefaults TequilaDash.ActiveAppleID.
/// 切换/退出时同步写 MemoryLimitSettings 的 keychain 主键 —— 消费方
/// （CertificateManager / IPAInstallService.warmUp / 商店链）不改读取方式.
@MainActor
final class AppleUserAccountStore: ObservableObject {
    // 全部消费方（View / MemoryLimitSettings / IPAInstallService.warmUp）均在 MainActor，
    // 单例随类隔离即可；nonisolated(unsafe) 反而把 MainActor init 变成非隔离上下文报错.
    static let shared = AppleUserAccountStore()

    @Published private(set) var accounts: [AppleUserAccount] = []
    /// 当前账户邮箱（小写）；nil = 未登录.
    @Published private(set) var activeEmail: String?

    static let ledgerURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Tequila/AppleUserAccounts.json")
    }()
    private static let activeKey = "TequilaDash.ActiveAppleID"

    private init() {
        load()
        importLegacyIfNeeded()
        // 台账里有账户但没标当前：标第一个（首启迁移后常见）.
        if activeEmail == nil, let first = accounts.first {
            setActive(first.email, persist: false)
        }
    }

    var activeAccount: AppleUserAccount? {
        guard let activeEmail else { return nil }
        return accounts.first { $0.id == activeEmail }
    }
    var hasAccounts: Bool { !accounts.isEmpty }

    // MARK: - 登录完成入口（AppleIDLoginSheet / MemoryLimitSettings.completeSignIn 调用）

    /// 用 keychain 主键里的最新凭据 upsert 一个账户并设为当前.
    /// 在 completeSignIn 之后调用，此时 keychain 已写入全套会话.
    func upsertFromKeychain(email: String, password: String,
                            swiftDSID: String?, swiftAuthToken: String?,
                            name: String?) {
        let key = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return }
        let now = Date()
        if let idx = accounts.firstIndex(where: { $0.id == key }) {
            accounts[idx].password = password
            accounts[idx].swiftDSID = swiftDSID ?? accounts[idx].swiftDSID
            accounts[idx].swiftAuthToken = swiftAuthToken ?? accounts[idx].swiftAuthToken
            if let name, !name.isEmpty { accounts[idx].accountName = name }
            accounts[idx].lastUsedAt = now
        } else {
            accounts.append(AppleUserAccount(
                email: key, password: password,
                swiftDSID: swiftDSID, swiftAuthToken: swiftAuthToken,
                sideloadDSID: nil, sideloadAuthToken: nil,
                accountName: name, addedAt: now, lastUsedAt: now))
        }
        // 完整登录也必须切换两条活会话；不能只改台账指针后继续持有旧账户.
        switchActive(to: key)
    }



    /// 切换当前账户：把该账户的双链会话写回 MemoryLimitSettings 主键.
    func switchActive(to email: String) {
        let key = email.lowercased()
        guard let acc = accounts.first(where: { $0.id == key }) else { return }
        setActive(acc.email)
        MemoryLimitSettings.shared.restoreAccountSession(
            email: acc.email, password: acc.password,
            dsid: acc.swiftDSID ?? "", authToken: acc.swiftAuthToken ?? "",
            sideloadDSID: acc.sideloadDSID ?? "", sideloadAuthToken: acc.sideloadAuthToken ?? "",
            accountName: acc.accountName)
        save()

        // v0.3.746：切户后两链已持有的旧会话必须立即失效，否则：
        // - IPA 侧载页 isSignedIn 仍挂旧 session，warmUp 的 `guard !isSignedIn`
        //   永远不重恢复（切户后回侧载页显示旧账户已登录）；
        // - CertificateManager 单例的 hasLoaded/didAutoLoad 还是旧账户的 true，
        //   页面不在层级时 onChange(settings.appleID) 不触发，重进页 autoLoad 被拦.
        // 在这里（MainActor）统一失效并后台重恢复新账户，页面无须各自补观察.
        IPAInstallService.shared.signOutForAccountSwitch()
        CertificateManager.shared.reset()
        IPAInstallService.shared.warmUp()
        CertificateManager.shared.warmUp()
    }

    /// 移除单个账户（当前账户则一并清 MemoryLimitSettings 登录态）.
    func remove(_ email: String, options: AppleAccountSignOutOptions = .init()) {
        let key = email.lowercased()
        accounts.removeAll { $0.id == key }
        MemoryLimitSettings.shared.removeLoginHistory(email)
        if activeEmail == key {
            if let first = accounts.first {
                switchActive(to: first.email)
            } else {
                activeEmail = nil
                UserDefaults.standard.removeObject(forKey: Self.activeKey)
                IPAInstallService.shared.signOut()
                CertificateManager.shared.reset()
                MemoryLimitSettings.shared.signOut(
                    keepAnisetteData: options.keepAnisetteData,
                    keepAnisetteHeaders: options.keepAnisetteHeaders)
            }
        }
        // 本地证书与机器身份为共享资产；仍有账户时不作破坏性清理.
        if accounts.isEmpty, !options.keepCertificate {
            _ = DeveloperCertStore.shared.removeLocalCert()
        }
        if accounts.isEmpty {
            IPAInstallService.shared.removeLocalAuthenticationCache(emails: [key],
                keepCertificate: options.keepCertificate, keepAnisetteData: options.keepAnisetteData)
        }
        save()
    }

    /// 退出全部（含 isideload 签名会话释放）.
    func signOutAll(options: AppleAccountSignOutOptions = .init()) {
        let removedEmails = accounts.map(\.email)
        for account in accounts { MemoryLimitSettings.shared.removeLoginHistory(account.email) }
        accounts.removeAll()
        activeEmail = nil
        UserDefaults.standard.removeObject(forKey: Self.activeKey)
        IPAInstallService.shared.signOut()
        CertificateManager.shared.reset()
        MemoryLimitSettings.shared.signOut(
            keepAnisetteData: options.keepAnisetteData,
            keepAnisetteHeaders: options.keepAnisetteHeaders)
        if !options.keepCertificate { _ = DeveloperCertStore.shared.removeLocalCert() }
        IPAInstallService.shared.removeLocalAuthenticationCache(emails: removedEmails,
            keepCertificate: options.keepCertificate, keepAnisetteData: options.keepAnisetteData)
        save()
    }

    // MARK: - 持久化

    private func setActive(_ email: String, persist: Bool = true) {
        activeEmail = email.lowercased()
        if persist { UserDefaults.standard.set(activeEmail, forKey: Self.activeKey) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.ledgerURL) else {
            // 无台账文件：回读 UserDefaults 指针（上次运行写入过）.
            activeEmail = UserDefaults.standard.string(forKey: Self.activeKey)?.lowercased()
            return
        }
        // 整份解不开不救（台账是我们自己写的原子写，半文件=外力破坏，不回写）.
        guard let list = try? JSONDecoder().decode([AppleUserAccount].self, from: data) else { return }
        accounts = list.sorted { $0.addedAt < $1.addedAt }
        var saved = UserDefaults.standard.string(forKey: Self.activeKey)?.lowercased()
        if saved != nil, !accounts.contains(where: { $0.id == saved }) { saved = nil }
        activeEmail = saved ?? accounts.first?.id
    }

    private func save() {
        let url = Self.ledgerURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 首启迁移：keychain 里已有单账户登录态、台账为空 → 收编为台账第一笔.
    private func importLegacyIfNeeded() {
        guard accounts.isEmpty, MemoryLimitSettings.shared.isLoggedIn else { return }
        let s = MemoryLimitSettings.shared
        let email = s.appleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { return }
        let acc = AppleUserAccount(
            email: email,
            password: s.password(forHistory: email) ?? "",
            swiftDSID: s.dsid, swiftAuthToken: s.authToken,
            sideloadDSID: s.sideloadDSID, sideloadAuthToken: s.sideloadAuthToken,
            accountName: s.accountName, addedAt: Date(), lastUsedAt: Date())
        accounts.append(acc)
        activeEmail = acc.id
        UserDefaults.standard.set(acc.id, forKey: Self.activeKey)
        save()
    }
}
