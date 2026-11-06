//
//  NetworkDiscoveryView.swift
//  TequilaDash
//
//  网络发现（mDNS）—— 入口：Cellular 隧道支持 → 网络发现.
//  SideStore「Discovery」三层结构照搬：可浏览域 → 该域的服务类型 → 该类型的实例，
//  另加 mDNS 服务列表 + 直连端点观测 + 导航栏蜂窝支持开关（SideStore 同位）+ 隧道事件日志.
//  v0.3.774（用户图二反馈）：实例不再塞在域二级页里，改成像 SideStore 那样点类型进下一级.
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
            Text("SideStore Discovery 同款：设备可注册的 Bonjour 域.点进去看该域下的服务类型.")
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

/// 域二级页：只列该域下枚举到的服务类型（SideStore ServiceTypesView 同款两层结构）.
/// v0.3.774（用户图二）：原先塞在本页底部的「隧道服务实例」Section 不该出现在这里 ——
/// 实例属于类型那一层，改成点类型行进 NetworkTypeInstancesView.
private struct NetworkDomainDetailView: View {
    @ObservedObject var discovery: BonjourNetworkDiscovery
    let domain: String

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
                        NavigationLink {
                            NetworkTypeInstancesView(discovery: discovery, info: t, domain: domain)
                        } label: {
                            // 有友好名：主行友好名 + 副行原始类型；查不到（SideStore 的橙色问号
                            // 那类）主行直接显示原始串，不再被我方过滤器吞掉.
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.displayName)
                                if t.friendlyName != nil {
                                    Text(t.rawType)
                                        .font(AppFont.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("服务类型")
            } footer: {
                Text("SideStore 同款：_services._dns-sd._udp 枚举 + 常见类型兜底探测，两路探测都落定后自动停止.点类型看实例.")
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

/// 类型三级页：该类型下的实例（SideStore ServiceInstancesView 同款）.
/// meta-query 带回来的 PTR 全名（"_apple-mobdev2._tcp.local."）在浏览前由
/// BonjourNetworkDiscovery.browseComponents 归一化成真实类型 + 域，否则浏览直接失败.
private struct NetworkTypeInstancesView: View {
    @ObservedObject var discovery: BonjourNetworkDiscovery
    let info: BonjourNetworkDiscovery.ServiceTypeInfo
    let domain: String

    var body: some View {
        List {
            Section {
                if discovery.typeInstances.isEmpty {
                    Text(discovery.isBrowsingInstances ? "正在浏览该类型…" : "该类型下暂未发现实例.")
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(discovery.typeInstances) { s in
                        NetworkDiscoveryView.serviceRow(s)
                    }
                }
                if let err = discovery.instanceErrorText {
                    Text(err)
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("服务实例")
            } footer: {
                Text("原始类型 \(info.rawType).所在域 \(domain).")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(info.friendlyName ?? "服务实例")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            discovery.startInstanceBrowsing(rawType: info.rawType, domain: domain)
        }
        .onDisappear {
            discovery.stopInstanceBrowsing()
        }
    }
}
