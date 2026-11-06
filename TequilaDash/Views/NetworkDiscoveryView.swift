//
//  NetworkDiscoveryView.swift
//  TequilaDash
//
//  网络发现（mDNS）二级页 —— 入口：Cellular 隧道支持 → 网络发现.
//  SideStore「Discovery」完整移植：可浏览域（含域二级页）+ mDNS 服务列表 +
//  直连端点观测 + 导航栏蜂窝支持开关（SideStore 同位）+ 最近隧道事件快照.
//

import SwiftUI

struct NetworkDiscoveryView: View {
    @StateObject private var discovery = BonjourNetworkDiscovery()

    /// 与「Cellular 隧道支持」总开关同键 —— SideStore Discovery 右上角蜂窝按钮同位.
    @AppStorage(CellularTunnelManager.enabledKey) private var cellularEnabled = false

    @State private var probing = false
    @State private var probeResult = ""
    @State private var recentEvents: [String] = []

    private var directText: String {
        RemotePairingPort.freshDirectIPCandidate ?? "未打戳（等待正向事件）"
    }

    var body: some View {
        List {
            Section {
                statusRow("解析端口", RemotePairingPort.summary)
                statusRow("直连端点", directText)
                statusRow("建连 IP", LocalDevVPN.connectIP)
                statusRow("隧道缓存", TunnelGate.isReady ? "就绪" : "未就绪")
                Button {
                    runProbe()
                } label: {
                    if probing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("解析中…")
                        }
                    } else {
                        Text("解析并探测直连")
                    }
                }
                .disabled(probing)
                if !probeResult.isEmpty {
                    Text(probeResult)
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("通道状态")
            } footer: {
                Text("直连端点 = 回环 127.0.0.1 + Bonjour 发现的 RSD 端口（Gnoix 同款），事件驱动打戳，蜂窝下不依赖 LocalDevVPN.")
            }

            domainSection

            Section {
                if discovery.services.isEmpty {
                    Text(discovery.isBrowsing
                         ? "正在浏览…（首次发现最多数秒）"
                         : "未发现服务.检查本地网络权限，或让设备与本机同网.")
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(discovery.services) { s in
                        Self.serviceRow(s)
                    }
                }
                if let err = discovery.lastErrorText {
                    Text(err)
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("mDNS 服务")
            } footer: {
                Text("实时浏览 _remotepairing / _remoted / _remotepairing-pairable-host 三类服务（SideStore Network Discovery 同款）.在 LiveContainer 内宿主已声明 _remotepairing._tcp，其余类型可能浏览失败，不影响使用.")
            }

            Section {
                if recentEvents.isEmpty {
                    Text("暂无隧道事件.做一次隧道操作后回来点「刷新」.")
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(recentEvents.enumerated()), id: \.offset) { pair in
                        Text(pair.element)
                            .font(AppFont.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Button("刷新") {
                    recentEvents = TunnelDiagnostics.recentEvents()
                }
            } header: {
                Text("最近隧道事件")
            } footer: {
                Text("与「运行日志 / SSH tunnellog」同一份隧道诊断的内存快照（新在上，最多 12 条）.蜂窝下无法 SSH 时，用这里看隧道失败原因.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("网络发现（mDNS）")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    cellularEnabled.toggle()
                    CellularLogStore.shared.log(cellularEnabled
                                                ? "蜂窝刷新已开启（网络发现页）"
                                                : "蜂窝刷新已关闭（网络发现页）")
                    AppHaptics.success()
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(cellularEnabled ? AppTheme.accent : Color.secondary)
                }
                .accessibilityLabel("蜂窝支持开关")
            }
        }
        .onAppear {
            discovery.start()
            recentEvents = TunnelDiagnostics.recentEvents()
        }
        .onDisappear { discovery.stop() }
    }

    /// SideStore Discovery「Browsable Domains」同款：可浏览域 + 域二级页.
    private var domainSection: some View {
        Section {
            if discovery.domains.isEmpty {
                Text(discovery.isBrowsing ? "正在浏览域…" : "未发现可浏览域.")
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(discovery.domains, id: \.self) { domain in
                    NavigationLink {
                        NetworkDomainDetailView(discovery: discovery, domain: domain)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                                .foregroundStyle(AppTheme.accent)
                            Text(domain)
                        }
                    }
                }
            }
        } header: {
            Text("可浏览域")
        } footer: {
            Text("SideStore Discovery 同款：设备可注册的 Bonjour 域.点进去看该域下发现的服务.")
        }
    }

    fileprivate static func serviceRow(_ s: BonjourNetworkDiscovery.DiscoveredService) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.name)
                Text(s.typeLabel)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(s.endpointText)
                .font(AppFont.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .font(AppFont.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func runProbe() {
        probing = true
        probeResult = ""
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let port = RemotePairingPort.resolveNow(timeout: 5)
                let source = RemotePairingPort.lastSourceDescription
                let ok = RemotePairingPort.probeDirectEndpoint(timeout: 2)
                return (port, source, ok)
            }.value
            probing = false
            recentEvents = TunnelDiagnostics.recentEvents()
            let (port, source, ok) = result
            if ok {
                probeResult = "直连探测通过：127.0.0.1:\(port),可直接建隧道."
            } else if source == "Bonjour" {
                probeResult = "已发现配对服务（端口 \(port)）,但直连探测未通过.可重试一次."
            } else {
                probeResult = "未发现配对服务（回落端口 \(port)）.请确认设备与本机同网后重试."
            }
        }
    }
}

/// 域二级页：该域下发现的服务（SideStore 点「local」进来的页面）.
private struct NetworkDomainDetailView: View {
    @ObservedObject var discovery: BonjourNetworkDiscovery
    let domain: String

    private var rows: [BonjourNetworkDiscovery.DiscoveredService] {
        discovery.services.filter { $0.domain == domain }
    }

    var body: some View {
        List {
            if rows.isEmpty {
                Text(discovery.isBrowsing ? "正在浏览该域…" : "该域下暂未发现服务.")
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { s in
                    NetworkDiscoveryView.serviceRow(s)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(domain)
        .navigationBarTitleDisplayMode(.inline)
    }
}
