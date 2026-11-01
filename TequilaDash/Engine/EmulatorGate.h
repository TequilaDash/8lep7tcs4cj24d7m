#pragma once

// ─────────────────────────────────────────────────────────────────────────────
//  EmulatorGate — 进程内所有 Unicorn 引擎的全局串行闸门
//
//  为什么需要（v0.3.743 真机崩溃取证）：
//  App 里有**两套**各自建 Unicorn 引擎的子系统 ——
//    1. SAP 签名链（`Services/AppleAuth/SAP/SapMachine.cpp`，每个 SAPContext 一台引擎）
//    2. Anisette/ADI 模拟链（`Engine/Anisette/Loader/elf_loader_emulator.cpp`，全局一台）
//  Unicorn 的 TCG 翻译缓冲带**进程级共享状态**：一方触发 tb_flush 会回收另一方正在执行的
//  翻译块。两台引擎并发跑时，正在跑的那台会跳进已回收的代码页 —— 内核按
//  CODESIGNING / Invalid Page 直接杀掉进程（真机 .ips 实证：termination
//  = CODESIGNING Invalid Page，另一线程正停在 tcg_qemu_tb_exec 里，崩溃线程 PC=0）。
//
//  这不是「偶发」，而是「两边同时用到仿真器」时才出现的确定性竞态：
//  商店搜索会同时触发 SAP 配给（已购/版本查询）与下载链（kbsync），两条链各建一台引擎。
//
//  因此把**所有** `uc_emu_start` 串行化。用 recursive_mutex：同一线程里
//  Exchange → Invoke 这类嵌套调用不会自锁。串行化的代价是第二个仿真任务排队，
//  而仿真本身有超时上限（SAP 侧 kTimeout、ADI 侧 timeout_us），不会永久占用。
// ─────────────────────────────────────────────────────────────────────────────

#include <mutex>

/// 取得进程级仿真闸门。所有 uc_emu_start 调用点必须持有它。
inline std::recursive_mutex &UnicornGate() {
    static std::recursive_mutex gate;
    return gate;
}
