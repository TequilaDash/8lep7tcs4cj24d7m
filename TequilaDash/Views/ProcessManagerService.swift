//
//  ProcessManagerService.swift
//  TequilaDash
//
//  从 ProcessManagerView.swift 拆分而来：原文件 1298 行、9 个 top-level 声明，
//  拆成 4 个文件以满足「每文件 ≤ 600 行」的规模约束.
//  本文件只承载服务层 ProcessManagerService（隧道 + app_service FFI），
//  成员逐字节原样搬运，未做任何逻辑改动.
//

import Foundation
import Darwin

// MARK: - 服务层（隧道 + app_service FFI）

/// 进程管理服务：复用 JITEnableService 的隧道写法，直接调用 idevice.h 暴露的
/// `app_service_*` C 函数（经 bridging header 可见）.
///
/// v0.2.108 关键修复：
/// - 所有进程操作（枚举 / 发信号）走**同一条串行队列**，禁止并发的
///   `TequilaDashProcess` 隧道互相抢占/覆盖；
/// - `app_service_connect_rsd` 与 `tunnel_create_rppairing` 一样加 3 次退避重试，
///   覆盖 RSD 服务发现的偶发 `ServiceNotFound`；
/// - 发信号使用 `UInt32(SIGKILL)` 直接量，与「设备控制」侧完全一致，避免
///   `Int32 → UInt32` 转换在任何编译/平台组合下出现歧义.
/// `Sendable`（非 unchecked）：本类**没有可变存储属性**——两个存储属性都是
/// `let` 的串行队列（`DispatchQueue` 本身是 `Sendable`），所有进程状态都在
/// 方法内局部变量里、并已被这两条队列串行化。
///
/// 注意： **本条注释已经被改过三次 —— 前两版「成因」都是猜的，全部作废**：
/// ① 上面「3 次退避重试覆盖**偶发** `ServiceNotFound`」：作废；
/// ② 第二版「设备未挂 DDI（Developer Disk Image）⇒ CoreDevice 整块不广播」：作废；
/// ③ 第三版「接错隧道（CoreDevice 族只在 CoreDeviceProxy 隧道的第二个 RSD 握手上）」：
///    **同样作废**（与 PC 侧 `pymobiledevice3` 的交叉验证矛盾）。
/// **⇒ 本文件从此不再写任何成因推测。**
///
/// **事实（用户实测 + PC 侧交叉验证）**：`ServiceNotFound`(21) 是**设备侧的服务状态问题**，
/// **不是本 App 的缺陷** —— 该服务在设备侧**偶尔**不可用，**重启手机即恢复**（用户实测；
/// 同类工具也这么处理）。**与 DDI 无关，也与「用哪条隧道」无关**：PC 侧标准工具
/// `pymobiledevice3` 拿到的 RSD 服务表与我们**逐条一致**（64 条），调同一个服务**同样失败**。
/// **原理未知。**
///
/// **仍然成立（保留）**：`rsd.rs:171-189` 查服务是纯 `HashMap`、查不到直接
/// `Err(ServiceNotFound)`（错误码 21），**无回退** ⇒ 失败时**重试 3 次毫无意义**（只是白等 0.9s）；
/// 两个内置模块 / 进程管理 / 虚拟定位停止 / 拨号器主题重启电话 / IPCC 重启 CommCenter /
/// 设备控制重启 SpringBoard **共用同一套 `app_service` 底座** ⇒ 它不可用时这些会一起失败。
///
/// **v0.3.599 修复（主页-模块「执行」报 `ServiceNotFound`）—— 不再赌它「在不在」，改为先查表再选路**：
/// - `rsd_service_available(handshake, "com.apple.coredevice.appservice")` 与
///   `app_service_connect_rsd` 读的是**同一张** `handshake.services`（源码实证：
///   `RsdHandshake::connect` = `self.services.get(name)`；`rsd_service_available` =
///   `self.services.contains_key(name)`）⇒ 预检结果**精确预测**连接会不会抛 21，不会误判；
/// - 预检说「不在」⇒ 改走 **DVT 族**（`com.apple.instruments.dtservicehub`，与内存查询 /
///   截图 / 虚拟定位**同族**、**不依赖 CoreDevice**）：`device_info_running_processes` 列进程、
///   `process_control_kill_app(pid)` 结束进程；
/// - 两条路都失败才如实报错 —— 不再把裸 `ServiceNotFound` 弹给用户（`ModuleService` 侧同步映射成人话）。
/// - **仍未验证（诚实标注）**：DVT 的进程表是否包含 `locationd` / `wifid` 这类**系统守护进程**、
///   以及 `killPid:` 对守护进程是否放行 —— 本设备截图 / sysmontap 已证 DVT 族可连，但
///   「守护进程可见性」需真机复测。代码在失败时会如实报「未找到 xxx（DVT 通道）」，不假装成功。
final class ProcessManagerService: Sendable {

    static let shared = ProcessManagerService()
    private init() {}

    /// 串行队列：保证 listProcesses / sendSignal 不并发建隧道.
    /// 同一 hostname 并发 `tunnel_create_rppairing` 会互相抢占（RSD 通道竞争），
    /// 因此这里必须串行 —— 这条约束本身成立。
    /// 注意： 2026-09-19 更正：但它是**通道被抢占**的根因，**不是** `ServiceNotFound` 的根因 ——
    /// 后者是**设备侧的服务状态问题**（该服务偶尔不可用，**重启手机即恢复**），与并发无关。
    /// 见上方注释。
    private let operationQueue = DispatchQueue(label: "com.tequila.dash.processmgr", qos: .userInitiated)
    /// v0.3.38：内存查询专用串行队列（sysmontap 阻塞式，不与其他操作争用）
    private let memoryQueue = DispatchQueue(label: "com.tequila.dash.processmgr.memory", qos: .utility)

    /// TequilaDash 的配对文件路径（与「应用管理」/ 虚拟定位共用）.
    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "ProcessManager", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else { return makeError(fallback) }
        let message: String
        if let cString = ffiError.pointee.message {
            message = String(cString: cString)
        } else {
            message = ""
        }
        let code = Int(ffiError.pointee.code)
        idevice_error_free(ffiError)
        return NSError(domain: "ProcessManager", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message])
    }

    // MARK: 隧道

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }

    private func createTunnel(hostname: String) throws -> TunnelHandles {
        // 隧道就绪闸门：缓存可达即零等待放行；不可达补一次 0.5s 探测后快速失败（替代直连 75s+ 挂死）.
        try TunnelGate.guardReady()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw makeError("未检测到配对文件.请到「更多 → 配对文件导入」导入配对文件（需 LocalDevVPN + 开发者模式）.")
        }

        var pairingFile: OpaquePointer?
        if let ffiError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw error(from: ffiError, fallback: "读取配对文件失败")
        }
        guard let pairingFile else { throw makeError("读取配对文件失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(RemotePairingPort.current).bigEndian

        // 蜂窝隧道支持（默认关）：开关开 + 无 Wi-Fi 时先等本地隧道就绪；其余情况为 no-op.
        CellularTunnelManager.shared.prepareForTunnel()
        let deviceIP = LocalDevVPN.targetIP
        let parseResult = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard parseResult == 1 else {
            throw makeError("隧道 IP 无效：\(deviceIP)（请检查「设置 → 本地隧道」）")
        }

        // 隧道建立失败自动重试（最多 3 次、短退避）：对齐 DeviceControlService.
        var lastError: NSError?
        TunnelDiagnostics.begin("进程管理隧道")
        for attempt in 0..<3 {
            var tunnel = TunnelHandles()
            let ffiError = hostname.withCString { hn in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing(
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hn,
                            pairingFile,
                            nil,
                            nil,
                            &tunnel.adapter,
                            &tunnel.handshake
                        )
                    }
                }
            }
            if let ffiError {
                lastError = error(from: ffiError, fallback: "创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
            } else if tunnel.adapter != nil, tunnel.handshake != nil {
                TunnelDiagnostics.succeed("进程管理隧道")
                return tunnel
            } else {
                var incomplete = tunnel
                incomplete.free()
                lastError = makeError("创建开发者隧道失败")
            }
            if attempt < 2 {
                usleep(useconds_t(300_000 * (attempt + 1)))
            }
        }
        TunnelDiagnostics.fail("进程管理隧道", error: lastError)
        throw lastError ?? makeError("创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
    }

    /// 连接 app_service，失败自动重试 3 次.
    ///
    /// 注意： 这 3 次重试**覆盖不了任何东西**：失败是设备侧 `app_service` 服务偶尔不可用
    /// （`ServiceNotFound`，**重启手机即恢复**），重试只是白等 0.9s。见类头注释。
    private func connectAppService(adapter: OpaquePointer, handshake: OpaquePointer) throws -> OpaquePointer {
        var lastError: NSError?
        for attempt in 0..<3 {
            var appService: OpaquePointer?
            if let ffiError = app_service_connect_rsd(adapter, handshake, &appService) {
                lastError = error(from: ffiError, fallback: "连接应用服务失败")
            } else if let appService {
                return appService
            } else {
                lastError = makeError("连接应用服务失败")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("连接应用服务失败")
    }

    // MARK: 服务表预检 + 通道选路

    /// RSD 服务表里的 CoreDevice 入口名（= 上游 `AppServiceClient::rsd_service_name()`，源码实证）。
    /// 该族未挂 DDI 时不广播 ⇒ 不在表里 ⇒ `app_service_connect_rsd` 必抛 `ServiceNotFound`(21)。
    private static let appServiceServiceName = "com.apple.coredevice.appservice"

    /// 预检：`app_service` 是否在**本次** RSD 握手的服务表里。
    ///
    /// `rsd_service_available` 只做 `handshake.services.contains_key(name)`：**不连设备、
    /// 不发任何请求**，所以能安全地当路由开关用。它与 `app_service_connect_rsd`
    /// （`RsdHandshake::connect` = `services.get(name)`）读的是**同一张**表
    /// ⇒ 预检结果精确预测连接会不会抛 21。
    private func appServiceAvailable(handshake: OpaquePointer) -> Bool {
        var available = false
        if let ffiError = Self.appServiceServiceName.withCString({
            rsd_service_available(handshake, $0, &available)
        }) {
            idevice_error_free(ffiError)
            return false
        }
        return available
    }

    // MARK: 枚举进程

    /// 枚举设备进程。**先查服务表再选路**：
    /// `app_service` 在表里 → 走 CoreDevice（原路径）；不在或连不上 → 走 DVT 回退。
    func listProcesses() throws -> [ProcessEntry] {
        try operationQueue.sync {
            var tunnel = try createTunnel(hostname: "TequilaDashProcess")
            defer { tunnel.free() }
            guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
                throw makeError("隧道未建立")
            }

            if appServiceAvailable(handshake: handshake),
               let entries = try? listProcessesViaAppService(adapter: adapter, handshake: handshake) {
                return entries
            }
            // app_service 不在服务表里（CoreDevice 族未广播）或连接失败 ⇒ DVT 回退。
            return try listProcessesViaDVT(adapter: adapter, handshake: handshake)
        }
    }

    /// 原路径：CoreDevice `app_service_list_processes`。
    private func listProcessesViaAppService(
        adapter: OpaquePointer, handshake: OpaquePointer
    ) throws -> [ProcessEntry] {
        let appService = try connectAppService(adapter: adapter, handshake: handshake)
        defer { app_service_free(appService) }

        var processes: UnsafeMutablePointer<ProcessTokenC>?
        var count = UInt(0)
        if let ffiError = app_service_list_processes(appService, &processes, &count) {
            throw error(from: ffiError, fallback: "枚举进程失败")
        }
        defer {
            if let processes { app_service_free_process_list(processes, count) }
        }
        guard let processes else { return [] }

        var result: [ProcessEntry] = []
        result.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let p = processes[index]
            let path = p.executable_url.flatMap { String(cString: $0) } ?? "未知"
            result.append(ProcessEntry(pid: Int(p.pid), executablePath: path))
        }
        return result
    }

    /// 回退路径：DVT `device_info_running_processes`。
    ///
    /// 走 `com.apple.instruments.dtservicehub`（与内存查询 / 截图 / 虚拟定位**同族**；
    /// 该族在本设备已被截图 / sysmontap 真机验证可用，**不依赖 CoreDevice**）。
    /// 设备回传 `name`（execname，如 `locationd` / `wifid`）与 `realAppName`；这里把 execname
    /// 放进 `executablePath` —— `ProcessEntry.displayName` 取路径末段，于是
    /// `displayName == "locationd"`，与模块 `process` 字段能直接匹配。
    private func listProcessesViaDVT(
        adapter: OpaquePointer, handshake: OpaquePointer
    ) throws -> [ProcessEntry] {
        var server: OpaquePointer?
        if let ffiError = remote_server_connect_rsd(adapter, handshake, &server) {
            throw error(from: ffiError, fallback: "创建 DVT 服务失败")
        }
        guard let server else { throw makeError("创建 DVT 服务失败") }
        defer { remote_server_free(server) }   // 晚于下方 handle 释放（defer 后进先出）

        var deviceInfo: OpaquePointer?
        if let ffiError = device_info_new(server, &deviceInfo) {
            throw error(from: ffiError, fallback: "创建 DeviceInfo 失败")
        }
        guard let deviceInfo else { throw makeError("创建 DeviceInfo 失败") }
        defer { device_info_free(deviceInfo) }

        var processes: UnsafeMutablePointer<UnsafeMutablePointer<IdeviceRunningProcess>?>?
        var count = UInt(0)
        if let ffiError = device_info_running_processes(deviceInfo, &processes, &count) {
            throw error(from: ffiError, fallback: "枚举进程失败（DVT 通道）")
        }
        defer {
            if let processes { device_info_running_processes_free(processes, count) }
        }
        guard let processes else { return [] }

        var result: [ProcessEntry] = []
        result.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let entry = processes[index] else { continue }
            let name = entry.pointee.name.flatMap { String(cString: $0) } ?? ""
            result.append(ProcessEntry(pid: Int(entry.pointee.pid), executablePath: name))
        }
        return result
    }

    // MARK: 发送信号

    // MARK: - 内存查询（v0.3.33：DVT sysmontap physFootprint）

    /// 通过 DVT sysmontap 获取每个进程的 physFootprint（物理内存占用）.
    /// 返回 [pid: bytes]，进程已退出时不出现在字典中.
    func fetchMemoryUsage() throws -> [Int32: UInt64] {
        // v0.3.38：不用 operationQueue.sync（sysmontap 阻塞式会卡死串行队列）
        try memoryQueue.sync {
            var tunnel = try createTunnel(hostname: "TequilaDashSysmon")
            defer { tunnel.free() }
            guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
                throw makeError("隧道未建立")
            }

            // 1. RemoteServer
            SysmonLogger.shared.log("[SysmonDiag] step1: 创建 RemoteServer…")
            var server: OpaquePointer?
            if let err = remote_server_connect_rsd(adapter, handshake, &server) {
                let msg = error(from: err, fallback: "创建 RemoteServer 失败")
                SysmonLogger.shared.log("[SysmonDiag] step1 失败: \(msg.localizedDescription)")
                throw msg
            }
            guard let server else { throw makeError("RemoteServer 为空") }
            SysmonLogger.shared.log("[SysmonDiag] step1 成功")
            defer { remote_server_free(server) }

            // 2. SysmontapClient
            SysmonLogger.shared.log("[SysmonDiag] step2: 创建 SysmontapClient…")
            var sysmon: OpaquePointer?
            if let err = sysmontap_new(server, &sysmon) {
                let msg = error(from: err, fallback: "创建 Sysmontap 失败")
                SysmonLogger.shared.log("[SysmonDiag] step2 失败: \(msg.localizedDescription)")
                throw msg
            }
            guard let sysmon else { throw makeError("Sysmontap 为空") }
            SysmonLogger.shared.log("[SysmonDiag] step2 成功")
            defer { sysmontap_free(sysmon) }

            // 3. 查询设备支持的 sysmon 属性名（iOS 27 beta 可能不叫 physFootprint）
            SysmonLogger.shared.log("[SysmonDiag] step3a: 查询设备 sysmon 属性列表…")
            var devInfo: OpaquePointer?
            if let err = device_info_new(server, &devInfo) {
                let msg = error(from: err, fallback: "创建 DeviceInfo 失败")
                SysmonLogger.shared.log("[SysmonDiag] step3a 失败: \(msg.localizedDescription)")
                throw msg
            }
            defer { device_info_free(devInfo) }
            guard let devInfo else { throw makeError("DeviceInfo 为空") }

            var attrs: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
            var attrCount: Int = 0
            if let err = device_info_sysmon_process_attributes(devInfo, &attrs, &attrCount) {
                let msg = error(from: err, fallback: "查询属性列表失败")
                SysmonLogger.shared.log("[SysmonDiag] step3b 查询失败: \(msg.localizedDescription)")
                throw msg
            }
            var attrNames: [String] = []
            if let attrs, attrCount > 0 {
                for i in 0..<attrCount {
                    if let ptr = attrs[i] {
                        attrNames.append(String(cString: ptr))
                    }
                }
                device_info_string_array_free(attrs, UInt(attrCount))
            }
            SysmonLogger.shared.log("[SysmonDiag] step3b 属性列表(\(attrCount)): \(attrNames.joined(separator: ","))")

            guard !attrNames.isEmpty else {
                SysmonLogger.shared.log("[SysmonDiag] step3b 设备返回空属性列表——sysmontap 不支持此设备")
                throw makeError("设备 sysmon 属性为空")
            }

            // 用真实属性名构建 C 数组
            var cAttrs: [UnsafeMutablePointer<CChar>] = []
            for name in attrNames {
                if let buf = strdup(name) { cAttrs.append(buf) }
            }
            defer { for buf in cAttrs { free(UnsafeMutableRawPointer(buf)) } }
            var attrPtrs: [UnsafePointer<CChar>?] = cAttrs.map { UnsafePointer($0) }
            attrPtrs.append(nil)

            // 查询系统属性列表（空 sysAttrs 会导致设备断连——pmd3 传完整列表）
            SysmonLogger.shared.log("[SysmonDiag] step3c: 查询系统属性列表…")
            var sysAttrs: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
            var sysAttrCount: Int = 0
            var sysAttrNames: [String] = []
            if let err = device_info_sysmon_system_attributes(devInfo, &sysAttrs, &sysAttrCount) {
                let msg = error(from: err, fallback: "系统属性查询失败")
                SysmonLogger.shared.log("[SysmonDiag] step3c 系统属性查询失败: \(msg.localizedDescription)")
            } else if let sysAttrs, sysAttrCount > 0 {
                for i in 0..<sysAttrCount {
                    if let ptr = sysAttrs[i] {
                        sysAttrNames.append(String(cString: ptr))
                    }
                }
                device_info_string_array_free(sysAttrs, UInt(sysAttrCount))
                SysmonLogger.shared.log("[SysmonDiag] step3c 系统属性(\(sysAttrCount)): \(sysAttrNames.prefix(5).joined(separator: ","))…")
            }

            var sysCAttrs: [UnsafeMutablePointer<CChar>] = []
            for name in sysAttrNames {
                if let buf = strdup(name) { sysCAttrs.append(buf) }
            }
            defer { for buf in sysCAttrs { free(UnsafeMutableRawPointer(buf)) } }
            var sysPtrs: [UnsafePointer<CChar>?] = sysCAttrs.map { UnsafePointer($0) }
            sysPtrs.append(nil)

            // ur=1 对齐 pymobiledevice3（interval_ms 同时写 ur 和 sampleInterval）
            var config = IdeviceSysmontapConfig(
                interval_ms: 1,
                process_attributes: attrPtrs,
                process_attributes_count: UInt(attrNames.count),
                system_attributes: sysPtrs,
                system_attributes_count: UInt(sysAttrNames.count)
            )
            if let err = sysmontap_set_config(sysmon, &config) {
                let msg = error(from: err, fallback: "配置 Sysmontap 失败")
                SysmonLogger.shared.log("[SysmonDiag] step3c 失败: \(msg.localizedDescription)")
                throw msg
            }
            SysmonLogger.shared.log("[SysmonDiag] step3c 配置成功(\(attrNames.count) 属性)")

            // 4. 启动
            if let err = sysmontap_start(sysmon) {
                let msg = error(from: err, fallback: "启动 Sysmontap 失败")
                SysmonLogger.shared.log("[SysmonDiag] step4 失败: \(msg.localizedDescription)")
                throw msg
            }
            SysmonLogger.shared.log("[SysmonDiag] step4 启动成功，等待样本…")

            // 5. 获取一次样本
            var processes: plist_t? = nil
            var system: plist_t? = nil
            var cpu: plist_t? = nil
            // next_sample 阻塞式 → 单次 2 秒超时 + 循环读样本
            // （首几个样本可能只有 System 数据，带 Processes 的样本在后续到达）
            for attempt in 1...8 {
                let sampleSemaphore = DispatchSemaphore(value: 0)
                var sampleError: Error?
                DispatchQueue.global(qos: .utility).async {
                    var p: plist_t? = nil, s: plist_t? = nil, c: plist_t? = nil
                    if let err = sysmontap_next_sample(sysmon, &p, &s, &c) {
                        sampleError = self.error(from: err, fallback: "获取内存样本失败")
                    } else {
                        processes = p; system = s; cpu = c
                    }
                    sampleSemaphore.signal()
                }
                let waitResult = sampleSemaphore.wait(timeout: .now() + 3)
                if waitResult == .timedOut {
                    SysmonLogger.shared.log("[SysmonDiag] step5 第\(attempt)次读样本超时")
                    sysmontap_stop(sysmon)
                    return [:]
                }
                if let sampleError {
                    SysmonLogger.shared.log("[SysmonDiag] step5 第\(attempt)次失败: \(sampleError.localizedDescription)")
                    throw sampleError
                }
                SysmonLogger.shared.log("[SysmonDiag] step5 第\(attempt)次样本 processes=\(processes != nil)")
                if processes != nil { break }  // 拿到进程数据，结束循环
            }

            defer {
                if let p = processes { plist_free(p) }
                if let s = system { plist_free(s) }
                if let c = cpu { plist_free(c) }
            }

            // 6. 停止
            sysmontap_stop(sysmon)

            // 7. 解析 processes dict → { "pid": [physFootprint_value] }
            var result: [Int32: UInt64] = [:]
            guard let procs = processes else { return result }

            // physFootprint 在属性数组中的真实下标
            guard let fpIdx = attrNames.firstIndex(of: "physFootprint") else {
                throw makeError("属性列表中无 physFootprint")
            }
            SysmonLogger.shared.log("[SysmonDiag] physFootprint 下标=\(fpIdx)")

            var iter: plist_dict_iter? = nil
            plist_dict_new_iter(procs, &iter)
            defer { if let it = iter { free(it) } }

            while true {
                var key: UnsafeMutablePointer<CChar>? = nil
                var val: plist_t? = nil
                plist_dict_next_item(procs, iter, &key, &val)
                guard let k = key else { break }
                let pidStr = String(cString: k)
                free(k)
                guard let pid = Int32(pidStr) else { continue }

                // val 是数组，physFootprint 在真实下标位（74 属性里它不在 0 位！
                // 之前写死 index 0 读到 msgRecv 消息计数器 → 全是小数字的根因）
                guard let v = val else { continue }
                let item = plist_array_get_item(v, UInt32(fpIdx))
                guard let footprint = item, footprint != nil else { continue }
                var mem: UInt64 = 0
                plist_get_uint_val(footprint, &mem)
                if mem > 0 { result[pid] = mem }
            }

            return result
        }
    }

    /// 向指定 PID 发信号。同样**先查服务表再选路**：
    /// `app_service` 在表里 → 走 CoreDevice（原路径，支持 SIGCONT / SIGSTOP / SIGKILL）；
    /// 不在或连不上 → 走 DVT（**只支持结束进程**，见 `sendSignalViaDVT`）。
    ///
    /// `expectedName`：调用方若知道该 PID「应该叫什么」（模块按名字匹配后拿到），
    /// 传进来可在 DVT 通道上做一次**进程名核对**，避免 PID 复用导致误杀。
    func sendSignal(_ action: ProcessControlAction, toPID pid: Int, expectedName: String? = nil) throws {
        try operationQueue.sync {
            var tunnel = try createTunnel(hostname: "TequilaDashProcess")
            defer { tunnel.free() }
            guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
                throw makeError("隧道未建立")
            }

            if appServiceAvailable(handshake: handshake),
               (try? sendSignalViaAppService(action, toPID: pid, adapter: adapter, handshake: handshake)) != nil {
                return
            }
            try sendSignalViaDVT(action, toPID: pid, expectedName: expectedName,
                                 adapter: adapter, handshake: handshake)
        }
    }

    /// 原路径：CoreDevice `app_service_send_signal`（SIGCONT / SIGSTOP / SIGKILL 都支持）。
    private func sendSignalViaAppService(
        _ action: ProcessControlAction, toPID pid: Int,
        adapter: OpaquePointer, handshake: OpaquePointer
    ) throws {
        let appService = try connectAppService(adapter: adapter, handshake: handshake)
        defer { app_service_free(appService) }

        var response: UnsafeMutablePointer<SignalResponseC>?
        let signalValue: UInt32 = {
            switch action {
            case .resume: return UInt32(SIGCONT)
            case .pause:  return UInt32(SIGSTOP)
            case .kill:   return UInt32(SIGKILL)
            }
        }()
        let ffiError = app_service_send_signal(appService, UInt32(pid), signalValue, &response)
        if let ffiError {
            throw error(from: ffiError, fallback: "发送信号失败")
        }
        defer { if let response { app_service_free_signal_response(response) } }
    }

    /// 回退路径：DVT `process_control_kill_app(pid)`。
    ///
    /// DVT 的 processcontrol 通道只有 `killPid:`（源码实证：上游 `kill_app` 直接发
    /// `killPid:` + pid，**不做名字查表**）⇒ **只能结束进程**；恢复 / 挂起如实报错，
    /// 不假装成功。结束前若调用方给了 `expectedName`，先用 `device_info_execname_for_pid`
    /// 核对一次，避免 PID 复用误杀。
    private func sendSignalViaDVT(
        _ action: ProcessControlAction, toPID pid: Int, expectedName: String?,
        adapter: OpaquePointer, handshake: OpaquePointer
    ) throws {
        guard action == .kill else {
            throw makeError("DVT 通道只能结束进程（不支持\(action.buttonLabel)）：等设备重新广播 app_service 后再试")
        }

        var server: OpaquePointer?
        if let ffiError = remote_server_connect_rsd(adapter, handshake, &server) {
            throw error(from: ffiError, fallback: "创建 DVT 服务失败")
        }
        guard let server else { throw makeError("创建 DVT 服务失败") }
        defer { remote_server_free(server) }   // 晚于下方 handle 释放（defer 后进先出）

        // 1) 名字核对（仅当调用方提供了期望名）：PID 可能被系统复用，杀错进程后果严重。
        if let expectedName, !expectedName.isEmpty {
            var deviceInfo: OpaquePointer?
            if let ffiError = device_info_new(server, &deviceInfo) {
                throw error(from: ffiError, fallback: "创建 DeviceInfo 失败")
            }
            guard let deviceInfo else { throw makeError("创建 DeviceInfo 失败") }
            defer { device_info_free(deviceInfo) }

            var execName: UnsafeMutablePointer<CChar>?
            if let ffiError = device_info_execname_for_pid(deviceInfo, UInt32(pid), &execName) {
                throw error(from: ffiError, fallback: "核对 PID \(pid) 进程名失败")
            }
            let actual = execName.flatMap { String(cString: $0) } ?? ""
            if let execName { idevice_string_free(execName) }
            // 设备可能回传名字或路径，取末段后大小写不敏感比较。
            let actualLeaf = actual.split(separator: "/").last.map(String.init) ?? actual
            guard actualLeaf.lowercased() == expectedName.lowercased() else {
                throw makeError("PID \(pid) 现在是「\(actual.isEmpty ? "未知" : actualLeaf)」，"
                                + "不是「\(expectedName)」——已跳过，避免杀错进程")
            }
        }

        // 2) 下发 killPid:
        var processControl: OpaquePointer?
        if let ffiError = process_control_new(server, &processControl) {
            throw error(from: ffiError, fallback: "创建 ProcessControl 失败")
        }
        guard let processControl else { throw makeError("创建 ProcessControl 失败") }
        defer { process_control_free(processControl) }

        if let ffiError = process_control_kill_app(processControl, UInt64(pid)) {
            throw error(from: ffiError, fallback: "结束进程失败（DVT 通道）")
        }
    }
}
