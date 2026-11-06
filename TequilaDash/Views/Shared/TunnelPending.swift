import SwiftUI

// 判据：隧道未就绪不是错误，是「待发」——功能挂起并订阅就绪翻转，VPN 一开当场自动续跑；
// 禁止终态报错要用户手动重试、禁止定时重试、禁止任何线程被隧道调用同步阻塞.
// 本文件只放三条口径里可复用的部分，「续跑哪一个动作」仍由各页面自己决定：
//   1. TunnelPending.isPending(_:) —— catch 到的错误是不是隧道闸门快速失败；
//   2. TunnelPendingRow —— 待发态的中性展示（.secondary，不给重试按钮，绝不用 danger）；
//   3. View.onTunnelReady —— 挂在 body 上，TunnelReadiness 的 isReady 翻 true 当场回调，零定时器.

/// 隧道未就绪的统一判据与文案.
enum TunnelPending {
    /// 用户可见文案：与 Engine/SecurityScanner.swift:416「等待 LocalDevVPN 隧道（开启后自动复检本项）」同口径，
    /// 这里把「复检本项」泛化成「自动继续」，因为页面侧续跑的是整个动作而不止一项检查.
    static let copy = "等待 LocalDevVPN 隧道（开启后自动继续）"

    /// 隧道未就绪的**全部**来源（规则 31 要求覆盖完整，只认一种就会把别的页留在终态报错）：
    /// 1. TunnelGate.guardReady() 抛的 TunnelReadinessError —— 11 处 createTunnel 第一行都调它，类型原样上抛到视图层；
    /// 2. AppDiscoveryError.heartbeatFailed（Engine/AppDiscovery.swift:37）—— 应用列表族走 ensureHeartbeat，
    ///    VPN 没开时它先炸，空间回收整页灰就是这条；
    /// 3. IconCleanupService.CleanupError.tunnelFailed（Engine/IconCleanupService.swift:79）—— 图标清理自己直连，不等闸门.
    /// 2 与 3 只在就绪位还没翻到 ready 时算待发：已经 ready 还失败就是真故障，必须照旧上屏，不许挂成永久待发.
    static func isPending(_ error: Error) -> Bool {
        if error is TunnelReadinessError { return true }
        // 用 TunnelGate 的 NSLock 缓存读（同一面就绪旗）：isPending 会被非隔离上下文调到，
        guard !TunnelGate.isReady else { return false }
        if let e = error as? AppDiscoveryError, case .heartbeatFailed = e { return true }
        if let e = error as? IconCleanupService.CleanupError, case .tunnelFailed = e { return true }
        return false
    }

    /// 错误转文案：隧道未就绪走中性待发文案，其余错误保持原样（给只在非 UI 路径用的场景）.
    static func describe(_ error: Error) -> String {
        isPending(error) ? copy : error.localizedDescription
    }

    /// **同一条**卡点链（弹卡 → 关蜂窝 → 断网窗口内建链 → 成功置真），本行随即由 onTunnelReady
    /// 当场消失并续跑；Wi-Fi / 已就绪 / 已离线都不动作（判据在 kickPassiveGate 内）.
    ///
    /// 标签取 detail 的首个短句（「读取设备应用，然后扫描可回收空间」→「读取设备应用」）：
    /// 弹窗把它当导航标题，整句太长；同时它也是「同一页面只踢一次」的去重键.
    static func kickCellularGate(for detail: String?) {
        let head = (detail ?? "本页等待隧道").split(separator: "，").first.map(String.init) ?? "本页等待隧道"
        CellularGlitchCoordinator.shared.kickPassiveGate(label: head)
    }
}

/// 待发态的行内展示：转圈 + 中性文案，语义是「还在等」，不是「失败」.
/// 复用 AppLoadingRow 的取色（标题 secondary / detail tertiary），不新增 token、不碰 DesignSystem.
struct TunnelPendingRow: View {
    /// 挂在队列里的动作（例如「读取 AFC 目录」），显示在文案下方；可省.
    var detail: String? = nil
    /// 档位：列表内一行用 inline，卡片内整块用 block.
    var level: AppLoadingRow.Level = .inline

    var body: some View {
        AppLoadingRow(title: TunnelPending.copy, detail: detail, level: level)
            // 走心跳的页面（空间回收/应用列表）挂在待发位上没人建隧道，4G 下永久停在这行.
            .onAppear { TunnelPending.kickCellularGate(for: detail) }
    }
}

extension View {
    /// 隧道就绪翻转即续跑：只在翻到 ready 时触发，不轮询、不发初始值、不带定时器.
    /// 调用方自己在 action 里判「本页是否有待发动作」，没有就 no-op，避免每次就绪都重跑.
    func onTunnelReady(_ action: @escaping () -> Void) -> some View {
        modifier(TunnelReadyWatcher(action: action))
    }
}

/// 双保险触发：① 就绪翻转（原始语义）；② 回到前台时若已就绪补一脚 ——
/// 后台期间发生的翻转可能只留下最新值，页面没有其它状态变化就不重算；
/// action 由调用方自带幂等守卫，重复触发是 no-op.
private struct TunnelReadyWatcher: ViewModifier {
    let action: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content
            .onReceive(TunnelReadiness.shared.$isReady) { ready in
                if ready { action() }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                if TunnelGate.isReady {
                    action()
                } else {
                    // 规则 37：回前台但旗标还没翻（App 挂起期间探测停摆）→ 立即加拍探测，
                    // 不等下一个 1.5 秒节拍；翻转会经 @ObservedObject/事件双路通知页面.
                    Task { @MainActor in await TunnelReadiness.shared.probeOnce() }
                }
            }
    }
}
