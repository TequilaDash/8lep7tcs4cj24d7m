//
//  CellularGlitchModalView.swift
//  TequilaDash
//
//  v0.3.760：蜂窝卡点弹窗（Gnoix CellularGlitchModalView 同职责，本仓卡片风格）.
//

import SwiftUI

/// 蜂窝卡点弹窗：等待断网 → 趁隙注入 → 结果，三段式卡片流.
/// 由 RootView 的 .sheet(item:) 挂载（CellularGlitchCoordinator.modalRequest）.
struct CellularGlitchModalView: View {
    @ObservedObject private var coordinator = CellularGlitchCoordinator.shared
    let request: CellularGlitchCoordinator.ModalRequest

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    switch coordinator.phase {
                    case .waitingDisconnect(let reason):
                        waitingCard(reason: reason)
                    case .injecting(let label):
                        injectingCard(label: label)
                    case .success:
                        successCard
                    case .failed(let message):
                        failedCard(message: message)
                    case .idle:
                        // 弹窗出现前的一瞬（modalRequest 刚置上）或已取消 —— 空态防闪烁.
                        AppLoadingRow(title: "准备中…", level: .block)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .navigationTitle(request.label)
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - 等待断网

    private func waitingCard(reason: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AppTheme.pending)
                .frame(width: 64, height: 64)
                .background(AppTheme.pending.opacity(0.12), in: Circle())
            Text("请关闭「蜂窝网络」")
                .font(AppFont.bodyEmphasis)
            Text("检测到当前为蜂窝网络，本地配对服务休眠中.关闭蜂窝会触发系统路由重置，趁隙自动完成\(request.label).")
                .font(AppFont.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("从屏幕右上角下拉打开「控制中心」")
                } icon: {
                    Image(systemName: "1.circle")
                }
                Label {
                    Text("轻点关闭「蜂窝网络」")
                } icon: {
                    Image(systemName: "2.circle")
                }
            }
            .font(AppFont.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(AppTheme.surfaceCard, in: RoundedRectangle(cornerRadius: 12))
            Text(reason)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Button {
                coordinator.cancel()
            } label: {
                Text("取消")
                    .font(AppFont.bodyEmphasis)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 趁隙执行

    private func injectingCard(label: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 64, height: 64)
                .background(AppTheme.accent.opacity(0.12), in: Circle())
            Text("已感知断网，正在趁隙\(label)")
                .font(AppFont.bodyEmphasis)
            Text("蜂窝断开成功触发了 iOS 底层网络路由重置，本地配对回环已激活.")
                .font(AppFont.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
                .controlSize(.regular)
            Text("请勿离开本页面.")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 成功

    private var successCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AppTheme.success)
                .frame(width: 64, height: 64)
                .background(AppTheme.success.opacity(0.12), in: Circle())
            Text("\(request.label)已成功.")
                .font(AppFont.bodyEmphasis)
            Text("本次免电脑操作全部完成.请在「控制中心」重新开启「蜂窝网络」恢复上网.")
                .font(AppFont.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                coordinator.dismiss()
            } label: {
                Text("完成")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TintedButtonStyle(tint: AppTheme.accent))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 未成功

    private func failedCard(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AppTheme.danger)
                .frame(width: 64, height: 64)
                .background(AppTheme.danger.opacity(0.12), in: Circle())
            Text("\(request.label)未成功.")
                .font(AppFont.bodyEmphasis)
            Text(message)
                .font(AppFont.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("如被蜂窝流程打断，可重试；或改在 Wi-Fi 下操作.")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Button {
                coordinator.dismiss()
            } label: {
                Text("完成")
                    .font(AppFont.bodyEmphasis)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }
}
