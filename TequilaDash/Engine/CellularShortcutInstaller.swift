import Foundation
import Network
import UIKit

/// 「关 / 开蜂窝」快捷指令的可达性检查与创建引导。
///
/// ## 为什么没有「自动静默安装」了（v0.3.650 重新设计）
///
/// v0.3.599 曾试过 `shortcuts://import-shortcut?url=...&silent=true` 静默导入，
/// **真机实测失败**：URL 无效 + 强制跳转到快捷指令 App（v0.3.616 撤销）。
/// v0.3.616 之后 `ensureInstalled()` 被改成恒返回 false 的死函数，
/// 但蜂窝开关仍然去跑 `shortcuts://run-shortcut?name=TurnOffData` ⇒
/// 用户看到的就是「未找到快捷指令 TurnOffData」这个弹窗。
///
/// ## 源码对照结论（LiveContainer + SideStore 都读了）
///
/// · LiveContainer：自己的 Swift/ObjC 里 `NWPathMonitor|cellular|shortcut` 命中 **0**，
///   刷新整个通过 App Intents/XPC 外包给 SideStore ⇒ 它不是实现方。
/// · SideStore `Core/Shortcuts/CellularRefreshManager.swift`：只按名字调
///   `shortcuts://run-shortcut?name=TurnOffData`，**自己不创建、也不引导创建**
///   （SideStore issue #1393 / #1413 / #1191 全是用户抱怨「找不到快捷指令」）。
///   Shortcuts 目录下只有这一个文件，无任何 `.shortcut` 生成代码。
///
/// ⇒ **两个参考项目都不自动创建快捷指令**，用户看到的「LiveContainer 自动创建且不跳转」
///   在这个版本里没有源码依据。不再照一个不存在的做法去实现。
///
/// ## 现在的做法
///
/// 1. **运行前先探测**快捷指令是否存在（`isShortcutInstalled`）——
///    不存在就**不跳转**，改为引导用户一键创建（见 `createShortcutURL`）。
/// 2. 创建用 `shortcuts://create-shortcut`（Apple 官方 URL scheme），
///    **无法静默**（Apple 不允许第三方代建）—— 这一步如实告知用户。
/// 3. 蜂窝开关打开时主动提示一次，不要让用户在建隧道时才撞见弹窗。
enum CellularShortcutInstaller {

    /// 持久化键：用户是否已被告知「需要自建快捷指令」.
    static let advisedKey = "TequilaDash.CellularShortcutAdvised"

    /// 以 `shortcuts://open-shortcut?name=` 探测某个快捷指令是否存在。
    ///
    /// ⚠️ **无法真正检测**：iOS 没有「查询快捷指令是否存在」的公开 API。
    /// 这里用一个保守的近似的**用户是否已确认建好**的持久化标记，
    /// 不伪造系统返回值（v0.3.616 的教训：URL 被受理 ≠ 事情已办成）。
    static func isShortcutInstalled(_ name: String) -> Bool {
        let key = "TequilaDash.CellularShortcut.\(name)"
        return UserDefaults.standard.bool(forKey: key)
    }

    /// 标记某个快捷指令已建好（由 UI 在用户确认后调用）。
    static func markShortcutInstalled(_ name: String) {
        UserDefaults.standard.set(true, forKey: "TequilaDash.CellularShortcut.\(name)")
    }

    /// 生成「一键创建快捷指令」的 URL（Apple 官方 `shortcuts://create-shortcut`）。
    ///
    /// 无法静默：Apple 不允许第三方应用替用户建快捷指令，必然跳转到快捷指令 App。
    /// 这一步如实告知，不包装成「自动安装」。
    static func createShortcutURL(name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "create-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    /// 供 UI 判断：是否该提示用户去建快捷指令。
    ///   两个都没建 ⇒ 提示（返回 false 表示「不该直接跑」）。
    static var shouldPromptCreation: Bool {
        !isShortcutInstalled("TurnOffData") || !isShortcutInstalled("TurnOnData")
    }

    static func resetImportedFlag() {
        UserDefaults.standard.removeObject(forKey: advisedKey)
    }
}
/// Loopback-only file server retained for local diagnostics. Readiness and
/// requests share one serial queue; no caller holds a lock while waiting.
final class LocalShortcutServer: @unchecked Sendable {
    static let shared = LocalShortcutServer()
    private let queue = DispatchQueue(label: "com.tequila.dash.shortcut-files")
    private var listener: NWListener?
    private var routes: [String: Data] = [:]
    private var pending: [UUID: (String, CheckedContinuation<URL?, Never>)] = [:]
    private var port: UInt16 = 0

    private init() {}

    func serve(fileURL: URL, as name: String) async -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                let path = "/" + name
                self.routes[path] = data
                if self.port != 0 {
                    continuation.resume(returning: self.url(for: path))
                    return
                }
                let id = UUID()
                self.pending[id] = (path, continuation)
                self.queue.asyncAfter(deadline: .now() + 3) {
                    guard let item = self.pending.removeValue(forKey: id) else { return }
                    item.1.resume(returning: nil)
                    if self.port == 0 && self.pending.isEmpty { self.stopOnQueue() }
                }
                guard self.listener == nil else { return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { connection.cancel(); return }
                        self.handle(connection)
                    }
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self, let listener, self.listener === listener else { return }
                        switch state {
                        case .ready:
                            self.port = listener.port?.rawValue ?? 0
                            self.finishPending()
                        case .failed, .cancelled:
                            self.stopOnQueue()
                        default: break
                        }
                    }
                    listener.start(queue: self.queue)
                } catch {
                    self.stopOnQueue()
                }
            }
        }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func url(for path: String) -> URL? {
        guard port != 0 else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = path
        return components.url
    }

    private func finishPending() {
        let items = pending.values
        pending.removeAll()
        for (path, continuation) in items { continuation.resume(returning: url(for: path)) }
    }

    private func stopOnQueue() {
        let old = listener
        listener = nil
        port = 0
        old?.cancel()
        finishPending()
        routes.removeAll()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = buffered
            if let data { request.append(data) }
            guard error == nil, request.count <= 8192 else { connection.cancel(); return }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() }
                else { self.receive(connection, buffered: request) }
                return
            }
            let line = String(data: request, encoding: .utf8)?.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let method = parts.first.map(String.init) ?? ""
            let path = parts.count > 1 ? String(parts[1]).components(separatedBy: "?")[0] : "/"
            let body = (method == "GET" || method == "HEAD") ? self.routes[path] : nil
            let status = body == nil ? "404 Not Found" : "200 OK"
            let header = "HTTP/1.1 \(status)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n"
            let payload = Data(header.utf8) + (method == "HEAD" ? Data() : (body ?? Data()))
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
