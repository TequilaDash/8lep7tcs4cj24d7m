import Foundation
import Security

/// 「重置数据」：只清本 App 自己产生的数据，不碰设备、不碰用户导出的备份.
enum AppDataResetService {

    struct Summary: Sendable {
        var defaultsKeysRemoved = 0
        var keychainItemsRemoved = 0
        var filesRemoved = 0
        var bytesRemoved: Int64 = 0
    }

    /// 白名单只列本 App 自己写入的键；单个大数组字面量会把 Xcode 的类型检查推到超时，故分组求解.
    private enum DefaultsKeys {
        static let account = [
            "TequilaDash.ActiveAppleID", "TequilaDash.LegacyImportDone",
            "AppStore.CountryCode", "AppStore.SelectedEmail", "ApplePackageDeviceIdentifier",
            "AppStore.RegionFollowedEmail", "AppStore.ShopRegion", "LoginHistory",
            "SRPTestResult_v2", "SigningTrueUDID", "IPA.autoSignInEnabled", "niuwa.pseudoUDID",
        ]
        static let anisette = [
            "AnisetteServer", "AnisetteIdentityServer", "CustomAnisetteClientInfo",
            "TequilaDash.OnDeviceAnisette", "TequilaDash.OnDeviceAnisette.EngineVersion",
        ]
        static let certificate = [
            "modules.certSignEnabled", "certs.autoRevokeEnabled", "certs.revokeWhitelist", "SecurityMainExeHash",
        ]
        static let tunnel = [
            "TunnelDeviceIP", "TequilaDash.AutoStartLocalDevVPN", "TequilaDash.LocalDevVPNLastHandover",
            "TequilaDash.TunnelKind", "TequilaDash.CellularTunnelSupport",
            "TequilaDash.CellularTogglePolarityInverted", "CellularToggleMode",
            "rppairing.portOverride", "rppairing.resolvedPort", "rppairing.directIP",
            "rppairing.directHost", "rppairing.directIPAt", "wirelessHostAltIrk",
        ]
        static let ssh = ["ssh.username", "ssh.password", "ssh.port", "ssh.hasSetPassword", "ssh.debugMode"]
        static let services = [
            "KeepAliveEnabled", "keepAliveAudio", "keepAliveLocation", "ProcessMemoryWatch",
            "LogLimit.maxFileMB", "LogLimit.maxCatMB", "escape.onlineInstallEndpoint",
            "DeveloperModeStatus", "pip.height", "IPCCInstallHistory",
        ]
        static let modules = [
            "Module.uninstalled.ids", "Module.hostInstall.version", "Module.disabled.inplace",
            "ExploitSettings.enabled.rawValues", "ExploitSettings.initialized",
            "I4Mobile.customPacks", "SourcePackageLocator.availability.v2",
        ]
        static let uiState = [
            "AppStoreDisclaimerAccepted_v1",   
            "HasAcknowledgedLimits", "SignSource.HideAnnouncement", "VersionHistory.Source",
            "mha_app_group_override", "escape.jitRecents", "escape.favorites", "escape.recents",
            "escape.locationGuard", "escape.routeLoopEnabled", "escape.speedMultiplier",
            "escape.bluetoothRole", "domainblocker_presets", "domainblocker_custom",
            "dialerThemeContainerPath", "dialerThemeCacheDirectory", "dialerThemeScanVersion",
            "CallRecordingTone.disabled", "CallRecordingTone.silencedWithoutBackup",
            "wallpaperTendies", "wallpaperPBContainerPath", "wallpaperHasShownFirstRunMsg", "mg_devicename",
        ]
        static var all: [String] { account + anisette + certificate + tunnel + ssh + services + modules + uiState }
    }

    private enum DefaultsPrefixes {
        static let all = ["bilinHistory.", "AppStore.LastGoodVersion.", "Binary.startInFlight."]
    }

    private static let keychainServices = ["com.tequila.dash.memorylimit", "com.tequila.dash.onlineinstall"]

    private enum Documents {
        static let directories = [
            "AFCDownloads", "AppIcons", "AppStoreDownloads", "BLELogs", "CapabilityLog",
            "CrashLogs", "Custom", "DDI", "DeveloperCert", "Downloads", "ExportedDialerThemes", "DomainBlocker", "Imports", "KernelCache", "LoginLogs", "Modules", "Profiles", "Repaired", "Ringtones",
            "SAPAssets", "SysmonLogs", "Tequila", "TendiesExports", "Wallpapers", "文件导出浏览",
        ]
        static let files = [
            "pairingFile.plist", "ipa_downloads.json", "app_favorites.json", "appstore_accounts.json",
            "device_guid.txt", "SavedGestalt.plist", "login.log", "ble.log",
        ]
    }

    /// 跳过名单：名字含 backup 的目录一律不碰 —— `Documents/Backups` 是用户从设备导出的别机备份（BackupPaths.swift:122），
    /// ConfigsBackups / GestaltBackups / IconStateBackup / CallRecordingToneBackup 同理是还原锚点.
    private static let skipDirectoryNameSubstring = "backup"

    private enum Library {
        static let directories = ["TequilaDashIsideload", "TequilaDash"]
    }

    /// 沙盒里没有 Caches 时用的占位（purgeChildren 读到空目录即返回）.
    private static let cachesSkip = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/CachesSkip", isDirectory: true)

    static func reset() async -> Summary {
        var summary = await clearState()
        let purged = await Task.detached(priority: .userInitiated, operation: purgeFiles).value
        summary.filesRemoved = purged.count
        summary.bytesRemoved = purged.bytes
        return summary
    }

    @MainActor
    private static func clearState() -> Summary {
        var summary = Summary()
        AppleUserAccountStore.shared.signOutAll(options: AppleAccountSignOutOptions(
            keepCertificate: false, keepAnisetteData: false, keepAnisetteHeaders: false))
        AppStoreDownloadStore.shared.signOutAll()
        AnisetteProvider.shared.reset()
        CertificateManager.shared.reset()
        MemoryLimitSettings.shared.signOut(keepAnisetteData: false, keepAnisetteHeaders: false)
        LoginLogger.shared.clear()
        for service in keychainServices {
            summary.keychainItemsRemoved += EscapeKeychain(service: service).deleteAllItems()
        }
        let defaults = UserDefaults.standard
        let stored = Set(defaults.dictionaryRepresentation().keys)
        var removed = 0
        for key in DefaultsKeys.all where stored.contains(key) { defaults.removeObject(forKey: key); removed += 1 }
        for prefix in DefaultsPrefixes.all {
            for key in stored where key.hasPrefix(prefix) { defaults.removeObject(forKey: key); removed += 1 }
        }
        summary.defaultsKeysRemoved = removed
        LoginLogger.shared.log("[重置数据] UserDefaults \(removed) 项，钥匙串 \(summary.keychainItemsRemoved) 项")
        return summary
    }

    private static func purgeFiles() -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        var count = 0
        var freed: Int64 = 0
        func bytes(of url: URL) -> Int64 {
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
            guard let meta = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
            if meta.isRegularFile == true { return Int64(meta.totalFileAllocatedSize ?? meta.fileSize ?? 0) }
            guard let walk = fm.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
            var total: Int64 = 0
            for case let child as URL in walk {
                let v = try? child.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0) }
            }
            return total
        }
        func remove(_ url: URL) {
            guard fm.fileExists(atPath: url.path) else { return }
            guard !url.lastPathComponent.lowercased().contains(skipDirectoryNameSubstring) else { return }
            let b = bytes(of: url)
            do { try fm.removeItem(at: url); count += 1; freed += b }
            catch { LoginLogger.shared.log("[重置数据] 未删除 \(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        func purgeChildren(of dir: URL) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            for item in items { remove(item) }
        }

        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        let libs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let docs {
            for name in Documents.directories { remove(docs.appendingPathComponent(name, isDirectory: true)) }
            for name in Documents.files { remove(docs.appendingPathComponent(name)) }
        }
        for url in [libs, support].compactMap({ $0 }) {
            for name in Library.directories { remove(url.appendingPathComponent(name, isDirectory: true)) }
        }
        purgeChildren(of: libs?.appendingPathComponent("Caches", isDirectory: true) ?? Self.cachesSkip)
        purgeChildren(of: fm.temporaryDirectory)
        return (count: count, bytes: freed)
    }
}
