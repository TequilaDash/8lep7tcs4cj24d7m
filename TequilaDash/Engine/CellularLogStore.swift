//
//  CellularLogStore.swift
//  TequilaDash
//
//  v0.3.756：蜂窝开关运行日志（环形缓冲 200 条，CellularLogView 读取）.
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

    func log(_ text: String) {
        let entry = Entry(time: Date(), text: text)
        lock.lock()
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
