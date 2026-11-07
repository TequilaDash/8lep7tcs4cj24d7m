import Foundation

// 沙盒容器 · 引擎
//
// 目录模型照 LiveContainer（不是照它的注入模型）：
//   · 一个 IPA 进来 → 解包到 Documents/SandboxApps/Applications/<名字>.app
//   · 每次安装配一个独立元数据家目录 Documents/SandboxApps/Data/Application/<UUID>/
//   · 清单**不落台账**，一律由磁盘现状推导（与 ImportedPackageList 同一取向）
//
// 边界（重要）：
//   · 本文件只做「容器目录 + 导入 + 体检 + 删除」，**不启动访客进程**。启动要复刻
//     LiveContainer 的进程内 dlopen + LC_MAIN 跳转（getAppEntryPoint / overwriteMainNSBundle /
//     CFFIXED_USER_HOME 那一整套），属独立阶段，见 02_审计与报告/修复记录/sandbox-container.md。
//   · 加密包（FairPlay，主二进制 cryptid != 0）**直接拒收**：LiveContainer 同样拒收
//     （LCAppInfo.m:341 "The app you tried to install is encrypted. Please provide decrypted app."），
//     理由一致 —— 解密后的代码页在无 JIT 的进程里无法映射执行。
//   · 不做整包重签：ZSign 只暴露单文件签名入口（zsign_sign_file_with_cert），整包还要自己
//     递归 PlugIns / Frameworks 并重写 _CodeSignature/CodeResources，属独立阶段。

// MARK: - 元数据模型

/// 一个沙盒容器里的应用。
///
/// id 取 bundleId：同一个 bundleId 只允许存在一份容器，重复导入按「替换」处理，
/// 避免同一 App 多份容器互相抢元数据目录。LiveContainer 允许同名多容器，我们不做，
/// 因为我们的清单是扫盘推导的，多份同 bundleId 会让「哪个是用户点的那份」失去判据。
struct SandboxApp: Identifiable, Hashable, Sendable {
    let id: String                 // bundleId
    let displayName: String
    let bundleVersion: String?
    let executable: String?
    let appPath: String            // .../Applications/<名字>.app
    let dataPath: String?          // .../Data/Application/<UUID>，首次启动才建
    let installedAt: Date?
    let sizeBytes: Int64

    var sizeText: String { IPADownloadLibrary.sizeText(sizeBytes) }

    /// 元数据家目录是否已就绪（没有 = 还没启动过）。
    var hasDataHome: Bool {
        guard let dataPath else { return false }
        return FileManager.default.fileExists(atPath: dataPath)
    }
}

/// 容器根下的持久化登记：只记**磁盘推不出来的那几项**（安装时间、元数据目录 UUID）。
///
/// 原则同 ImportedPackageList：能扫出来的绝不再存一份，存了就必须容忍它缺失 / 损坏
/// （读不出就当没有，绝不因此让列表变空）。
private struct SandboxRegistry {
    struct Entry {
        var displayName: String?
        var dataUUID: String?
        var installedAt: Date?
    }

    var entries: [String: Entry] = [:]

    static func load(from url: URL) -> SandboxRegistry {
        var reg = SandboxRegistry()
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let apps = root["apps"] as? [String: Any] else { return reg }
        for (bundleId, raw) in apps {
            guard let dict = raw as? [String: Any] else { continue }
            reg.entries[bundleId] = Entry(
                displayName: dict["displayName"] as? String,
                dataUUID: dict["dataUUID"] as? String,
                installedAt: dict["installedAt"] as? Date
            )
        }
        return reg
    }

    func save(to url: URL) {
        var apps: [String: Any] = [:]
        for (bundleId, entry) in entries {
            var dict: [String: Any] = [:]
            dict["displayName"] = entry.displayName
            dict["dataUUID"] = entry.dataUUID
            dict["installedAt"] = entry.installedAt
            apps[bundleId] = dict
        }
        let root: [String: Any] = ["version": 1, "apps": apps]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: root,
                                                             format: .xml,
                                                             options: 0) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - 容器根与清单

enum SandboxContainerStore {

    /// 容器根：Documents/SandboxApps/。
    ///
    /// 放 Documents 下（不是 Caches）的理由与 Imports 一致：用户能在「文件」App 里看见、
    /// 能用 Finder 拷走整份容器；Caches 会被系统在空间紧张时清掉，容器被清等于装的应用凭空消失。
    static var root: URL {
        URL(fileURLWithPath: FileSystemRoots.appDocuments, isDirectory: true)
            .appendingPathComponent("SandboxApps", isDirectory: true)
    }

    static var applicationsDirectory: URL { root.appendingPathComponent("Applications", isDirectory: true) }
    static var dataDirectory: URL { root.appendingPathComponent("Data/Application", isDirectory: true) }
    static var registryURL: URL { root.appendingPathComponent("containers.plist") }

    static func ensureRoot() throws {
        let fm = FileManager.default
        for dir in [root, applicationsDirectory, dataDirectory] where !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: 清单（扫盘推导）

    /// 扫容器目录，返回全部应用（按安装时间倒序，读不出时间排最后）。
    ///
    /// 每一项都必须有磁盘证据：Applications/<x>.app/Info.plist 能读出 CFBundleIdentifier 才算一条；
    /// 读不出就跳过并记日志（半截目录 / 用户手动改坏的情况），**绝不凭空补一条**。
    static func scan() -> [SandboxApp] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: applicationsDirectory.path) else { return [] }
        let registry = SandboxRegistry.load(from: registryURL)
        var apps: [SandboxApp] = []
        for name in names where name.hasSuffix(".app") {
            let appPath = applicationsDirectory.appendingPathComponent(name, isDirectory: true).path
            guard let info = readInfoPlist(appBundlePath: appPath),
                  let bundleId = info["CFBundleIdentifier"] as? String,
                  !bundleId.isEmpty else {
                LoginLogger.shared.log("[沙盒容器] 跳过无法识别的容器目录：\(name)", category: .general)
                continue
            }
            let entry = registry.entries[bundleId]
            let dataPath = entry?.dataUUID.map {
                dataDirectory.appendingPathComponent($0, isDirectory: true).path
            }
            let registeredName = entry?.displayName ?? ""
            let displayName = registeredName.isEmpty
                ? ((info["CFBundleDisplayName"] as? String)
                   ?? (info["CFBundleName"] as? String)
                   ?? (name as NSString).deletingPathExtension)
                : registeredName
            apps.append(SandboxApp(
                id: bundleId,
                displayName: displayName,
                bundleVersion: info["CFBundleShortVersionString"] as? String,
                executable: info["CFBundleExecutable"] as? String,
                appPath: appPath,
                dataPath: dataPath,
                installedAt: entry?.installedAt ?? directoryDate(appPath),
                sizeBytes: directorySize(appPath)
            ))
        }
        return apps.sorted {
            switch ($0.installedAt, $1.installedAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }
    }

    /// 读容器内 Info.plist（纯读取，不改字节）。
    static func readInfoPlist(appBundlePath: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: appBundlePath, isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }
        return plist as? [String: Any]
    }

    // MARK: 元数据家目录

    /// 取（必要时新建）该应用的元数据家目录。
    ///
    /// 目录名用 UUID（不用 bundleId）：LiveContainer 同型，理由是访客 App 会把 bundleId
    /// 当成自己的标识写进 Preferences / 缓存路径，目录名与 bundleId 脱钩后，用户重装同款
    /// App 可以拿到全新元数据目录而不与旧元数据混在一起。
    @discardableResult
    static func makeDataHome(for app: SandboxApp) throws -> URL {
        try ensureRoot()
        var registry = SandboxRegistry.load(from: registryURL)
        var entry = registry.entries[app.id] ?? SandboxRegistry.Entry()
        if let uuid = entry.dataUUID {
            let existing = dataDirectory.appendingPathComponent(uuid, isDirectory: true)
            if FileManager.default.fileExists(atPath: existing.path) { return existing }
        }
        let uuid = UUID().uuidString
        let home = dataDirectory.appendingPathComponent(uuid, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // 访客 App 期望的三件套（LiveContainer 同样预建，缺了会在首次写缓存时崩）。
        for sub in ["Library/Caches", "Library/Cookies", "Documents", "SystemData"] {
            try? FileManager.default.createDirectory(at: home.appendingPathComponent(sub, isDirectory: true),
                                                     withIntermediateDirectories: true)
        }
        entry.dataUUID = uuid
        entry.displayName = entry.displayName ?? app.displayName
        entry.installedAt = entry.installedAt ?? app.installedAt
        registry.entries[app.id] = entry
        registry.save(to: registryURL)
        return home
    }

    /// 清空元数据家目录（保留目录本身与登记）。
    static func resetDataHome(for app: SandboxApp) throws {
        guard let dataPath = app.dataPath else { return }
        let url = URL(fileURLWithPath: dataPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let fm = FileManager.default
        for child in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
            try fm.removeItem(at: child)
        }
        for sub in ["Library/Caches", "Library/Cookies", "Documents", "SystemData"] {
            try? fm.createDirectory(at: url.appendingPathComponent(sub, isDirectory: true),
                                    withIntermediateDirectories: true)
        }
    }

    // MARK: 登记与图标

    /// 记下安装时间与显示名（元`UUID` 首次启动时由 makeDataHome 补）。
    static func registerInstall(bundleId: String, displayName: String, installedAt: Date) {
        var registry = SandboxRegistry.load(from: registryURL)
        var entry = registry.entries[bundleId] ?? SandboxRegistry.Entry()
        entry.displayName = displayName
        entry.installedAt = installedAt
        registry.entries[bundleId] = entry
        registry.save(to: registryURL)
    }

    /// 图标落盘位置：`Caches/SandboxContainerIcons/<bundleId>.png`。
    ///
    /// 放 Caches 而不是容器目录：图标是可再生资源，丢了下次从 app 包重新取即可；
    /// 放容器里会让「删 App」多一处要清，且用户用 Finder 拷容器时带一堆 png 很脏。
    static func iconFileURL(bundleId: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SandboxContainerIcons", isDirectory: true)
            .appendingPathComponent(sanitize(bundleId) + ".png")
    }

    /// 写入图标（覆盖旧图）。
    static func storeIcon(_ data: Data, bundleId: String) {
        let url = iconFileURL(bundleId: bundleId)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 读回图标（没有就 nil，调用方回落 SF Symbol）。
    static func icon(for bundleId: String) -> Data? {
        try? Data(contentsOf: iconFileURL(bundleId: bundleId))
    }

    /// bundleId 里只有 `.` 与字母数字，但仍然过一遍净化：它是文件名，不是标识符。
    private static func sanitize(_ raw: String) -> String {
        FileNameRules.sanitize(raw) ?? raw
    }

    // MARK: 删除

    enum RemoveResult: Equatable {
        case removed
        case notFound
        case failed(String)
    }

    /// 删除该应用：app 包 + 元数据家目录 + 登记项。
    ///
    /// 返回**真实结果**（同 IPADownloadLibrary.RemoveResult 的取向）：删不掉必须如实上报，
    /// 不许报「已删除」然后列表里还在。
    static func remove(_ app: SandboxApp) -> RemoveResult {
        let fm = FileManager.default
        var anyExisted = false
        var failure: String?
        let targets = [app.appPath, app.dataPath].compactMap { $0 }
        for path in targets where fm.fileExists(atPath: path) {
            anyExisted = true
            do {
                try fm.removeItem(atPath: path)
            } catch {
                failure = error.localizedDescription
            }
        }
        if failure == nil {
            var registry = SandboxRegistry.load(from: registryURL)
            if registry.entries.removeValue(forKey: app.id) != nil {
                registry.save(to: registryURL)
            }
        }
        if let failure { return .failed(failure) }
        return anyExisted ? .removed : .notFound
    }

    // MARK: 磁盘量

    /// 容器包体积（只统计 app 包本身，不含元数据目录 —— 元数据目录在详情页单列）。
    private static func directorySize(_ path: String) -> Int64 {
        (try? FileService().countTree(at: path))?.bytes ?? 0
    }

    private static func directoryDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }
}
