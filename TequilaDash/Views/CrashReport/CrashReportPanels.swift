import SwiftUI

/// 帧列表：序号 + 镜像名 + 位置（符号名，或「地址 + 镜像内偏移」）.
///
/// `limit` 给摘要页截断用；线程页不传，显示全部.
struct CrashFrameList: View {
    let frames: [Frame]
    let images: [BinaryImage]
    var startIndex: Int = 0
    var limit: Int? = nil

    private var visible: ArraySlice<Frame> {
        guard let limit else { return frames[...] }
        return frames.prefix(limit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.offset) { offset, frame in
                HStack(alignment: .top, spacing: AppSpacing.tight) {
                    Text("\(startIndex + offset)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(CrashFormat.imageName(frame, images: images))
                            .font(AppFont.footnote)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(CrashFormat.frameLocation(frame, images: images))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                if offset < visible.count - 1 { CrashRowSeparator() }
            }
        }
    }
}

/// 线程页：崩溃线程置顶并带徽标，点开展开帧列表与寄存器.
struct CrashThreadsPanel: View {
    let crash: CrashReport

    /// 崩溃线程（`isTriggered` 或 `faultingThreadIndex` 命中）置顶，其余按原序.
    private var orderedThreads: [ReportThread] {
        let faulting = crash.faultingThreadIndex
        return crash.threads.sorted { lhs, rhs in
            let l = lhs.isTriggered || lhs.index == faulting
            let r = rhs.isTriggered || rhs.index == faulting
            if l != r { return l }
            return lhs.index < rhs.index
        }
    }

    private func isCrashed(_ thread: ReportThread) -> Bool {
        thread.isTriggered || thread.index == crash.faultingThreadIndex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            if orderedThreads.isEmpty {
                Text("报告未包含线程堆栈.")
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(orderedThreads.enumerated()), id: \.element.index) { position, thread in
                CrashThreadRow(thread: thread,
                               crash: crash,
                               isCrashed: isCrashed(thread),
                               defaultExpanded: isCrashed(thread))
                if position < orderedThreads.count - 1 { CrashRowSeparator() }
            }
        }
    }
}

/// 单线程行：标题可点，展开帧列表与寄存器.
struct CrashThreadRow: View {
    let thread: ReportThread
    let crash: CrashReport
    let isCrashed: Bool
    var defaultExpanded: Bool = false

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: AppSpacing.tight) {
                    Text("Thread \(thread.index)")
                        .font(AppFont.footnoteEmphasis)
                        .foregroundStyle(.primary)
                    if isCrashed {
                        CrashBadge(text: "崩溃", tint: AppTheme.danger, level: .tiny)
                    }
                    if let name = thread.name, !name.isEmpty {
                        Text(name)
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let queue = thread.queue, !queue.isEmpty {
                        Text(queue)
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text("\(thread.frames.count) 帧")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thread \(thread.index)，\(thread.frames.count) 帧，\(expanded ? "已展开" : "已折叠")")

            if expanded {
                if thread.frames.isEmpty {
                    Text("无堆栈帧.")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                } else {
                    CrashFrameList(frames: thread.frames, images: crash.images)
                }
                if !thread.registers.isEmpty {
                    CrashRowSeparator()
                    CrashRegistersGrid(thread: thread, crash: crash)
                }
            }
        }
        .onAppear { expanded = defaultExpanded }
    }
}

/// 寄存器视图：名称 + 定宽十六进制值，关键寄存器附 RegisterNotes 注解.
struct CrashRegistersGrid: View {
    let thread: ReportThread
    /// 注解要查镜像区间与栈指针，需要整份 CrashReport.
    let crash: CrashReport

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: AppSpacing.tight)]

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            Text("寄存器")
                .font(AppFont.captionEmphasis)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: AppSpacing.tight) {
                ForEach(thread.registers, id: \.name) { register in
                    CrashRegisterCell(register: register, thread: thread, crash: crash)
                }
            }
        }
    }
}

/// 单寄存器：等宽值 + 可选注解行（pc / lr / sp / fp 高亮）.
struct CrashRegisterCell: View {
    let register: Register
    let thread: ReportThread
    let crash: CrashReport

    private var isKey: Bool {
        ["pc", "lr", "sp", "fp"].contains(register.name.lowercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(register.name)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(isKey ? AppTheme.accent : .secondary)
                Text(CrashFormat.paddedHex(register.value))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            if let note = RegisterNotes.note(for: register, thread: thread, in: crash),
               !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                .fill(AppSurface.inner)
        )
    }
}

/// 二进制镜像页：数量 + 逐镜像（名 / 架构 / 基址 / UUID）.
struct CrashImagesPanel: View {
    let images: [BinaryImage]

    /// 只显示前若干条，其余给计数说明（真机报告常有 200+ 镜像）.
    var limit: Int = 60

    private var visible: ArraySlice<BinaryImage> { images.prefix(limit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.offset) { index, image in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: AppSpacing.tight) {
                        Text("\(index)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                        Text(image.name)
                            .font(AppFont.footnote)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let tag = CrashFormat.imageSourceTag(image) {
                            CrashBadge(text: tag, level: .tiny)
                        }
                    }
                    HStack(spacing: AppSpacing.tight) {
                        Text(CrashFormat.paddedHex(image.base))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(CrashFormat.hex(image.size))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 6)
                        if let arch = image.arch, !arch.isEmpty {
                            Text(arch)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(image.uuid)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 5)
                if index < visible.count - 1 { CrashRowSeparator() }
            }
            if images.count > limit {
                CrashRowSeparator()
                Text("其余 \(images.count - limit) 个镜像未列出，完整清单见「原文」.")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
    }
}
