import Foundation
import SwiftUI

/// 连接诊断（移植自 SideStore Health Check，适配本仓 LocalDevVPN + TunnelContext）.
///
/// 用途：真机上打开此页即知「每一步到底通不通」，替代靠猜排查.
/// 数据全部来自**本仓实际使用的代码路径**，不是模拟值.
///
/// ## 并发口径（Swift 6 严格并发）
/// 探测本身是**阻塞**的（`NWPathMonitor` 等首个路径回调、TCP `poll` 最多 1s），
/// 所以整段放在 `Task.detached` 里跑，**不占主线程**；结果用一个 `Sendable` 快照
/// 传回主 actor 再赋值. 否则在 `@MainActor` 上直接调会卡住界面.
@MainActor
final class TunnelHealthViewModel: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var loaded = false

    /// 探测结果快照（`Sendable`：全是值类型，可安全跨隔离域传递）.
    struct Snapshot: Sendable {
        var wifiSatisfied = false
        var utunAvailable = false
        var targetIP = ""
        var candidatePeers: [String] = []
        var targetReachable = false
        var anyPeerReachable = false
        var pairingFileExists = false
        var anisetteReady = false
        var anisetteStatus = ""
        var interfaces: [LocalDevVPN.InterfaceInfo] = []
        /// 各来源枚举到的候选数（分清「没有 utun」还是「枚举方式没覆盖到」）.
        var utunPeerCount = 0
        var routePeerCount = 0
        var overridePeer: String?
        /// 已有可用隧道句柄（**只读**，不建连）.
        var tunnelActive = false
        /// 是否正在建连（只读）.
        var tunnelConnecting = false
        /// 最近一次建连失败原因（只读，v0.3.639）.
        ///
        /// 这是全仓唯一记录真实失败原因的地方 —— 没有它，诊断页只能显示
        /// 「不可达 / 未建立」这类现象，用户永远拿不到「为什么」。
        var lastTunnelError: String?
        /// 配对文件能否被 RPPairing 解析（只读，v0.3.639）.
        ///
        /// `pairingFileExists` 只查文件存在性 —— 损坏 / 格式不对的文件也会打绿勾。
        var pairingFileParsable = false
        /// 解析失败原因（`pairingFileParsable == false` 时非空）.
        var pairingFileParseError: String?
    }

    /// 一行诊断结果.
    struct Row: Identifiable, Sendable {
        let id: String
        let title: String
        let subtitle: String
        let satisfied: Bool?
        /// `true` = 该项失败不阻塞主流程（显示为橙色减号而非红叉）.
        let optional: Bool

        init(_ title: String, _ subtitle: String, _ satisfied: Bool?, optional: Bool = false) {
            self.id = title
            self.title = title
            self.subtitle = subtitle
            self.satisfied = satisfied
            self.optional = optional
        }
    }

    func refresh() async {
        // 阻塞探测（NWPathMonitor 首个回调 / TCP poll）放后台，不占主线程.
        var probe = await Task.detached(priority: .userInitiated) { Self.probe() }.value
        // Anisette 就绪只是文件与钥匙串的存在性检查（微秒级），留在主 actor，
        // 避免依赖 `OnDeviceAnisetteManager` 的隔离域假设.
        let mgr = OnDeviceAnisetteManager.shared
        probe.anisetteReady = mgr.readiness().isReady
        probe.anisetteStatus = mgr.readinessText
        snapshot = probe
        loaded = true
    }

    /// 阻塞探测集中在这里，**不在主 actor 上跑**.
    private nonisolated static func probe() -> Snapshot {
        var s = Snapshot()
        // 网络（NWPathMonitor 等首个回调，最多 0.5s）
        s.wifiSatisfied = CellularTunnelManager.isWiFiSatisfied(timeout: 0.5)
        // 隧道
        s.utunAvailable = LocalDevVPN.isConnected
        s.targetIP = LocalDevVPN.targetIP
        s.candidatePeers = LocalDevVPN.candidateTunnelPeers()
        s.targetReachable = LocalDevVPN.isReachable(ip: s.targetIP, timeout: 1.0)
        s.anyPeerReachable = LocalDevVPN.isAnyCandidateReachable(timeout: 0.5)
        // 对端来源分布
        let sources = LocalDevVPN.peerSourceReport()
        s.utunPeerCount = sources.utunPeerCount
        s.routePeerCount = sources.routeCount
        s.overridePeer = sources.override
        // 配对文件
        // 注意：`TunnelContext.shared` 是 ObjC 类属性（`@property (class, readonly)`），
        // Swift 侧导入为**属性**而非方法 —— 写 `shared()` 会报
        // 「cannot call value of non-function type 'TunnelContext'」.
        s.pairingFileExists = TunnelContext.shared.hasPairingFile
        // v0.3.639：真解析一次（纯内存，不建连）。
        // 原实现只查 fileExistsAtPath —— 损坏文件也打绿勾，是最误导人的盲区。
        s.pairingFileParsable = TunnelContext.shared.isPairingFileParsable
        s.pairingFileParseError = TunnelContext.shared.pairingFileParseError
        // 接口列表
        s.interfaces = LocalDevVPN.allInterfaces()
        // 隧道句柄状态 —— **只读**，绝不在这里建连.
        //
        // v0.3.620 修正：v0.3.619 曾在这里调 `ensureHeartbeat()`，两个后果都是回归：
        //   1) 诊断页「正在检查…」卡死 —— 建连最多阻塞 35s（RP 预算）；
        //   2) 主界面「一直卡在刷新中」—— 建连期间 `_tunnelConnecting = YES`，
        //      主 App 的隧道请求被 `_rejectIfConnectingWithError` 直接拒（-8）。
        // ⇒ 诊断只读状态；握手交给真正的业务路径.
        s.tunnelActive = TunnelContext.shared.hasActiveTunnel
        s.tunnelConnecting = TunnelContext.shared.isConnecting
        // 只读已有 ivar，不建连（与上面两行同款）。
        s.lastTunnelError = TunnelContext.shared.lastTunnelError?.localizedDescription
        return s
    }

    /// 按 SideStore Health Check 语言输出的诊断行.
    var rows: [Row] {
        let s = snapshot
        var result: [Row] = []
        result.append(Row("网络", s.wifiSatisfied ? "Wi-Fi 已连接" : "无 Wi-Fi", s.wifiSatisfied))
        result.append(Row("utun 隧道接口", s.utunAvailable ? "存在" : "不存在", s.utunAvailable))
        result.append(Row(
            "目标对端可达（\(s.targetIP):49152）",
            s.targetReachable ? "可达" : "不可达",
            s.targetReachable))
        if s.candidatePeers.count > 1 {
            result.append(Row(
                "任一候选可达",
                s.anyPeerReachable ? "可达（\(s.candidatePeers.joined(separator: " / "))）" : "全部不可达",
                s.anyPeerReachable, optional: true))
        }
        // 对端来源：区分「没有 utun」与「枚举方式没覆盖到」—— 这是 2026-10-17 真机暴露的盲点.
        let sourceText = "override=\(s.overridePeer ?? "无") / utun 对端=\(s.utunPeerCount) / 路由表=\(s.routePeerCount)"
        result.append(Row(
            "对端来源",
            sourceText,
            (s.utunPeerCount + s.routePeerCount) > 0, optional: true))
        // v0.3.639：把「文件在」与「能解析」分成两件事显示。
        // 损坏 / 格式不对的文件，前者绿勾后者红叉 —— 这才是可定位的。
        if s.pairingFileExists {
            if s.pairingFileParsable {
                result.append(Row("配对文件", "已导入（可解析）", true))
            } else {
                result.append(Row("配对文件", "文件存在但无法解析：\(s.pairingFileParseError ?? "未知原因")", false))
            }
        } else {
            result.append(Row("配对文件", "未导入", false))
        }
        // 隧道句柄状态（只读）：分清「没连过」「正在连」「已就绪」.
        let tunnelDetail: String
        if s.tunnelActive {
            tunnelDetail = "已就绪（句柄可用）"
        } else if s.tunnelConnecting {
            tunnelDetail = "正在建连…"
        } else {
            tunnelDetail = "未建立（回主界面刷新一次才会建）"
        }
        result.append(Row("隧道句柄", tunnelDetail, s.tunnelActive))
        // v0.3.639：把真实失败原因显示出来。
        // 在此之前，诊断页只能显示现象（不可达 / 未建立），用户永远拿不到「为什么」——
        // 这是「完全连不上但说不清原因」的直接成因。
        if let lastError = s.lastTunnelError, !lastError.isEmpty {
            result.append(Row("最近一次失败原因", lastError, false, optional: true))
        }
        result.append(Row("本机 Anisette", s.anisetteStatus, s.anisetteReady, optional: true))
        return result
    }
}

/// 诊断页：全宽行 + 图标判定，照 SideStore Health CheckView 结构.
struct TunnelHealthCheckView: View {
    @StateObject private var viewModel = TunnelHealthViewModel()

    var body: some View {
        List {
            if !viewModel.loaded {
                // v0.3.650：加载态**整页居中**。
                //
                // 原实现是一个孤立 Section，转圈图标停在页面顶部、下面大片空白，
                // 用户第一眼以为页面坏了。当时的做法是 ZStack + Color.clear 手写居中；
                // 现收口到 AppLoadingRow 的 .page 档（整页居中：大圈 + 标题），
                // Section 不带头部 / 行背景透明 / 无行内边距这三条保持不变。
                // minHeight 320 是 v0.3.650 的产物：List 行若只按内容高度排，
                // 转圈仍会贴在页面顶部 —— 保留同值，页面高度不变.
                Section {
                    AppLoadingRow(title: "正在检查…", level: .page)
                        .frame(maxWidth: .infinity, minHeight: 320)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
            } else {
                Section(header: Text("诊断结果")) {
                    ForEach(viewModel.rows) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title).font(.body)
                                Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            statusIcon(row)
                        }
                    }
                }

                Section(header: Text("候选对端")) {
                    if viewModel.snapshot.candidatePeers.isEmpty {
                        // v0.3.679：裸 Text 空态 → 统一卡片（同上，区块自带 Section 头）。
                        InfoActionCard(icon: "antenna.radiowaves.left.and.right.slash",
                                       title: "无候选对端",
                                       message: "既没枚举到 utun 对端，也没从路由表读到对端地址，请确认隧道已建立.")
                    } else {
                        ForEach(viewModel.snapshot.candidatePeers, id: \.self) { peer in
                            HStack {
                                Text(peer).font(.system(.body, design: .monospaced))
                                Spacer()
                                if peer == viewModel.snapshot.targetIP {
                                    Text("当前目标").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section(header: Text("网络接口")) {
                    if viewModel.snapshot.interfaces.isEmpty {
                        // v0.3.679：裸 Text 空态 → 统一卡片（本区块已有 Section 头，故直接嵌 InfoActionCard，
                        // 不再套 AppStateSection —— 后者自带 Section，嵌进 Section 是非法的 List 结构）。
                        InfoActionCard(icon: "network.slash",
                                       title: "未枚举到网络接口",
                                       message: "设备上没有可用的 utun 或 Wi-Fi 接口，通常是 VPN 描述文件未生效.")
                    } else {
                        ForEach(viewModel.snapshot.interfaces) { iface in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(iface.name).fontWeight(.semibold)
                                    if iface.isPointToPoint {
                                        // Step 3 批 6-C：手写胶囊收编到共享 `SizePill` 的 `.tiny` 档（caption2 + 6 / 1）；
                                        // 水平内边距 5（非档位默认 6）、字重 `.medium`、底色 15%（默认 12%）三项均用覆盖项钉住.
                                        SizePill(text: "P2P",
                                                 tint: AppTheme.categorySettings,
                                                 level: .tiny,
                                                 horizontalPadding: 5,
                                                 weight: .medium,
                                                 fillOpacity: 0.15)
                                    }
                                    Spacer()
                                    Text(iface.isIPv4 ? "IPv4" : "IPv6")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(iface.address)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if let peer = iface.peer {
                                    Text("对端 \(peer)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Button("重新检查") {
                    Task { await viewModel.refresh() }
                }
            }
        }
        .navigationTitle("连接诊断")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.refresh() }
    }

    @ViewBuilder
    private func statusIcon(_ row: TunnelHealthViewModel.Row) -> some View {
        if let satisfied = row.satisfied {
            if satisfied {
                Image(systemName: "checkmark.circle.fill").foregroundColor(AppTheme.success).font(.title3)
            } else if row.optional {
                // 可选项失败不阻塞主流程：橙色减号，与 SideStore 的呈现一致.
                Image(systemName: "minus.circle.fill").foregroundColor(AppTheme.pending).font(.title3)
            } else {
                Image(systemName: "xmark.circle.fill").foregroundColor(AppTheme.danger).font(.title3)
            }
        } else {
            Image(systemName: "questionmark.circle.fill").foregroundColor(AppTheme.unselected).font(.title3)
        }
    }
}
