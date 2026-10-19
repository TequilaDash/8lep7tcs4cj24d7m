//
//  anisette_core_uc.cpp
//  AnisetteKit
//
//  Created by Magesh K on 25/07/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

#include "anisette_core.h"
#include "anisette_base.h"
#include "Loader/elf_loader_emulator.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#if !defined(_WIN32) && !defined(_MSC_VER)
#include <unistd.h>
#endif
#include <sys/stat.h>

#if defined(_WIN32) || defined(_MSC_VER)
#define NOMINMAX
#include <io.h>
#include <direct.h>
#define mkdir(p, m) _mkdir(p)
#define rmdir _rmdir
#define stat _stat64
#ifndef S_ISDIR
#define S_ISDIR(m) (((m) & _S_IFMT) == _S_IFDIR)
#endif
#ifndef S_ISREG
#define S_ISREG(m) (((m) & _S_IFMT) == _S_IFREG)
#endif
#endif
#include <string>
#include <vector>
#include <sstream>
#include <mutex>

// v0.3.662：ADI 回填 buffer 的合理性上限（mid/otp/cpim 正常都是几百字节以内）.
// 用来挡住 guest 把长度字段写坏后引发的巨额宿主分配 / 越界读.
static const uint32_t kMaxAnisetteBlobLen = 1024 * 1024;

static EmulatorVM *g_shared_vm = nullptr;
static std::mutex g_vm_mutex;
static std::string g_current_prov_path = "";
static std::string g_current_android_id = "";
static bool g_libraries_initialized = false;

// v0.3.662：把共享 VM 整个丢弃。用于「装载到一半失败」这种不可恢复的状态 ——
// 留着它下一轮会在同一台 VM 上重复装载库/符号，地址与符号表越积越多.
// 只在持有 g_vm_mutex 时调用（当前唯一调用点 setup_vm_and_adi 全部路径都持锁）.
static void reset_shared_vm(EmulatorVM *&vm) {
    delete g_shared_vm;
    g_shared_vm = nullptr;
    vm = nullptr;
    g_current_prov_path.clear();
    g_current_android_id.clear();
    g_libraries_initialized = false;
}

static bool setup_vm_and_adi(
    EmulatorVM *&vm,
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    std::string &out_uuid_prov_dir,
    std::string &out_err
) {
    if (!lib_dir) {
        out_err = "Library directory path is null.";
        return false;
    }
    struct stat st;
    if (stat(lib_dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        out_err = std::string("Provided library path is not a valid directory: ") + lib_dir;
        return false;
    }

    if (!g_shared_vm) {
        g_shared_vm = new EmulatorVM();
    }
    vm = g_shared_vm;

    // v0.3.616：链接进来的 libunicorn.a 若不含 AArch64 后端，uc_open 会失败.
    // 必须在这里返回错误（让上层回退远程），不能继续用空引擎 —— 那会崩在后续调用上.
    if (!vm->valid) {
        out_err = "Unicorn AArch64 backend unavailable (libunicorn.a built without aarch64)";
        return false;
    }

    if (!g_libraries_initialized) {
        std::string lib_path(lib_dir);
        if (!lib_path.empty() && lib_path.back() != '/') lib_path += "/";
        std::string ssc_path     = lib_path + kADISymbols.lib_ssc;
        std::string coreadi_path = lib_path + kADISymbols.lib_core_adi;

        // v0.3.662：原来这里失败只写一句 out_err 就返回 false，而 g_shared_vm 已经被
        // new 出来、可能已经映射了一部分库，g_libraries_initialized 仍是 false.
        // 下一轮进来会在这同一个 vm 上**再装一遍**（setup_vm_and_adi 只看 initialized 标志），
        // 库地址与符号表都会重复累积 —— 这是旧代码就有的隐患，一旦 F5/F6 让它变得
        // 「可能失败」就必须处理。失败时把 VM 整个丢弃重建，保证下一轮从干净状态开始.
        if (!load_library_to_vm(vm, ssc_path, kADISymbols.lib_ssc) ||
            !load_library_to_vm(vm, coreadi_path, kADISymbols.lib_core_adi)) {
            out_err = "Failed to load libraries into VM";
            reset_shared_vm(vm);
            return false;
        }

        relocate_all_vm_libraries(vm);
        run_library_constructors(vm);

        uint64_t load_lib_ptr = get_vm_symbol_address(vm, kADISymbols.load_library);
        if (!load_lib_ptr) {
            out_err = "Required ADI setup symbol missing in VM";
            // 同上：库与构造器都已经作用在这台 VM 上，但符号表不完整，
            // 留着会让下一轮在同一个半初始化状态上再装一遍.
            reset_shared_vm(vm);
            return false;
        }

        uint64_t lib_path_vm = vm->write_string(lib_path.c_str());
        // v0.3.662：堆/字符串写入失败时 write_string 返回 0，原来会拿 0 当路径指针传给 ADI.
        if (!lib_path_vm) {
            out_err = "Emulator heap exhausted while staging library path";
            // 堆已满，这台 VM 的地址空间不可再用；整个丢弃，下一轮重建.
            reset_shared_vm(vm);
            return false;
        }
        LOG_UC("[AnisetteKit - UC] Step 1: Calling ADILoadLibraryWithPath (0x%llx, path=\"%s\")...\n",
               (unsigned long long)load_lib_ptr, lib_path.c_str());
        int32_t load_res = run_vm_procedure(vm, load_lib_ptr, {lib_path_vm, 0});
        LOG_UC("[AnisetteKit - UC] Step 1 result: %d\n", load_res);
        if (load_res != 0) {
            out_err = "ADILoadLibraryWithPath failed: " + std::to_string(load_res);
            // 同上：库已经装进 VM 了，但 ADI 侧初始化失败，这台 VM 不可再用.
            reset_shared_vm(vm);
            return false;
        }
        g_libraries_initialized = true;
    }

    std::string uuid = format_uuid_string(identifier);
    out_uuid_prov_dir = std::string(provisioning_dir) + "/" + uuid;
    // v0.3.662：mkdir 的返回值原来被丢弃。目录没建成时 ADI 写 adi.pb 会失败，
    // 但错误会一路飘到「OTP 请求失败」那里，看不出真正原因；这里直接判错.
    if (mkdir(out_uuid_prov_dir.c_str(), 0755) != 0 && errno != EEXIST) {
        out_err = std::string("Failed to create provisioning directory: ") + out_uuid_prov_dir +
                  " (errno " + std::to_string(errno) + ")";
        return false;
    }

    if (out_uuid_prov_dir != g_current_prov_path) {
        uint64_t set_prov_ptr = get_vm_symbol_address(vm, kADISymbols.set_provisioning_path);
        if (!set_prov_ptr) {
            out_err = "Symbol ADISetProvisioningPath missing in VM";
            return false;
        }
        uint64_t prov_path_vm = vm->write_string(out_uuid_prov_dir.c_str());
        if (!prov_path_vm) {
            out_err = "Emulator heap exhausted while staging provisioning path";
            return false;
        }
        LOG_UC("[AnisetteKit - UC] Step 2: Calling ADISetProvisioningPath (0x%llx, path=\"%s\")...\n",
               (unsigned long long)set_prov_ptr, out_uuid_prov_dir.c_str());
        int32_t prov_res = run_vm_procedure(vm, set_prov_ptr, {prov_path_vm});
        LOG_UC("[AnisetteKit - UC] Step 2 result: %d\n", prov_res);
        if (prov_res != 0) {
            out_err = "ADISetProvisioningPath failed: " + std::to_string(prov_res);
            return false;
        }
        g_current_prov_path = out_uuid_prov_dir;
    }

    std::string android_id = get_android_id_string(identifier);
    if (android_id != g_current_android_id) {
        uint64_t set_id_ptr = get_vm_symbol_address(vm, kADISymbols.set_android_id);
        if (!set_id_ptr) {
            out_err = "Symbol ADISetAndroidID missing in VM";
            return false;
        }
        uint64_t android_id_vm = vm->write_string(android_id.c_str());
        if (!android_id_vm) {
            out_err = "Emulator heap exhausted while staging android id";
            return false;
        }
        LOG_UC("[AnisetteKit - UC] Step 3: Calling ADISetAndroidID (0x%llx, id=\"%s\", len=%zu)...\n",
               (unsigned long long)set_id_ptr, android_id.c_str(), android_id.length());
        int32_t id_res = run_vm_procedure(vm, set_id_ptr, {android_id_vm, (uint64_t)android_id.length()});
        LOG_UC("[AnisetteKit - UC] Step 3 result: %d\n", id_res);
        if (id_res != 0) {
            out_err = "ADISetAndroidID failed: " + std::to_string(id_res);
            return false;
        }
        g_current_android_id = android_id;
    }

    return true;
}

extern "C" {

int32_t get_anisette_headers_uc(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    const uint8_t *adi_pb,
    uint32_t adi_pb_len,
    char **out_json
) {
    LOG_UC("[AnisetteKit - UC] Invoked get_anisette_headers_uc\n");
    if (!lib_dir || !provisioning_dir || !identifier || !adi_pb || !out_json) {
        return ANISETTE_ERR_INVALID_ARGUMENT;
    }

    std::lock_guard<std::mutex> lock(g_vm_mutex);

    EmulatorVM *vm = nullptr;
    std::string uuid_prov_dir, err;
    if (!setup_vm_and_adi(vm, lib_dir, provisioning_dir, identifier, uuid_prov_dir, err)) {
        std::stringstream ss;
        ss << "{\"error\":\"" << err << "\"}";
        *out_json = strdup(ss.str().c_str());
        return ANISETTE_ERR_LOADER_FAILED;
    }

    std::string adi_pb_path = uuid_prov_dir + "/" + kADISymbols.adi_pb_filename;
    FILE* f = fopen(adi_pb_path.c_str(), "wb");
    // v0.3.662：原来写盘失败（fopen 为 NULL / fwrite 短写）完全静默，ADI 随后读到的是
    // 旧 adi.pb 或空文件，错误最终表现为一段看不懂的 OTP 失败。这里显式报错.
    if (!f) {
        std::stringstream ss;
        ss << "{\"error\":\"Failed to write adi.pb: " << adi_pb_path << " (errno " << errno << ")\"}";
        *out_json = strdup(ss.str().c_str());
        return ANISETTE_ERR_WRITE_FILE_FAILED;
    }
    if (fwrite(adi_pb, 1, adi_pb_len, f) != adi_pb_len || fclose(f) != 0) {
        std::stringstream ss;
        ss << "{\"error\":\"Failed to write adi.pb (short write): " << adi_pb_path << "\"}";
        *out_json = strdup(ss.str().c_str());
        return ANISETTE_ERR_WRITE_FILE_FAILED;
    }

    uint64_t otp_req_ptr = get_vm_symbol_address(vm, kADISymbols.otp_request);
    if (!otp_req_ptr) {
        *out_json = strdup("{\"error\":\"Symbol ADIOTPRequest missing\"}");
        return ANISETTE_ERR_SYMBOL_MISSING;
    }

    uint64_t mid_ptr = vm->heap.alloc(8);
    uint64_t mid_len_ptr = vm->heap.alloc(4);
    uint64_t otp_ptr = vm->heap.alloc(8);
    uint64_t otp_len_ptr = vm->heap.alloc(4);
    // v0.3.662：堆耗尽时 alloc 返回 0，原来会继续把这些 0 当地址传给 ADI.
    if (!mid_ptr || !mid_len_ptr || !otp_ptr || !otp_len_ptr) {
        *out_json = strdup("{\"error\":\"Emulator heap exhausted in ADIOTPRequest\"}");
        return ANISETTE_ERR_LOADER_FAILED;
    }

    uint64_t dsid = (uint64_t)-2;
    LOG_UC("[AnisetteKit - UC] Step 4: Calling ADIOTPRequest (0x%llx)...\n", (unsigned long long)otp_req_ptr);
    int32_t res = run_vm_procedure(vm, otp_req_ptr, {dsid, mid_ptr, mid_len_ptr, otp_ptr, otp_len_ptr});
    LOG_UC("[AnisetteKit - UC] Step 4 result: %d\n", res);

    if (res != 0) {
        std::stringstream ss;
        ss << "{\"error\":\"ADIOTPRequest failed ("
           << get_anisette_error_description(res) << "): " << res << "\"}";
        *out_json = strdup(ss.str().c_str());
        return res;
    }

    uint64_t final_mid_addr = 0, final_otp_addr = 0;
    uint32_t final_mid_len = 0, final_otp_len = 0;
    
    // v0.3.662：原来四次读全丢返回码，且先用 guest 给的长度去 std::vector 分配宿主内存
    // （一个坏掉的 ADI 让 final_mid_len = 0xFFFFFFFF 就是 4GB 宿主分配）.先把长度限制住，
    // 再逐次检查读取结果，读不出来就报错，绝不拿半截/随机数据去 base64.
    uc_err r1 = uc_mem_read(vm->uc, mid_ptr, &final_mid_addr, 8);
    uc_err r2 = uc_mem_read(vm->uc, mid_len_ptr, &final_mid_len, 4);
    uc_err r3 = uc_mem_read(vm->uc, otp_ptr, &final_otp_addr, 8);
    uc_err r4 = uc_mem_read(vm->uc, otp_len_ptr, &final_otp_len, 4);
    if (r1 != UC_ERR_OK || r2 != UC_ERR_OK || r3 != UC_ERR_OK || r4 != UC_ERR_OK) {
        *out_json = strdup("{\"error\":\"Failed to read ADIOTPRequest out-params\"}");
        return ANISETTE_ERR_INVALID_DATA;
    }
    if (final_mid_len > kMaxAnisetteBlobLen || final_otp_len > kMaxAnisetteBlobLen) {
        std::stringstream ss;
        ss << "{\"error\":\"ADIOTPRequest returned implausible lengths (mid=" << final_mid_len
           << ", otp=" << final_otp_len << ")\"}";
        *out_json = strdup(ss.str().c_str());
        return ANISETTE_ERR_INVALID_DATA;
    }

    std::vector<uint8_t> mid_data(final_mid_len);
    if (final_mid_len > 0 && final_mid_addr != 0 &&
        uc_mem_read(vm->uc, final_mid_addr, mid_data.data(), final_mid_len) != UC_ERR_OK) {
        *out_json = strdup("{\"error\":\"Failed to read mid buffer from guest\"}");
        return ANISETTE_ERR_INVALID_DATA;
    }

    std::vector<uint8_t> otp_data(final_otp_len);
    if (final_otp_len > 0 && final_otp_addr != 0 &&
        uc_mem_read(vm->uc, final_otp_addr, otp_data.data(), final_otp_len) != UC_ERR_OK) {
        *out_json = strdup("{\"error\":\"Failed to read otp buffer from guest\"}");
        return ANISETTE_ERR_INVALID_DATA;
    }

    std::string mid = base64_encode(mid_data.data(), final_mid_len);
    std::string otp = base64_encode(otp_data.data(), final_otp_len);

    std::stringstream ss;
    ss << "{\"X-Apple-I-MD-M\":\"" << mid
       << "\",\"X-Apple-I-MD\":\"" << otp
       << "\",\"X-Apple-I-MD-RINFO\":\"17106176\",\"X-Apple-I-MD-LU\":\"0000000000000000000000000000000000000000000000000000000000000001\"}";
    *out_json = strdup(ss.str().c_str());

    return ANISETTE_OK;
}

int32_t start_provision_uc(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    const uint8_t *spim,
    uint32_t spim_len,
    char **out_json
) {
    LOG_UC("[AnisetteKit - UC] Invoked start_provision_uc\n");
    if (!lib_dir || !provisioning_dir || !identifier || !spim || !out_json) {
        return ANISETTE_ERR_INVALID_ARGUMENT;
    }

    std::lock_guard<std::mutex> lock(g_vm_mutex);

    EmulatorVM *vm = nullptr;
    std::string uuid_prov_dir, err;
    if (!setup_vm_and_adi(vm, lib_dir, provisioning_dir, identifier, uuid_prov_dir, err)) {
        std::stringstream ss;
        ss << "{\"error\":\"" << err << "\"}";
        *out_json = strdup(ss.str().c_str());
        return ANISETTE_ERR_LOADER_FAILED;
    }

    uint64_t prov_start_ptr = get_vm_symbol_address(vm, kADISymbols.provisioning_start);
    if (!prov_start_ptr) {
        *out_json = strdup("{\"error\":\"Symbol ADIProvisioningStart missing\"}");
        return ANISETTE_ERR_SYMBOL_MISSING;
    }

    uint64_t spim_vm = vm->write_bytes(spim, spim_len);
    uint64_t cpim_ptr = vm->heap.alloc(8);
    uint64_t cpim_len_ptr = vm->heap.alloc(4);
    uint64_t session_ptr = vm->heap.alloc(4);
    // v0.3.662：这些分配/写入失败时原来是拿 0 当地址继续跑（写 0x0 页、传 NULL 给 ADI）.
    if (!spim_vm || !cpim_ptr || !cpim_len_ptr || !session_ptr) {
        *out_json = strdup("{\"error\":\"Emulator heap exhausted during provisioning start\"}");
        return ANISETTE_ERR_LOADER_FAILED;
    }

    uint64_t zero64 = 0;
    uint32_t zero32 = 0;
    uc_mem_write(vm->uc, cpim_ptr, &zero64, sizeof(zero64));
    uc_mem_write(vm->uc, cpim_len_ptr, &zero32, sizeof(zero32));
    uc_mem_write(vm->uc, session_ptr, &zero32, sizeof(zero32));

    uint64_t dsid = (uint64_t)-2;
    LOG_UC("[AnisetteKit - UC] Step 4: Calling ADIProvisioningStart (0x%llx) [spim_len=%u]...\n",
           (unsigned long long)prov_start_ptr, spim_len);
    int32_t res = run_vm_procedure(vm, prov_start_ptr, {dsid, spim_vm, (uint64_t)spim_len, cpim_ptr, cpim_len_ptr, session_ptr});
    LOG_UC("[AnisetteKit - UC] Step 4 result: %d\n", res);

    if (res != 0) {
        // v0.3.662：原来这里会 rmdir(uuid_prov_dir)。但该目录里可能已经有上一次成功配给写下的
        // adi.pb（setup_vm_and_adi 只保证目录存在），一次失败的 start 会把用户的有效 adi.pb
        // 连同目录一起删掉，下一轮就得重新向 Apple 配给。这里只记录，不再删.
        LOG_UC("[AnisetteKit - UC] ADIProvisioningStart failed; keeping provisioning dir %s\n",
               uuid_prov_dir.c_str());
        std::stringstream ss;
        ss << "{\"error\":\"ADIProvisioningStart failed ("
           << get_anisette_error_description(res) << "): " << res << "\"}";
        *out_json = strdup(ss.str().c_str());
        return res;
    }

    uint64_t final_cpim_addr = 0;
    uint32_t final_cpim_len = 0;
    uint32_t session = 0;

    // v0.3.662：同 get_anisette_headers_uc —— 先验读取结果与长度上限，再分配宿主内存.
    uc_err rs1 = uc_mem_read(vm->uc, cpim_ptr, &final_cpim_addr, 8);
    uc_err rs2 = uc_mem_read(vm->uc, cpim_len_ptr, &final_cpim_len, 4);
    uc_err rs3 = uc_mem_read(vm->uc, session_ptr, &session, 4);
    if (rs1 != UC_ERR_OK || rs2 != UC_ERR_OK || rs3 != UC_ERR_OK) {
        *out_json = strdup("{\"error\":\"Failed to read ADIProvisioningStart out-params\"}");
        return ANISETTE_ERR_INVALID_DATA;
    }
    if (final_cpim_len > kMaxAnisetteBlobLen) {
        std::stringstream ss;
        ss << "{\"error\":\"ADIProvisioningStart returned implausible cpim_len (" << final_cpim_len << ")\"}";
        *out_json = strdup(ss.str().c_str());
        return ANISETTE_ERR_INVALID_DATA;
    }

    LOG_UC("[AnisetteKit - UC] ADIProvisioningStart OK: cpim_addr=0x%llx, cpim_len=%u, session=%u\n",
           (unsigned long long)final_cpim_addr, final_cpim_len, session);
    fflush(stdout);

    std::vector<uint8_t> cpim_data(final_cpim_len);
    if (final_cpim_len > 0 && final_cpim_addr != 0 &&
        uc_mem_read(vm->uc, final_cpim_addr, cpim_data.data(), final_cpim_len) != UC_ERR_OK) {
        *out_json = strdup("{\"error\":\"Failed to read cpim buffer from guest\"}");
        return ANISETTE_ERR_INVALID_DATA;
    }

    std::string cpim_b64 = base64_encode(cpim_data.data(), final_cpim_len);

    std::stringstream ss;
    ss << "{\"cpim_base64\":\"" << cpim_b64 << "\",\"session\":" << session << "}";
    *out_json = strdup(ss.str().c_str());

    return ANISETTE_OK;
}

int32_t end_provision_uc(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    uint32_t session,
    const uint8_t *ptm,
    uint32_t ptm_len,
    const uint8_t *tk,
    uint32_t tk_len,
    char **out_json
) {
    LOG_UC("[AnisetteKit - UC] Invoked end_provision_uc\n");
    if (!lib_dir || !provisioning_dir || !identifier || !ptm || !tk || !out_json) {
        return ANISETTE_ERR_INVALID_ARGUMENT;
    }

    std::lock_guard<std::mutex> lock(g_vm_mutex);

    EmulatorVM *vm = nullptr;
    std::string uuid_prov_dir, err;
    if (!setup_vm_and_adi(vm, lib_dir, provisioning_dir, identifier, uuid_prov_dir, err)) {
        std::stringstream ss;
        ss << "{\"error\":\"" << err << "\"}";
        *out_json = strdup(ss.str().c_str());
        return ANISETTE_ERR_LOADER_FAILED;
    }

    uint64_t prov_end_ptr = get_vm_symbol_address(vm, kADISymbols.provisioning_end);
    if (!prov_end_ptr) {
        *out_json = strdup("{\"error\":\"Symbol ADIProvisioningEnd missing\"}");
        return ANISETTE_ERR_SYMBOL_MISSING;
    }

    uint64_t ptm_vm = vm->write_bytes(ptm, ptm_len);
    uint64_t tk_vm  = vm->write_bytes(tk, tk_len);
    // v0.3.662：堆/字符串写入失败原来会拿 0 当地址调 ADIProvisioningEnd.
    if (!ptm_vm || !tk_vm) {
        *out_json = strdup("{\"error\":\"Emulator heap exhausted during provisioning end\"}");
        return ANISETTE_ERR_LOADER_FAILED;
    }

    LOG_UC("[AnisetteKit - UC] Step 4: Calling ADIProvisioningEnd (0x%llx) [session=%u, ptm_len=%u, tk_len=%u]...\n",
           (unsigned long long)prov_end_ptr, session, ptm_len, tk_len);
    int32_t res = run_vm_procedure(vm, prov_end_ptr, {(uint64_t)session, ptm_vm, (uint64_t)ptm_len, tk_vm, (uint64_t)tk_len});
    LOG_UC("[AnisetteKit - UC] Step 4 result: %d\n", res);

    if (res != 0) {
        std::stringstream ss;
        ss << "{\"error\":\"ADIProvisioningEnd failed ("
           << get_anisette_error_description(res) << "): " << res << "\"}";
        *out_json = strdup(ss.str().c_str());
        return res;
    }

    std::string adi_pb_path = uuid_prov_dir + "/" + kADISymbols.adi_pb_filename;
    FILE* f = fopen(adi_pb_path.c_str(), "rb");
    if (!f) {
        *out_json = strdup("{\"error\":\"Failed to read generated adi.pb\"}");
        return ANISETTE_ERR_READ_FILE_FAILED;
    }

    // v0.3.662：ftell 失败返回 -1（强转 size_t 就是天文数字），fread 短读也无检查 ——
    // 原来会拿这个长度去 std::vector 分配并 base64，产出一个看起来合法实则乱码的 adi.pb.
    fseek(f, 0, SEEK_END);
    long file_len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (file_len <= 0 || (uint64_t)file_len > kMaxAnisetteBlobLen) {
        fclose(f);
        *out_json = strdup("{\"error\":\"Generated adi.pb has implausible size\"}");
        return ANISETTE_ERR_READ_FILE_FAILED;
    }
    size_t size = (size_t)file_len;

    std::vector<uint8_t> pb_data(size);
    size_t got = fread(pb_data.data(), 1, size, f);
    fclose(f);
    if (got != size) {
        *out_json = strdup("{\"error\":\"Failed to read generated adi.pb (short read)\"}");
        return ANISETTE_ERR_READ_FILE_FAILED;
    }

    std::string adi_pb_b64 = base64_encode(pb_data.data(), size);

    std::stringstream ss;
    ss << "{\"adi_pb_base64\":\"" << adi_pb_b64 << "\"}";
    *out_json = strdup(ss.str().c_str());

    return ANISETTE_OK;
}

int32_t cancel_provision_uc(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    uint32_t session
) {
    LOG_UC("[AnisetteKit - UC] Invoked cancel_provision_uc\n");
    if (!lib_dir || !provisioning_dir || !identifier) {
        return ANISETTE_ERR_INVALID_ARGUMENT;
    }

    std::lock_guard<std::mutex> lock(g_vm_mutex);

    // v0.3.662：原来这里直接对 g_shared_vm 取符号，从不调用 setup_vm_and_adi.
    // 后果：VM 还没建、或库还没装载（g_libraries_initialized == false）时，
    // get_vm_symbol_address 必然返回 0，整个函数什么也没做，却照样 return ANISETTE_OK，
    // 让调用方以为会话已被销毁（ADI 侧 session 会一直占着，后续 start 可能报 -45063 PendingSession）.
    // 现在按 get/start/end 同样的方式先确保 VM + ADI 就绪，失败如实返回.
    EmulatorVM *vm = nullptr;
    std::string uuid_prov_dir, err;
    if (!setup_vm_and_adi(vm, lib_dir, provisioning_dir, identifier, uuid_prov_dir, err)) {
        LOG_UC("[AnisetteKit - UC] cancel_provision_uc: setup failed: %s\n", err.c_str());
        return ANISETTE_ERR_LOADER_FAILED;
    }

    uint64_t destroy_session_ptr = get_vm_symbol_address(vm, kADISymbols.destroy_session);
    if (!destroy_session_ptr) {
        LOG_UC("[AnisetteKit - UC] cancel_provision_uc: symbol ADIProvisioningDestroy missing\n");
        return ANISETTE_ERR_SYMBOL_MISSING;
    }

    int32_t res = run_vm_procedure(vm, destroy_session_ptr, {(uint64_t)session});
    LOG_UC("[AnisetteKit - UC] cancel_provision_uc: ADIProvisioningDestroy(session=%u) -> %d\n",
           session, res);
    if (res != 0) {
        return res;
    }

    return ANISETTE_OK;
}

}
