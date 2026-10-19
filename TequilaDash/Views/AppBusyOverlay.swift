import SwiftUI

// 共享组件 · 忙碌遮罩（全屏黑幕 + 系统材质卡片 + 进度圈 + 标题）.
//
// 由 8 处逐字复制的私有实现提升而来（Step 3 批 8-A）. 提升后实现体逐字节等价，
// 默认参数即「最常见那种写法」的原值，变体站点用显式参数原样传值 ⇒ 渲染结果零变化.
//
// 已迁移：AppDetailView / DeviceControlView / FileBrowserView / LiveCleanTabView /
//         ReclaimAppView / ReclaimTabView（六处逐字相同，仅标题不同）+
//         Wallpaper/WallpaperView（同构，仅度量值不同）.
// 未迁移：CrashLogView / RingtonesView —— 它们**没有全屏黑幕层**，文案是次级样式
//         且带投影，层级与排版都不同，强行并入会改观感（详见批 8-A 报告）.

/// 忙碌遮罩：全屏黑幕 + 材质卡片 + 进度圈 + 标题.
///
/// 视觉与批 8 之前的复制块**逐像素等价**：默认值就是复制块的原值，差异站点一律显式传参.
/// 不要为「统一」而改这些值（材质档次尤其不要一律改成 ultraThin）.
struct AppBusyOverlay: View {
    /// 卡片标题.
    var title: String
    /// 黑幕不透明度（默认 0.28；WallpaperView 用 0.18）.
    var scrimOpacity: Double = 0.28
    /// 卡片材质档次（默认 regularMaterial；调用点原样是什么就传什么）.
    var material: Material = .regularMaterial
    /// 卡片圆角（默认 16；WallpaperView 用 14）.
    var radius: CGFloat = 16
    /// 卡片内纵向间距（默认 14；WallpaperView 用 12）.
    var spacing: CGFloat = 14
    /// 卡片横向内边距（默认 28；WallpaperView 用 24）.
    var horizontalPadding: CGFloat = 28
    /// 卡片纵向内边距（默认 22；WallpaperView 用 16）.
    var verticalPadding: CGFloat = 22
    /// 标题字体（默认 headline；WallpaperView 用 subheadline）.
    var titleFont: Font = .headline
    /// 进度圈缩放倍数（默认 1.15；nil = 不加 scaleEffect，即原始尺寸）.
    var progressScale: CGFloat? = 1.15

    var body: some View {
        ZStack {
            Color.black.opacity(scrimOpacity).ignoresSafeArea()
            VStack(spacing: spacing) {
                progress
                Text(title)
                    .font(titleFont)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(material, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    /// 进度圈：不加缩放时**不能**写 scaleEffect(1) —— 保持「修饰符不存在」的原始态.
    @ViewBuilder
    private var progress: some View {
        if let progressScale {
            ProgressView()
                .scaleEffect(progressScale)
        } else {
            ProgressView()
        }
    }
}
