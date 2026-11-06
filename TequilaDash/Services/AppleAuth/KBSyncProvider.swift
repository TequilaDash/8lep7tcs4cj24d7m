//
//  KBSyncProvider.swift
//  TequilaDash
//
//  把 `SAPStoreAgentContext`（解释 `storeagent` 生成 kbsync）接到
//  `Configuration.kbsyncGenerator` —— 这是 `ent/download` 能跑起来的**唯一**前置.
//
//  ## 为什么要这么绕
//
//  kbsync 要用 Unicorn 解释执行 Apple 的 `storeagent`，这部分是宿主能力
//  （ObjC++ + Unicorn，见 `Services/AppleAuth/SAP`）.而 `ent/download` 的请求
//  构造在 `vendor/ApplePackage` 里，**vendor 不能反向依赖宿主**.
//  所以走依赖注入：vendor 声明一个 `KBSyncGenerator` 闭包类型，宿主在启动时装配.
//  与 `Configuration.sapSignerFactory` 是同一个模式.
//
//  ## 为什么是「算完即弃」
//
//  （`kbsync.go:11-13` 的注释说得很清楚）.我们这边每调一次就建一台机器、
//  跑完 guest 就丢 —— 代价是每次下载多几十毫秒，换来的是**没有跨请求的共享状态**，
//  省掉一整类「会话被关掉了还在用」的问题.
//

import Foundation

enum KBSyncProvider {

    /// 装配到 `Configuration.kbsyncGenerator`.**启动时调用一次即可.**
    ///
    /// 装配失败（资产不在）不报错、不抛 —— 只是让 `ent/download` 那一跳跳过，
    static func install() {
        Configuration.kbsyncGenerator = { hardwareID, dsid in
            // kbsync 是纯 CPU 的 guest 执行（可能要几秒），必须在后台线程，
            // 不能占主线程 —— 否则一次下载会把界面卡住.
            //
            // `Task.detached` 而不是 `Task {}`：调用方（下载链）本身可能跑在
            // 某个 actor 上，`Task {}` 会继承它的执行器；这里要的是「彻底离开
            // 调用者的隔离域」，所以用 detached.
            try await Task.detached(priority: .userInitiated) {
                try await generate(hardwareID: hardwareID, dsid: dsid)
            }.value
        }

        // 装完自检一次：只写日志、不抛错，用于排障 ent/download 未走的原因.
        if SAPAssetsLocator.url == nil {
            LoginLogger.shared.log("[kbsync] 未装配：SAP 资产目录缺失（\(SAPAssetsLocator.describe())）",
                                   category: .appleID)
        } else {
            LoginLogger.shared.log("[kbsync] 已装配（资产目录 \(SAPAssetsLocator.url?.path ?? "?")）",
                                   category: .appleID)
        }
    }

    /// 真正跑一次 kbsync.抛错由上面的闭包原样传回 vendor 层，vendor 捕获后落回旧链.
    /// `nonisolated`：纯函数（读资产 → 跑 guest → 返回字节），`Task.detached` 调用不需 hop.
    private nonisolated static func generate(hardwareID: Data, dsid: UInt64) async throws -> Data {
        // 先查缓存（对齐上游 `appstore_kbsync_cache.go`）.
        // kbsync 需在 Unicorn 里解释执行 `storeagent`（纯 CPU 数秒），输入只有 hardwareID + DSID，
        // 同设备同登录恒等 ⇒ 不缓存即每次下载白烧 CPU.
        // 键是为了在「换机 / 换机器标识」后绝不复用旧 blob.
        // 命中/未命中均打日志，作为冷缓存跑 Unicorn 的直接判据.
        let started = Date()
        let key = KBKey(dsid: dsid, hardwareID: hardwareID)
        if let cached = cache.value(for: key) {
            // 命中 = 未跑 Unicorn，耗时只是查表.
            LoginLogger.shared.log(
                "[kbsync] 缓存命中 耗时=\(elapsedMs(since: started))ms DSID=\(dsid) 字节=\(cached.count)",
                category: .appleID)
            return cached
        }
        // 未命中 = 跑 Unicorn（真机约数秒），kbsync 段主要耗时来源.
        LoginLogger.shared.log(
            "[kbsync] 缓存未命中 DSID=\(dsid)",
            category: .appleID)

        // singleflight：一次生成要吃数秒纯 CPU，同键并发请求必须共享同一次运行，
        // 否则下载准备阶段会叠加数份 guest 执行（真机 SSH 日志实证过 30s 级生成）.
        if let running = cache.inflightTask(for: key) {
            let waited = Date()
            do {
                let data = try await running.value
                LoginLogger.shared.log(
                    "[kbsync] 并发复用 等待=\(elapsedMs(since: waited))ms DSID=\(dsid) 字节=\(data.count)",
                    category: .appleID)
                return data
            } catch {
                // 在跑的那份失败：本调用方改为自跑（走下方主路径）.
                LoginLogger.shared.log(
                    "[kbsync] 并发复用失败，改为自跑 DSID=\(dsid) 错误=\(error.localizedDescription)",
                    category: .appleID)
            }
        }

        let task = Task.detached(priority: .userInitiated) {
            try KBSyncProvider.generateUncached(hardwareID: hardwareID, dsid: dsid, started: started)
        }
        // 原子注册：nil = 我是生成者；非 nil = 撞上同时注册的并发者（罕见），
        // 此时直接等对方、自己这份任其跑完（结果等价，只是多烧一次 CPU）.
        if let raced = cache.register(task, for: key) {
            return try await raced.value
        }
        defer { cache.removeInflight(for: key) }
        let data = try await task.value
        cache.store(data, for: key)
        return data
    }

    /// 纯 CPU 的真正生成（不含缓存与并发去重）.由 singleflight 的 detached 任务调用.
    private nonisolated static func generateUncached(hardwareID: Data, dsid: UInt64, started: Date) throws -> Data {
        guard let assets = SAPAssetsLocator.url else {
            throw KBSyncError.assetsMissing
        }
        // 定案：**ObjC 的 `NSError **` 出参在 Swift 侧就是 `throws`** ——
        //   调用时写 `try`、**不要**再显式传 `error:` 实参.
        //
        //   这个坑连着坑了三版（/545/546 全是同一条
        //   `error: extra argument 'error' in call`）.根因是把 ObjC 的
        //   NSError-out-parameter **当成了普通的带 error 参数的方法**：
        //   Swift importer 看到 `NSError **` 会把它**从参数列表里拿走**、
        //   改写成 `throws`（`NSError` → `Error`），所以调用处**根本没有 error 这个 label**.
        //
        //   判据：本仓同文件的 `SAPContext` 一直是这么用的、从来没报过错 ——
        //     `let signer = try SAPContext(assetsURL:hardwareID:)`（不带 error）
        //     `try signer.exchangeData(cert, version: 200)`（不带 error）
        //   照着它的写法就对了.
        //
        //   注意： 不要去改 `.h` 里 `NSError **` 的写法（/546 试过
        //   `NSError * _Nullable * _Nullable`，不仅没用、还让 `.h` 与 `.mm` 不一致）.
        //   出参类型保持全文件统一的 `NSError **` 即可.
        let blob = try SAPStoreAgentContext.generateKBSync(
            withAssetsURL: assets,
            hardwareID: hardwareID,
            dsid: dsid
        )
        guard !blob.isEmpty else {
            throw KBSyncError.generationFailed("生成结果为空")
        }
        let data = blob as Data
        LoginLogger.shared.log(
            "[kbsync] 生成完成 耗时=\(elapsedMs(since: started))ms DSID=\(dsid) 字节=\(data.count)",
            category: .appleID)
        return data
    }

    /// `[计时]` 日志用 —— 与锚点的毫秒差.
    private nonisolated static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    // MARK: - kbsync 缓存

    ///
    /// 我们是常驻 App，进程内缓存已经覆盖了「连续装多个包」这个真实场景，
    /// 而落盘会多出一份「设备绑定凭据躺在沙盒里」的东西，不划算.
    ///
    /// 那条规则是为了避免把一个算对了但服务端不认的 blob 缓存下来反复用.
    /// 我们这边的 `generate` 是纯函数（同样的输入必然同样输出），
    /// 缓存一个「算出来了但服务端不认」的值，和重新算一遍得到的结果**完全一样**，
    /// 所以那条规则对我们没有收益，只会让实现变复杂.
    /// （若将来发现某种 DSID 下服务端会拒，再按「只在拿到 HTTP 200 后 store」改.）
    private struct KBKey: Hashable {
        let dsid: UInt64
        let hardwareID: Data
    }

    private final class KBSyncCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [KBKey: Data] = [:]
        private var inflight: [KBKey: Task<Data, Error>] = [:]

        func value(for key: KBKey) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func store(_ data: Data, for key: KBKey) {
            lock.lock()
            defer { lock.unlock() }
            // 只服务「当前正在用的账号」，实际不会超过一两个；
            // 加个上限纯粹是防御（账号换了又换时不至于无限涨）.
            if entries.count > 8 { entries.removeAll() }
            entries[key] = data
        }

        /// singleflight 注册：nil = 注册成功（我是生成者）；
        /// 返回已有任务 = 已有同键生成在跑，调用方改为等待它.
        func register(_ task: Task<Data, Error>, for key: KBKey) -> Task<Data, Error>? {
            lock.lock()
            defer { lock.unlock() }
            if let existing = inflight[key] { return existing }
            inflight[key] = task
            return nil
        }

        func inflightTask(for key: KBKey) -> Task<Data, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return inflight[key]
        }

        func removeInflight(for key: KBKey) {
            lock.lock()
            defer { lock.unlock() }
            inflight[key] = nil
        }
    }

    private static let cache = KBSyncCache()

    enum KBSyncError: LocalizedError {
        case assetsMissing
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .assetsMissing:
                "SAP 资产缺失"
            case let .generationFailed(reason):
                "kbsync 生成失败：\(reason)"
            }
        }
    }
}
