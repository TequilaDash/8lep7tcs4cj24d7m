import Foundation

// MARK: - 禁用通话录音提示音（移植 AirBeep v2.5.1）
//
// ## 原理（来自 AirBeep / 原名 Placard，仓库 LinkPass888/AirBeep）
// 通话录音开始 / 结束时会播放一段**披露提示音**（disclosure tone），文件落在
// /var/mobile/Library/CallServices/Greetings/default/：
//   · 开始：StartDisclosureWithTone.m4a
//   · 结束：StopDisclosure.caf
// AirBeep 的做法：把这几个文件**替换成等长静音**（时长、容器、采样率一致，只是内容全零）。
// 系统照常播放「一个文件」，只是听不到提示音；**录音本身不受影响**。
//
// ## v0.3.661：读通道容错（对齐 AirBeep v2.5.1 的 readTonesTolerant）
//
// 真机上 airlift 的**读通道**在某些 iOS 版本上会失败，而**写通道**是好的
// （AirBeep 上游注释原话：the airlift read channel can fail to recover it on some
// iOS releases even though the write channel works）。
//
// 我们原来的实现把「读」当成一切的前提：
//   · disable(): current = try await readTones()  ← 任一文件读不出就整体抛错
//   · writeTones(): 写成功后 try await readTones() 读回校验 ← 读不回就把**已成功**的写入报成失败
// 于是用户看到的就是那条 AirTraffic did not recover … StartDisclosureWithTone.m4a，
// 功能完全不可用 —— 而这跟「写入」其实没关系。
//
// 现在的分层（与上游一致）：
//   · 读：逐文件独立容错，读不出的位置是 nil，**从不抛错**
//   · 写：写入通道的返回码即真相；读回校验降级为「尽力而为」
//   · 备份：读不到的文件无法备份 ⇒ 显式告知，且要求调用方确认后才继续
//
// ## 诚实边界
// · 本机（Windows）无法编译 / 实机验证，格式与时长按 AirBeep 钉死的素材为准。
// · 状态判据用持久化标记（UserDefaults）而非文件内容比对 —— PCM 静音与原音
//   长度相同、字节数也相同，按大小无法区分；故如实说明「状态以本 App 的标记为准」。
// · 上游还有第三个可选文件 StartDisclosure.caf（很多系统版本没有）。本仓暂不处理：
//   没有对应的静音素材，盲写一个设备上原本不存在的文件风险大于收益。
// · 写入需**导入配对文件 + LocalDevVPN 隧道**（目标 iOS/iPadOS 18.0–27.2 B2）。

/// 通话录音提示音的禁用 / 恢复服务。
enum CallRecordingToneService {

    // MARK: - 目标文件

    /// 一个提示音文件（设备路径 + bundle 内等长静音素材名）。
    struct Tone: Sendable {
        /// 文件名（也是备份文件名）。
        let name: String
        /// 设备上的绝对路径。
        let path: String
        /// bundle 内等长静音素材名（不含扩展名）。
        let resourceName: String
        /// 静音素材扩展名。
        let resourceExtension: String
        /// 该文件在系统上可能不存在（上游 AirBeep 用同一个字段区分必选 / 可选）。
        let optional: Bool
    }

    /// 提示音所在目录（AirBeep 实测落点）。
    static let directory = "/var/mobile/Library/CallServices/Greetings/default"

    /// 开始录音提示音。
    static let startTone = Tone(
        name: "StartDisclosureWithTone.m4a",
        path: directory + "/StartDisclosureWithTone.m4a",
        resourceName: "AirBeepStartSilence",
        resourceExtension: "m4a",
        optional: false
    )

    /// 结束录音提示音。
    static let stopTone = Tone(
        name: "StopDisclosure.caf",
        path: directory + "/StopDisclosure.caf",
        resourceName: "AirBeepStopSilence",
        resourceExtension: "caf",
        optional: false
    )

    /// 全部提示音（顺序即备份 / 静音素材的对应顺序）。
    static var allTones: [Tone] { [startTone, stopTone] }

    // MARK: - 状态

    /// 当前提示音状态。
    enum ToneState: Equatable, Sendable {
        /// 原始提示音（未禁用）。
        case original
        /// 已替换为静音。
        case silenced
    }

    /// 一次「禁用」的结果报告。
    ///
    /// v0.3.661：禁用不再因为「读不到原始音」而直接失败，但**必须把风险如实交给界面**：
    /// backupComplete 为 false 时，用户点「恢复」是拿不回原始提示音的。
    struct DisableReport: Sendable {
        /// 原始提示音是否已完整备份（false = 有文件读不到，或本来就已是静音）。
        let backupComplete: Bool
        /// 读不到、因而无法备份的文件名。
        let unreadable: [String]
        /// 写入是否已生效（写入通道返回码为准；false 只出现在「payload 为空」这种退化情况）。
        let wroteTones: Bool

        /// 给界面看的一句话说明（不含中文句号，符合本仓文案规则）。
        var summary: String {
            if backupComplete {
                return "已把通话录音提示音替换为静音，原始提示音已备份到本机."
            }
            if unreadable.isEmpty {
                return "已把通话录音提示音替换为静音，但设备上原本就是静音，没有可备份的原始提示音."
            }
            return "已把通话录音提示音替换为静音，但 \(unreadable.count) 个原始提示音读不出来，"
                + "未能备份（\(unreadable.joined(separator: "、"))）—— 本 App 无法帮你恢复，"
                + "需要恢复时请切换系统语言让系统重新生成提示音."
        }
    }

    /// 禁用 / 恢复过程中的错误（airlift 自身的错误由 AirLiftService.AirLiftError 直接抛出）。
    enum ToneError: Error, LocalizedError, Sendable {
        /// 没有可恢复的备份。
        case noBackup
        /// bundle 内缺少等长静音素材。
        case invalidToneBundle
        /// 写入后读回校验不一致（写入未生效）。
        case verificationFailed(String)
        /// v0.3.646：设备上已是静音、且没有任何备份 ⇒ 无法恢复。
        ///
        /// 这个错误必须**显式存在**：它代表「用户的原始提示音可能已永久丢失」，
        /// 绝不能被「提前返回成功」掩盖。
        case silentWithoutBackup
        /// v0.3.646：回滚失败 ⇒ 设备状态未知。
        ///
        /// 用两个 String 而不是 Error：enum 声明为 Sendable，
        /// 而关联值带 Error 会让 Sendable 合成失败。
        case rollbackFailed(original: String, rollback: String)
        /// v0.3.661：读不到原始提示音 ⇒ 无法备份，需要用户确认后才继续。
        case backupIncomplete([String])
        /// v0.3.689：备份已不可用，且系统还没有重新生成原始提示音。
        ///
        /// 与 .noBackup 的区别：.noBackup 可能只是「用户还没禁用过」；
        /// 本错误专指「我们确实把它静音过，但备份已经拿不到（0 字节 / 缺项 / 被清理）」，
        /// 此时指引必须可执行 —— 不能说「请先执行一次禁用」（那一刻禁用按钮是锁住的）。
        case languageRestoreRequired

        var errorDescription: String? {
            switch self {
            case .noBackup:
                return "没有找到备份，无法恢复.请先执行一次「禁用提示音」以生成备份."
            case .invalidToneBundle:
                return "bundle 内缺少等长静音素材."
            case .verificationFailed(let name):
                return "写入 \(name) 后校验失败（写入未生效）."
            case .rollbackFailed(let original, let rollback):
                return "操作失败，且回滚也失败（设备上的提示音状态未知）."
                    + "原因：\(original)；回滚失败：\(rollback)."
                    + "请重新打开本页读取真实状态，不要重复操作."
            case .silentWithoutBackup:
                return "设备上的提示音已经是静音，且本机没有备份 —— 无法恢复原始提示音."
                    + "这种情况发生在：禁用后删除/重装过 App，或备份被清理."
                    + "可通过切换系统语言让系统重新生成提示音，或用 iTunes/iOS 还原恢复."
            case .languageRestoreRequired:
                return "本机备份已不可用，系统也还没有重新生成原始提示音."
                    + "请先切换一次系统语言（设置 → 通用 → 语言与地区），让 iOS 重新生成提示音后再点恢复."
            case .backupIncomplete(let names):
                return "读不到原始提示音（\(names.joined(separator: "、"))），因此无法备份."
                    + "如果继续禁用，原始提示音将无法通过本 App 恢复."
                    + "这是 airlift 读通道在该 iOS 版本上的已知限制，与写入无关."
            }
        }
    }

    /// 持久化标记键（用户级）.
    static let disabledKey = "CallRecordingTone.disabled"
    /// v0.3.689：第二个持久键 —— 「曾在没有完整备份的情况下把设备置为静音」.
    ///
    /// 语义等价上游 AirBeep v2.5.1 的 ToneBackupStateCache.
    /// 缺了它，restore() 无法区分「从未静音过」与「静音过但备份丢了」，只能给一条做不到的指令。
    static let silencedWithoutBackupKey = "CallRecordingTone.silencedWithoutBackup"
    /// 备份目录名（App Documents 下）.
    static let backupDirectoryName = "CallRecordingToneBackup"

    /// 备份目录：Documents/CallRecordingToneBackup。
    static var backupDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(backupDirectoryName, isDirectory: true)
    }

    // MARK: - 状态查询

    /// 查询当前状态。
    ///
    /// v0.3.650：**不在加载时探可达性**（照 AirBeep 的 refresh()）。
    ///
    /// AirBeep 源码注释明确说：
    ///   > Never probe the system disclosure files at app-open:
    ///   > airlift reads are unreliable on some iOS releases and would surface a spurious error.
    ///
    /// 也就是说这个探测在某些 iOS 版本上**必然失败**，于是本页常年显示「不可达」，
    /// v0.3.689：原先还有第三种状态 .unreachable（读不到就报不可达）。它由 loadState
    /// 时期的 airlift 探测产生，而那段探测已按 AirBeep 的建议删除 ⇒ 该状态**永不出现**，
    /// 已从 ToneState 里移除，避免界面出现一条走不到的文案。
    ///
    /// 现在与 AirBeep 一致：**以持久化标记为准**，不做网络探测。
    /// 真实可达性留给具体的禁用 / 恢复动作去验证（那时失败也会如实报错）。
    static func currentState() -> ToneState {
        UserDefaults.standard.bool(forKey: disabledKey) ? .silenced : .original
    }

    /// 保留一个**显式**的探测入口（用户点「重新检查」时才用），
    /// 不再由页面加载自动调用。
    static func probeReachable() async -> Bool {
        do {
            _ = try await AirLiftService.readFile(at: startTone.path)
            lastReadFailure = nil
            return true
        } catch {
            // 与 readOne 一致地留痕：界面上「检查读取通道」失败时要能说出为什么。
            lastReadFailure = startTone.name + "：" + error.localizedDescription
            return false
        }
    }

    // MARK: - 禁用

    /// 禁用提示音：先尽力备份原始文件，再把提示音替换为等长静音。
    ///
    /// - Parameter acknowledgingRisk: 读不到原始提示音、无法建立备份时，
    ///   界面必须先向用户说明「禁用后不可恢复」，得到确认后再以 true 调用。
    ///   未确认时抛 .backupIncomplete（携带读不到的文件名）。
    ///
    /// 写入失败时**回滚**到写入前的原始内容（与 AirBeep 的 applySilentTone 一致）。
    @discardableResult
    static func disable(acknowledgingRisk: Bool = false) async throws -> DisableReport {
        let silent = try silentTones()
        let current = await readTones()

        // 「设备上已经是静音」必须**全部读得到**才能断言。
        //
        // v0.3.672：原来用 requireAll: false —— 只读到 start、stop 读不到时也算「已是静音」，
        // 于是走「补标记直接返回成功」分支，界面说「已替换为静音」，而 stop 其实还是原始音。
        // 这正是 v0.3.646 记的那类「界面全对、设备不对」，只是换了个入口。
        // 读不全 ⇒ 不能断言已静音 ⇒ 走下面的备份/确认分支，由用户决定。
        let readable = current.compactMap { $0 }.count
        let alreadySilent = readable == allTones.count && tonesEqual(current, silent, requireAll: true)

        var backupComplete = hasBackup()
        var unreadable: [String] = []

        // ⚠️⚠️ v0.3.646 的致命缺陷教训：**备份必须在任何提前返回之前建立**。
        // 原实现在「设备已是静音」时先置标记再 return，备份从未创建，
        // 于是「恢复」永远报 noBackup —— 用户的原始提示音永久丢失，而界面显示一切正常。
        // 现在无论走哪条分支，都先尝试备份。
        if !backupComplete && !alreadySilent {
            unreadable = allTones.enumerated()
                .filter { current[$0.offset] == nil }
                .map { $0.element.name }
            if unreadable.isEmpty {
                // 全部读到了 —— 正常备份。
                try writeBackups(current)
                backupComplete = true
            } else if !acknowledgingRisk {
                // 读不到 ⇒ 无法备份 ⇒ 必须让用户明确知道「禁用后不可恢复」。
                throw ToneError.backupIncomplete(unreadable)
            }
            // 用户已确认风险：跳过备份，继续写入（照 AirBeep 的容错语义）。
        }

        if alreadySilent {
            // 有备份、内容已是静音：只需补标记，无需重写（避免无谓写入）。
            if !backupComplete {
                // 设备静音但没备份 —— 保持 v0.3.646 的诚实报错，不假装成功。
                throw ToneError.silentWithoutBackup
            }
            UserDefaults.standard.set(true, forKey: disabledKey)
            return DisableReport(backupComplete: true, unreadable: [], wroteTones: false)
        }

        do {
            try await writeTones(silent)
            UserDefaults.standard.set(true, forKey: disabledKey)
            // v0.3.689：记下「这次是在没有完整备份的情况下静音的」——
            // 没有这个标记，restore() 在备份丢失时只能给一条用户做不到的指令。
            UserDefaults.standard.set(!backupComplete, forKey: silencedWithoutBackupKey)
            return DisableReport(
                backupComplete: backupComplete,
                unreadable: unreadable,
                wroteTones: true
            )
        } catch {
            // v0.3.646：回滚失败时**必须如实告知**，不能静默吞掉。
            //
            // 原实现是 try? await writeTones(current) —— 回滚失败时错误被吞，
            // 调用方只看到「写入失败」，于是界面回到「原始提示音」状态；
            // 而设备上可能是**静音**（写成功一半）或**半新半旧**。
            // ⇒ 用户以为没事，实际提示音状态与 App 显示完全相反。
            do {
                try await writeTones(current)
            } catch let rollbackError {
                throw ToneError.rollbackFailed(
                    original: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }
    }

    // MARK: - 恢复

    /// 从备份恢复原始提示音。
    ///
    /// v0.3.646：备份不存在时，**先分清「设备上是什么」再报错**。
    ///
    /// 原实现不管三七二十一抛 noBackup，文案是「请先执行一次禁用提示音以生成备份」。
    /// 这句提示在「设备上已经是静音、但备份丢了」的场景下是**有害的**：
    /// 用户照着做 → 再禁一次 → disable() 看到已是静音 → 补标记返回「成功」
    /// ⇒ 用户以为恢复了，其实系统文件还是静音，而且**永远**拿不回来了。
    /// v0.3.689 三处修正：
    /// ① 先读设备、再判备份 —— 原实现第一行就读备份，缺备份即抛 noBackup，文案却是
    ///    「请先执行一次『禁用提示音』以生成备份」，而那一刻禁用按钮被
    ///    .disabled(state == .silenced) 锁住 ⇒ 用户既做不到，也不会被告知真正有效的做法；
    /// ② 「已是原始音」必须**全部读得到**才敢断言（requireAll: true，对齐上游 :307），
    ///    原实现 requireAll: false 会让「有一项读不到」也判成已恢复；
    /// ③ 用第二个持久键区分「从未静音过」与「静音过但备份丢了」，后者给可执行指引。
    static func restore() async throws {
        let current = await readTones()
        let flagged = UserDefaults.standard.bool(forKey: silencedWithoutBackupKey)

        let backup: [Data?]
        do {
            backup = try readBackups()
        } catch {
            // 没有可用备份（缺失 / 0 字节 / 必选项读不回）。
            //
            // 关键：**不能凭一个标记就断言「已是原始音」**——只有「本 App 从未把它静音过」
            // 且「设备上的内容也不是我们的静音素材」时，才能按「已经是原始音」收尾；
            // 其余情形都要给可执行指引：我们确实改过设备，而备份已经拿不回来。
            let wasSilenced = UserDefaults.standard.bool(forKey: disabledKey) || flagged
            var stillSilent = false
            if let silent = try? silentTones(),
               current.compactMap({ $0 }).count == allTones.count {
                stillSilent = tonesEqual(current, silent, requireAll: true)
            }
            if !wasSilenced && !stillSilent {
                UserDefaults.standard.set(false, forKey: disabledKey)
                UserDefaults.standard.set(false, forKey: silencedWithoutBackupKey)
                return
            }
            throw ToneError.languageRestoreRequired
        }

        // 全部读得到、且逐项等于备份 ⇒ 已经是原始音，只补标记；读不全则不做此断言，走写入分支。
        let readable = current.compactMap { $0 }.count
        if readable == allTones.count,
           tonesEqual(current, backup, requireAll: true) {
            UserDefaults.standard.set(false, forKey: disabledKey)
            UserDefaults.standard.set(false, forKey: silencedWithoutBackupKey)
            return
        }

        do {
            try await writeTones(backup)
            UserDefaults.standard.set(false, forKey: disabledKey)
            UserDefaults.standard.set(false, forKey: silencedWithoutBackupKey)
        } catch {
            // v0.3.646：同上，回滚失败必须如实告知。
            do {
                try await writeTones(current)
            } catch let rollbackError {
                throw ToneError.rollbackFailed(
                    original: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }
    }

    // MARK: - 读 / 写（经 airlift）

    /// 逐个读提示音，**单个文件失败不影响其它文件**。
    ///
    /// 返回数组与 allTones 一一对应，读不出的位置是 nil。
    /// 读通道在部分 iOS 版本上不可用是上游已知现象，因此这里**从不抛错**。
    private static func readTones() async -> [Data?] {
        // 顺序读。**不要**改成 async let 并发：
        // AirliftToneTransport 内部是一条专用串行队列（见 AirliftToneTransport.swift:63-66），
        // 且 al_set_target_host 是进程级全局状态，并发调只会排队，
        // 省不下任何一次握手，反而让人误以为「已经并发了」。
        var result: [Data?] = []
        for tone in allTones {
            result.append(await readOne(tone))
        }
        return result
    }

    /// 读一个提示音；失败返回 nil（只留痕，不抛错）。
    private static func readOne(_ tone: Tone) async -> Data? {
        do {
            return try await AirLiftService.readFile(at: tone.path)
        } catch {
            let reason = error.localizedDescription
            lastReadFailure = tone.name + "：" + reason
            return nil
        }
    }

    /// 最近一次读取失败的原因（诊断用，如「StartDisclosureWithTone.m4a：AirTraffic did not recover」）。
    ///
    /// nonisolated(unsafe)：只写一个字符串、仅供界面/日志读取，值本身不是同步原语保护的对象；
    /// 加锁反而会引入 NSLock 的 Sendable 不确定性（本仓 SWIFT_STRICT_CONCURRENCY = complete）。
    private nonisolated(unsafe) static var lastReadFailure: String?

    /// 读出最近一次读取失败的原因（诊断用）。
    static func lastReadFailureReason() -> String? { lastReadFailure }

    /// 一次 airlift 操作写入若干提示音，随后**尽力而为**校验。
    ///
    /// nil 项（设备上不存在 / 读不到 / 没有备份）跳过不写。
    /// **写入通道的返回码即真相**：写成功就是成功；读回只是为了尽早发现写入未生效，
    /// 读不回（读通道坏）**不得**把已经成功的写入报成失败 —— 这正是 v0.3.660 之前的错误面。
    private static func writeTones(_ tones: [Data?]) async throws {
        let payload = zip(allTones, tones).compactMap { tone, data -> AirliftToneFile? in
            guard let data else { return nil }
            return AirliftToneFile(name: tone.name, data: data)
        }
        // 全部为 nil（一个都没读到 / 没有备份）⇒ 没有可写的内容。
        // 这不是「吞错」：调用方本来就要写「读到的东西」，读到 0 个就无事可做，
        // 随后由调用方按自己的语义决定报错（disable 会抛 backupIncomplete 或原错误，
        // restore 在 readBackups 阶段就已经因为缺备份抛了 noBackup）。
        guard !payload.isEmpty else { return }
        try await AirLiftService.placeFiles(payload, in: directory)

        let verified = await readTones()
        for (index, tone) in allTones.enumerated() {
            guard let expected = tones.indices.contains(index) ? tones[index] : nil else { continue }
            guard verified.indices.contains(index), let actual = verified[index] else {
                // 读不回 ⇒ 只留痕，不推翻写入成功的结论。
                continue
            }
            guard actual == expected else {
                throw ToneError.verificationFailed(tone.name)
            }
        }
    }

    /// 逐元素比较；nil 项按 requireAll 决定是「不等」还是「跳过」。
    ///
    /// 语义与 AirBeep v2.5.1 的 tones(_:equal:requireAll:) 一致：
    /// requireAll == false 时，任一为 nil 的项直接跳过（「不知道」不等于「不同」）。
    private static func tonesEqual(_ lhs: [Data?], _ rhs: [Data?], requireAll: Bool) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (l, r) in zip(lhs, rhs) {
            switch (l, r) {
            case (nil, _), (_, nil):
                if requireAll { return false }
            case let (l?, r?):
                if l != r { return false }
            }
        }
        return true
    }

    // MARK: - 备份

    /// 备份目录里是否有**可用**的完整备份。
    ///
    /// v0.3.689：原来只做 fileExists，于是「两个文件都在但其中一个是 0 字节」也算完整备份
    /// ⇒ disable() 的 backupComplete 判 true、永不重新备份，界面显示「已备份」，
    /// 用户之后点恢复拿到的是那个 0 字节文件。现在与 readBackups 共用同一套判定。
    private static func hasBackup() -> Bool {
        backupIsUsable()
    }

    /// 备份可用性（非空 + 必需项齐全）的唯一判据 —— hasBackup 与 readBackups 必须一致。
    private static func backupIsUsable() -> Bool {
        (try? readBackups()) != nil
    }

    /// 把当前内容写成备份（跳过读不出的项；调用方已在全部可读时才会调用）。
    ///
    /// v0.3.689 两条保护（对齐上游 AirBeep v2.5.1 的 ensureBackup）：
    /// ① 内容等于静音素材的项**不备份** —— 那不是「原始提示音」，存下来只会让 restore
    ///    把静音写回设备还报成功（上游注释：data == silentData 则跳过）；
    /// ② 已有备份**绝不覆盖** —— 备份是恢复的唯一凭据，覆盖等于毁掉唯一的一份原始音。
    private static func writeBackups(_ current: [Data?]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let silent = try? silentTones()
        for (index, tone) in allTones.enumerated() {
            guard current.indices.contains(index), let data = current[index] else { continue }
            if let silent, silent.indices.contains(index), let silentData = silent[index], silentData == data {
                continue
            }
            let url = backupURL(for: tone)
            if fm.fileExists(atPath: url.path) { continue }
            try data.write(to: url, options: .atomic)
        }
    }

    /// 读回已备份的原始提示音。
    ///
    /// v0.3.689：判定从「文件在不在」升级为「**非空 + 必需项齐全**」。
    ///
    /// 原实现只判 fileExists，于是 0 字节备份被当成有效备份：
    /// restore() 会把 0 字节写进设备、读回校验读到的也是 0 字节（与 expected 相等）
    /// ⇒ 界面报「已从备份恢复原始提示音」，而设备上的提示音根本没动。
    /// 上游 AirBeep v2.5.1 的等价判据是 file.optional || (data?.isEmpty == false)。
    private static func readBackups() throws -> [Data?] {
        var result: [Data?] = []
        result.reserveCapacity(allTones.count)
        for tone in allTones {
            let url = backupURL(for: tone)
            guard FileManager.default.fileExists(atPath: url.path) else {
                if tone.optional { result.append(nil); continue }
                throw ToneError.noBackup
            }
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                // 0 字节 = 不可用的备份，按「没有备份」处理，绝不写进设备。
                if tone.optional { result.append(nil); continue }
                throw ToneError.noBackup
            }
            result.append(data)
        }
        return result
    }

    private static func backupURL(for tone: Tone) -> URL {
        backupDirectory.appendingPathComponent(tone.name)
    }

    // MARK: - 静音素材

    /// 读 bundle 内**等长静音**素材（顺序与 allTones 对应）。
    private static func silentTones() throws -> [Data?] {
        try allTones.map { tone in
            guard let url = resourceURL(for: tone) else {
                throw ToneError.invalidToneBundle
            }
            return try Data(contentsOf: url)
        }
    }

    /// 定位 bundle 内静音素材。
    ///
    /// 依次尝试：bundle 根目录（Resources/ 递归资源会被平铺到根）、Resources/ 子目录、
    /// SilentTones/ 子目录（若改为 folder reference 保留目录时命中）—— 覆盖两种打包方式。
    private static func resourceURL(for tone: Tone) -> URL? {
        let bundle = Bundle.main
        return bundle.url(forResource: tone.resourceName, withExtension: tone.resourceExtension)
            ?? bundle.url(
                forResource: tone.resourceName,
                withExtension: tone.resourceExtension,
                subdirectory: "Resources"
            )
            ?? bundle.url(
                forResource: tone.resourceName,
                withExtension: tone.resourceExtension,
                subdirectory: "SilentTones"
            )
    }
}
