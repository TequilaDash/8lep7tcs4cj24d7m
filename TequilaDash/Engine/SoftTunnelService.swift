import Foundation

/// 进程内软隧道（Gnoix 同型）：usbmuxd → lockdown → start_service(com.apple.coredevice.proxy)
/// → CoreDeviceProxy（CDTunnel TLS-PSK）→ create_software_tunnel → connect(server_rsd_port)
/// → RsdHandshake. 不依赖 utun 对端、不依赖外部 App，蜂窝与 Wi-Fi 均可用.
/// 配对四级链：usbmuxd 存档 → 指定文件 → 无 session → 自配对，任一级成功即继续.
/// 全部建立串行（单队列）：建立过程彼此独立，仍按仓内「同通道串行」铁律收敛.
final class SoftTunnelService: @unchecked Sendable {
    static let shared = SoftTunnelService()
    private let queue = DispatchQueue(label: "com.tequila.dash.soft-tunnel")
    private init() {}

    struct Handles {
        var adapter: OpaquePointer
        var handshake: OpaquePointer
    }

    /// 建一条 RSD 软隧道. 成功返回句柄（rsd_* 系 FFI 可直接用）；
    /// 失败返回 nil，`stage` 带失败阶段名（usbmuxd_connect / start_session / cd_tunnel_handshake /
    /// software_tunnel / rsd_handshake 等），供诊断与日志.
    func createTunnel(label: String, pairingPath: String?) -> Handles? {
        queue.sync {
            TunnelDiagnostics.begin("软隧道", "label=\(label)")
            var adapter: OpaquePointer?
            var handshake: OpaquePointer?
            var stageBuf = [CChar](repeating: 0, count: 256)
            let call: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<IdeviceFfiError>? = { path in
                tunnel_create_soft(path, nil, &adapter, &handshake, &stageBuf, UInt(stageBuf.count))
            }
            let ffiError: UnsafeMutablePointer<IdeviceFfiError>?
            if let pairingPath, !pairingPath.isEmpty {
                ffiError = pairingPath.withCString { call($0) }
            } else {
                ffiError = call(nil)
            }
            let stage = String(cString: stageBuf)
            if let ffiError {
                let code = ffiError.pointee.code
                let text = DeviceErrorText.cleaned(ffiError.pointee.message) ?? ""
                idevice_error_free(ffiError)
                TunnelDiagnostics.fail("软隧道", code: code, message: "stage=\(stage) \(text)")
                return nil
            }
            guard let adapter, let handshake else {
                if adapter != nil { adapter_free(adapter) }
                if handshake != nil { rsd_handshake_free(handshake) }
                TunnelDiagnostics.fail("软隧道", code: -1, message: "stage=\(stage) 句柄不全")
                return nil
            }
            TunnelDiagnostics.succeed("软隧道", "stage=\(stage)")
            return Handles(adapter: adapter, handshake: handshake)
        }
    }
}

