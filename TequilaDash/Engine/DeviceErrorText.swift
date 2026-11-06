import Foundation

/// FFI 错误的语义分类：把设备侧回的错误标识翻成用户能执行的下一步.
enum LockdownFailure: Equatable {
    case deviceLocked
    case passcodeRequired
    case mcProtected
    case sessionActive
    case sessionInactive
    case pairingDialogPending
    case userDeniedPairing
    case invalidHostID
    case developerModeDisabled
    case startServiceDeclined
    case other

    init(message: String) {
        let m = message.lowercased()
        func hit(_ key: String) -> Bool { m.contains(key.lowercased()) }
        if hit("PasscodeRequired") { self = .passcodeRequired }
        else if hit("MCProtected") { self = .mcProtected }
        else if hit("SessionActive") { self = .sessionActive }
        else if hit("SessionInactive") { self = .sessionInactive }
        else if hit("PairingDialogResponsePending") { self = .pairingDialogPending }
        else if hit("UserDeniedPairing") || hit("Canceled by user") { self = .userDeniedPairing }
        else if hit("InvalidHostID") { self = .invalidHostID }
        else if hit("Developer mode is not enabled") { self = .developerModeDisabled }
        else if hit("StartService") || hit("MissingService") { self = .startServiceDeclined }
        else if hit("DeviceLocked") { self = .deviceLocked }
        else { self = .other }
    }

    /// 一句可执行的下一步；无建议返回 nil（不许把未知错误硬编成建议）.
    var advice: String? {
        switch self {
        case .deviceLocked: return "设备当前处于锁屏状态，解锁后重试."
        case .passcodeRequired: return "设备要求先解锁并输入开机密码，完成后重试."
        case .mcProtected: return "该操作受监督保护（MCProtected），需要设备上的监督描述文件授权，普通配对无法执行."
        case .sessionActive: return "设备上已有活动会话占用该服务，先在设备端确认信任或断开其它工具后重试."
        case .sessionInactive: return "配对会话已失效，需要重新配对."
        case .pairingDialogPending: return "设备屏幕正在等待「信任此电脑」，请在设备上确认."
        case .userDeniedPairing: return "设备已拒绝信任，可在「设置 - 通用 - 传输或还原 TequilaDash - 还原 - 还原位置与隐私」后重新配对."
        case .invalidHostID: return "本机配对记录与设备不匹配，请删除配对文件后重新配对."
        case .developerModeDisabled: return "设备未开启开发者模式，请在「设置 - 隐私与安全性 - 开发者模式」打开后重试."
        case .startServiceDeclined: return "设备拒绝了该服务的启动请求，可能是escapeOS版本限制或未安装对应服务."
        case .other: return nil
        }
    }
}

/// Rust FFI 错误文案的统一出口：剥调试外壳 + 补一句可执行建议.
enum DeviceErrorText {

    /// 直接返回 char* 的净化文案；指针为空返回 nil.
    static func cleaned(_ raw: UnsafePointer<CChar>?) -> String? {
        guard let raw else { return nil }
        return annotate(String(cString: raw))
    }

    /// 已知的外壳枚举名：只有这些（或形如 EnumName("正文") 的带引号壳）才剥，其余原样保留.
    private static let shellNames: Set<String> = [
        "UnexpectedResponse", "ServiceNotFound", "DeviceError", "ServiceError",
        "LockdownError", "AfcError", "HttpError", "PlistError", "PairingError",
    ]

    static func stripDebugShell(_ text: String) -> String {
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return text }
        let head = String(text[..<open])
        guard !head.isEmpty, head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return text }
        var inner = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        let quoted = inner.hasPrefix("\"") && inner.hasSuffix("\"") && inner.count > 1
        guard shellNames.contains(head) || quoted else { return text }
        if quoted { inner = String(inner.dropFirst().dropLast()) }
        return inner.isEmpty ? text : inner
    }

    /// 剥外壳 + 追加建议；已有建议或无分类时不改语义.
    static func annotate(_ text: String) -> String {
        let base = stripDebugShell(text)
        guard let advice = LockdownFailure(message: base).advice else { return base }
        if base.contains(advice) { return base }
        return base + "（" + advice + "）"
    }
}
