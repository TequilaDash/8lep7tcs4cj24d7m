import SwiftUI
import UIKit

/// 「禁用通话录音」控制台 —— 「更多 → 禁用通话录音」的二级页。
///
/// 参考项目 AirBeep（原名 Placard，仓库 LinkPass888/AirBeep）：把通话录音的开始 /
/// 结束**披露提示音**替换成等长静音，录音本身不受影响。替换写入经 AirLiftService
/// —— 真 airlift：配对文件 + LocalDevVPN 隧道在设备上直接驱动 AirTraffic
/// （Rust libairlift_ffi.a，见 Engine/Airlift/）。
///
/// 界面只保留必要信息：原理说明卡片 + 当前状态 + 两个动作（禁用 / 恢复）。
struct CallRecordingToneView: View {
    @State private var state: CallRecordingToneService.ToneState = .original
    @State private var busy = false
    @State private var alert: ToneAlert?
    /// v0.3.652：当前进行到哪一步（airlift 每次操作都要重建隧道，全程可能数十秒）。
    @State private var phase: String?
    /// v0.3.661：读不到原始提示音时的「继续即不可恢复」确认。
    @State private var risk: RiskPrompt?
    /// v0.3.672：正在做「检查写入通道」的探测。
    @State private var checking = false

    var body: some View {
        List {
            Section {
                InfoActionCard(
                    icon: "speaker.slash.fill",
                    title: "禁用通话录音",
                    message: "把通话录音的起止提示音替换为等长静音，录音本身仍正常进行.原始提示音会备份到本机，可随时恢复."
                )
            }

            Section {
                HStack {
                    Text("当前状态")
                    Spacer()
                    Text(statusText)
                        .foregroundColor(.secondary)
                }
            } header: {
                Label("状态", systemImage: "waveform")
            } footer: {
                Text("需先导入配对文件并连接 LocalDevVPN，才能写入系统提示音文件.支持 iOS/iPadOS 18.0–27.2 B2.")
            }

            Section {
                Button {
                    run(.disable)
                } label: {
                    Label("禁用提示音", systemImage: "speaker.slash.fill")
                }
                .disabled(busy || state == .silenced)

                // v0.3.652：把「正在做什么」显示出来。
                //
                // airlift 每次操作都要重新建隧道（无连接复用），全流程有 5 次操作，
                // 加起来可能几十秒。原来界面什么都不显示，用户看到的就是
                // 「点了没反应 / 一直转圈」，以为卡死了。
                if let phase {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(phase)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    run(.restore)
                } label: {
                    Label("恢复原始提示音", systemImage: "arrow.uturn.backward")
                }
                // v0.3.650：.disabled(busy || state != .silenced) 会把 .unreachable
                // 也一起禁掉 —— 而 .unreachable 恰恰是最该允许用户尝试恢复的时候
                // （AirBeep 的探测在某些 iOS 版本上必然失败，会常年卡在这个状态）。
                // 现在只禁「已经是原始音」的情况，其余一律放行，让用户自己试。
                .disabled(busy || state == .original)

                // v0.3.672：动手之前先能确认「配对文件 + LocalDevVPN + 系统版本」这一串前置真的通.
                // 它接到 Service.probeReachable() 与 lastReadFailureReason() —— 这两个原来是死符号.
                Button {
                    checkChannel()
                } label: {
                    Label("检查写入通道", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(busy || checking)

                if checking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取系统提示音文件…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Label("操作", systemImage: "slider.horizontal.3")
            } footer: {
                Text("禁用后建议拨打一次录音验证效果.恢复会从本机备份写回原始提示音.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("禁用通话录音")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            state = loadState()
        }
        .alert(item: $alert) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("好"))
            )
        }
        // 读不到原始音 ⇒ 无法备份。这种情况下「禁用」依然可做（写入通道是好的），
        // 但原始提示音会永久丢失，所以必须让用户明确确认，不能替他决定。
        .confirmationDialog(
            "无法备份原始提示音",
            isPresented: Binding(
                get: { risk != nil },
                set: { if !$0 { risk = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("仍然禁用（原始提示音将无法恢复）", role: .destructive) {
                let names = risk?.unreadable ?? []
                risk = nil
                perform(.disable, acknowledgingRisk: true, unreadable: names)
            }
            Button("取消", role: .cancel) {
                risk = nil
                busy = false
                phase = nil
            }
        } message: {
            Text(risk?.message ?? "")
        }
    }

    // MARK: - 展示

    private var statusText: String {
        switch state {
        case .original: return "原始提示音"
        case .silenced: return "已禁用（静音）"
        case .unreachable: return "不可达"
        }
    }

    // MARK: - 动作

    /// 一个可发送到后台执行的动作（枚举而非闭包：天然 Sendable，跨并发边界无需额外标注）.
    private enum ToneAction: Sendable, Equatable {
        case disable
        case restore

        var startPhase: String {
            switch self {
            case .disable: return "正在读取当前提示音…"
            case .restore: return "正在读取备份…"
            }
        }

        var doneMessage: String {
            switch self {
            case .disable: return "已把通话录音提示音替换为静音."
            case .restore: return "已从备份恢复原始提示音."
            }
        }
    }

    /// 在后台线程执行 airlift 传输（含建隧道与文件 IO，会阻塞），完成后回主线程刷新状态.
    ///
    /// v0.3.652：加阶段提示。airlift 全程要多次独立操作（每次重建隧道），
    /// 不告诉用户「在等什么」，界面就像死了一样。
    /// v0.3.661：读通道失败不再让整个动作失败（见 CallRecordingToneService 文件头），
    /// 但「无法备份」必须先经用户确认。
    private func run(_ action: ToneAction) {
        perform(action, acknowledgingRisk: false, unreadable: [])
    }

    private func perform(_ action: ToneAction, acknowledgingRisk: Bool, unreadable: [String]) {
        guard !busy else { return }
        busy = true
        phase = action.startPhase
        AppHaptics.tap()
        Task {
            // v0.3.672：全程可能数十秒，默认锁屏时间（最短 30 秒）足够在中途锁屏.
            // 锁屏会让写到一半的提示音停在中间态，而持久化标记要到写完才置位 ⇒
            // 界面显示「原始提示音」、设备上却是半新半旧. 所以操作期间不自动锁屏.
            // defer 覆盖成功 / 失败 / 等用户确认三条出口：这三条之后都没有写入在飞.
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let summary = try await Task.detached(priority: .userInitiated) { () -> String in
                    switch action {
                    case .disable:
                        let report = try await CallRecordingToneService.disable(
                            acknowledgingRisk: acknowledgingRisk
                        )
                        return report.summary
                    case .restore:
                        try await CallRecordingToneService.restore()
                        return action.doneMessage
                    }
                }.value
                state = loadState()
                busy = false
                phase = nil
                AppHaptics.success()
                alert = ToneAlert(title: "完成", message: summary)
            } catch let error as CallRecordingToneService.ToneError {
                busy = false
                phase = nil
                if case .backupIncomplete(let names) = error {
                    // 不是失败，是需要用户决定：写入本身没问题，丢的是「能恢复」这个后路。
                    risk = RiskPrompt(unreadable: names)
                    return
                }
                alert = ToneAlert(title: "失败", message: error.localizedDescription)
            } catch {
                busy = false
                phase = nil
                alert = ToneAlert(title: "失败", message: error.localizedDescription)
            }
        }
    }

    /// v0.3.672：把 probeReachable 接到界面上.
    ///
    /// 它原来是死符号（定义在 Service、全仓零调用），.unreachable 也就永远走不到.
    /// 现在用户可以在动手之前先确认前置是否真的通，失败时把 lastReadFailureReason()
    /// 一并显示出来 —— 那个诊断字段同样曾是死符号.
    private func checkChannel() {
        guard !checking else { return }
        checking = true
        AppHaptics.tap()
        Task {
            let ok = await CallRecordingToneService.probeReachable()
            checking = false
            if ok {
                alert = ToneAlert(
                    title: "通道可用",
                    message: "已成功读取系统提示音文件，可以执行禁用或恢复."
                )
            } else {
                let reason = CallRecordingToneService.lastReadFailureReason() ?? "原因未知"
                alert = ToneAlert(
                    title: "通道不可用",
                    message: "读不到系统提示音文件.请确认已导入配对文件、已连接 LocalDevVPN，"
                        + "且系统版本在支持范围内（iOS/iPadOS 18.0–27.2 B2）."
                        + "\n\n" + reason
                )
            }
        }
    }

    /// 读状态。v0.3.650 起**不做 airlift 探测**（照 AirBeep），同步即可。
    private func loadState() -> CallRecordingToneService.ToneState {
        CallRecordingToneService.currentState()
    }
}

/// 「读不到原始音、无法备份」的风险确认内容.
private struct RiskPrompt: Identifiable {
    let id = UUID()
    let unreadable: [String]

    var message: String {
        "读不到 " + unreadable.joined(separator: "、") + "，因此无法备份原始提示音."
            + "这是 airlift 读通道在该 iOS 版本上的已知限制，与写入无关."
            + "继续禁用后，本 App 无法帮你恢复原始提示音（需切换系统语言让系统重新生成，或用 iTunes/iOS 还原）."
    }
}

/// 结果 / 错误弹窗内容.
private struct ToneAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
