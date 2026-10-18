//
//  GestaltComponents.swift
//  bad_query
//
//  从 TequilaDash/Views/GestaltView.swift 拆出（原文件 1087 行、12 个顶层声明）。
//  拆分原因：MGToggle / KeySection 是可复用的小组件，从主文件剥离，主文件只保留 GestaltView 本体。
//  本文件装两个小组件：MGToggle / KeySection。MGToggleInfoType 定义在
//  TequilaDash/Engine/MCM/GestaltEngine.swift，不在原文件内，未搬动、未重复声明。
//  纯搬迁、零逻辑改动：成员逐行字节原样，未改任何函数体、注释、空行或字符串；
//  import 与原文件一致（只有 import SwiftUI），未增删。
//  MGToggle.currentVersion() 用到 UIDevice —— 原文件就是靠 import SwiftUI 传递可见的，
//  同一 target 内 ConfigurationsView.swift / RestrictionTweaksView.swift 也是这么写的，故不加 UIKit。
//

import SwiftUI

// MARK: - MGToggle

struct MGToggle: View {
    let text: String
    var infoType: MGToggleInfoType?
    var infoMessage: String?
    var minVersion: Double = 0
    @Binding var isOn: Bool

    @State private var showingInfo = false

    var body: some View {
        Toggle(text, isOn: $isOn)
            .disabled(minVersion > 0 && currentVersion() < minVersion)
    }

    private func currentVersion() -> Double {
        Double(UIDevice.current.systemVersion) ?? 0
    }
}

// MARK: - Key Section

struct KeySection: View {
    let title: String
    let keys: [String]
    let value: (String) -> Any?
    let select: (String) -> Void

    var body: some View {
        if !keys.isEmpty {
            Section(title) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        select(key)
                    } label: {
                        HStack {
                            Text(key)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(PlistValueInfo.info(for: value(key)).display)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
