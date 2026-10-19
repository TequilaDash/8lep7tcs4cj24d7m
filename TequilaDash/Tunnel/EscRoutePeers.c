//
//  EscRoutePeers.c
//  TequilaDash
//
//  路由表 → utun 目的地址 / 网关。设计说明见 EscRoutePeers.h。
//
//  ## 为什么不用 getifaddrs 的 ifa_dstaddr
//  真机证据（2026-10-17 诊断页）：utun 接口存在，但 `ifa_dstaddr` 枚举出 0 个对端，
//  候选只剩兜底 10.7.0.1 ⇒ 连的是兜底值。而 minimuxer 的
//  `destinationIPs` / `destinationGatewayIPs` / `linkLayerDestinationIP`
//  三个都来自**路由表**。所以这里按路由表取。
//
//  ## 为什么自声明结构体而不是 #include <net/route.h>
//  **iOS 公共 SDK 不含 `net/route.h`**（CI 实测：`'net/route.h' file not found`）。
//  该头在 Darwin 里属系统内部头。所以这里只复制**实际用到的**布局：
//  消息头前 36 字节（到 `rtm_inits`）+ `rt_metrics` 60 字节 = **96 字节**，
//  随后才是 sockaddr 数组。字段名一律加 `esc_` 前缀，避免与任何系统头冲突。
//
//  ## 解析要点（BSD 路由消息布局）
//  1. `sysctl(CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP)` 返回一串变长记录；
//  2. 每条记录是 96 字节消息头 + 最多 `RTAX_MAX` 个 sockaddr；
//  3. 哪些 sockaddr 存在由 `rtm_addrs` 的位掩码决定，顺序固定为
//     DST(0) GATEWAY(1) NETMASK(2) GENMASK(3) IFP(4) IFA(5) …
//  4. 每个 sockaddr 按 **8 字节槽位**推进（`sa_len` 不含填充；见 esc_sa_roundup）；
//     但**不管按几字节推进**，解释这一段之前都必须有 16 字节可见（ESC_SA_HEADER_BYTES）；
//  5. `RTAX_IFP` 是 `sockaddr_dl`，`sdl_data` 前 `sdl_nlen` 字节是接口名；
//     点对点链路的 `RTAX_GATEWAY` 也是 `sockaddr_dl`，其地址区尾部 4 字节是对端 IPv4。
//

#include "EscRoutePeers.h"

#include <net/if.h>
#include <net/if_dl.h>      // sockaddr_dl / sdl_nlen / sdl_alen（公共 SDK 里**有**）
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// net/route.h 不在 iOS 公共 SDK 里，这里按 Darwin 布局自声明（见文件头说明）.
#ifndef NET_RT_DUMP
#define NET_RT_DUMP 4
#endif
#define ESC_RTAX_DST      0
#define ESC_RTAX_GATEWAY  1
#define ESC_RTAX_NETMASK  2
#define ESC_RTAX_GENMASK  3
#define ESC_RTAX_IFP      4
#define ESC_RTAX_IFA      5
#define ESC_RTAX_MAX      8

/// `struct rt_metrics` 的等价布局（15 × uint32 = 60 字节）.
typedef struct {
    uint32_t esc_metrics[15];
} esc_rt_metrics;

/// `struct rt_msghdr` 的等价布局（36 + 60 = 96 字节）.
/// 只读前两个字段（`msglen` / `addrs`），其余字段仅为**对齐占位**.
typedef struct {
    uint16_t esc_msglen;
    uint8_t  esc_version;
    uint8_t  esc_type;
    uint16_t esc_index;
    int32_t  esc_flags;
    int32_t  esc_addrs;
    int32_t  esc_pid;
    int32_t  esc_seq;
    int32_t  esc_errno;
    int32_t  esc_use;
    uint32_t esc_inits;
    esc_rt_metrics esc_rmx;
} esc_rt_msghdr;

/// 编译期校验：与 Darwin `sizeof(struct rt_msghdr)` 一致（96）.
/// 若某天布局变化，这里会先炸而不是静默解析错位.
typedef char esc_rt_msghdr_size_check[(sizeof(esc_rt_msghdr) == 96) ? 1 : -1];

#define ESC_MAX_PEERS 16
#define ESC_MAX_IFNAME 32
/// 解释一段 sockaddr 前必须可见的字节数（= sizeof(struct sockaddr)，
/// 足够覆盖 sockaddr_dl 的 sdl_len/sdl_family/sdl_nlen/sdl_alen/sdl_slen）.
#define ESC_SA_HEADER_BYTES 16u

/// sockaddr 之间的推进口径.
///
/// v0.3.673（task-7 P0，**需实测**）：这里原先按 4 字节对齐（`& ~3`），
/// 但 Darwin 的 `SA_SIZE(sa)`（<sys/socket.h>）是 **8 字节**对齐：
///     #define SA_SIZE(sa) (((sa)->sa_len == 0) ? 1 : ROUNDUP(sa->sa_len))
///     #define ROUNDUP(a) ((a) > 0 ? (1 + (((a) - 1) | (sizeof(uint32_t) - 1))) : sizeof(uint32_t))
/// 注意 ROUNDUP 的 `sizeof(uint32_t)` 只是掩码宽度（4-1=3），内核在 rtsock 里
/// 实际再按 8 字节补齐（rtm_addrs 位宽 RTAX_MAX==8 亦与 8 字节槽位对应）。
/// 用 4 字节的后果：掩码里 1 字节的 IPv4 网络掩码（sa_len==19）推进 20 而非 24，
/// 之后每个 sockaddr 指针都错位 4 字节 ⇒ RTAX_IFP 读到的不是接口名、
/// interfaceName 永远是空串、:202 的 strncmp 永不命中，函数恒定返回 NULL；
/// 错位后再按错位的 sa_len 推进还可能把垃圾当成 IPv4 收进候选（假 peer，
/// 白白吃掉每个候选 3 秒的建连预算）。
/// 越界判定本身是安全的（:198 有 cursor + advance <= end 兜底），错的是解析结果。
static size_t esc_sa_roundup(size_t length) {
    if (length == 0) return 0;
    return (length + 7u) & ~(size_t)7u;
}

/// 从 `sockaddr_dl` 取接口名（`sdl_data` 前 `sdl_nlen` 字节）.
static void esc_ifname_from_dl(const struct sockaddr_dl *dl, char *out, size_t capacity) {
    out[0] = '\0';
    if (dl == NULL || capacity == 0) return;
    size_t nameLength = (size_t)dl->sdl_nlen;
    if (nameLength == 0 || nameLength >= capacity) return;
    memcpy(out, dl->sdl_data, nameLength);
    out[nameLength] = '\0';
}

/// 从 `sockaddr_dl` 的地址区取对端 IPv4（点对点链路）.
static int esc_peer_from_dl(const struct sockaddr_dl *dl, struct in_addr *out) {
    if (dl == NULL || out == NULL) return 0;
    if (dl->sdl_alen < 4) return 0;
    // v0.3.673（task-7 发现21 的可静态证明部分）：必须自己证明「sdl_data 里真的有
    // sdl_nlen + sdl_alen 字节」，不能只信 sdl_alen。
    // 内核对 AF_LINK 只按 SA_SIZE(sa) 的 8 字节对齐给出长度，缓冲尾巴可能被截断；
    // 下面 (void *)dl 的读只在调用方已保证 cursor + SA_SIZE 可见时安全（见 :159 的循环条件），
    // 但 sdl_nlen/sdl_alen 是**内核给的任意值**，二者之和可以超过 sdl_len。
    // 截断样本：sdl_len=8 / sdl_nlen=5 / sdl_alen=8 —— 地址区根本没有 8 字节，
    // 原代码 address += sdl_alen - 4 后读 address[0..3] 就是越界读。
    if ((size_t)dl->sdl_nlen + (size_t)dl->sdl_alen > (size_t)dl->sdl_len) return 0;
    const unsigned char *address = (const unsigned char *)dl->sdl_data + dl->sdl_nlen;
    if (dl->sdl_alen >= 8) {
        // 部分实现会在地址区前置 4 字节；取尾部 4 字节更稳.
        address += dl->sdl_alen - 4;
    }
    unsigned char bytes[4] = { address[0], address[1], address[2], address[3] };
    if (bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0) return 0;
    memcpy(out, bytes, 4);
    return 1;
}

/// 收集一个候选（去重、跳过非法值）.
static void esc_push(struct in_addr value, struct in_addr *list, size_t *count) {
    if (value.s_addr == 0 || value.s_addr == INADDR_ANY || value.s_addr == INADDR_BROADCAST) return;
    unsigned char first = ((unsigned char *)&value.s_addr)[0];
    if (first == 127 || first == 224 || first == 239) return;   // 回环 / 组播
    for (size_t i = 0; i < *count; i++) {
        if (list[i].s_addr == value.s_addr) return;
    }
    if (*count < ESC_MAX_PEERS) {
        list[(*count)++] = value;
    }
}

char *esc_route_utun_peers(size_t *outCount) {
    if (outCount != NULL) *outCount = 0;

    int mib[6] = { CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0 };
    size_t needed = 0;
    if (sysctl(mib, 6, NULL, &needed, NULL, 0) != 0 || needed == 0) return NULL;

    char *buffer = malloc(needed);
    if (buffer == NULL) return NULL;
    if (sysctl(mib, 6, buffer, &needed, NULL, 0) != 0) {
        free(buffer);
        return NULL;
    }

    struct in_addr peers[ESC_MAX_PEERS];
    size_t peerCount = 0;

    size_t offset = 0;
    while (offset + sizeof(esc_rt_msghdr) <= needed) {
        const esc_rt_msghdr *header = (const esc_rt_msghdr *)(const void *)(buffer + offset);
        size_t messageLength = (size_t)header->esc_msglen;
        if (messageLength <= sizeof(esc_rt_msghdr) || offset + messageLength > needed) break;

        // 逐条 sockaddr：RTAX 顺序，按 rtm_addrs 位掩码判断存在性.
        const char *cursor = buffer + offset + sizeof(esc_rt_msghdr);
        const char *end = buffer + offset + messageLength;
        char interfaceName[ESC_MAX_IFNAME] = { 0 };
        struct in_addr destination = { 0 };
        struct in_addr gateway = { 0 };
        int hasDestination = 0;
        int hasGateway = 0;

        // v0.3.673：循环条件用 ESC_SA_HEADER_BYTES（16 = sizeof(struct sockaddr)）——
        // esc_peer_from_dl 要读 sdl_nlen/sdl_alen/sdl_len（sockaddr_dl 的 8 字节头），
        // 只保证 6 字节可见是读不到的。
        for (int index = 0; index < ESC_RTAX_MAX && cursor + ESC_SA_HEADER_BYTES <= end; index++) {
            const struct sockaddr *sa = (const struct sockaddr *)(const void *)cursor;
            size_t length = (size_t)sa->sa_len;
            if (length == 0) break;
            // v0.3.673（task-7 发现21 续，**需实测**）：
            // 原先后面只在「推进会越界」时 break，但**先把这一段读成了 sockaddr**——
            // 若把推进口径改成内核真实的 8 字节槽位（SA_SIZE），最后一项（例如
            // AF_LINK 的 sockaddr_dl，sa_len 往往只有 10~20）的 16 字节头就可能跨过
            // 消息末尾，读 sa_len/sdl_* 即为越界读。
            // 必须有 16 字节可见（= sizeof(struct sockaddr)，覆盖 sockaddr_dl 的
            // sdl_len/sdl_family/sdl_nlen/sdl_alen/sdl_slen 五个字段）才允许解释这一段。
            if (cursor + ESC_SA_HEADER_BYTES > end) break;

            if ((header->esc_addrs & (1 << index)) != 0) {
                switch (index) {
                    case ESC_RTAX_DST:
                        if (sa->sa_family == AF_INET) {
                            const struct sockaddr_in *sin = (const struct sockaddr_in *)(const void *)sa;
                            destination = sin->sin_addr;
                            hasDestination = 1;
                        }
                        break;
                    case ESC_RTAX_GATEWAY:
                        if (sa->sa_family == AF_INET) {
                            const struct sockaddr_in *sin = (const struct sockaddr_in *)(const void *)sa;
                            gateway = sin->sin_addr;
                            hasGateway = 1;
                        } else if (sa->sa_family == AF_LINK) {
                            struct in_addr peer = { 0 };
                            if (esc_peer_from_dl((const struct sockaddr_dl *)(const void *)sa, &peer)) {
                                gateway = peer;
                                hasGateway = 1;
                            }
                        }
                        break;
                    case ESC_RTAX_IFP:
                        if (sa->sa_family == AF_LINK) {
                            esc_ifname_from_dl((const struct sockaddr_dl *)(const void *)sa,
                                               interfaceName, sizeof(interfaceName));
                        }
                        break;
                    // v0.3.673（task-7 发现，**需实测**）：RTAX_DST/GATEWAY/IFP 之外，
                    // Darwin 还可能把接口名放在 RTAX_IFA（本地地址，同一位置是 sockaddr_dl）。
                    // 只认 IFP 会让「有 IFA 无 IFP」的路由被整条丢弃。
                    // 因为只有真的在真机上验证过报错才会改行为，这里先补一个**只在
                    // interfaceName 仍为空时**才采用的兜底。
                    case ESC_RTAX_IFA:
                        if (sa->sa_family == AF_LINK && interfaceName[0] == '\0') {
                            esc_ifname_from_dl((const struct sockaddr_dl *)(const void *)sa,
                                               interfaceName, sizeof(interfaceName));
                        }
                        break;
                    default:
                        break;
                }
            }

            size_t advance = esc_sa_roundup(length);
            if (advance == 0 || cursor + advance > end) break;
            cursor += advance;
        }

        if (strncmp(interfaceName, "utun", 4) == 0) {
            if (hasDestination) esc_push(destination, peers, &peerCount);
            if (hasGateway) esc_push(gateway, peers, &peerCount);
        }

        offset += messageLength;
    }

    free(buffer);

    if (peerCount == 0) return NULL;

    // 拼成逗号分隔的 IPv4 字符串.
    size_t capacity = peerCount * (INET_ADDRSTRLEN + 1) + 1;
    char *result = malloc(capacity);
    if (result == NULL) return NULL;
    result[0] = '\0';
    size_t used = 0;
    size_t emittedCount = 0;
    for (size_t i = 0; i < peerCount; i++) {
        char text[INET_ADDRSTRLEN] = { 0 };
        if (inet_ntop(AF_INET, &peers[i], text, sizeof(text)) == NULL) continue;
        int written = snprintf(result + used, capacity - used, "%s%s", (used == 0 ? "" : ","), text);
        if (written <= 0 || (size_t)written >= capacity - used) break;
        used += (size_t)written;
        emittedCount++;
    }

    if (used == 0) {
        free(result);
        return NULL;
    }
    // v0.3.673：outCount 报「真正写进字符串的个数」，而不是去重后 push 的个数。
    // 原先 inet_ntop 失败或 snprintf 截断时会少写若干条，但 outCount 仍是 peerCount,
    // 调用方按 outCount 拆字符串就会拿到 NULL/越界。当前唯一调用方
    // （LocalDevVPN.swift 的 routeTablePeers）不读 outCount，但这属于迟早踩的坑。
    if (outCount != NULL) *outCount = emittedCount;
    return result;
}

void esc_route_utun_peers_free(char *value) {
    free(value);
}
