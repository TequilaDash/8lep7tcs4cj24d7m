//
//  BonjourNetworkDiscovery.swift
//  TequilaDash
//
//  网络发现（mDNS）—— SideStore「Network Discovery」三层模型的移植：
//  ① 域枚举（searchForRegistrationDomains + local 写死保底，同上游 :113-129）；
//  ② 服务类型枚举（_services._dns-sd._udp. meta-query + commonServiceTypesToBrowse
//     68 型 NWBrowser 兜底探测，同上游 discoverServiceTypes/startFallbackSearches）；
//  ③ 服务实例浏览（工程消费的三型：RemotePairing / RSD / Pairable-Host）.
//
//  对齐上游：SideStore/Core/Bonjour/BonjourDiscoveryManager.swift（develop, 896 行）
//  与 BonjourDiscoveryTypes.swift（68 型清单与友好名映射逐项照搬）。NSBonjourServices
//  声明与上游 AltStore/Info.plist 的 69 项逐项一致（68 型 + _services._dns-sd._udp），
//  缺一型 iOS 14+ 本地网络权限就会拦掉对应浏览.
//
//  线程模型（与 RemotePairingPort.BonjourPortWorker 同款）：NetServiceBrowser schedule
//  在主 RunLoop，delegate 回调天然主线程；NWBrowser 兜底探测跑在全局队列，
//  结果回主线程后并入 @Published。本类非隔离.
//

import Foundation
import Network

final class BonjourNetworkDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {

    struct DiscoveredService: Identifiable, Equatable {
        let id: String
        var name: String
        var type: String
        var domain: String
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

    /// SideStore ServiceTypeInfo 同款：原始类型 + 友好名（枚举层展示用）.
    struct ServiceTypeInfo: Identifiable, Equatable {
        var id: String { rawType }
        let rawType: String
        let friendlyName: String?

        var displayName: String { friendlyName ?? rawType }
    }

    /// 与 Info.plist NSBonjourServices 声明一致的工程消费三型（实例层）.
    static let serviceTypes = ["_remotepairing._tcp.", "_remoted._tcp.", "_remotepairing-pairable-host._tcp."]
    /// SideStore BonjourDiscoveryTypes.swift 逐项照搬（68 型）：meta-query 常不响应，
    /// 兜底用 NWBrowser 直接探常见类型，探到即视为该域下存在的服务类型.
    static let commonServiceTypesToBrowse: [String] = [
        "_altserver._tcp.",
        "_remotepairing-pairable-host._tcp.",
        "_remotepairing-manual-pairing._tcp.",
        "_airplay._tcp.",
        "_raop._tcp.",
        "_sftp-ssh._tcp.",
        "_sleep-proxy._udp.",
        "_ssh._tcp.",
        "_apple-mobdev2._tcp.",
        "_asquic._udp.",
        "_companion-link._tcp.",
        "_meshcop._udp.",
        "_remotepairing._tcp.",
        "_rp-tunnel._tcp.",
        "_srpl-tls._tcp.",
        "_trel._udp.",
        "_http._tcp.",
        "_https._tcp.",
        "_smb._tcp.",
        "_afpovertcp._tcp.",
        "_printer._tcp.",
        "_ipp._tcp.",
        "_ipps._tcp.",
        "_scanner._tcp.",
        "_daap._tcp.",
        "_dpap._tcp.",
        "_airport._tcp.",
        "_homekit._tcp.",
        "_hap._tcp.",
        "_touch-able._tcp.",
        "_spotify-connect._tcp.",
        "_googlecast._tcp.",
        "_device-info._tcp.",
        "_workstation._tcp.",
        "_rfb._tcp.",
        "_net-assistant._udp.",
        "_rdlink._tcp.",
        "_stikpairprobe._tcp.",
        "_webdav._tcp.",
        "_webdavs._tcp.",
        "_ftp._tcp.",
        "_telnet._tcp.",
        "_coap._udp.",
        "_coaps._udp.",
        "_mqtt._tcp.",
        "_adb._tcp.",
        "_airdrop._tcp.",
        "_sidecar._tcp.",
        "_sonos._tcp.",
        "_plex._tcp.",
        "_amzn-alexa._tcp.",
        "_home-assistant._tcp.",
        "_rtsp._tcp.",
        "_sip._udp.",
        "_sip._tcp.",
        "_h323._tcp.",
        "_h323._udp.",
        "_ws._tcp.",
        "_wss._tcp.",
        "_remoted._tcp.",
        "_coredevice._tcp.",
        "_appletv-v2._tcp.",
        "_apple-mobdev._tcp.",
        "_jitstreamer._tcp.",
        "_matter._tcp.",
        "_matterc._udp.",
        "_airprint._tcp.",
        "_vnc._tcp.",
    ]

    /// SideStore 同款友好名映射（68 键逐项照搬）.
    static let commonKnownServiceTypes: [String: String] = [
        "_airplay._tcp.": "Protocol for streaming of audio/video content",
        "_raop._tcp.": "Remote Audio Output Protocol (AirTunes)",
        "_sftp-ssh._tcp.": "Secure File Transfer Protocol over SSH",
        "_sleep-proxy._udp.": "Sleep Proxy Server",
        "_ssh._tcp.": "SSH Remote Login Protocol",
        "_http._tcp.": "World Wide Web (HTTP)",
        "_https._tcp.": "World Wide Web (HTTPS)",
        "_smb._tcp.": "SMB File Sharing",
        "_afpovertcp._tcp.": "Apple Filing Protocol (AFP)",
        "_printer._tcp.": "Printer",
        "_ipp._tcp.": "Internet Printing Protocol",
        "_scanner._tcp.": "Scanner",
        "_ftp._tcp.": "File Transfer Protocol",
        "_nfs._tcp.": "Network File System",
        "_daap._tcp.": "Digital Audio Access Protocol (iTunes)",
        "_dpap._tcp.": "Digital Photo Access Protocol (iPhoto)",
        "_airport._tcp.": "AirPort Base Station",
        "_homekit._tcp.": "HomeKit Accessory",
        "_hap._tcp.": "HomeKit Accessory Protocol",
        "_companion-link._tcp.": "Companion Link (Apple Watch)",
        "_apple-mobdev2._tcp.": "Apple Mobile Device v2",
        "_remotepairing._tcp.": "Remote Pairing",
        "_remotepairing-pairable-host._tcp.": "Remote Pairing (Pairable Host)",
        "_remotepairing-manual-pairing._tcp.": "Remote Pairing (Manual / Apple TV)",
        "_rdlink._tcp.": "Remote Debug Link",
        "_net-assistant._udp.": "Apple Remote Desktop",
        "_rfb._tcp.": "Remote Frame Buffer (VNC)",
        "_spotify-connect._tcp.": "Spotify Connect",
        "_googlecast._tcp.": "Google Cast (Chromecast)",
        "_meshcop._udp.": "Thread Mesh Commissioning",
        "_asquic._udp.": "Apple QUIC Service",
        "_rp-tunnel._tcp.": "Remote Pairing Tunnel",
        "_altserver._tcp.": "AltServer",
        "_workstation._tcp.": "Workstation",
        "_device-info._tcp.": "Device Info",
        "_touch-able._tcp.": "Remote App (Apple TV Remote)",
        "_srpl-tls._tcp.": "Spatial Remote Playback Link TLS",
        "_trel._udp.": "Thread Radio Encapsulation Link",
        "_ipps._tcp.": "Secure Internet Printing Protocol",
        "_webdav._tcp.": "Web Distributed Authoring and Versioning (WebDAV)",
        "_webdavs._tcp.": "Secure WebDAV",
        "_telnet._tcp.": "Telnet Remote Login Protocol",
        "_coap._udp.": "Constrained Application Protocol (CoAP)",
        "_coaps._udp.": "Secure CoAP",
        "_mqtt._tcp.": "Message Queuing Telemetry Transport (MQTT)",
        "_adb._tcp.": "Android Debug Bridge (ADB)",
        "_airdrop._tcp.": "Apple AirDrop",
        "_sidecar._tcp.": "Apple Sidecar",
        "_sonos._tcp.": "Sonos Speaker System",
        "_plex._tcp.": "Plex Media Server",
        "_amzn-alexa._tcp.": "Amazon Alexa Service",
        "_home-assistant._tcp.": "Home Assistant Smart Home",
        "_rtsp._tcp.": "Real Time Streaming Protocol (RTSP)",
        "_sip._udp.": "Session Initiation Protocol (SIP over UDP)",
        "_sip._tcp.": "Session Initiation Protocol (SIP over TCP)",
        "_h323._tcp.": "H.323 Video Conferencing (TCP)",
        "_h323._udp.": "H.323 Video Conferencing (UDP)",
        "_ws._tcp.": "WebSocket Connection",
        "_wss._tcp.": "Secure WebSocket Connection",
        "_remoted._tcp.": "CoreDevice Remote Service Discovery (RSD)",
        "_coredevice._tcp.": "Apple CoreDevice Debug Service",
        "_appletv-v2._tcp.": "Apple TV Companion Remote Protocol",
        "_apple-mobdev._tcp.": "Apple Mobile Device v1 (Wi-Fi Sync)",
        "_jitstreamer._tcp.": "JitStreamer Service",
        "_matter._tcp.": "Matter Smart Home Device",
        "_matterc._udp.": "Matter Device Commissioning",
        "_airprint._tcp.": "Apple AirPrint",
        "_vnc._tcp.": "VNC Remote Desktop",
    ]

    static func friendlyName(for rawType: String) -> String? {
        commonKnownServiceTypes[rawType]
    }

    @Published private(set) var services: [DiscoveredService] = []
    /// 当前域下枚举到的服务类型（域二级页展示，SideStore「服务类型」列表同款）.
    @Published private(set) var serviceTypes: [ServiceTypeInfo] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var isEnumeratingTypes = false
    @Published private(set) var lastErrorText: String?

    /// 浏览到的可注册域（SideStore Discovery「Browsable Domains」同款，如 "local"）.
    @Published private(set) var domains: [String] = []

    private var browsers: [NetServiceBrowser] = []
    private var domainBrowser: NetServiceBrowser?
    private var typeBrowser: NetServiceBrowser?
    private var fallbackTypeBrowsers: [NWBrowser] = []
    private var pending: [NetService] = []
    private var typeEnumTimeout: DispatchWorkItem?

    func start() {
        guard !isBrowsing else { return }
        isBrowsing = true
        lastErrorText = nil
        services = []
        domains = []
        pending = []
        for type in Self.serviceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.schedule(in: .main, forMode: .common)
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
        let domainBrowser = NetServiceBrowser()
        domainBrowser.delegate = self
        domainBrowser.schedule(in: .main, forMode: .common)
        domainBrowser.searchForRegistrationDomains()
        self.domainBrowser = domainBrowser
        // SideStore 同款（BonjourDiscoveryManager.discoverDomains 启动即写死 local）：
        // 注册域枚举在 iOS 上几乎不回结果，保底 local 让可浏览域列表不再空白.
        if !domains.contains("local") {
            domains.append("local")
        }
    }

    func stop() {
        browsers.forEach { $0.stop() }
        browsers = []
        domainBrowser?.stop()
        domainBrowser = nil
        stopTypeSearch()
        pending.forEach { $0.stop() }
        pending = []
        isBrowsing = false
    }

    // MARK: - 服务类型枚举（SideStore 三层模型的第②层）

    /// SideStore discoverServiceTypes 同款：_services._dns-sd._udp. meta-query 优先，
    /// 68 型 NWBrowser 兜底探测并行挂上，10 秒超时统一收摊.
    func discoverServiceTypes(in domain: String) {
        let domainWithDot = domain.hasSuffix(".") ? domain : domain + "."
        stopTypeSearch()
        serviceTypes = []
        isEnumeratingTypes = true
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.schedule(in: .main, forMode: .common)
        browser.searchForServices(ofType: "_services._dns-sd._udp.", inDomain: domainWithDot)
        typeBrowser = browser
        startFallbackSearches(types: Self.commonServiceTypesToBrowse, in: domainWithDot)
        let timeout = DispatchWorkItem { [weak self] in self?.stopTypeSearch() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        typeEnumTimeout = timeout
    }

    /// SideStore startFallbackSearches 同款：每型一个 NWBrowser 直接 browse，
    /// 有结果即记类型；浏览器挂入 fallbackTypeBrowsers 统一停.
    private func startFallbackSearches(types: [String], in domain: String) {
        for t in types {
            let typeWithoutDot = t.hasSuffix(".") ? String(t.dropLast()) : t
            let parameters = typeWithoutDot.contains("_tcp") ? NWParameters.tcp : NWParameters.udp
            let descriptor = NWBrowser.Descriptor.bonjour(type: typeWithoutDot, domain: domain)
            let browser = NWBrowser(for: descriptor, using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard !results.isEmpty else { return }
                DispatchQueue.main.async {
                    self?.insertServiceType(rawType: t)
                }
            }
            browser.stateUpdateHandler = { state in
                // 探测失败（含 LC 宿主白名单拦截）静默：枚举是观测面，不打扰用户.
                _ = state
            }
            browser.start(queue: DispatchQueue.global(qos: .userInitiated))
            fallbackTypeBrowsers.append(browser)
        }
    }

    func stopTypeSearch() {
        typeBrowser?.stop()
        typeBrowser = nil
        for b in fallbackTypeBrowsers { b.cancel() }
        fallbackTypeBrowsers.removeAll()
        typeEnumTimeout?.cancel()
        typeEnumTimeout = nil
        if isEnumeratingTypes { isEnumeratingTypes = false }
    }

    /// 规范化并去重插入类型：补尾点，只收 ._tcp. / ._udp. 结尾的真实类型，
    /// 过滤 meta 自身（_services._dns-sd）与残段.
    private func insertServiceType(rawType: String) {
        var t = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !t.hasSuffix(".") { t += "." }
        guard t.hasSuffix("._tcp.") || t.hasSuffix("._udp.") else { return }
        let info = ServiceTypeInfo(rawType: t, friendlyName: Self.friendlyName(for: t))
        if !serviceTypes.contains(info) {
            serviceTypes.append(info)
        }
    }

    private func serviceID(_ service: NetService) -> String {
        (service.name ?? "") + "/" + (service.type ?? "unknown")
    }

    // MARK: - NetServiceBrowserDelegate（主 RunLoop 回调）

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        if browser === typeBrowser {
            // meta-query：PTR 目标（如 "_airplay._tcp.local."）被 NetService 解析为
            // name=类型主体 + type=协议段；两种拆法都归一成 "_airplay._tcp."（SideStore :553 同款拼法）.
            let name = (service.name ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let type = service.type ?? ""
            var rawType = name
            if !name.contains(".") && type.hasPrefix(".") && !type.contains("_dns-sd") {
                rawType = name + type
            }
            insertServiceType(rawType: rawType)
            return
        }
        lastErrorText = nil
        let id = serviceID(service)
        pending.append(service)
        service.delegate = self
        service.resolve(withTimeout: 6)
        guard !services.contains(where: { $0.id == id }) else { return }
        services.append(DiscoveredService(id: id, name: service.name ?? "（未命名）",
                                          type: service.type ?? "unknown",
                                          domain: service.domain ?? "local.",
                                          ip: nil, port: nil, state: .resolving))
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0.id == serviceID(service) }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFindDomain domain: String, moreComing: Bool) {
        let name = domain.hasSuffix(".") ? String(domain.dropLast()) : domain
        guard !name.isEmpty, !domains.contains(name) else { return }
        domains.append(name)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard browser !== domainBrowser, browser !== typeBrowser else { return }
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
        // 主动 stop 的正常收尾；状态由 stop()/stopTypeSearch() 管理，这里不动.
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard (1...65535).contains(sender.port) else { return }
        let id = serviceID(sender)
        let ip = RemotePairingPort.ipv4Address(of: sender)
        services = services.map { row in
            guard row.id == id else { return row }
            return DiscoveredService(id: row.id, name: row.name, type: row.type,
                                     domain: row.domain,
                                     ip: ip, port: sender.port,
                                     state: ip == nil ? .failed : .ready)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let id = serviceID(sender)
        services = services.map { row in
            guard row.id == id else { return row }
            return DiscoveredService(id: row.id, name: row.name, type: row.type,
                                     domain: row.domain,
                                     ip: nil, port: nil, state: .failed)
        }
    }
}
