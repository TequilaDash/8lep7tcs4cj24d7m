//
//  BonjourNetworkDiscovery.swift
//  TequilaDash
//
//  网络发现（mDNS）—— SideStore「Network Discovery」(BonjourDiscoveryManager) 的本仓移植.
//  裁剪到本项目实际消费的范围：设备广播的 RemotePairing / RSD / Pairable-Host 三型服务.
//
//  线程模型（与 RemotePairingPort.BonjourPortWorker 同款）：浏览器 schedule 在主 RunLoop，
//  delegate 回调天然主线程；本类非隔离，@Published 仅在主线程回调里更新.
//  浏览结果与 RemotePairingPort 的后台解析相互独立 —— 本页是可视化观测面，
//  直连通道消费的是 RemotePairingPort 自己的解析缓存.
//

import Foundation

final class BonjourNetworkDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {

    struct DiscoveredService: Identifiable, Equatable {
        let id: String
        var name: String
        var type: String
        var ip: String?
        var port: Int?
        var state: State

        enum State: Equatable { case resolving, ready, failed }

        var typeLabel: String { Self.typeLabels[type] ?? type }

        var endpointText: String {
            if state == .resolving { return "解析中…" }
            if let i = ip, let p = port { return "\(i):\(p)" }
            if let p = port { return "端口 \(p)" }
            return state == .failed ? "解析失败" : "未解析"
        }

        static let typeLabels: [String: String] = [
            "_remotepairing._tcp.": "Remote Pairing（经典远程配对）",
            "_remoted._tcp.": "Remote Service Discovery（RSD，iOS 17+）",
            "_remotepairing-pairable-host._tcp.": "Pairable Host（无线配对广播）"
        ]
    }

    /// 与 Info.plist NSBonjourServices 声明一致的三型（加新类型须同步 Info.plist）.
    static let serviceTypes = ["_remotepairing._tcp.", "_remoted._tcp.", "_remotepairing-pairable-host._tcp."]

    @Published private(set) var services: [DiscoveredService] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var lastErrorText: String?

    private var browsers: [NetServiceBrowser] = []
    private var pending: [NetService] = []

    func start() {
        guard !isBrowsing else { return }
        isBrowsing = true
        lastErrorText = nil
        services = []
        pending = []
        for type in Self.serviceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.schedule(in: .main, forMode: .common)
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.stop() }
        browsers = []
        pending.forEach { $0.stop() }
        pending = []
        isBrowsing = false
    }

    private func serviceID(_ service: NetService) -> String {
        (service.name ?? "") + "/" + (service.type ?? "unknown")
    }

    // MARK: - NetServiceBrowserDelegate（主 RunLoop 回调）

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let id = serviceID(service)
        pending.append(service)
        service.delegate = self
        service.resolve(withTimeout: 6)
        guard !services.contains(where: { $0.id == id }) else { return }
        services.append(DiscoveredService(id: id, name: service.name ?? "（未命名）",
                                          type: service.type ?? "unknown",
                                          ip: nil, port: nil, state: .resolving))
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0.id == serviceID(service) }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        let code = errorDict["NSNetServicesErrorCode"]?.intValue ?? -1
        // LC #1519：LiveContainer 宿主按自己的 NSBonjourServices 白名单校验服务类型，
        // guest 声明不合并；缺类型时该浏览器报错且权限弹窗不弹（_remotepairing._tcp
        // 宿主已声明，可用）。列表里有服务时不打扰用户；回环建连不需要本地网络权限.
        if services.isEmpty {
            lastErrorText = "浏览失败（Bonjour code \(code)）.在 LiveContainer 内多为宿主未声明该服务类型，不影响回环建连."
        }
        isBrowsing = false
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        // 主动 stop 的正常收尾；状态由 stop() 管理，这里不动.
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard (1...65535).contains(sender.port) else { return }
        let id = serviceID(sender)
        let ip = RemotePairingPort.ipv4Address(of: sender)
        services = services.map { row in
            guard row.id == id else { return row }
            return DiscoveredService(id: row.id, name: row.name, type: row.type,
                                     ip: ip, port: sender.port,
                                     state: ip == nil ? .failed : .ready)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let id = serviceID(sender)
        services = services.map { row in
            guard row.id == id else { return row }
            return DiscoveredService(id: row.id, name: row.name, type: row.type,
                                     ip: nil, port: nil, state: .failed)
        }
    }
}
