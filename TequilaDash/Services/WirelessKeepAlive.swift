//
//  WirelessKeepAlive.swift
//  TequilaDash
//
//  无线配对期间的后台保活调度器.
//  组合静默音频与位置更新，并申请 beginBackgroundTask
//  延长后台存活时间，避免 Bonjour 广播被系统回收.
//

import UIKit

// Swift 6：beginBackgroundTask 到期回调与调用点（PairingSetupView）均在主线程，
// 整个类收敛到 @MainActor（修 sending 'self'）.
@MainActor
final class WirelessKeepAlive {
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// 启动用户选择的保活机制.
    /// - Parameters:
    ///   - audio: 是否启用静默音频保活.
    ///   - location: 是否启用位置更新保活.
    func start(audio: Bool, location: Bool) {
        if audio {
            BackgroundAudioManager.shared.start()
        }
        if location {
            BackgroundLocationManager.shared.start()
        }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "TequilaDashWirelessPairing") { [weak self] in
            self?.stop()
        }
    }

    /// 停止全部保活机制并结束后台任务.
    func stop() {
        BackgroundAudioManager.shared.stop()
        BackgroundLocationManager.shared.stop()

        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
}
