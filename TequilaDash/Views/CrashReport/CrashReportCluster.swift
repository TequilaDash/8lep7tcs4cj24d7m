import SwiftUI

/// 同签名报告的一簇（Xrash 的 "same crash" 分组口径：异常类型 + 顶部非系统帧）.
struct CrashCluster: Identifiable {
    let signature: String
    let entries: [CrashLogService.Entry]
    var id: String { signature }

    /// 一簇内的份数.
    var count: Int { entries.count }

    /// 卡片副标题：签名首行去掉帧分隔符后截断，完整签名见卡片体.
    var headline: String {
        let line = signature.split(separator: "\n", omittingEmptySubsequences: false).first
            .map(String.init) ?? signature
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }
}

/// 由「路径 → 签名」映射装配分组：按份数降序、同数按签名字典序.
enum CrashClusterBuilder {
    static func build(signatures: [String: String], entries: [CrashLogService.Entry]) -> [CrashCluster] {
        var grouped: [String: [CrashLogService.Entry]] = [:]
        for entry in entries {
            guard let signature = signatures[entry.path] else { continue }
            grouped[signature, default: []].append(entry)
        }
        return grouped.map { CrashCluster(signature: $0.key, entries: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.signature < rhs.signature
            }
    }

    /// 路径 → 同簇份数，供列表行 ×N 徽标.
    static func counts(byPath clusters: [CrashCluster]) -> [String: Int] {
        var map: [String: Int] = [:]
        for cluster in clusters {
            for entry in cluster.entries { map[entry.path] = cluster.count }
        }
        return map
    }
}

/// 聚类结果页：一簇一张卡，行内文件名可点击直接进预览.
struct CrashClusterListView: View {
    let clusters: [CrashCluster]
    let onSelect: (CrashLogService.Entry) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                Text("按崩溃签名归组：同簇报告指向同一缺陷，共 \(clusters.count) 簇 / \(clusters.reduce(0) { $0 + $1.count }) 份.")
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(clusters) { cluster in
                    clusterCard(cluster)
                }
            }
            .padding(AppSpacing.row)
        }
        .background(AppSurface.page)
        .navigationTitle("崩溃聚类")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func clusterCard(_ cluster: CrashCluster) -> some View {
        CrashSectionCard(title: "\(cluster.count) 份",
                         systemImage: cluster.count > 1 ? "square.stack.3d.up.fill" : "square.stack.3d.up",
                         tint: AppTheme.categoryHealth,
                         trailing: AnyView(CrashBadge(text: "×\(cluster.count)", level: .tiny))) {
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                CrashMonoBlock(text: cluster.signature, lines: 3)
                CrashRowSeparator()
                ForEach(cluster.entries) { entry in
                    entryRow(entry)
                    if entry.id != cluster.entries.last?.id { CrashRowSeparator() }
                }
            }
        }
    }

    private func entryRow(_ entry: CrashLogService.Entry) -> some View {
        Button {
            onSelect(entry)
        } label: {
            HStack(alignment: .top, spacing: AppSpacing.row) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(AppFont.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let detail = CrashFormat.date(entry.modified) {
                        Text("\(detail) · \(CrashFormat.size(entry.size))")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
