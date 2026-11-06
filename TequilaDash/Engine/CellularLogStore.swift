//
//  CellularLogStore.swift
//  TequilaDash
//
//  蜂窝开关运行日志（环形缓冲 200 条，CellularLogView 读取）.
//  同时镜像进 LoginLogger（category .tunnelCellular），SSH 侧同样可查.
//

import Foundation
import Combine

final class CellularLogStore: ObservableObject, @unchecked Sendable {
    static let shared = CellularLogStore()
    static let capacity = 200

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        let text: String
        var timeText: String { Self.formatter.string(from: time) }
        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    @Published private(set) var entries: [Entry] = []
    private let lock = NSLock()
    private var buffer: [Entry] = []

    private init() {}

    /// 同文去重窗口：10 秒内逐字相同的日志只记首条 ——
    /// 建隧道调用点有 28 处，闸门类文案会反复命中，不去重会把 200 条环形刷穿.
    private static let dedupeWindow: TimeInterval = 10

    func log(_ text: String) {
        let entry = Entry(time: Date(), text: text)
        lock.lock()
        if let last = buffer.last, last.text == text,
           entry.time.timeIntervalSince(last.time) < Self.dedupeWindow {
            lock.unlock()
            return
        }
        buffer.append(entry)
        if buffer.count > Self.capacity {
            buffer.removeFirst(buffer.count - Self.capacity)
        }
        lock.unlock()
        let snapshotText = "[CellularLog] " + text
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries.append(entry)
            if self.entries.count > Self.capacity {
                self.entries.removeFirst(self.entries.count - Self.capacity)
            }
        }
        LoginLogger.shared.log(snapshotText, category: .tunnelCellular)
    }

    func clear() {
        lock.lock(); buffer.removeAll(); lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.entries = [] }
    }
}
