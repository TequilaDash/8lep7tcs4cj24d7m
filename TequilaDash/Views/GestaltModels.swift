//
//  GestaltModels.swift
//  bad_query
//
//  从 TequilaDash/Views/GestaltView.swift 拆出（原文件 1087 行、12 个顶层声明）。
//  拆分原因：主文件把 UI 与数据类型混在一起，按「纯模型 / 编辑器 / 小组件」三刀拆开，主文件只留 GestaltView 本体。
//  本文件只装六个纯数据类型：PlistSection / PlistKey / FieldEditorRoute / AddFieldError /
//  GestaltValueType / PlistValueInfo。内部依赖只有 PlistKey→PlistSection、
//  FieldEditorRoute→PlistKey，六个类型全部本来就没有 private 前缀，搬出无需改修饰符。
//  纯搬迁、零逻辑改动：成员逐行字节原样，未改任何函数体、注释、空行或字符串；
//  import 与原文件一致（只有 import SwiftUI），未增删。
//

import SwiftUI

// MARK: - Advanced Field Editor Types

enum PlistSection: Hashable {
    case cacheExtra
    case topLevel
}

struct PlistKey: Hashable {
    let section: PlistSection
    let key: String
}

enum FieldEditorRoute: Identifiable, Hashable {
    case edit(PlistKey)
    case addCacheExtra

    var id: Self { self }
}

enum AddFieldError: LocalizedError {
    case emptyKey
    case duplicateKey(String)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "Key cannot be empty."
        case .duplicateKey(let key):
            return "Key \"\(key)\" already exists."
        }
    }
}

enum GestaltValueType: String, CaseIterable {
    case bool = "Bool"
    case integer = "Integer"
    case string = "String"
}

struct PlistValueInfo {
    let display: String
    let searchText: String

    static func info(for value: Any?) -> PlistValueInfo {
        guard let value else {
            return PlistValueInfo(display: "—", searchText: "")
        }
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            let b = n.boolValue
            return PlistValueInfo(display: b ? "true" : "false",
                                  searchText: b ? "true" : "false")
        }
        if let data = value as? Data {
            return PlistValueInfo(display: "Data (\(data.count) bytes)",
                                  searchText: "data")
        }
        if let dict = value as? [String: Any] {
            return PlistValueInfo(display: "Dict (\(dict.count) keys)",
                                  searchText: "dictionary")
        }
        if let arr = value as? [Any] {
            return PlistValueInfo(display: "Array (\(arr.count) items)",
                                  searchText: "array")
        }
        let str = "\(value)"
        return PlistValueInfo(display: str, searchText: str)
    }
}
