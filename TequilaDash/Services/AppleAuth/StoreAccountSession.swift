import Foundation

/// Account cookie mutations are transactions. Actor reentrancy alone does not serialize awaits.
private actor StoreAccountRequestGate {
    /// email → 持有者令牌集合。**必须是令牌而非裸 email**（v0.3.742 修复）：
    /// 旧实现用 `Set<String>`，强制接管那条路**不插入自己的 entry**（`insert` 失败），
    /// 于是接管者手里有租约、门里却没有它的记录 —— 一旦它 `release` 清掉僵尸 entry，
    /// 门就变成空集，**任何并发调用都能立刻拿到租约**，同一账号又回到「多持有者并发」，
    /// 正是「搜索 → 点下载」两条链同时持账号会话、进而闪退的形状（33429ee 只给已购链加了单飞）。
    /// 改成令牌后：每次 acquire 都插入自己的令牌，release 只删自己的令牌，
    /// 强制接管时**清掉该 email 下所有旧令牌再插入自己的** —— 门不会再永久失信.
    private var owners: [String: Set<UInt64>] = [:]

    /// 下一个令牌（单调递增，进程内唯一）.
    private var nextToken: UInt64 = 0

    /// 取锁等待的**上限**。超时后**强制接管**（宁可变慢/偶发并发，绝不永久卡死）。
    ///
    /// ## 为什么必须有这个上限（v0.3.389 真机事故）
    /// 本门是**纯内存态**，`release` 只在 `withAccount` 的 do/catch 两路被调用。
    /// 但只要**持锁的那一次 `withAccount` 没走到 release**（最典型：App 进后台被挂起、
    /// 或进程被系统回收 —— 异步任务不会补跑 defer），`owners` 里就会留下一个
    /// **永不释放的 email**。此后这台设备上**所有下载都永久停在「准备中 0%」**，
    /// 而且**一条日志都没有**（卡死在第一条 `onLog` 之前，`[AppleID] 请求下载信息…` 永远不出现）。
    /// 真机实测就是这个形状：用户点下载 → 顶部「准备中 0%」不动 → 日志里没有任何下载记录。
    ///
    /// 旧实现用 `withCheckedContinuation` 排队，等待者**没有任何超时/取消能力** → 一旦泄漏就是永久。
    /// 现在改成**轮询 + 超时接管**：超时后本次照常继续，并由调用方的 `release` 把那个僵尸 owner 清掉，
    /// 于是**一次超时之后链路自行恢复**。
    static let acquireTimeout: TimeInterval = 25

    /// 因超时被强制接管的次数（诊断用）.
    ///
    /// v0.3.662（task-13 发现13）：此前该计数器**只写不读**（全仓无消费者）,
    /// 而它恰好是排查「下载卡在准备中 0%」时最关键的一项指标 —— 每次强制接管
    /// 都意味着有并发操作在共享同一账号会话。现在在接管发生的那条日志里带上它,
    /// 让它不再是一条死代码。
    private(set) var forcedAcquires = 0

    /// 取锁。返回 `(令牌, 是否超时夺来)`；调用方**必须**用同一令牌 release.
    func acquire(_ email: String) async -> (token: UInt64, forced: Bool) {
        let deadline = Date().addingTimeInterval(Self.acquireTimeout)
        while true {
            var set = owners[email] ?? []
            if set.isEmpty {
                nextToken &+= 1
                let token = nextToken
                set.insert(token)
                owners[email] = set
                return (token, false)
            }
            // iOS 27.2 beta: Date.>= 编译为 weak import（GOT 为空即崩），不得直接用比较符.
            if Date().timeIntervalSinceReferenceDate >= deadline.timeIntervalSinceReferenceDate {
                forcedAcquires += 1
                nextToken &+= 1
                let token = nextToken
                // 强制接管：旧持有者几乎必然已挂起/被回收（永远不会 release），
                // 这里直接把该 email 下的旧令牌全部清掉，只留本次这一个 ——
                // 既清僵尸，又保证「接管者也在门里」，不会让门退化成无锁.
                owners[email] = [token]
                return (token, true)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// 释放**自己那一个**令牌。别的持有者的令牌不受影响.
    func release(_ email: String, token: UInt64) {
        guard var set = owners[email] else { return }
        set.remove(token)
        if set.isEmpty {
            owners[email] = nil
        } else {
            owners[email] = set
        }
    }

    /// 供诊断日志读取的强制接管次数（actor 的隔离属性不能跨隔离域直读）.
    func forcedAcquireCount() -> Int { forcedAcquires }
}

enum StoreAccountSession {
    private static let gate = StoreAccountRequestGate()

    /// Only hold this lease while obtaining metadata/licenses, never while downloading/installing an IPA.
    static func withAccount<T>(email: String,
                               operation: (inout AppStoreAccount) async throws -> T) async throws -> T {
        let gateKey = email.lowercased()
        let lease = await gate.acquire(gateKey)
        if lease.forced {
            // 强制接管：上一个持有者很可能因 App 进后台被挂起/回收而未释放租约；
            // 本次结束时 release 会把它清掉，所以一次超时之后链路自行恢复。
            let forcedCount = await gate.forcedAcquireCount()
            LoginLogger.shared.log(
                "[会话] 账号租约等待超过 \(Int(StoreAccountRequestGate.acquireTimeout))s，已强制接管"
                + "（本进程累计 \(forcedCount) 次）.",
                category: .appleID)
        }
        do {
            try Task.checkCancellation()
            // v0.3.743 面包屑：拿到租约之后、取账号会话之前 —— 与调用方的
            // 「申请账号租约…」配对，用来区分「门排队」和「取账号会话」两段.
            LoginLogger.shared.log("[会话] 租约已获得，取账号会话…", category: .appleID)
            guard var account = AppStoreDownloadStore.shared.account(for: email) else {
                throw StoreAuthenticationError.accountChanged
            }
            let result: T
            do {
                result = try await operation(&account)
            } catch {
                AppStoreDownloadStore.shared.update(account)
                throw error
            }
            AppStoreDownloadStore.shared.update(account)
            await gate.release(gateKey, token: lease.token)
            return result
        } catch {
            await gate.release(gateKey, token: lease.token)
            throw error
        }
    }
}

/// Shared by explicit login and automatic refresh. This is an app-side backoff only.
actor StoreLoginBackoff {
    static let shared = StoreLoginBackoff()
    private var blockedUntil: [String: Date] = [:]

    func check(_ email: String) throws {
        let key = email.lowercased()
        if let until = blockedUntil[key], until > Date() {
            // v0.3.5xx：此前这里**静默抛错** —— 日志里一行都没有，用户只看到「点了没反应」。
            // 补一条明确日志（含剩余冷却时长）；冷却窗口内直接失败、不重试（避免重复发送密码），
            // 且不写 email，避免 PII 进日志。
            let remaining = Int(ceil(until.timeIntervalSinceNow))
            LoginLogger.shared.log(
                "[会话] 登录退避冷却中 剩余=\(remaining)s",
                category: .appleID)
            throw StoreAuthenticationError.cooldown(remaining)
        }
        blockedUntil[key] = nil
    }

    func record(_ error: StoreAuthenticationError, email: String) {
        guard let interval = error.backoffInterval else { return }
        blockedUntil[email.lowercased()] = Date().addingTimeInterval(interval)
        // v0.3.5xx：退避**开始**也补一条日志（原只在 UI 显示）；冷却期间自动重登会被直接拒绝。
        LoginLogger.shared.log(
            "[会话] 登录失败触发退避 冷却=\(Int(interval))s",
            category: .appleID)
    }

    func clear(_ email: String) { blockedUntil[email.lowercased()] = nil }
}

/// All callers refreshing the same saved session await one login, rather than replaying passwords.
actor StoreRefreshCoordinator {
    static let shared = StoreRefreshCoordinator()
    private struct Flight {
        let id: UUID
        let task: Task<AppStoreAccount, Error>
    }
    private var flights: [String: Flight] = [:]

    private func key(_ email: String) -> String { email.lowercased() }

    func refresh(email: String, code: String, failedAccount: AppStoreAccount?) async throws -> AppStoreAccount {
        try Task.checkCancellation()
        let flightKey = key(email)
        guard let stored = AppStoreDownloadStore.shared.account(for: email) else {
            throw StoreAuthenticationError.accountChanged
        }
        // Another request already refreshed the failed ticket: reuse it without another login.
        if let failedAccount, !AppStoreDownloadStore.sameSession(stored, failedAccount) {
            return stored
        }
        if let flight = flights[flightKey] { return try await flight.task.value }
        guard !stored.password.isEmpty else { throw StoreAuthenticationError.credentialsRequired }
        try await StoreLoginBackoff.shared.check(email)
        // The backoff actor await is a reentrancy point; another caller may have installed a flight.
        if let flight = flights[flightKey] { return try await flight.task.value }
        if let latest = AppStoreDownloadStore.shared.account(for: email),
           !AppStoreDownloadStore.sameSession(latest, stored) { return latest }
        let id = UUID()
        let task = Task<AppStoreAccount, Error> {
            let currentGUID = AppleIDSignInService.sapGUID()
            // v0.3.354：Apple 的 store 会话与「机器身份」绑定。用户点过「重置设备标识」之后，
            // 旧 passwordToken/Cookie 在 Apple 眼里属于另一台设备 —— 继续把它们当 Cookie 发出去，
            // Auth 边缘回的是畸形应答（真机实测 204 空响应 / 302 无 Location），
            // 而不是一句清楚的「Sign In to the iTunes Store」。换过身份就**不带旧会话**重登。
            let reusableCookies = stored.deviceGuid == currentGUID ? stored.cookie : []
            if let old = stored.deviceGuid, old != currentGUID {
                LoginLogger.shared.log("[SAP] 设备标识已变更（\(old) → \(currentGUID)），登录不带旧会话",
                                       category: .appleID)
            }
            let refreshed = try await SignedStoreAuthenticator().authenticate(
                email: stored.email, password: stored.password, code: code,
                guid: currentGUID, cookies: reusableCookies)
            try Task.checkCancellation()
            return try AppStoreDownloadStore.shared.commitRefresh(refreshed, replacing: stored)
        }
        flights[flightKey] = Flight(id: id, task: task)
        do {
            let account = try await task.value
            if flights[flightKey]?.id == id { flights[flightKey] = nil }
            await StoreLoginBackoff.shared.clear(email)
            return account
        } catch {
            // Record backoff before removing the flight so reentrant callers cannot start another login.
            if let authError = error as? StoreAuthenticationError {
                await StoreLoginBackoff.shared.record(authError, email: email)
            }
            if flights[flightKey]?.id == id { flights[flightKey] = nil }
            throw error
        }
    }
}
