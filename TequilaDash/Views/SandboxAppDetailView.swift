//
//  SandboxAppDetailView.swift
//  TequilaDash
//
//  单个容器的详情：包体与可写目录的元数据、目录浏览、可写目录建/重建、删除容器.
//  本阶段只做容器管理与数据隔离，不做容器内启动（启动需要未加密包 + JIT 或 JITLess 重签，另案）.
//

import SwiftUI
import UIKit

struct SandboxAppDetailView: View {
    let app: SandboxApp
    /// 目录发生变化（新建 / 重建 / 删除）后回调，让列表页重新扫描.
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var dataExists = false
    @State private var busy = false
    @State private var showBrowser = false
    @State private var showShare = false
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            identitySection
            storageSection
            actionsSection
            notesSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppTheme.surfaceBase)
        .navigationTitle(app.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toastHost()
        .onAppear { refreshDataState() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        AppHaptics.tap()
                        showShare = true
                    } label: { Label("分享包体", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) {
                        AppHaptics.tap()
                        showDeleteConfirm = true
                    } label: { Label("删除容器", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(AppTheme.accent)
                }
            }
        }
        .sheet(isPresented: $showBrowser) { browserSheet }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [URL(fileURLWithPath: app.appPath)])
        }
        .confirmationDialog("删除 \(app.displayName) 的容器？",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("删除包体与可写目录", role: .destructive) { removeContainer() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("包体与可写目录会一起清掉，操作不可恢复.")
        }
        .overlay {
            if busy { AppBusyOverlay(title: "正在处理…", style: .card) }
        }
    }

    // MARK: - 身份

    private var identitySection: some View {
        Section {
            card(title: "容器", symbol: "square.stack.3d.up.fill", tint: AppModule.store.tint) {
                HStack(alignment: .top, spacing: 14) {
                    SandboxAppIconView(bundleID: app.id, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.displayName)
                            .font(AppFont.title3)
                            .lineLimit(2)
                        Text(app.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 6)
                infoRow("版本", app.bundleVersion ?? "未知")
                infoRow("可执行文件", app.executable ?? "未知")
                infoRow("包体大小", app.sizeText)
                infoRow("安装时间", app.installedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "未知")
            }
        }
    }

    // MARK: - 目录

    private var storageSection: some View {
        Section {
            card(title: "目录", symbol: "folder", tint: AppTheme.categoryDevice) {
                pathRow(title: "包体", path: app.appPath)
                pathRow(title: "可写目录", path: app.dataPath ?? "尚未创建")
                HStack(spacing: 8) {
                    Text("可写目录状态")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    SizePill(text: dataExists ? "已就绪" : "未创建",
                             tint: dataExists ? AppTheme.success : AppTheme.pending,
                             level: .compact)
                }
                .padding(.top, 10)
            }
        }
    }

    // MARK: - 操作

    private var actionsSection: some View {
        Section {
            card(title: "操作", symbol: "wrench.and.screwdriver", tint: AppTheme.accent) {
                Button {
                    AppHaptics.tap()
                    showBrowser = true
                } label: {
                    Text("浏览包体目录").frame(maxWidth: .infinity)
                }
                .buttonStyle(TintedButtonStyle(tint: AppTheme.categoryDevice))
                .padding(.bottom, 10)
                if dataExists {
                    Button {
                        AppHaptics.tap()
                        rebuildDataHome()
                    } label: {
                        Text("重建可写目录").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TintedButtonStyle(tint: AppTheme.accent))
                } else {
                    Button {
                        AppHaptics.tap()
                        createDataHome()
                    } label: {
                        Text("创建可写目录").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TintedButtonStyle(tint: AppTheme.accent))
                }
            }
        }
    }

    // MARK: - 说明

    private var notesSection: some View {
        Section {
            card(title: "说明", symbol: "info.circle", tint: AppTheme.accent) {
                Text("可写目录相当于容器自己的 Documents：包体保持原样，运行期写入都落在隔离目录里，删容器时一起清掉.")
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("本阶段只提供容器管理与目录隔离，容器内启动需要未加密包并配合 JIT 或重签，后续版本再接.")
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: - 组件

    /// 卡片容器：与 StorageDetailView 的 sectionCard 同一范式（头 10pt 间距 + cardPadding + 16 连续圆角）.
    ///
    /// 闭包放最后：Swift 的尾随闭包只能是最后一个参数，写成 `card { … } header: …` 编不过.
    private func card<Content: View>(title: String, symbol: String, tint: Color,
                                     @ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AppSectionHeader(title, symbol: symbol, tint: tint)
                .padding(.bottom, 10)
            body()
        }
        .padding(AppMetrics.cardPadding)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(AppSurface.card))
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            AppHairline()
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(value)
                    .font(AppFont.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 7)
        }
    }

    private func pathRow(title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var browserSheet: some View {
        NavigationStack {
            FileBrowserView(rootPath: app.appPath, title: "包体目录")
        }
    }

    // MARK: - 行为

    private func refreshDataState() {
        dataExists = app.hasDataHome
    }

    private func createDataHome() {
        busy = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try SandboxContainerStore.makeDataHome(for: app) }
            }.value
            busy = false
            switch outcome {
            case .success:
                AppHaptics.success()
                // dataPath 是安装期登记的，新建目录后列表要重扫才拿得到路径.
                onChange()
                ToastCenter.shared.show("已创建可写目录", seconds: 2.6)
            case .failure(let error):
                ToastCenter.shared.show(error.localizedDescription, seconds: 4.0)
            }
        }
    }

    private func rebuildDataHome() {
        busy = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    try SandboxContainerStore.resetDataHome(for: app)
                    return try SandboxContainerStore.makeDataHome(for: app)
                }
            }.value
            busy = false
            switch outcome {
            case .success:
                AppHaptics.success()
                onChange()
                ToastCenter.shared.show("可写目录已重建", seconds: 2.6)
            case .failure(let error):
                ToastCenter.shared.show(error.localizedDescription, seconds: 4.0)
            }
        }
    }

    private func removeContainer() {
        busy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                SandboxContainerStore.remove(app)
            }.value
            busy = false
            switch result {
            case .removed:
                AppHaptics.success()
                SandboxIconLoader.shared.forget(app.id)
                onChange()
                dismiss()
                ToastCenter.shared.show("已删除 \(app.displayName) 的容器", seconds: 3.0)
            case .notFound:
                onChange()
                dismiss()
                ToastCenter.shared.show("目录已不存在，登记已清理", seconds: 3.0)
            case .failed(let message):
                // 删不掉必须如实上报：报「已删除」而列表里还在是欺骗.
                ToastCenter.shared.show(message, seconds: 4.0)
            }
        }
    }
}
