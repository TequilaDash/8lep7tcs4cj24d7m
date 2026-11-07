//
//  SandboxResigner.swift
//  TequilaDash
//
//  沙盒容器整包重签（v0.3.782）
//  —— 照 LiveContainer 的做法：遍历 .app 内所有 64 位 Mach-O 逐个就地重签，
//  不生成 _CodeSignature/CodeResources、不重打包 IPA。
//  真机事实依据：LC 的 ZSigner signWithAppPath 只把 filesToSign 交给
//  signMachOPathArr，Sign 的 Info.plist hash 与 CodeResources 传空串，
//  系统照样允许容器内加载。
//
//  证书来源：DeveloperCertStore（本机创建或 p12 导入的真开发证书）。
//  与 zsign_sign_file_with_cert 共用同一套前置自愈、UUID 扰动、换 inode 与后置自洽校验。
//

import Foundation

enum SandboxResignError: LocalizedError {
    case noCertificate
    case notADirectory(String)
    case noMachO(String)
    case tempFailure(String)
    case partial(failed: Int, firstPath: String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noCertificate:
            return "没有可用的签名证书. 请先到「更多 → 证书管理」创建或导入 p12."
        case .notADirectory(let path):
            return "包体路径不是目录: \(path)"
        case .noMachO(let path):
            return "包体里没有可签名的 64 位 Mach-O: \(path)"
        case .tempFailure(let detail):
            return "临时文件准备失败: \(detail)"
        case .partial(let failed, let firstPath):
            return "有 \(failed) 个文件签名失败，首个: \(firstPath)"
        case .failed(let detail):
            return "重签失败: \(detail)"
        }
    }
}

struct SandboxResignResult: Sendable {
    let signed: Int
    let failed: Int
    let logPath: String?

    var summary: String {
        if failed == 0 {
            return "已重签 \(signed) 个 Mach-O"
        }
        return "已重签 \(signed) 个，失败 \(failed) 个"
    }
}

enum SandboxResigner {
    /// 对一个容器应用整包重签.
    /// - Parameters:
    ///   - app: 容器内的应用（用 app.appPath 与 app.id）.
    ///   - useMainIdentifier: 传 true 时签名 identifier 用本 App 的 bundle id
    ///     （iOS 27 真机实锤：dlopen 的库 identifier 必须与主程序一致）.
    ///     容器安装场景保持 false，用访客自己的 bundle id.
    static func resign(_ app: SandboxApp,
                       useMainIdentifier: Bool = false,
                       debugLog: URL? = nil) throws -> SandboxResignResult {
        let bundleId = useMainIdentifier
            ? (Bundle.main.bundleIdentifier ?? app.id)
            : app.id
        return try resign(appPath: app.appPath, bundleId: bundleId, debugLog: debugLog)
    }

    /// 直接按路径重签（详情页/调试用）.
    static func resign(appPath: String,
                       bundleId: String,
                       debugLog: URL? = nil) throws -> SandboxResignResult {
        guard let material = DeveloperCertStore.shared.certMaterial() else {
            throw SandboxResignError.noCertificate
        }
        var errBuf = [CChar](repeating: 0, count: 512)
        var signed: Int32 = 0
        var failed: Int32 = 0
        let rc: Int32 = material.certPem.withUnsafeBytes { certBuf -> Int32 in
            material.keyPem.withUnsafeBytes { keyBuf -> Int32 in
                guard let certPtr = certBuf.baseAddress?.assumingMemoryBound(to: CChar.self),
                      let keyPtr = keyBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                    return -1
                }
                return appPath.withCString { appC in
                    bundleId.withCString { bidC in
                        material.teamId.withCString { teamC in
                            errBuf.withUnsafeMutableBufferPointer { errPtr -> Int32 in
                                zsign_resign_app(appC, bidC,
                                                 certPtr, Int32(material.certPem.count),
                                                 keyPtr, Int32(material.keyPem.count),
                                                 debugLog?.path, teamC,
                                                 &signed, &failed,
                                                 errPtr.baseAddress, Int32(errBuf.count))
                            }
                        }
                    }
                }
            }
        }
        let detail = String(cString: errBuf)
        switch rc {
        case 0:
            LoginLogger.shared.log("[完成] 沙盒容器重签 \(bundleId) 成功 \(signed) 个 Mach-O")
            return SandboxResignResult(signed: Int(signed), failed: 0, logPath: debugLog?.path)
        case 1:
            LoginLogger.shared.log("[失败] 沙盒容器重签 \(bundleId) 部分失败 \(failed) 个，\(detail)")
            throw SandboxResignError.partial(failed: Int(failed), firstPath: detail)
        case -2:
            throw SandboxResignError.notADirectory(appPath)
        case -3:
            throw SandboxResignError.noMachO(appPath)
        case -4:
            throw SandboxResignError.tempFailure(detail.isEmpty ? "未知" : detail)
        default:
            LoginLogger.shared.log("[失败] 沙盒容器重签 \(bundleId) rc=\(rc) \(detail)")
            throw SandboxResignError.failed(detail.isEmpty ? "rc=\(rc)" : detail)
        }
    }
}
