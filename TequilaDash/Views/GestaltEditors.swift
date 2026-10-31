//
//  GestaltEditors.swift
//  bad_query
//
//  从 TequilaDash/Views/GestaltView.swift 拆出（原文件 1087 行、12 个顶层声明）。
//  拆分原因：三个编辑视图与主视图无耦合，独立成文件，主文件只保留 GestaltView 本体。
//  本文件装三个编辑视图：AdvancedGestaltEditor / ValueEditor / AddCacheExtraFieldEditor。
//  它们只引用 GestaltModels.swift 的模型类型与 BQMobileGestaltModel，不触碰 GestaltView 成员，
//  因此内部 private 成员（cacheExtraKeys / filtered / saveValue 等）原样保留、无需改动。
//  纯搬迁、零逻辑改动：成员逐行字节原样，未改任何函数体、注释、空行或字符串；
//  import 与原文件一致（只有 import SwiftUI），未增删。
//

import SwiftUI

// MARK: - Advanced Gestalt Editor

struct AdvancedGestaltEditor: View {
    @Bindable var model: BQMobileGestaltModel

    @State private var searchText = ""
    @State private var activeEditor: FieldEditorRoute?

    private var cacheExtraKeys: [String] {
        let cacheExtra = model.mgDict["CacheExtra"] as? NSMutableDictionary
        let keys = cacheExtra?.allKeys as? [String] ?? []
        return filtered(keys, section: .cacheExtra)
    }

    private var topLevelKeys: [String] {
        let keys = (model.mgDict.allKeys as? [String] ?? [])
            .filter { $0 != "CacheExtra" }
        return filtered(keys, section: .topLevel)
    }

    var body: some View {
        List {
            if model.loaded {
                KeySection(
                    title: "CacheExtra",
                    keys: cacheExtraKeys,
                    value: { value(for: PlistKey(section: .cacheExtra, key: $0)) },
                    select: { activeEditor = .edit(PlistKey(section: .cacheExtra, key: $0)) }
                )

                KeySection(
                    title: "Top Level",
                    keys: topLevelKeys,
                    value: { value(for: PlistKey(section: .topLevel, key: $0)) },
                    select: { activeEditor = .edit(PlistKey(section: .topLevel, key: $0)) }
                )
            }
        }
        .navigationTitle("Advanced Field Editor")
        .searchable(text: $searchText, prompt: "Search key or value")
        .avoidSearchZoom()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    activeEditor = .addCacheExtra
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add CacheExtra Field")
                .disabled(!model.loaded || model.isApplying)

                Button("Save") { model.apply() }
                    .fontWeight(.semibold)
                    .disabled(!model.isDirty || model.isApplying)
            }
        }
        .sheet(item: $activeEditor) { editor in
            Group {
                switch editor {
                case .edit(let key):
                    ValueEditor(
                        key: key.key,
                        initialValue: value(for: key),
                        save: { update($0, for: key) },
                        delete: key.section == .cacheExtra
                            ? { deleteCacheExtraField(key.key) }
                            : nil
                    )
                case .addCacheExtra:
                    AddCacheExtraFieldEditor(save: addCacheExtraField)
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func filtered(_ keys: [String], section: PlistSection) -> [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return keys }

        return keys.filter { key in
            let reference = PlistKey(section: section, key: key)
            let info = PlistValueInfo.info(for: value(for: reference))
            return key.localizedCaseInsensitiveContains(query)
                || info.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    private func value(for key: PlistKey) -> Any? {
        switch key.section {
        case .cacheExtra:
            let cacheExtra = model.mgDict["CacheExtra"] as? NSMutableDictionary
            return cacheExtra?[key.key]
        case .topLevel:
            return model.mgDict[key.key]
        }
    }

    private func update(_ value: Any, for key: PlistKey) {
        switch key.section {
        case .cacheExtra:
            let cacheExtra = model.mgDict["CacheExtra"] as? NSMutableDictionary
                ?? NSMutableDictionary()
            model.mgDict["CacheExtra"] = cacheExtra
            cacheExtra[key.key] = value
        case .topLevel:
            model.mgDict[key.key] = value
        }
        model.isDirty = true
    }

    private func addCacheExtraField(key: String, value: Any) throws {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw AddFieldError.emptyKey
        }
        let cacheExtra = model.mgDict["CacheExtra"] as? NSMutableDictionary
            ?? NSMutableDictionary()
        model.mgDict["CacheExtra"] = cacheExtra
        guard cacheExtra[normalizedKey] == nil else {
            throw AddFieldError.duplicateKey(normalizedKey)
        }
        cacheExtra[normalizedKey] = value
        model.isDirty = true
    }

    private func deleteCacheExtraField(_ key: String) {
        let cacheExtra = model.mgDict["CacheExtra"] as? NSMutableDictionary
        cacheExtra?.removeObject(forKey: key)
        model.isDirty = true
    }
}

// MARK: - Value Editor

struct ValueEditor: View {
    let key: String
    let initialValue: Any?
    let save: (Any) -> Void
    let delete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var valueType: GestaltValueType = .integer
    @State private var boolValue = false
    @State private var intValue: Int = 0
    @State private var stringValue: String = ""
    @State private var isComplex = false
    @State private var complexDisplay = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("键") {
                    Text(key)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                Section("值") {
                    if isComplex {
                        Text(complexDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Type", selection: $valueType) {
                            ForEach(GestaltValueType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        switch valueType {
                        case .bool:
                            Toggle("Enabled", isOn: $boolValue)
                        case .integer:
                            TextField("值", value: $intValue, format: .number)
                                .keyboardType(.numberPad)
                        case .string:
                            TextField("值", text: $stringValue)
                                .autocorrectionDisabled()
                        }
                    }
                }

                if let delete {
                    Section {
                        Button("Delete Field", role: .destructive) {
                            delete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Edit Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveValue() }
                        .disabled(isComplex)
                }
            }
        }
        .onAppear { configureForInitialValue() }
    }

    private func configureForInitialValue() {
        guard let v = initialValue else {
            valueType = .integer
            intValue = 0
            return
        }
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            valueType = .bool
            boolValue = n.boolValue
        } else if let i = v as? Int {
            valueType = .integer
            intValue = i
        } else if let n = v as? NSNumber {
            valueType = .integer
            intValue = n.intValue
        } else if let s = v as? String {
            valueType = .string
            stringValue = s
        } else if let data = v as? Data {
            isComplex = true
            complexDisplay = "Data (\(data.count) bytes) — not editable here"
        } else if let dict = v as? [String: Any] {
            isComplex = true
            complexDisplay = "Dictionary (\(dict.count) keys) — not editable here"
        } else if let arr = v as? [Any] {
            isComplex = true
            complexDisplay = "Array (\(arr.count) items) — not editable here"
        } else {
            isComplex = true
            complexDisplay = "\(v)"
        }
    }

    private func saveValue() {
        let value: Any
        switch valueType {
        case .bool:
            value = boolValue ? 1 : 0
        case .integer:
            value = intValue
        case .string:
            value = stringValue
        }
        save(value)
        dismiss()
    }
}

// MARK: - Add CacheExtra Field Editor

struct AddCacheExtraFieldEditor: View {
    let save: (String, Any) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var valueType: GestaltValueType = .integer
    @State private var boolValue = true
    @State private var intValue = 1
    @State private var stringValue = ""
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("键") {
                    TextField("键", text: $key)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("值") {
                    Picker("Type", selection: $valueType) {
                        ForEach(GestaltValueType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    switch valueType {
                    case .bool:
                        Toggle("Enabled", isOn: $boolValue)
                    case .integer:
                        TextField("值", value: $intValue, format: .number)
                            .keyboardType(.numberPad)
                    case .string:
                        TextField("值", text: $stringValue)
                            .autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle("Add CacheExtra Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addField() }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func addField() {
        let value: Any
        switch valueType {
        case .bool:
            value = boolValue ? 1 : 0
        case .integer:
            value = intValue
        case .string:
            value = stringValue
        }
        do {
            try save(key, value)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
