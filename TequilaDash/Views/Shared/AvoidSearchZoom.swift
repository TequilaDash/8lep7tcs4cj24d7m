import SwiftUI

/// iOS 26/27 系统搜索框一激活就把整页缩进居中圆角卡（search zoom presentation，
/// 用户截图实锤：内容带只剩 62.6% 宽、右缘露邻卡碎片）. 苹果为抑制该行为提供的
/// 官方开关是 `searchPresentationToolbarBehavior(.avoidHidingContent)`.
/// 全仓统一经由本修饰器接入（HARD-RULES 30：禁止自绘常驻搜索条；系统搜索框外观
/// 不动，只关掉缩卡），各 `.searchable` 页面在 `.searchable(...)` 之后挂 `.avoidSearchZoom()`.
struct AvoidSearchZoom: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.searchPresentationToolbarBehavior(.avoidHidingContent)
        } else {
            content
        }
    }
}

extension View {
    /// 关闭 iOS 26+ 搜索放大态（整页缩卡）；iOS 26 以下无此行为，原样返回.
    func avoidSearchZoom() -> some View {
        modifier(AvoidSearchZoom())
    }
}
