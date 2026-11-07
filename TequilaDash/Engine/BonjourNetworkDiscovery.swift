//
//  BonjourNetworkDiscovery.swift
//  TequilaDash
//
//  ② 服务类型枚举（_services._dns-sd._udp. meta-query + commonServiceTypesToBrowse
//  ③ 服务实例浏览（工程消费的三型：RemotePairing / RSD / Pairable-Host）.
//
//  缺一型 iOS 14+ 本地网络权限就会拦掉对应浏览.
//
//  线程模型（与 RemotePairingPort.BonjourPortWorker 同款）：NetServiceBrowser schedule
//  在主 RunLoop，delegate 回调天然主线程；NWBrowser 兜底探测跑在全局队列，
//  结果回主线程后并入 @Published.本类 @unchecked Sendable：@Published 只在主线程写，
//  NWBrowser 的 @Sendable 闭包只持弱引用回主线程消费.
//

import Foundation
import Network

final class BonjourNetworkDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {

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

    struct ServiceTypeInfo: Identifiable, Equatable {
        var id: String { rawType }
        let rawType: String
        let friendlyName: String?

        var displayName: String { friendlyName ?? rawType }
    }

    /// 与 Info.plist NSBonjourServices 声明一致的工程消费三型（实例层）.
    static let serviceTypes = ["_remotepairing._tcp.", "_remoted._tcp.", "_remotepairing-pairable-host._tcp."]
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
    @Published private(set) var serviceTypes: [ServiceTypeInfo] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var isEnumeratingTypes = false
    @Published private(set) var lastErrorText: String?

    @Published private(set) var domains: [String] = []

    @Published private(set) var typeInstances: [DiscoveredService] = []
    @Published private(set) var isBrowsingInstances = false
    @Published private(set) var instanceErrorText: String?

    private var browsers: [NetServiceBrowser] = []
    private var domainBrowser: NetServiceBrowser?
    private var typeBrowser: NetServiceBrowser?
    private var instanceNWBrowser: NWBrowser?
    /// NWBrowser 只给名字；NSNetService 解析出的 ip:port 记在这，结果集重放时不丢.
    private var resolvedInstanceEndpoints: [String: (ip: String?, port: Int?)] = [:]
    private var fallbackTypeBrowsers: [NWBrowser] = []
    private var pending: [NetService] = []
    /// 事件收摊记账：原先前这里是 `asyncAfter(.now()+10)` 统一定时收摊（用户令：不许自己加秒数），
    /// 现在两路都落定才停，全程零定时器.
    private var metaQuerySettled = false
    private var fallbackTypesTotal = 0
    private var settledFallbackBrowsers: Set<ObjectIdentifier> = []
    /// 故闭包只捕获 Int 令牌，回表取浏览器.
    private var fallbackBrowserBox: [Int: NWBrowser] = [:]

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
        // 注册域枚举在 iOS 上几乎不回结果，保底 local 让可浏览域列表不再空白.
        if !domains.contains("local") {
            domains.append("local")
        }
    }

    func stop() {
        stopInstanceBrowsing()
        browsers.forEach { $0.stop() }
        browsers = []
        domainBrowser?.stop()
        domainBrowser = nil
        stopTypeSearch()
        pending.forEach { $0.stop() }
        pending = []
        isBrowsing = false
    }

    // MARK: - 单类型实例浏览（三层模型的第③层，类型二级页专用）

    /// 实例层照 SideStore 走 NWBrowser（能收到回环广播）；ip:port 由 NSNetService 解析补齐.
    func startInstanceBrowsing(rawType: String, domain: String) {
        stopInstanceBrowsing()
        let parts = Self.browseComponents(rawType: rawType, domain: domain)
        typeInstances = []
        instanceErrorText = nil
        isBrowsingInstances = true
        let typeNoDot = parts.type.hasSuffix(".") ? String(parts.type.dropLast()) : parts.type
        let parameters = typeNoDot.contains("_tcp") ? NWParameters.tcp : NWParameters.udp
        // SideStore 同款（BonjourDiscoveryManager:237）：不开 P2P 通道时部分实例
        // （含本机 remoted 在回环上的广播）收不到，实例页会一直空.
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: typeNoDot, domain: parts.domain), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBrowsingInstances = false
                self.applyInstanceResults(results, rawType: parts.type)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state {
                DispatchQueue.main.async {
                    self?.instanceErrorText = "实例浏览失败（\(err)）.多为宿主未声明该服务类型，不影响其它功能."
                    self?.isBrowsingInstances = false
                }
            }
        }
        browser.start(queue: DispatchQueue.global(qos: .userInitiated))
        instanceNWBrowser = browser
    }

    func stopInstanceBrowsing() {
        instanceNWBrowser?.cancel()
        instanceNWBrowser = nil
        isBrowsingInstances = false
    }

    /// 结果集全量重放（SideStore handleInstanceResults 同型）：每轮回调替换整表，
    /// 已解析的 ip:port 从 resolvedInstanceEndpoints 回填，名字行永远可见.
    private func applyInstanceResults(_ results: Set<NWBrowser.Result>, rawType: String) {
        var rows: [DiscoveredService] = []
        for result in results {
            if case .service(let name, _, _, _) = result.endpoint {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let id = trimmed + "/" + rawType
                let known = resolvedInstanceEndpoints[id]
                let state: DiscoveredService.State = known == nil ? .resolving : (known!.ip != nil ? .ready : .failed)
                rows.append(DiscoveredService(id: id, name: trimmed, type: rawType, domain: "local.",
                                              ip: known?.ip, port: known?.port, state: state))
            }
        }
        rows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        typeInstances = rows
        for row in rows where resolvedInstanceEndpoints[row.id] == nil {
            let svc = NetService(domain: "local.", type: rawType, name: row.name)
            svc.delegate = self
            pending.append(svc)
            svc.resolve(withTimeout: 6)
        }
    }

    /// 把枚举层的原始类型串拆成 NetServiceBrowser 能吃的（类型, 域）：
    /// "_apple-mobdev2._tcp.local." → ("_apple-mobdev2._tcp.", "local.")；
    /// "_remotepairing._tcp." + domain "local" → ("_remotepairing._tcp.", "local.").
    /// meta-query 回来的是 PTR 全名（类型里自带域），浏览时必须剥掉，否则 code -65563.
    static func browseComponents(rawType: String, domain: String) -> (type: String, domain: String) {
        var t = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        var d = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower.hasSuffix(".local.") {
            t = String(t.dropLast(".local.".count))
            d = "local"
        } else if lower.hasSuffix(".local") {
            t = String(t.dropLast(".local".count))
            d = "local"
        }
        if t.hasSuffix(".") { t = String(t.dropLast()) }
        if !t.contains("_tcp") && !t.contains("_udp") { t += "._tcp" }
        if !t.hasSuffix(".") { t += "." }
        if d.isEmpty { d = "local" }
        if !d.hasSuffix(".") { d += "." }
        return (t, d)
    }

/// 68 型 NWBrowser 兜底探测并行挂上；收摊靠事件（tryFinishTypeEnumeration），不定秒.
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
    }

    /// 收摊判据（用户 m27306「谁让你加的延迟和秒数」）：两路事件都落定才 stop ——
    /// ① meta-query 出终态（didFind moreComing=false / didNotSearch / DidStopSearch）；
    /// ② 68 型兜底浏览器每型都回过至少一次结果集（空集也算）或进入 failed/cancelled.
    /// 任何一路没落定就继续挂着，页面显示「正在枚举服务类型…」——没有定时器，也不许有.
    private func tryFinishTypeEnumeration() {
        guard isEnumeratingTypes, metaQuerySettled else { return }
        guard settledFallbackBrowsers.count >= fallbackTypesTotal else { return }
        stopTypeSearch()
    }

    private func noteFallbackBrowserSettled(_ token: Int) {
        guard let browser = fallbackBrowserBox[token] else { return }
        let key = ObjectIdentifier(browser)
        guard !settledFallbackBrowsers.contains(key) else { return }
        settledFallbackBrowsers.insert(key)
        tryFinishTypeEnumeration()
    }

    /// 有结果即记类型；浏览器挂入 fallbackTypeBrowsers 统一停.
    private func startFallbackSearches(types: [String], in domain: String) {
        settledFallbackBrowsers = []
        fallbackBrowserBox = [:]
        fallbackTypesTotal = types.count
        for (browseToken, t) in types.enumerated() {
            let typeWithoutDot = t.hasSuffix(".") ? String(t.dropLast()) : t
            let parameters = typeWithoutDot.contains("_tcp") ? NWParameters.tcp : NWParameters.udp
            let descriptor = NWBrowser.Descriptor.bonjour(type: typeWithoutDot, domain: domain)
            let browser = NWBrowser(for: descriptor, using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !results.isEmpty { self.insertServiceType(rawType: t) }
                    // 首回调（含空集）即该型探完：NWBrowser 就绪后必发一次结果集，这就是收摊事件.
                    self.noteFallbackBrowserSettled(browseToken)
                }
            }
            browser.stateUpdateHandler = { [weak self] state in
                // 探测失败（含 LC 宿主白名单拦截）静默：枚举是观测面，不打扰用户；
                // 但 failed/cancelled 同样是终态，必须记账，否则该型永不落定、枚举永不收摊.
                switch state {
                case .failed, .cancelled:
                    DispatchQueue.main.async { self?.noteFallbackBrowserSettled(browseToken) }
                case .ready, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            browser.start(queue: DispatchQueue.global(qos: .userInitiated))
            fallbackTypeBrowsers.append(browser)
            fallbackBrowserBox[browseToken] = browser
        }
    }

    func stopTypeSearch() {
        typeBrowser?.stop()
        typeBrowser = nil
        for b in fallbackTypeBrowsers { b.cancel() }
        fallbackTypeBrowsers.removeAll()
        fallbackBrowserBox = [:]
        settledFallbackBrowsers = []
        fallbackTypesTotal = 0
        metaQuerySettled = false
        if isEnumeratingTypes { isEnumeratingTypes = false }
    }

    /// 规范化并去重插入类型：补尾点；只过滤 meta 自身（_services._dns-sd）与空串.
    ///
    /// 由 displayName 回落原始串；实例浏览再按 browseComponents 归一化回真实类型.
    private func insertServiceType(rawType: String) {
        var t = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.lowercased().contains("_dns-sd") else { return }
        if !t.hasSuffix(".") { t += "." }
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
            let name = (service.name ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let type = service.type ?? ""
            var rawType = name
            if !name.contains(".") && type.hasPrefix(".") && !type.contains("_dns-sd") {
                rawType = name + type
            }
            insertServiceType(rawType: rawType)
            if !moreComing {
                metaQuerySettled = true
                tryFinishTypeEnumeration()
            }
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
        let id = serviceID(service)
        services.removeAll { $0.id == id }
        typeInstances.removeAll { $0.id == id }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFindDomain domain: String, moreComing: Bool) {
        let name = domain.hasSuffix(".") ? String(domain.dropLast()) : domain
        guard !name.isEmpty, !domains.contains(name) else { return }
        domains.append(name)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        if browser === typeBrowser {
            // 枚举失败（LC 宿主未声明 _services._dns-sd._udp 时常见）同样是终态：记账收摊，
            // 但不报错——兜底探测可能仍有结果，本页只是观测面.
            metaQuerySettled = true
            tryFinishTypeEnumeration()
            return
        }
        guard browser !== domainBrowser else { return }
        let code = errorDict["NSNetServicesErrorCode"]?.intValue ?? -1
        // guest 声明不合并；缺类型时该浏览器报错且权限弹窗不弹（_remotepairing._tcp
        // 宿主已声明，可用）.列表里有服务时不打扰用户；回环建连不需要本地网络权限.
        if services.isEmpty {
            lastErrorText = "浏览失败（Bonjour code \(code)）.在 LiveContainer 内多为宿主未声明该服务类型，不影响回环建连."
        }
        isBrowsing = false
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        // 主动 stop 的正常收尾；typeBrowser 被停掉也算 meta 落定，别把枚举吊着.
        if browser === typeBrowser {
            metaQuerySettled = true
            tryFinishTypeEnumeration()
        }
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard (1...65535).contains(sender.port) else { return }
        let id = serviceID(sender)
        let ip = RemotePairingPort.ipv4Address(of: sender)
        resolvedInstanceEndpoints[id] = (ip, Int(sender.port))
        services = services.map { row in
            guard row.id == id else { return row }
            return DiscoveredService(id: row.id, name: row.name, type: row.type,
                                     domain: row.domain,
                                     ip: ip, port: sender.port,
                                     state: ip == nil ? .failed : .ready)
        }
        typeInstances = typeInstances.map { row in
            guard row.id == id else { return row }
            return DiscoveredService(id: row.id, name: row.name, type: row.type,
                                     domain: row.domain,
                                     ip: ip, port: sender.port,
                                     state: ip == nil ? .failed : .ready)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let id = serviceID(sender)
        resolvedInstanceEndpoints[id] = (nil, nil)
        services = services.map { row in
            guard row.id == id else { return row }
            return DiscoveredService(id: row.id, name: row.name, type: row.type,
                                     domain: row.domain,
                                     ip: nil, port: nil, state: .failed)
        }
        typeInstances = typeInstances.map { row in
            guard row.id == id else { return row }
            return DiscoveredService(id: row.id, name: row.name, type: row.type,
                                     domain: row.domain,
                                     ip: nil, port: nil, state: .failed)
        }
    }
}
