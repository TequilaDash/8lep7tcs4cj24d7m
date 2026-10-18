//
//  elf_loader_emulator.h
//  AnisetteKit
//
//  Created by Magesh K on 17/08/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

#ifndef ELF_LOADER_EMULATOR_H
#define ELF_LOADER_EMULATOR_H

#if defined(_WIN32) || defined(_MSC_VER)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <windows.h>
#endif

#include <stdint.h>
#include <stddef.h>
#include <string>
#include <vector>
#include <unordered_map>
#include <unicorn/unicorn.h>
#include "anisette_base.h"

#define LOG_UC(...) anisetteCoreLog(__VA_ARGS__)

static const uint64_t kReturnAddress = 0xDEAD0000;
static const uint64_t kHeapAddress   = 0x48000000;
static const uint32_t kHeapSize      = 0x20000000;
static const uint64_t kStackAddress  = 0x70000000;
static const uint32_t kStackSize     = 0x1000000;
static const uint64_t kImportAddress = 0x80000000;
static const uint32_t kImportSize    = 0x10000;

// v0.3.662：run_vm_procedure 的兜底执行上限（调用方不传时生效）.
// 为什么需要：uc_emu_start 的 0 == 无限。guest(ADI) 一次正常调用是毫秒级、
// 百万级指令；给 5 秒 / 5 亿条指令足够宽松，又不至于让一次死循环把 Anisette
// 子系统永久卡死（调用方全程持有 g_vm_mutex）.
static const uint64_t kDefaultExecTimeoutUs = 5000000ULL;   // 5 秒
static const uint64_t kDefaultExecMaxCount  = 500000000ULL; // 5 亿条指令
// 库构造器（DT_INIT / DT_INIT_ARRAY）单个上限。为什么单独给：一个 .so 可能有几十个构造器，
// 若都按 5 秒兜底，最坏情况（全卡住）会叠成几分钟；构造器正常是毫秒级，1 秒足够，早停早回退.
static const uint64_t kConstructorTimeoutUs = 1000000ULL;   // 1 秒

struct AndroidSystemProperties {
    const char *sdk_version  = "30";
    const char *release      = "11";
    const char *model        = "Pixel 5";
    const char *brand        = "google";
    const char *name         = "redfin";
    const char *device       = "redfin";
    const char *manufacturer = "Google";
    const char *fingerprint  = "google/redfin/redfin:11/RQ3A.211001.001/7641976:user/release-keys";
};

extern const AndroidSystemProperties kAndroidProperties;

class PageAllocator {
private:
    uint64_t base;
    uint64_t size;
    uint64_t offset;
    uint64_t alignment;

    /// v0.3.662：上一次 alloc 是否因为地址空间耗尽而失败.
    /// 为什么需要：guest 侧的 malloc/calloc 可能真的把 512MB 堆用光（ADI 引擎只 free 不归还，
    /// 见 hook_free）。旧实现在这里 abort() —— 整个宿主 App 当场消失，用户只看到闪退，
    /// 也走不到「回退远程 Anisette」的分支。
    bool out_of_memory = false;

public:
    PageAllocator(uint64_t base_addr, uint64_t total_size, uint64_t align_bytes = 16)
        : base(base_addr), size(total_size), offset(0), alignment(align_bytes) {}

    /// 分配一段 guest 地址；**空间不足时返回 0**（不再 abort）.
    /// 调用方必须把 0 当作失败处理（guest 侧返回 NULL / 本函数返回失败）.
    uint64_t alloc(uint64_t bytes);

    /// 读并清除「上次 alloc 是否失败」标志（失败时已经打过日志）.
    bool take_out_of_memory() {
        bool f = out_of_memory;
        out_of_memory = false;
        return f;
    }
};

struct EmulatorVM {
    struct LibraryInfo {
        std::string name;
        uint64_t base_address;
        uint64_t min_vaddr;
        uint64_t max_vaddr;
        uint64_t dynamic_address;
        uint64_t symtab;
        uint64_t strtab;
        size_t   strsz;
        uint64_t rel;
        size_t   relsz;
        uint64_t rela;
        size_t   relasz;
        uint64_t jmprel;
        size_t   pltrelsz;
        uint64_t init_func;
        uint64_t init_array;
        size_t   init_arraysz;
        std::unordered_map<std::string, uint64_t> symbols;
        std::vector<std::string> needed_libs;
    };

    uc_engine *uc;
    PageAllocator heap;
    PageAllocator library_alloc;

    /// v0.3.616：`uc_open` 失败（例如链接进来的 libunicorn.a 不含 AArch64 后端）时
    /// 置 false，**不再 abort()** —— 那会让宿主 App 当场崩溃，无法回退远程 Anisette.
    /// 调用方（`setup_vm_and_adi`）必须先检查它.
    bool valid = false;
    
    std::unordered_map<std::string, uint64_t> imported_symbols;
    std::unordered_map<uint64_t, std::string> import_stubs;
    uint64_t next_import_address;

    std::unordered_map<int, int> fd_map;
    int next_guest_fd;

    uint64_t errno_addr;
    uc_hook invalid_hook = 0;
    uc_hook import_hook = 0;
    uc_hook pc_trace_hook = 0;

    std::vector<LibraryInfo> loaded_libraries;

    EmulatorVM();
    ~EmulatorVM();

    uint64_t register_import(const std::string &name);
    uint64_t write_bytes(const uint8_t *data, size_t len);
    uint64_t write_string(const char *str);
};

bool load_library_to_vm(EmulatorVM *vm, const std::string &file_path, const std::string &so_name);
void relocate_all_vm_libraries(EmulatorVM *vm);
void run_library_constructors(EmulatorVM *vm);
uint64_t get_vm_symbol_address(EmulatorVM *vm, const std::string &name);

int32_t run_vm_procedure(EmulatorVM *vm, uint64_t proc_addr, const std::vector<uint64_t> &args, uint64_t timeout_us = 0, size_t max_count = 0);

#endif /* ELF_LOADER_EMULATOR_H */
