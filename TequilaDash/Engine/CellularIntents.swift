//
//  CellularIntents.swift
//  TequilaDash
//
//  v0.3.759：AppIntent 完全静默方案（照 Gnoix AutoRenewAppsIntent 同款机制移植）.
//
//  背景（取证结论，详见 02_审计与报告/AppIntent静默方案.md）：
//  · Gnoix 的静默续签真身 = AppIntents 框架的 AppIntent（openAppWhenRun = false），
//    由快捷指令「自动化」后台触发 —— 系统在后台拉起 App 执行 perform()，全程无前台 UI.
//  · 与 shortcuts://run-shortcut 的本质区别：URL 方案会把快捷指令 App 拉到前台；
//    AppIntent 方案只唤醒本 App 的后台执行，用户无感知.
//  · **AppIntent 不赋予任何系统特权**：私有 CoreTelephony setter 在 Intent 里
//    同样会被 CommCenter 权限层拒绝（CTError 2），本文件如实把结果回给快捷指令.
//

import AppIntents
import Foundation

// MARK: - 关/开蜂窝（私有 CoreTelephony 通路，效果判定）

/// 设置蜂窝网络开关（私有通路，效果判定；快捷指令自动化可后台静默执行）.
@available(iOS 16.0, *)
struct CellularSetIntent: AppIntent {
    static let title: LocalizedStringResource = "设置蜂窝网络"
    static let description = IntentDescription(
        "通过私有 CoreTelephony 通路尝试开关蜂窝网络，并以真实联网状态判定效果. 普通自签沙盒可能被系统权限层拒绝，届时会如实回报."
    )
    /// Gnoix 同款：自动化触发时不打开 App 前台，完全静默.
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "目标状态", description: "开 = 打开蜂窝网络；关 = 关闭蜂窝网络", default: false)
    var enable: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = CellularDataToggleService.shared
        guard service.isPrivateAPIAvailable else {
            return .result(dialog: "私有 CoreTelephony 通路在本机不可用，无法执行.")
        }
        do {
            try await service.setCellularEnabled(enable)
        } catch {
            return .result(dialog: "私有开关被系统拒绝（普通自签沙盒缺少 CommCenter 特权凭证）.")
        }
        // 效果判定：setter 返回 0 ≠ 生效，以真实蜂窝状态为准（v0.3.757 同款口径）.
        if enable {
            let back = await CellularNetworkChecker.shared.waitForNetworkToReturn(timeoutSeconds: 8)
            if back || CellularNetworkChecker.shared.isNetworkConnectedNow {
                return .result(dialog: "蜂窝网络已恢复联网.")
            }
            return .result(dialog: "调用完成但联网状态未恢复，蜂窝可能仍是关闭状态.")
        }
        let down = await CellularNetworkChecker.shared.waitForCellularToTurnOff(timeoutSeconds: 4)
        if down || !CellularNetworkChecker.shared.isNetworkConnectedNow {
            return .result(dialog: "蜂窝网络已断开.")
        }
        return .result(dialog: "调用完成但蜂窝状态未变化，可能被系统权限层拦截.")
    }
}

// MARK: - 便捷封装（自动化里免设参数，一键直达）

/// 关闭蜂窝网络（自动化友好：无参数，直接执行）.
@available(iOS 16.0, *)
struct CellularOffIntent: AppIntent {
    static let title: LocalizedStringResource = "关闭蜂窝网络"
    static let description = IntentDescription("私有通路尝试关闭蜂窝数据，后台静默执行，效果如实回报.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        var off = CellularSetIntent()
        off.enable = false
        return try await off.perform()
    }
}

/// 打开蜂窝网络（自动化友好：无参数，直接执行）.
@available(iOS 16.0, *)
struct CellularOnIntent: AppIntent {
    static let title: LocalizedStringResource = "打开蜂窝网络"
    static let description = IntentDescription("私有通路尝试恢复蜂窝数据，后台静默执行，效果如实回报.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        var on = CellularSetIntent()
        on.enable = true
        return try await on.perform()
    }
}
