//
//  NetworkDiscoveryView.swift
//  TequilaDash
//
//  网络发现（mDNS）二级页 —— 入口：Cellular 隧道支持 → 网络发现.
//  SideStore「Discovery」完整移植：可浏览域（含域二级页）+ mDNS 服务列表 +
//  直连端点观测 + 导航栏蜂窝支持开关（SideStore 同位）+ 右上角隧道事件日志.
//

import SwiftUI

struct NetworkDiscoveryView: View {
    @StateObject private var discovery = BonjourNetworkDiscovery()

    /// 与「Cellular 隧道支持」总开关同键 —— SideStore Discovery 右上角蜂窝按钮同位.
    @AppStorage(CellularTunnelManager.enabledKey) private var cellularEnabled = false

    @State private var probing = false
    @State private var probeResult = ""
    @State private var showEvents = false
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
                Text("RSD 端口由 Bonjour 事件驱动解析.建连主地址为 utun 对端；蜂窝下开启蜂窝支持，由 LocalDevVPN 在断网窗口兜底建链.")
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    recentEvents = TunnelDiagnostics.recentEvents()
                    showEvents = true
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .accessibilityLabel("隧道事件日志")
            }
        }
        .onAppear {
            discovery.start()
        }
        .onDisappear { discovery.stop() }
        .sheet(isPresented: $showEvents) {
            NavigationStack {
                List {
                    if recentEvents.isEmpty {
                        Text("暂无隧道事件.做一次隧道操作后点「刷新」.")
                            .font(AppFont.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(recentEvents.enumerated()), id: \.offset) { pair in
                            Text(pair.element)
                                .font(AppFont.footnote.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("隧道事件")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("刷新") {
                            recentEvents = TunnelDiagnostics.recentEvents()
                        }
                    }
                }
            }
        }
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
            let (port, source, ok) = result
            if ok {
                probeResult = "直连探测通过：127.0.0.1:\(port)（回环 TCP 可达）."
            } else if source == "Bonjour" {
                probeResult = "已发现配对服务（端口 \(port)）,但直连探测未通过.可重试一次."
            } else {
                probeResult = "未发现配对服务（回落端口 \(port)）.请确认设备与本机同网后重试."
            }
        }
    }
}

/// 域二级页：该域下枚举的服务类型 + 浏览到的实例
/// （SideStore 点「local」进来的页面：先类型列表，再逐型实例）.
private struct NetworkDomainDetailView: View {
    @ObservedObject var discovery: BonjourNetworkDiscovery
    let domain: String

    /// 实例的 domain 带尾点（NetService 原样，如 "local."），域行不带 —— 双向归一后再比.
    private var rows: [BonjourNetworkDiscovery.DiscoveredService] {
        let d = domain.hasSuffix(".") ? domain : domain + "."
        return discovery.services.filter { ($0.domain.hasSuffix(".") ? $0.domain : $0.domain + ".") == d }
    }

    var body: some View {
        List {
            Section {
                if discovery.isEnumeratingTypes && discovery.serviceTypes.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在枚举服务类型…")
                    }
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                } else if discovery.serviceTypes.isEmpty {
                    Text("该域下未枚举到服务类型.")
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(discovery.serviceTypes) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.displayName)
                            Text(t.rawType)
                                .font(AppFont.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("服务类型")
            } footer: {
                Text("SideStore 同款：_services._dns-sd._udp 枚举 + 常见类型兜底探测，10 秒收敛.")
            }

            Section {
                if rows.isEmpty {
                    Text(discovery.isBrowsing ? "正在浏览该域…" : "该域下暂未发现服务实例.")
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { s in
                        NetworkDiscoveryView.serviceRow(s)
                    }
                }
            } header: {
                Text("隧道服务实例")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(domain)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            discovery.discoverServiceTypes(in: domain)
        }
        .onDisappear {
            discovery.stopTypeSearch()
        }
    }
}
