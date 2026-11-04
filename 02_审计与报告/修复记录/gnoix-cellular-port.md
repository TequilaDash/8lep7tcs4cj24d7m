# Gnoix 蜂窝续签逆向与移植记录（v0.3.755，2026-11-04）

## 任务来源
用户指令：Gnoix（http://gnoix.com/）蜂窝续签那套方法逆向和反编译过来源码，移植到现有 Cellular 隧道支持.

## 取证对象
C:/Users/xcrad/Downloads/Gnoix_v1.2.15.ipa → 解包 C:/Users/xcrad/AppData/Local/Temp/gnoix/
（Gnoix 主二进制 80MB + SideInstallerFFI 25MB Rust + IDevice 9MB；LiveContainer 系，idevice-0.1.29 + minimuxer + rusty_libimobiledevice）

## 逆向结论（反汇编实锤）
- `setupPrivateCoreTelephony` @0x10013aca4：dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_NOW) → dlsym ×2：
  - **`_CTServerConnectionCreate`**（vaddr 0x1016a0180）→ 建 connection（Gnoix 传 kCFAllocatorSystemDefault, 0, 0）
  - **`_CTServerConnectionSetCellularDataIsEnabled`**（vaddr 0x1016a01a0）→ 签名 (OpaquePointer?, Bool) -> Int32，0 = 成功
- `CellularNetworkChecker`：NWPathMonitor 常驻（isConnected/isWiFi/isCellularOnly）+ `waitForCellularToTurnOff(timeoutSeconds:) async -> Bool`（等网络真的断=路由重置窗口）+ cancelWait + static isWiFiInterfaceActive
- `CellularDataToggleService`：singleton，isPrivateAPIAvailable 闸门 + `setCellularEnabled(_: Bool) async throws` + `performBypassGlitchHandshake(handshakeAction:)`
- 流程文案（二进制原文）：Apple 服务器交互在蜂窝正常时先做完；本地 profile 注入（misagent/lockdown over loopback）需回环可达，蜂窝-only 无 hairpin 不通 ⇒ 程序化关蜂窝触发 iOS 路由重置，窗口期内完成注入后再开蜂窝；私有 API 不可用时降级手动引导（CellularGlitchModalView + AutoSignManager.CellularGlitchStep）
- SideInstallerFFI 辅助串：loopback VPN 必须 blanket-forward 全端口（隧道每次开新高位端口，单端口规则代理盖不住）；iOS 27 不允许经隧道 lockdown 配对，移交 RPPairing 记录（StikDebug sideloaded / 2026-09-20 起 SideStore nightly 可读）

## 移植落地（commit 56fc071 = v0.3.755）
- 新增 `TequilaDash/Engine/CellularDataToggleService.swift`：dlopen+dlsym 同款双私有 C 函数；kCFAllocatorSystemDefault → NULL 两次尝试建 connection；`setCellularEnabled` C 调用放全局队列不卡 MainActor；失败抛 ToggleError（ctError 码）
- 新增 `TequilaDash/Engine/CellularNetworkChecker.swift`：常驻 NWPathMonitor（@Published isConnected/isWiFi/isCellularOnly + 带锁镜像 isNetworkConnectedNow）+ `waitForCellularToTurnOff`（断网 resume(true)/超时 resume(false)）+ cancelWait + static isWiFiInterfaceActive（探不到不冒充 Wi-Fi）
- 集成 `Engine/CellularTunnelManager.swift`：turnOffDataIfNeeded/turnOnDataIfNeeded 在快捷指令分支**之前**加私有 API 分支；成功置/清 `didTurnOffData`（切后台/回前台生命周期保险对两条路径同样生效）；私有 API 关蜂窝后按真实断网事件等路由重置窗口（上限 6s，超时继续走隧道就绪探测兜底）；失败自动回落快捷指令路径（v0.3.650 引导自建链路保留为降级面）
- 未移植：performBypassGlitchHandshake 包装（我们的本地链路在 prepareForTunnel 之后，等价窗口等待已在 turnOff 内实现）、手动引导 Modal（我们的自动化降级面更强）

## CI 教训（两次返工实录）
1. **NSLock.lock()/unlock() 在 async 上下文不可用**（"instance method 'lock' is unavailable from asynchronous contexts"）⇒ connection/setter 全改 `let`（init 期定死），免锁
2. **private typealias 的成员可见性**（"property must be declared private because its type uses a private type"）⇒ `ctConnection`/`setCellularFunc` 改 `private let`
3. `Resources/brand_tequila.png` 的 pngcrush libpng 告警为历史噪声（749 起就在，非致命，会被日志 grep "error:" 误标）
4. swiftc -parse 只验语法，**并发可用性与类型可见性只有真编译才暴露**——async Swift 别在本地只跑 parse 就当过审

## 发版
- run 41778662113（56fc071）success → tag v0.3.755 → tag run 41780263336 success → release 双包（dl=0）
