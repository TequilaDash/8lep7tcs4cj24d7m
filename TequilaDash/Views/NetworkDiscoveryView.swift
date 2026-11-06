//
//  NetworkDiscoveryView.swift
//  TequilaDash
//
//  网络发现（mDNS）二级页 —— 入口：Cellular 隧道支持 → 网络发现.
//  SideStore「Network Discovery」移植：实时浏览设备广播的 Bonjour 服务，
//  并展示直连端点（Gnoix 对齐）：回环 127.0.0.1 + Bonjour 发现的 RSD 端口.
//

import SwiftUI

struct NetworkDiscoveryView: View {
    @StateObject private var discovery = BonjourNetworkDiscovery()

    @State private var probing = false
    @State private var probeResult = ""

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
                Text("实时浏览 _remotepairing / _remoted / _remotepairing-pairable-host 三类服务（SideStore Network Discovery 同款）.在 LiveContainer 内宿主已声明 _remotepairing._tcp，其余类型可能浏览失败，不影响使用.")
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
                let source = RemotePairingPort.lastSourceDescription
                let ok = RemotePairingPort.probeDirectEndpoint(timeout: 2)
                return (port, source, ok)
            }.value
            probing = false
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
