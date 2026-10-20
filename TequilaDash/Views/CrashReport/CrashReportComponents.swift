import SwiftUI

/// 崩溃分析分区卡（Xrash 式分区显示的最小容器）：
/// 头部「图标 + 标题 + 尾部件」，体部由调用方填.
/// 卡片底 / 圆角 / 内边距一律走 AppSurface.card + AppRadius.card + AppMetrics.cardPadding.
struct CrashSectionCard<Content: View>: View {
    let title: String
    var systemImage: String = "text.alignleft"
    var tint: Color = AppTheme.accent
    /// 标题右侧的计数或状态胶囊.
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.row) {
            HStack(spacing: AppSpacing.tight) {
                AppRowIcon(systemName: systemImage, tint: tint, symbolSize: 14, frameSize: 22)
                Text(title)
                    .font(AppFont.subheadlineEmphasis)
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
                if let trailing { trailing }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }
}

/// 键值行：左标签、右值.等宽值（地址 / UUID / 寄存器）走 CrashMonoValue.
struct CrashFactRow: View {
    let label: String
    let value: String
    /// 值是否等宽（地址、UUID、偏移一律 true）.
    var monospaced: Bool = false
    /// 长值是否允许换行（路径、终止描述需要换行，地址不需要）.
    var wraps: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.row) {
            Text(label)
                .font(AppFont.footnote)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced
                      ? .system(.footnote, design: .monospaced)
                      : AppFont.footnote)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(wraps ? nil : 1)
                .textSelection(.enabled)
        }
    }
}

/// 卡片内相邻行的发丝分隔.
struct CrashRowSeparator: View {
    var body: some View {
        AppHairline()
    }
}

/// 等宽文本块（签名 / 原文 / 经典全文 / vmSummary）.
struct CrashMonoBlock: View {
    let text: String
    var lines: Int? = nil

    var body: some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(lines)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 紧凑状态胶囊（崩溃徽标 / 类型标签）.
struct CrashBadge: View {
    let text: String
    var tint: Color = AppTheme.accent
    var level: SizePill.Level = .compact

    var body: some View {
        SizePill(text: text, tint: tint, level: level)
    }
}

/// 值区块：把一组键值行装进内层容器（AppSurface.inner + AppRadius.inner）.
struct CrashInnerBlock<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            content()
        }
        .padding(AppSpacing.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.inner, style: .continuous)
                .fill(AppSurface.inner)
        )
    }
}