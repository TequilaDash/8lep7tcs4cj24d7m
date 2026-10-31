import SwiftUI

/// v0.3.184：应用类型标签（应用板块列表行内）.
/// v0.3.184 7 类（细分 App Store 正版 / 共享 + 隐藏应用）.
/// v0.3.364：文案改走 `AppType.displayName`（对齐爱思；`.appStore` 兜底不再显示
/// 「AppStore」，与苹果正版同文案），并新增「越狱版」（红/粉系）.
/// 配色：品牌蓝=正版/紫=共享/橙=企业/绿=开发/橙状态=越狱/灰=系统或兜底.
struct AppTypeBadge: View {
    let type: AppType
    var compact: Bool = false

    /// 类型 → 配色（文本色 + 底色不透明度）.
    ///
    /// Step 3 批 6-B：底色由「色 + 内联 opacity」拆成「纯色 + 不透明度」两项，
    /// 与 `SizePill(tint:fillOpacity:)` 的口径对齐（该组件默认 12%）；
    /// 6 类色（accent 12% / purple 14% / orange 14% / green 14% / pending 16% /
    /// secondary 10%）逐一保留原值，不做归一，故收敛后逐类型渲染零变化.
    private var palette: (text: Color, fillOpacity: Double) {
        switch type {
        case .appStorePersonal: return (AppTheme.accent, 0.12)
        case .appStoreShared:   return (.purple,    0.14)
        case .appStore:         return (AppTheme.accent, 0.12)
        case .enterprise:       return (.orange,    0.14)
        case .development:      return (.green,     0.14)
        case .jailbroken:       return (AppTheme.pending, 0.16)
        case .hidden:           return (.secondary, 0.10)
        case .unknown:          return (.secondary, 0.10)
        }
    }

    /// Step 3 批 6-B：手写胶囊收编到共享 `SizePill`，度量靠覆盖项逐项钉住：
    /// `compact` 走 `.compact` 档（caption2 + 6 / 2），否则走 `.regular` 档并用
    /// 8 / 3 覆盖（`.regular` 的档位默认是 10 / 5，与原 8 / 3 不同）；
    /// 字重同样覆盖（compact 原为 default，即 `.regular`；否则 `.medium`）.
    var body: some View {
        let p = palette
        SizePill(text: type.displayName,
                 tint: p.text,
                 level: compact ? .compact : .regular,
                 horizontalPadding: compact ? 6 : 8,
                 verticalPadding: compact ? 2 : 3,
                 weight: compact ? .regular : .medium,
                 fillOpacity: p.fillOpacity)
            .accessibilityLabel("\(type.displayName)，\(type.subtitle)")
    }
}
