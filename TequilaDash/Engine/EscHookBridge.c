//
//  EscHookBridge.c
//  TequilaDash
//
//  见 EscHookBridge.h.实现层只做三件事：类型收口、错误可观测、参数校验.
//  不改上游行为,不加自己的 hook 逻辑 —— 上游语义就是语义.
//
#include "EscHookBridge.h"

#include <stdio.h>
#include <string.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>

// 上游两个头在本 .c 里各引一次（litehook.h 没有 include guard，重复引会炸）
#include "litehook.h"
#include "fishhook.h"

// 失败原因：静态缓冲区，调用方不 free、不长期持有（下一次失败会覆盖）
static char gHookErr[256];

static void setErr(const char *text)
{
    snprintf(gHookErr, sizeof(gHookErr), "%s", text ? text : "未提供原因");
}

static void clearErr(void)
{
    gHookErr[0] = 0;
}

const char *esc_hook_last_error(void)
{
    return gHookErr[0] ? gHookErr : NULL;
}

// 上游 extern 出来的计数器，用来把「静默 return」变成可判定的失败
extern uint32_t gRebindCount;

// litehook_get_dsc_slide 上游只在 .c 里定义，**没写进 litehook.h**（上游自己的头漏了声明）.
// 不声明就是隐式函数声明，C 里按 int 返回会把 64 位 slide 截断 —— 必须显式给原型.
uintptr_t litehook_get_dsc_slide(void);

void *esc_hook_find_dsc_symbol(const char *imagePath, const char *symbolName)
{
    clearErr();
    if (!imagePath || !*imagePath || !symbolName || !*symbolName) {
        setErr("镜像路径或符号名为空");
        return NULL;
    }
    void *symbol = litehook_find_dsc_symbol(imagePath, symbolName);
    if (!symbol) {
        // DSC 里查不到最常见的原因是镜像不在这台设备的 DSC 中（私有框架路径随系统版本变）
        setErr("dyld_shared_cache 里找不到该符号：确认镜像路径在这台系统上存在");
        return NULL;
    }
    return symbol;
}

uint32_t esc_hook_image_count(void)
{
    return (uint32_t)_dyld_image_count();
}

void *esc_hook_image_header(uint32_t index)
{
    if (index >= _dyld_image_count()) return NULL;
    return (void *)_dyld_get_image_header(index);
}

const char *esc_hook_image_name(uint32_t index)
{
    if (index >= _dyld_image_count()) return "";
    const char *name = _dyld_get_image_name(index);
    return name ? name : "";
}

void *esc_hook_find_image_symbol(void *header, const char *symbolName)
{
    clearErr();
    if (!symbolName || !*symbolName) {
        setErr("符号名为空");
        return NULL;
    }
    // header == NULL 在上游表示「读自己的符号表」
    void *symbol = litehook_find_symbol((const mach_header_u *)header, symbolName);
    if (!symbol) {
        setErr("该镜像符号表里没有这个符号（可能已被 strip）");
        return NULL;
    }
    return symbol;
}

void *esc_hook_rebind_symbol(const char *symbolName, void *replacement)
{
    clearErr();
    if (!symbolName || !*symbolName) {
        setErr("符号名为空");
        return NULL;
    }
    if (!replacement) {
        setErr("替身函数地址为空");
        return NULL;
    }
    // fishhook 只在命中时写 replaced，所以必须先置 NULL —— 空着就是「本进程没绑过这个符号」
    void *original = NULL;
    struct rebinding rebinding = { symbolName, replacement, &original };
    int rc = rebind_symbols(&rebinding, 1);
    if (rc != 0) {
        setErr("fishhook rebind_symbols 失败（内存不足）");
        return NULL;
    }
    return original;
}

int esc_hook_patch_function(void *source, void *target)
{
    clearErr();
    if (!source || !target) {
        setErr("source 或 target 为空");
        return -1;
    }
    // 上游语义：改完原函数不可再调用.需要走原逻辑请用 esc_hook_rebind_symbol.
    kern_return_t kr = litehook_hook_function(source, target);
    if (kr != KERN_SUCCESS) {
        setErr(kr == KERN_PROTECTION_FAILURE
               ? "litehook 写指令失败：内存保护不允许（KERN_PROTECTION_FAILURE）"
               : "litehook_hook_function 返回 Mach 错误码");
        return (int)kr;
    }
    return 0;
}

int esc_hook_rebind_in_image(void *targetHeader, void *replacee, void *replacement)
{
    clearErr();
    if (!targetHeader) {
        setErr("目标镜像 header 为空（全局重绑请用 esc_hook_rebind_global）");
        return -1;
    }
    if (!replacee || !replacement) {
        setErr("被替换或替身地址为空");
        return -1;
    }
    litehook_rebind_symbol((const mach_header_u *)targetHeader, replacee, replacement, NULL);
    // 上游无返回值也不报告是否命中：要确认效果请自己再读一次 GOT，
    // 或改用 esc_hook_rebind_symbol（它把原函数地址直接返回）.
    return 0;
}

int esc_hook_rebind_global(void *replacee, void *replacement)
{
    clearErr();
    if (!replacee || !replacement) {
        setErr("被替换或替身地址为空");
        return -1;
    }
    uint32_t before = gRebindCount;
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, replacee, replacement, NULL);
    // 上游在 dladdr 定位不到替身所在镜像时静默 return —— 计数器不变就是没登记成功
    if (gRebindCount == before) {
        setErr("全局重绑未登记：替身函数所在镜像无法被 dladdr 定位");
        return -1;
    }
    return 0;
}

uintptr_t esc_hook_dsc_slide(void)
{
    return litehook_get_dsc_slide();
}

const char *esc_hook_dsc_path(void)
{
    const char *path = litehook_locate_dsc();
    return path ? path : "";
}

bool esc_hook_tpro_supported(void)
{
    return os_tpro_is_supported();
}

void esc_hook_tpro_to_rw(void)
{
    os_thread_self_restrict_tpro_to_rw();
}

void esc_hook_tpro_to_ro(void)
{
    os_thread_self_restrict_tpro_to_ro();
}

int esc_hook_available(void)
{
    // 两个库都编进产物时这两个符号必然可解析
    void *lh = (void *)&litehook_hook_function;
    void *fh = (void *)&rebind_symbols;
    return (lh && fh) ? 1 : 0;
}
