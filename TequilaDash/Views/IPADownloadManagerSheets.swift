// 从 TequilaDash/Views/IPADownloadManagerView.swift 拆出（原文件 1307 行）：安装进度圆环与在线安装设置面板两个独立 View 体量过大，按职责拆到本文件；纯搬迁、零逻辑改动。

import SwiftUI

/// v0.3.388：行内**安装进度圆环**（44pt，与行首 48pt 图标等高，不动行高）。
///
/// · `fraction != nil` → 圆环 + 环内等宽百分比：12 点起画、圆头 3pt、主题青（`downloadAccent`）；
/// · `fraction == nil` → **不确定态**：一段持续旋转的弧，**不写百分比**
///   —— 这是「在线安装进了系统阶段、App 量不到进度」时唯一诚实的画法。
struct InstallProgressRing: View {

    let fraction: Double?

    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(downloadAccent.opacity(0.18), lineWidth: 3)

            if let fraction {
                let clamped = min(1, max(0, fraction))
                Circle()
                    .trim(from: 0, to: max(0.02, clamped))
                    .stroke(downloadAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((clamped * 100).rounded()))%")
                    .font(AppFont.numberSmall)
                    .foregroundStyle(downloadAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(downloadAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            }
        }
        .frame(width: 44, height: 44)
        .onAppear { spinning = true }
    }
}

/// v0.3.383：下载管理右上角齿轮弹出的**极简**设置 —— 只放一行 GitHub Token。
///
/// 用途：把在线安装的**清单**托管到私有 gist（`raw_url` 是可信 HTTPS），
/// 比公共临时托管可靠。token 存 **Keychain**（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，
/// 不做 iCloud 同步、不落 UserDefaults），日志最多只记前 8 位。
/// 注意：**这只换了一个更可靠的托管通道，不代表「在线安装装不上」被修好了**。
struct OnlineInstallSettingsSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("GitHub Token", text: $token)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.footnote)
                } footer: {
                    Text("仅用于托管安装清单.")
                        .font(AppFont.caption)
                }

                Section {
                    Button("保存") {
                        OnlineInstallConfig.setGitHubToken(token)
                        token = OnlineInstallConfig.githubToken ?? ""
                        ToastCenter.shared.show("已保存")
                    }
                    Button("清除", role: .destructive) {
                        OnlineInstallConfig.clearGitHubToken()
                        token = ""
                        ToastCenter.shared.show("已清除")
                    }
                }
            }
            .navigationTitle("在线安装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .toastHost()
        }
        .presentationDetents([.medium])
        .onAppear { token = OnlineInstallConfig.githubToken ?? "" }
    }
}
