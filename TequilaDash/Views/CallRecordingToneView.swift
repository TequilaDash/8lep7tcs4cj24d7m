import SwiftUI

/// 「禁用通话录音」控制台 —— 「更多 → 禁用通话录音」的二级页。
///
/// 参考项目 AirBeep（原名 Placard，仓库 `LinkPass888/AirBeep`）：把通话录音的开始 /
/// 结束**披露提示音**替换成等长静音，录音本身不受影响。替换写入经 `AirLiftService`
/// —— 真 airlift：配对文件 + LocalDevVPN 隧道在设备上直接驱动 AirTraffic
/// （Rust `libairlift_ffi.a`，见 `Engine/Airlift/`）。
///
/// 界面只保留必要信息：原理说明卡片 + 当前状态 + 两个动作（禁用 / 恢复）。
struct CallRecordingToneView: View {
    @State private var state: CallRecordingToneService.ToneState = .original
    @State private var busy = false
    @State private var alert: ToneAlert?

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

                Button {
                    run(.restore)
                } label: {
                    Label("恢复原始提示音", systemImage: "arrow.uturn.backward")
                }
                // v0.3.650：`.disabled(busy || state != .silenced)` 会把 `.unreachable`
                // 也一起禁掉 —— 而 `.unreachable` 恰恰是最该允许用户尝试恢复的时候
                // （AirBeep 的探测在某些 iOS 版本上必然失败，会常年卡在这个状态）。
                // 现在只禁「已经是原始音」的情况，其余一律放行，让用户自己试。
                .disabled(busy || state == .original)
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

    /// 一个可发送到后台执行的动作（枚举而非闭包：天然 `Sendable`，跨并发边界无需额外标注）.
    private enum ToneAction: Sendable {
        case disable
        case restore

        func perform() async throws {
            switch self {
            case .disable: try await CallRecordingToneService.disable()
            case .restore: try await CallRecordingToneService.restore()
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
    private func run(_ action: ToneAction) {
        guard !busy else { return }
        busy = true
        AppHaptics.tap()
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await action.perform()
                }.value
                state = loadState()
                busy = false
                AppHaptics.success()
                alert = ToneAlert(title: "完成", message: action.doneMessage)
            } catch {
                busy = false
                alert = ToneAlert(title: "失败", message: error.localizedDescription)
            }
        }
    }

    /// 读状态。v0.3.650 起**不做 airlift 探测**（照 AirBeep），同步即可。
    private func loadState() -> CallRecordingToneService.ToneState {
        CallRecordingToneService.currentState()
    }
}

/// 结果 / 错误弹窗内容.
private struct ToneAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
