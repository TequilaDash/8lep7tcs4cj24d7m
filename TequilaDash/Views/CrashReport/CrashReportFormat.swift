import Foundation

/// 崩溃分析显示层的取值与格式化（纯函数，无 UI）.
///
/// 只做「把已解析的模型变成一行文案」，不重复解析 JSON：
/// 解析一律走 `TequilaDash/Engine/CrashReport/` 的上游搬入件（只读）.
/// 与上游共用的字段格式化（Version / OS Version）直接复用
/// `CrashTextRenderer`，避免同一个报告在两个渲染器里写出两种拼法.
enum CrashFormat {
    /// 不带前导零的十六进制（偏移、寄存器值）.
    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    /// 定宽十六进制（地址，与经典崩溃报告的列对齐一致）.
    static func paddedHex(_ value: UInt64) -> String {
        String(format: "0x%016llx", value)
    }

    /// 报告类型的中文短标签（列表行胶囊用，名词化）.
    static func kindLabel(_ kind: ReportKind) -> String {
        switch kind {
        case .crash: return "崩溃"
        case .jetsam: return "内存"
        case .panic: return "内核"
        case .hang: return "卡死"
        case .resource: return "资源"
        case .analytics: return "统计"
        case .other: return "其他"
        }
    }

    /// 页数换算成 MB（jetsam 的 rpages 口径）.
    static func megabytes(pages: UInt64, pageSize: UInt64) -> String {
        let bytes = pages &* (pageSize == 0 ? 16384 : pageSize)
        return "\(bytes / (1024 * 1024)) MB"
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    /// 运行时长：秒 →「1h 23m」「5m 12s」「42s」，只留最高两位.
    static func uptime(_ seconds: TimeInterval?) -> String? {
        guard let seconds else { return nil }
        let total = Int(seconds)
        guard total >= 0 else { return nil }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(rest)s" }
        return "\(rest)s"
    }

    /// `Process [pid]`；无名时返回空串.
    static func process(_ name: String, pid: Int32?) -> String {
        pid.map { "\(name) [\($0)]" } ?? name
    }

    // MARK: 帧

    /// 帧所属镜像名；报告没写 imageIndex 或越界时为「?」.
    static func imageName(_ frame: Frame, images: [BinaryImage]) -> String {
        images.image(for: frame)?.name ?? "?"
    }

    /// 帧的位置行：有符号名走符号，没符号走「地址 + 镜像内偏移」.
    /// 上游符号化未接入前先显示偏移，已比整块文本可读.
    static func frameLocation(_ frame: Frame, images: [BinaryImage]) -> String {
        if let symbol = frame.symbol {
            let base = "\(symbol) + \(frame.symbolLocation ?? 0)"
            if let file = frame.sourceFile, let line = frame.sourceLine {
                return "\(base) (\(file):\(line))"
            }
            return base
        }
        return "\(paddedHex(frame.address)) + \(hex(frame.imageOffset))"
    }

    /// 镜像来源标记（S = 共享缓存，P = 进程，A = 绝对）.
    static func imageSourceTag(_ image: BinaryImage) -> String? {
        guard let source = image.source, !source.isEmpty else { return nil }
        switch source {
        case "S": return "共享缓存"
        case "P": return "进程"
        case "A": return "绝对"
        default: return source
        }
    }

    // MARK: 与上游渲染器共用的拼法

    /// `0.3.8 (62)`.
    static func version(_ process: ProcessDetails) -> String? {
        CrashTextRenderer.version(process)
    }

    /// `iPhone OS 26.6.1 (23G83)`.
    static func osVersion(_ crash: CrashReport) -> String? {
        CrashTextRenderer.osVersion(crash)
    }
}
