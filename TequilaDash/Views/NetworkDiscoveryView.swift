//
//  NetworkDiscoveryView.swift
//  TequilaDash
//
//  网络发现（mDNS）二级页 —— 入口：Cellular 隧道支持 → 网络发现.
//  SideStore「Network Discovery」移植：实时浏览设备广播的 Bonjour 服务，
//  并展示设备直连通道（Gnoix 对齐）的数据源：设备自身 IP + RSD 端口.
//

import SwiftUI

struct NetworkDiscoveryView: View {
    @StateObject private var discovery = BonjourNetworkDiscovery()

    @State private var probing = false
    @State private var probeResult = ""

    private var directText: String {
        guard let ip = RemotePairingPort.discoveredIP else { return "未发现" }
        return ip + (RemotePairingPort.freshDirectIPCandidate != nil ? "（新鲜）" : "（过期）")
    }

    var body: some View {
        List {
            Section {
                statusRow("解析端口", RemotePairingPort.summary)
                statusRow("直连候选", directText)
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
                Text("设备直连通道从同一份 Bonjour 发现结果取设备自身 IP 与 RSD 端口，蜂窝下不依赖 LocalDevVPN.")
            }

            Section {
                if discovery.services.isEmpty {
                    Text(discovery.isBrowsing
                         ? "正在浏览…（首次发现最多数秒）"
                         : "未发现服务.检查本地网络权限，或让设备与本机同网.")
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(discovery.services) { s in
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
                }
                if let err = discovery.lastErrorText {
                    Text(err)
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("mDNS 服务")
            } footer: {
                Text("实时浏览 _remotepairing / _remoted / _remotepairing-pairable-host 三类服务（SideStore Network Discovery 同款）.本地网络权限关闭时列表为空.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("网络发现（mDNS）")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
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
                let ip = RemotePairingPort.discoveredIP
                let ok = RemotePairingPort.probeDirectEndpoint(timeout: 2)
                return (port, ip, ok)
            }.value
            probing = false
            let (port, ip, ok) = result
            switch (ip, ok) {
            case let (i?, true):
                probeResult = "直连探测通过：\\(i):\\(port)（90 秒内可直连建隧道）."
            case let (i?, false):
                probeResult = "已解析 \\(i):\\(port)，直连探测未通过（设备可能换了网络）."
            default:
                probeResult = "未发现设备 IP（端口 \\(port)）.请让设备与本机同网后重试."
            }
        }
    }
}
