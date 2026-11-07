import Foundation

// 沙盒容器 · 导入
//
// 一次导入 = 体检 → 解包到暂存区 → 校验出唯一 .app → 落到 Applications/ → 取图标 → 清暂存。
//
// 为什么先解到暂存区再落盘：IPA 里可能压根没有 Payload/*.app（改过名的 zip、单文件伪装），
// 也可能有多个 .app（主包 + 扩展打包错）。先解到 .staging 就能在**污染容器目录之前**判定，
// 判定失败只删暂存，Applications/ 保持原样。
//
// 硬门槛（与 LiveContainer 对齐）：
//   · FairPlay 加密包直接拒 —— LCAppInfo.m:341 同样拒收，理由一致：加密段在无 JIT 的进程里无法映射执行。
//   · 主二进制缺失直接拒 —— 没有可执行文件装进去也起不来。
//   · 4 GB 上限（与 ImportService.maxIPA 同口径）。

enum SandboxImportService {

    enum Failure: LocalizedError {
        case fileMissing
        case emptyOrTooLarge
        case notAnIPA
        case encrypted
        case missingExecutable
        case missingAppBundle
        case multipleAppBundles(Int)
        case noBundleIdentifier
        case disk(String)

        var errorDescription: String? {
            switch self {
            case .fileMissing:
                return "没找到要导入的文件."
            case .emptyOrTooLarge:
                return "文件为空或超过 4 GB."
            case .notAnIPA:
                return "这不是一个可识别的 IPA 包."
            case .encrypted:
                return "这个包是 App Store 加密包，沙盒容器装不了. 请提供已解密的 IPA."
            case .missingExecutable:
                return "包里没有可执行文件，装进去也起不来."
            case .missingAppBundle:
                return "包里没有 Payload/*.app 目录，不是标准 IPA."
            case .multipleAppBundles(let n):
                return "包里有 \(n) 个 .app 目录，无法判断装哪一个."
            case .noBundleIdentifier:
                return "包的 Info.plist 里没有 CFBundleIdentifier."
            case .disk(let detail):
                return detail
            }
        }
    }

    /// 导入结果.
    struct Outcome: Sendable {
        let app: SandboxApp
        /// 之前已有同 bundleId 的容器，这次是覆盖安装（元数据目录保留）.
        let replaced: Bool
        /// 需要提示给用户但不算失败的情况（例如加密状态未知）.
        let warning: String?
    }

    /// 导入上限，与 ImportService 的 maxIPA 同口径.
    private static let maxBytes: Int64 = 4 * 1024 * 1024 * 1024

    /// 导入一个 IPA（同步、重活，调用方放后台）.
    ///
    /// - Parameters:
    ///   - url: 已在本应用沙盒内的 IPA 路径（SharedDocumentPicker 用 asCopy:true 保证）.
    ///   - progress: 阶段文案回调（在主线程外调用，调用方自行切主线程）.
    ///   - removeSourceWhenDone: 导入结束后是否删掉源文件。documentPicker 的副本归我们，
    ///     不删就会在收件箱里越积越多。
    static func importIPA(at url: URL,
                          progress: (@Sendable (String) -> Void)? = nil,
                          removeSourceWhenDone: Bool = true) throws -> Outcome {
        let fm = FileManager.default
        let path = url.path
        guard fm.fileExists(atPath: path) else { throw Failure.fileMissing }
        let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
        guard size > 0, size <= maxBytes else { throw Failure.emptyOrTooLarge }

        defer {
            if removeSourceWhenDone { try? fm.removeItem(atPath: path) }
        }

        // 关卡 A：是不是 IPA / 加没加密（走中央目录，不解整包）.
        progress?("正在体检安装包")
        guard let inspection = IPAPackageInspector.inspect(ipaPath: path) else {
            throw Failure.notAnIPA
        }
        if inspection.encryption == .encrypted { throw Failure.encrypted }
        if inspection.missingExecutable { throw Failure.missingExecutable }
        let warning: String? = inspection.encryption == .unknown
            ? "读不出主二进制的加密状态，按未加密处理. 如果启动失败，请换一个已解密的包."
            : nil

        try SandboxContainerStore.ensureRoot()
        let staging = SandboxContainerStore.root
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 关卡 B：解包（ZipReader 内部有 zip-slip 防护 + 20000 文件 / 2 GB 上限）.
        progress?("正在解包")
        let files = FileService()
        do {
            let reader = try ZipReader(url: url)
            defer { reader.close() }
            try reader.extract(into: staging.path, files: files)
        } catch {
            throw Failure.disk("解包失败：\(error.localizedDescription)")
        }

        // 定位唯一的 Payload/*.app.
        progress?("正在校验包结构")
        let payload = staging.appendingPathComponent("Payload", isDirectory: true)
        let entries = (try? fm.contentsOfDirectory(atPath: payload.path)) ?? []
        let appBundles = entries.filter { $0.hasSuffix(".app") }
        guard !appBundles.isEmpty else { throw Failure.missingAppBundle }
        guard appBundles.count == 1, let bundleName = appBundles.first else {
            throw Failure.multipleAppBundles(appBundles.count)
        }
        let stagedApp = payload.appendingPathComponent(bundleName, isDirectory: true)
        guard let info = SandboxContainerStore.readInfoPlist(appBundlePath: stagedApp.path),
              let bundleId = info["CFBundleIdentifier"] as? String,
              !bundleId.isEmpty else { throw Failure.noBundleIdentifier }
        guard let executable = info["CFBundleExecutable"] as? String,
              fm.fileExists(atPath: stagedApp.appendingPathComponent(executable).path) else {
            throw Failure.missingExecutable
        }

        // 定目标目录名：优先沿用原 .app 名（LiveContainer 同口径，用户认得出），
        // 与**别的** bundleId 撞名时加序号.
        let baseName = FileNameRules.sanitize(bundleName) ?? bundleName
        let target = uniqueAppURL(preferredName: baseName, bundleId: bundleId)

        // 同 bundleId 已存在 ⇒ 覆盖（保留元数据目录）.
        let replaced = removeExistingContainer(bundleId: bundleId, keeping: target)

        progress?("正在写入容器")
        do {
            try fm.moveItem(at: stagedApp, to: target)
        } catch {
            throw Failure.disk("写入容器失败：\(error.localizedDescription)")
        }

        // 登记（安装时间 + 显示名；元数据 UUID 首次启动时再补）.
        SandboxContainerStore.registerInstall(bundleId: bundleId,
                                              displayName: (info["CFBundleDisplayName"] as? String)
                                                  ?? (info["CFBundleName"] as? String)
                                                  ?? (bundleName as NSString).deletingPathExtension,
                                              installedAt: Date())

        // 图标：从**源 IPA** 取（ImportedPackageIconExtractor 吃 zip，已有实现，不重写）.
        progress?("正在提取图标")
        if let icon = ImportedPackageIconExtractor.iconPNGData(ipaPath: path) {
            SandboxContainerStore.storeIcon(icon, bundleId: bundleId)
        }

        guard let app = SandboxContainerStore.scan().first(where: { $0.id == bundleId }) else {
            throw Failure.disk("容器已写入，但清单里读不到它（Info.plist 可能损坏）.")
        }
        return Outcome(app: app, replaced: replaced, warning: warning)
    }

    // MARK: - 辅助

    /// 目标 .app 路径：同名且**不同** bundleId 时加序号，避免两个 App 抢一个目录名.
    private static func uniqueAppURL(preferredName: String, bundleId: String) -> URL {
        let fm = FileManager.default
        let dir = SandboxContainerStore.applicationsDirectory
        let stem = (preferredName as NSString).deletingPathExtension
        var candidate = dir.appendingPathComponent(preferredName, isDirectory: true)
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            // 同名同 bundleId 的情况由 removeExistingContainer 先删掉，这里只会撞到**别的** App.
            if let info = SandboxContainerStore.readInfoPlist(appBundlePath: candidate.path),
               (info["CFBundleIdentifier"] as? String) == bundleId {
                break
            }
            candidate = dir.appendingPathComponent("\(stem)-\(index).app", isDirectory: true)
            index += 1
        }
        return candidate
    }

    /// 删掉同 bundleId 的旧容器（保留元数据目录与登记），返回是否真的删了东西.
    private static func removeExistingContainer(bundleId: String, keeping target: URL) -> Bool {
        let fm = FileManager.default
        var removed = false
        let dir = SandboxContainerStore.applicationsDirectory
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasSuffix(".app") {
            let path = dir.appendingPathComponent(name, isDirectory: true)
            if path.standardizedFileURL == target.standardizedFileURL { continue }
            guard let info = SandboxContainerStore.readInfoPlist(appBundlePath: path.path),
                  (info["CFBundleIdentifier"] as? String) == bundleId else { continue }
            if (try? fm.removeItem(at: path)) != nil { removed = true }
        }
        return removed
    }
}
