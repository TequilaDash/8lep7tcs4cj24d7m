import SwiftUI

/// Filza-style hex dump with optional in-place byte editing for files under 512 KB.
struct HexEditorView: View {
    @ObservedObject var vm: FileViewerViewModel
    @State private var editOffset: Int?
    @State private var editValue = ""

    private let columns = 8

    var body: some View {
        VStack(spacing: 0) {
            if vm.truncated {
                Text("仅显示前 512 KB 的十六进制预览.超过此大小的文件不可保存.")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.12))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(stride(from: 0, to: vm.bytes.count, by: columns)), id: \.self) { start in
                        HexRow(
                            offset: start,
                            bytes: Array(vm.bytes[start..<min(start + columns, vm.bytes.count)]),
                            columns: columns
                        ) { tapped in
                            guard !vm.truncated else { return }
                            editOffset = tapped
                            if tapped < vm.bytes.count {
                                editValue = String(format: "%02X", vm.bytes[tapped])
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
        }
        .background(Color(UIColor.systemBackground))
        .alert("编辑字节", isPresented: Binding(
            get: { editOffset != nil },
            set: { if !$0 { editOffset = nil } }
        )) {
            TextField("00–FF", text: $editValue)
                .autocapitalization(.allCharacters)
                .disableAutocorrection(true)
            Button("取消", role: .cancel) { cancelEdit() }
            Button("设置") { applyEdit() }
        } message: {
            if let hint = editHint {
                Text(hint)
            } else if let offset = editOffset {
                Text("偏移 \(String(format: "0x%08X", offset))")
            }
        }
    }

    /// 编辑框的行内提示：只在「已经输入、但格式不合法」时给出，空框不打扰.
    private var editHint: String? {
        guard editOffset != nil else { return nil }
        let text = editValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, Self.hexByteValue(text) == nil else { return nil }
        return "需为 2 位十六进制，如 0A 或 FF."
    }

    /// 单个字节的 hex 文本 -> UInt8。三防：空串 / 字符集 / 定长 2 位.
    ///
    /// 不能只靠 `UInt8(_:radix:16)` 判非法 —— 它的失败模式是「非 nil 的垃圾」：
    /// `UInt8("+F", radix: 16) == Some(15)`（前导正号被当成合法）、
    /// `UInt8("", radix: 16) == Some(0)`（空串被当成 0x00）。
    /// 口径对齐 BigInt.swift:52 `init?(hex:)` 与 IPADownloadCenter.swift:1830 `hexDecoded`：
    /// 先 allSatisfy { $0.isHexDigit }，再判空，再判长度；超过 2 位不静默截断，一律拒绝.
    private static func hexByteValue(_ text: String) -> UInt8? {
        guard !text.isEmpty, text.count == 2,
              text.allSatisfy({ $0.isHexDigit }),
              let value = UInt8(text, radix: 16) else { return nil }
        return value
    }

    private func applyEdit() {
        guard let offset = editOffset, offset < vm.bytes.count else { return }
        let cleaned = editValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 非法输入：不写任何字节，弹窗与偏移保持不变，由 editHint 给行内提示.
        guard let value = Self.hexByteValue(cleaned) else { return }
        vm.bytes[offset] = value
        vm.markDirty()
        cancelEdit()
    }

    /// 收尾：清空偏移与残留输入，避免下次打开编辑框带上上一次的脏值.
    private func cancelEdit() {
        editOffset = nil
        editValue = ""
    }
}

private struct HexRow: View {
    let offset: Int
    let bytes: [UInt8]
    let columns: Int
    let onTap: (Int) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(format: "%08X", offset))
                .foregroundColor(.secondary)
                .frame(width: 74, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(0..<columns, id: \.self) { index in
                    if index < bytes.count {
                        Button {
                            onTap(offset + index)
                        } label: {
                            Text(String(format: "%02X", bytes[index]))
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("  ")
                    }
                }
            }
            Text(ascii)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private var ascii: String {
        String(bytes.map { byte in
            (byte >= 32 && byte < 127) ? Character(UnicodeScalar(byte)) : "."
        })
    }
}
