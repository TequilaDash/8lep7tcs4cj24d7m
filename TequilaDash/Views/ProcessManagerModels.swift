//
//  ProcessManagerModels.swift
//  TequilaDash
//
//  从 ProcessManagerView.swift 拆分而来：原文件 1298 行、9 个 top-level 声明，
//  拆成 4 个文件以满足「每文件 ≤ 600 行」的规模约束.
//  本文件只承载纯数据模型（ProcessAlert / ProcessEntry / ProcessControlAction / ProcessSortMode），
//  成员逐字节原样搬运，未做任何逻辑改动.
//

import SwiftUI
import Foundation
import Darwin

// MARK: - 进程模型

/// 统一的提示弹窗数据（v0.2.106：替代原先双 alert 通道）.
struct ProcessAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ProcessEntry: Identifiable {
    let pid: Int
    let executablePath: String
    /// 物理内存占用（bytes）.nil = FFI 尚未返回此字段（需 idevice crate 升级）.
    var memoryBytes: Int64? = nil

    var id: Int { pid }

    /// 格式化内存显示（MB/KB）.
    var memoryDisplay: String? {
        guard let bytes = memoryBytes, bytes > 0 else { return nil }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    /// 显示名取可执行路径末段（设备不回传友好名）.
    var displayName: String {
        let components = executablePath.split(separator: "/")
        if let last = components.last, !last.isEmpty {
            return String(last)
        }
        return "进程 \(pid)"
    }
}

// MARK: - 进程操作类型

enum ProcessControlAction: String {
    case resume
    case pause
    case kill

    /// 对应 Unix 信号.
    var signal: Int32 {
        switch self {
        case .resume: return Int32(SIGCONT)
        case .pause:  return Int32(SIGSTOP)
        case .kill:   return Int32(SIGKILL)
        }
    }

    var buttonLabel: String {
        switch self {
        case .resume: return "恢复"
        case .pause:  return "挂起"
        case .kill:   return "结束"
        }
    }

    var systemImage: String {
        switch self {
        case .resume: return "play.circle"
        case .pause:  return "pause.circle"
        case .kill:   return "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .resume: return .green
        case .pause:  return .orange
        case .kill:   return .red
        }
    }

    var progressTitle: String {
        switch self {
        case .resume: return "正在恢复进程"
        case .pause:  return "正在挂起进程"
        case .kill:   return "正在结束进程"
        }
    }

    var timeoutTitle: String {
        switch self {
        case .resume: return "恢复超时"
        case .pause:  return "挂起超时"
        case .kill:   return "结束超时"
        }
    }

    var failureTitle: String {
        switch self {
        case .resume: return "恢复失败"
        case .pause:  return "挂起失败"
        case .kill:   return "结束失败"
        }
    }

    var successTitle: String {
        switch self {
        case .resume: return "进程已恢复"
        case .pause:  return "进程已挂起"
        case .kill:   return "进程已结束"
        }
    }

    func successMessage(for pid: Int) -> String {
        switch self {
        case .resume: return "已向 PID \(pid) 发送 SIGCONT (19)."
        case .pause:  return "已向 PID \(pid) 发送 SIGSTOP (17)."
        case .kill:   return "PID \(pid) 已被终止."
        }
    }

    func timeoutMessage(for pid: Int) -> String {
        switch self {
        case .resume: return "无法确认 PID \(pid) 已恢复，请重试."
        case .pause:  return "无法确认 PID \(pid) 已挂起，请重试."
        case .kill:   return "无法确认 PID \(pid) 已结束，请重试."
        }
    }
}

// MARK: - 视图模型

/// 进程列表排序模式
enum ProcessSortMode: String, CaseIterable, Identifiable {
    case defaultOrder = "默认"
    case byName = "按名称"
    case byMemory = "按内存"
    var id: String { rawValue }
}
