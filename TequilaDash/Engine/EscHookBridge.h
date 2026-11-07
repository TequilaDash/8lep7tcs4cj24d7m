//
//  EscHookBridge.h
//  TequilaDash
//
//  litehook / fishhook 的 C 垫片（v0.3.783，照 LiveContainer 引入的 hook 底座）.
//
//  ## 为什么要这一层
//  上游两个头的签名里有三样 Swift 的 Clang Importer 处理不了或处理得很别扭的东西：
//    · `const mach_header_u *` —— mach_header_u 是 litehook.h 里 `#ifdef __arm64__` 的 typedef,
//      Swift 导入后与系统 `mach_header_64` 是两个不同类型，传不进去；
//    · `bool (*exceptionFilter)(const mach_header_u *header)` —— C 函数指针参数要跨语言携带上下文；
//    · `struct rebinding { const char *name; void *replacement; void **replaced; }` ——
//      Swift 得自己构造这个数组，name 的 C 字符串还得活到调用返回.
//
//  ## 为什么本垫片**一个出参都没有**（照搬前先读）
//  本仓记忆 `.workbuddy/memory/2026-09-10.md`「v0.3.279 八轮攻坚终结（C 垫片方案）」：
//  271~278 八轮 CI 里 `&x` / `withUnsafeMutablePointer` 闭包 / 显式 allocate 三种写法**全部编译失败**，
//  改用 C 垫片后 run 453 SUCCESS. ⇒ 本层刻意把指针出参全部消掉：
//    · 失败原因 → esc_hook_last_error()（静态缓冲区，返回 const char *，不用出参）
//    · fishhook 拿到的原函数地址 → 直接当 esc_hook_rebind_symbol 的返回值
//  Swift 侧只见 `const char *` / `void *` / 整数标量.
//
//  ## 能力边界（照上游 README 的口径，不要指望更多）
//  - esc_hook_find_dsc_symbol：解析 dyld_shared_cache，按「镜像路径 + 符号名」取私有符号地址.
//  - esc_hook_rebind_symbol：fishhook 的 GOT 重绑，**能拿到原函数地址**，可先做事再走原逻辑.
//  - esc_hook_patch_function：litehook 的入口改成分支，**原函数从此不可再调用**（上游不留 trampoline）.
//  - 只支持 arm64 / arm64e（我们的产物只有 arm64）.
//
//  ## 可见性（与 LiveContainer 的差异，故意保留）
//  fishhook.h 在未定义 FISHHOOK_EXPORT 时把 rebind_symbols 标成 `visibility("hidden")`.
//  我们是**单 target 静态编进同一个可执行文件**（LiveContainer 是 framework 导出给主 App，
//  才需要 GCC_PREPROCESSOR_DEFINITIONS="FISHHOOK_EXPORT=1"，见其 pbxproj:1939），
//  hidden 完全够用，还顺带不把第三方符号名导出成我们的 ABI.
//  ⇒ 若将来把容器启动拆成独立 extension target、需要跨镜像调用，再补那个宏.
//
#ifndef EscHookBridge_h
#define EscHookBridge_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 上一次失败的原因；成功时为 NULL.
///
/// 返回的是**静态缓冲区**：不要 free，也不要长期持有（下一次失败会覆盖）.
const char *esc_hook_last_error(void);

/// dyld_shared_cache 里按镜像路径取符号地址（取系统私有 API 的入口）.
///
/// - Parameters:
///   - imagePath: 镜像在 DSC 里的路径，如 `/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore`
///   - symbolName: 符号名，如 `_UIApplicationGetForegroundApplication`
/// - Returns: 符号地址；找不到返回 NULL，原因见 esc_hook_last_error().
void *esc_hook_find_dsc_symbol(const char *imagePath, const char *symbolName);

/// 已加载镜像的数量（配合 esc_hook_image_header / esc_hook_image_name 枚举）.
uint32_t esc_hook_image_count(void);

/// 第 index 个镜像的 mach_header（越界返回 NULL）.可直接喂给下面两个按镜像操作的函数.
void *esc_hook_image_header(uint32_t index);

/// 第 index 个镜像的路径（越界返回空串，不返回 NULL）.
const char *esc_hook_image_name(uint32_t index);

/// 在指定镜像的符号表里找符号地址.
///
/// header 传 NULL = 读自己的符号表（上游语义）.与 DSC 版的区别：这里读镜像自己的 LC_SYMTAB，
/// 用来拿 uloader 加载进来的 guest 符号.
void *esc_hook_find_image_symbol(void *header, const char *symbolName);

/// 把导入符号换成替身（fishhook `rebind_symbols`）.
///
/// 与上游一致：对当前已加载的所有镜像以及之后新加载的镜像都生效；同一符号重复绑定，后一次覆盖前一次.
///
/// - Parameters:
///   - symbolName: 要替换的符号名，如 `dlopen` / `mmap` / `fcntl`
///   - replacement: 替身函数地址.Swift 侧必须用 `@convention(c)` 的**全局函数**取地址，
///     不能是捕获上下文的闭包 —— C 侧没有 block 运行时
/// - Returns: 被替换掉的**原函数地址**；该符号在本进程里没被绑到过时返回 NULL
///     （NULL 不等于失败：失败判据是 esc_hook_last_error() 非空）.
void *esc_hook_rebind_symbol(const char *symbolName, void *replacement);

/// 就地改写函数入口使其跳转到 target（litehook `litehook_hook_function`）.
///
/// 上游语义：改完原函数不可再调用.需要「先做事再走原逻辑」请用 esc_hook_rebind_symbol.
/// - Returns: 0 = 成功；非 0 = Mach kernel 错误码（常见 KERN_PROTECTION_FAILURE = 2）.
int esc_hook_patch_function(void *source, void *target);

/// 对**指定镜像**按地址重绑（litehook `litehook_rebind_symbol`）.
/// 只扫该镜像 __DATA / __DATA_CONST / __AUTH_CONST 里的 symbol pointer 段，不动别的镜像.
/// - Returns: 0 = 调用已执行；非 0 = 参数为空.上游无返回值也不报告是否命中，
///   要确认效果请自己再读一次 GOT 或改用 esc_hook_rebind_symbol 拿 out_original.
int esc_hook_rebind_in_image(void *targetHeader, void *replacee, void *replacement);

/// 全局重绑（上游的 LITEHOOK_REBIND_GLOBAL）：登记后对之后加载的每个镜像自动生效.
/// - Returns: 0 = 已登记；非 0 = 未登记（上游在 dladdr 定位不到替身所在镜像时静默 return，
///   本垫片用 gRebindCount 前后差把它变成可判定的失败）.
int esc_hook_rebind_global(void *replacee, void *replacement);

/// dyld_shared_cache 的 slide（把 DSC 里的静态地址换算成运行时地址要用）.
uintptr_t esc_hook_dsc_slide(void);

/// dyld_shared_cache 文件路径；找不到返回空串（不返回 NULL）.
const char *esc_hook_dsc_path(void);

/// 当前设备是否支持 TPRO（arm64e 线程私有区域只读保护，写 __DATA 前可能要临时放开）.
bool esc_hook_tpro_supported(void);

/// 把本线程 TPRO 放开成可写 / 恢复成只读（上游改 __auth_got 时就是这么配对的）.
void esc_hook_tpro_to_rw(void);
void esc_hook_tpro_to_ro(void);

/// 自检：两个 hook 库是否真的被编进产物（1 = 都在）.
/// 容器内启动前给「hook 底座可用」一个判据，不靠猜.
int esc_hook_available(void);

#ifdef __cplusplus
}
#endif

#endif /* EscHookBridge_h */
