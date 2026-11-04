//
//  CellularLogView.swift
//  TequilaDash
//
//  v0.3.756：蜂窝开关运行日志面板（CellularSupportView 右上角入口）.
//

import SwiftUI

struct CellularLogView: View {
    @ObservedObject private var store = CellularLogStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if store.entries.isEmpty {
                Text("暂无日志. 触发一次蜂窝开关（或重启 App）后回来看.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.timeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(entry.text)
                        .font(.footnote)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("蜂窝开关日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.clear()
                } label: {
                    Label("清空", systemImage: "trash")
                }
            }
        }
    }
}
