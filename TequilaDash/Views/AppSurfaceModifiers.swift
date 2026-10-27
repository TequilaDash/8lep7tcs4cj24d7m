import SwiftUI

/// Step 3 批 8-B / 8-C：把「阴影」与「胶囊毛玻璃」这两类**分散的原始写法**
/// 收敛到 DesignSystem 已有的 token 上（AppShadow / 与 appGlass 同源的 material）.
///
/// 为什么单开一个文件、不改 `DesignSystem.swift`：
/// `DesignSystem.swift` 是本批其它成员的写域，且本批做的是「调用点接 token」，
/// 不是改 token 本身。这里**只读引用** `AppShadow.card(_:)` / `AppShadow.raised(_:)`
/// 及其半径与偏移常量，`DesignSystem.swift` 一行未动.
///
/// 为什么 `appGlassCapsule()` 不复用 `appGlass(radius:)`：
/// `AppGlassBackground.body` 的形状**硬编码**为
/// `RoundedRectangle(cornerRadius:style:.continuous)`，传不进 `Capsule`。
/// 故按「方案 β」另给一个 Capsule 形状的毛玻璃口：材质仍取 `.ultraThinMaterial`
/// （与 `appGlass` 同源），不新造第二套材质语言.
///
/// 只新增 `View` extension 方法，**不新增顶层类型、不改既有函数签名**
/// （本机只有 `swiftc -parse`，查不出类型错 / 缺 return / 跨结构体引用成员）.
extension View {
    /// 卡片投影（值语义 = `AppShadow.card`）.
    ///
    /// 浅色：黑 6% / 深色：黑 35%，radius 8 / y 2（判据见 `AppShadow` 定义处）。
    /// v0.3.721 起深色不再取 `.clear` —— 只靠 0.5pt 描边撑卡片边界观感偏平。
    /// 调用方须先取 `@Environment(\.colorScheme)` 再传入，视图才能在明暗切换时重算.
    func appCardShadow(_ colorScheme: ColorScheme) -> some View {
        shadow(color: AppShadow.card(colorScheme),
               radius: AppShadow.cardRadius,
               x: 0,
               y: AppShadow.cardY)
    }

    /// 浮层投影（值语义 = `AppShadow.raised`）：浅色黑 18% / 深色黑 55%，
    /// radius 12 / y 4。用于悬浮、拖拽中的元素（如底部临时提示条）.
    func appRaisedShadow(_ colorScheme: ColorScheme) -> some View {
        shadow(color: AppShadow.raised(colorScheme),
               radius: AppShadow.raisedRadius,
               x: 0,
               y: AppShadow.raisedY)
    }

    /// `Capsule` 形状的毛玻璃底：与 `appGlass(radius:)` 同材质（`.ultraThinMaterial`），
    /// 只有形状不同 —— 承载胶囊形浮层（toast / 底部提示条）.
    ///
    /// 用法：`.appGlassCapsule()`；需要描边时在调用点自行
    /// `.overlay(Capsule().stroke(...))`（与本口同源，本口不代管描边）.
    func appGlassCapsule() -> some View {
        background(.ultraThinMaterial, in: Capsule())
    }
}
