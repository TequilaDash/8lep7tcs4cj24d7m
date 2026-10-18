//
//  applist.c
//  StikJIT
//
//  Created by Stephen on 3/27/25.
//

#import "idevice.h"
#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>
#import "applist.h"
static NSString *extractAppName(plist_t app)
{
    plist_t displayNameNode = plist_dict_get_item(app, "CFBundleDisplayName");
    if (displayNameNode) {
        char *displayNameC = NULL;
        plist_get_string_val(displayNameNode, &displayNameC);
        if (displayNameC && displayNameC[0] != '\0') {
            NSString *displayName = [NSString stringWithUTF8String:displayNameC];
            plist_mem_free(displayNameC);
            return displayName;
        }
        plist_mem_free(displayNameC);
    }

    plist_t nameNode = plist_dict_get_item(app, "CFBundleName");
    if (nameNode) {
        char *nameC = NULL;
        plist_get_string_val(nameNode, &nameC);
        if (nameC && nameC[0] != '\0') {
            NSString *name = [NSString stringWithUTF8String:nameC];
            plist_mem_free(nameC);
            return name;
        }
        plist_mem_free(nameC);
    }

    return @"Unknown";
}

static BOOL nodeContainsHiddenTag(plist_t tagsNode)
{
    if (!tagsNode || plist_get_node_type(tagsNode) != PLIST_ARRAY) {
        return NO;
    }

    uint32_t tagsCount = plist_array_get_size(tagsNode);
    for (uint32_t i = 0; i < tagsCount; i++) {
        plist_t tagNode = plist_array_get_item(tagsNode, i);
        if (!tagNode || plist_get_node_type(tagNode) != PLIST_STRING) {
            continue;
        }
        char *tagC = NULL;
        plist_get_string_val(tagNode, &tagC);
        if (!tagC) {
            continue;
        }
        BOOL isHidden = (strcmp(tagC, "hidden") == 0 || strcmp(tagC, "hidden-system-app") == 0);
        free(tagC);
        if (isHidden) {
            return YES;
        }
    }
    return NO;
}

static BOOL isHiddenSystemApp(plist_t app)
{
    plist_t typeNode = plist_dict_get_item(app, "ApplicationType");
    BOOL isSystemType = NO;
    if (typeNode && plist_get_node_type(typeNode) == PLIST_STRING) {
        char *typeC = NULL;
        plist_get_string_val(typeNode, &typeC);
        if (typeC) {
            if (strcmp(typeC, "System") == 0 || strcmp(typeC, "HiddenSystemApp") == 0) {
                isSystemType = YES;
            }
            free(typeC);
        }
    }

    if (!isSystemType) {
        return NO;
    }

    plist_t hiddenNode = plist_dict_get_item(app, "IsHidden");
    if (hiddenNode && plist_get_node_type(hiddenNode) == PLIST_BOOLEAN) {
        uint8_t hidden = 0;
        plist_get_bool_val(hiddenNode, &hidden);
        if (hidden) {
            return YES;
        }
    }

    plist_t tagsNode = plist_dict_get_item(app, "SBAppTags");
    if (nodeContainsHiddenTag(tagsNode)) {
        return YES;
    }

    return NO;
}

static NSDictionary<NSString*, NSString*> *buildAppDictionary(void *apps,
                                                             size_t count,
                                                             BOOL requireGetTaskAllow,
                                                             BOOL (^filter)(plist_t app))
{
    NSMutableDictionary<NSString*, NSString*> *result = [NSMutableDictionary dictionaryWithCapacity:count];

    for (size_t i = 0; i < count; i++) {
        plist_t app = ((plist_t *)apps)[i];
        plist_t ent = plist_dict_get_item(app, "Entitlements");

        if (requireGetTaskAllow) {
            if (!ent) continue;
            plist_t tnode = plist_dict_get_item(ent, "get-task-allow");
            if (!tnode) continue;

            uint8_t isAllowed = 0;
            plist_get_bool_val(tnode, &isAllowed);
            if (!isAllowed) continue;
        }

        if (filter && !filter(app)) {
            continue;
        }

        plist_t bidNode = plist_dict_get_item(app, "CFBundleIdentifier");
        if (!bidNode) continue;

        char *bidC = NULL;
        plist_get_string_val(bidNode, &bidC);
        if (!bidC || bidC[0] == '\0') {
            plist_mem_free(bidC);
            continue;
        }

        NSString *bundleID = [NSString stringWithUTF8String:bidC];
        plist_mem_free(bidC);

        result[bundleID] = extractAppName(app);
    }

    return result;
}

static NSDictionary<NSString*, NSString*> *performAppQuery(struct AdapterHandle *adapter,
                                                           struct RsdHandshakeHandle *handshake,
                                                           BOOL requireGetTaskAllow,
                                                           NSString **error,
                                                           BOOL (^filter)(plist_t app))
{
    InstallationProxyClientHandle *client = NULL;
    IdeviceFfiError* err = installation_proxy_connect_rsd(adapter, handshake, &client);
    if (err) {
        // v0.3.673（task-7 发现16）：`*error` 必须判空。三个公开入口
        // list_installed_apps / list_all_apps / list_hidden_system_apps 把调用方的
        // error 指针原样透传下来，而 TunnelContext 侧存在传 NULL 的调用点
        // （只要返回值不看错因）。传 NULL 时这一句就是写地址 0 = 段错误。
        if (error) *error = [NSString stringWithFormat:@"Failed to connect to installation proxy: %s", err->message];
        idevice_error_free(err);
        return nil;
    }

    plist_t *apps = NULL;
    size_t count = 0;
    err = installation_proxy_get_apps(client, NULL, NULL, 0, (void*)&apps, &count);
    if (err) {
        if (error) *error = [NSString stringWithFormat:@"Failed to get apps: %s", err->message];
        idevice_error_free(err);
        installation_proxy_client_free(client);
        return nil;
    }

    NSDictionary<NSString*, NSString*> *result = buildAppDictionary(apps, count, requireGetTaskAllow, filter);
    installation_proxy_client_free(client);
    for(int i = 0; i < count; ++i) {
        plist_free(apps[i]);
    }
    idevice_data_free((uint8_t *)apps, sizeof(plist_t)*count);
    return result;
}

NSDictionary<NSString*, NSString*>* list_installed_apps(struct AdapterHandle *adapter, struct RsdHandshakeHandle *handshake, NSString** error) {
    return performAppQuery(adapter, handshake, YES, error, nil);
}

NSDictionary<NSString*, NSString*>* list_all_apps(struct AdapterHandle *adapter, struct RsdHandshakeHandle *handshake, NSString** error) {
    return performAppQuery(adapter, handshake, NO, error, nil);
}

NSDictionary<NSString*, NSString*>* list_hidden_system_apps(struct AdapterHandle *adapter, struct RsdHandshakeHandle *handshake, NSString** error) {
    return performAppQuery(adapter, handshake, NO, error, ^BOOL(plist_t app) {
        return isHiddenSystemApp(app);
    });
}

UIImage* getAppIcon(struct AdapterHandle *adapter, struct RsdHandshakeHandle *handshake, NSString* bundleID, NSString** error) {
    SpringBoardServicesClientHandle *client = NULL;
    if (springboard_services_connect_rsd(adapter, handshake, &client)) {
        if (error) *error = @"Failed to connect to SpringBoard Services";
        return nil;
    }

    void *pngData = NULL;
    size_t dataLen = 0;
    if (springboard_services_get_icon(client, [bundleID UTF8String], &pngData, &dataLen)) {
        springboard_services_free(client);
        if (error) *error = @"Failed to get app icon";
        return nil;
    }

    NSData *data = [NSData dataWithBytes:pngData length:dataLen];
    free(pngData);
    UIImage *icon = [UIImage imageWithData:data];

    springboard_services_free(client);
    return icon;
}

NSDictionary *getAllAppsInfo(struct AdapterHandle *adapter, struct RsdHandshakeHandle *handshake, NSString **error) {
    InstallationProxyClientHandle *client = NULL;
    if (installation_proxy_connect_rsd(adapter, handshake, &client)) {
        if (error) *error = @"Failed to connect to installation proxy";
        return nil;
    }

    void *apps = NULL;
    size_t count = 0;
    if (installation_proxy_get_apps(client, NULL, NULL, 0, &apps, &count)) {
        installation_proxy_client_free(client);
        if (error) *error = @"Failed to get apps";
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
        plist_t app = ((plist_t *)apps)[i];
        // v0.3.673（task-7 发现14/15）：plist_to_objc_object 对无法映射的节点
        // （PLIST_UID / PLIST_NULL / NONE 之外的类型）返回 nil；直接用
        // `result[appInfo[@"CFBundleIdentifier"]]` 会变成「用 nil 作 key」，
        // 触发 NSInvalidArgumentException —— 而调用链上游 TunnelContext.m 的 @try 只有
        // @finally 没有 @catch，异常会一路冒到 worker 的 @catch，整次建连被判失败。
        // 这里必须逐层兜底：非字典跳过、无 CFBundleIdentifier 跳过。
        id appInfo = plist_to_objc_object(app);
        if (![appInfo isKindOfClass:[NSDictionary class]]) continue;
        id bundleID = ((NSDictionary *)appInfo)[@"CFBundleIdentifier"];
        if (![bundleID isKindOfClass:[NSString class]] || ((NSString *)bundleID).length == 0) continue;
        result[bundleID] = appInfo;
    }

    installation_proxy_client_free(client);
    // v0.3.673（task-7 发现13）：安装代理返回的是 Rust 侧 into_boxed_slice 出来的
    // Vec<plist_t>（见 rust/idevice-ffi/src/installation_proxy.rs 的
    // `let mut r = r.into_boxed_slice(); std::mem::forget(r);`），元素是 PlistWrapper。
    // 原先这里既不 plist_free 元素、也不回收外层数组 ⇒ 每次主界面刷新泄漏整棵 app plist 树。
    // 正确释放函数是 idevice_plist_array_free（rust/idevice-ffi/src/lib.rs）：
    // 它逐个 plist_free 元素、再按 Vec 布局回收外层切片。
    idevice_plist_array_free((plist_t *)apps, count);
    return result;
}

NSDictionary *getAllAppsInfoFromProvider(struct IdeviceProviderHandle *provider, NSString **error) {
    InstallationProxyClientHandle *client = NULL;
    struct IdeviceFfiError *err = installation_proxy_connect(provider, &client);
    if (err) {
        if (error) *error = [NSString stringWithFormat:@"Failed to connect to installation proxy: %s", err->message];
        idevice_error_free(err);
        return nil;
    }

    void *apps = NULL;
    size_t count = 0;
    err = installation_proxy_get_apps(client, NULL, NULL, 0, &apps, &count);
    if (err) {
        installation_proxy_client_free(client);
        if (error) *error = [NSString stringWithFormat:@"Failed to get apps: %s", err->message];
        idevice_error_free(err);
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
        plist_t app = ((plist_t *)apps)[i];
        // v0.3.673（task-7 发现14/15）：与 getAllAppsInfo 同款兜底，见该函数内注释。
        id appInfo = plist_to_objc_object(app);
        if (![appInfo isKindOfClass:[NSDictionary class]]) continue;
        id bundleID = ((NSDictionary *)appInfo)[@"CFBundleIdentifier"];
        if (![bundleID isKindOfClass:[NSString class]] || ((NSString *)bundleID).length == 0) continue;
        result[bundleID] = appInfo;
    }

    installation_proxy_client_free(client);
    // v0.3.673（task-7 发现13）：同 getAllAppsInfo —— 元素与外壳都必须交还 Rust 侧释放。
    idevice_plist_array_free((plist_t *)apps, count);
    return result;
}

UIImage *getAppIconFromProvider(struct IdeviceProviderHandle *provider, NSString *bundleID, NSString **error) {
    SpringBoardServicesClientHandle *client = NULL;
    struct IdeviceFfiError *err = springboard_services_connect(provider, &client);
    if (err) {
        if (error) *error = [NSString stringWithFormat:@"Failed to connect to SpringBoard Services: %s", err->message];
        idevice_error_free(err);
        return nil;
    }

    void *pngData = NULL;
    size_t dataLen = 0;
    err = springboard_services_get_icon(client, [bundleID UTF8String], &pngData, &dataLen);
    if (err) {
        springboard_services_free(client);
        if (error) *error = [NSString stringWithFormat:@"Failed to get app icon: %s", err->message];
        idevice_error_free(err);
        return nil;
    }

    NSData *data = [NSData dataWithBytes:pngData length:dataLen];
    free(pngData);
    UIImage *icon = [UIImage imageWithData:data];
    springboard_services_free(client);
    return icon;
}

BOOL uninstall_app(struct AdapterHandle *adapter, struct RsdHandshakeHandle *handshake, NSString *bundleID, NSString **error) {
    InstallationProxyClientHandle *client = NULL;
    struct IdeviceFfiError *err = installation_proxy_connect_rsd(adapter, handshake, &client);
    if (err) {
        if (error) *error = [NSString stringWithFormat:@"无法连接安装代理（RPPairing）：%s", err->message];
        idevice_error_free(err);
        return NO;
    }
    err = installation_proxy_uninstall(client, [bundleID UTF8String], NULL);
    installation_proxy_client_free(client);
    if (err) {
        if (error) *error = [NSString stringWithFormat:@"卸载失败（RPPairing）：%s", err->message];
        idevice_error_free(err);
        return NO;
    }
    return YES;
}

BOOL uninstall_app_from_provider(struct IdeviceProviderHandle *provider, NSString *bundleID, NSString **error) {
    InstallationProxyClientHandle *client = NULL;
    struct IdeviceFfiError *err = installation_proxy_connect(provider, &client);
    if (err) {
        if (error) *error = [NSString stringWithFormat:@"无法连接安装代理（lockdown）：%s", err->message];
        idevice_error_free(err);
        return NO;
    }
    err = installation_proxy_uninstall(client, [bundleID UTF8String], NULL);
    installation_proxy_client_free(client);
    if (err) {
        if (error) *error = [NSString stringWithFormat:@"卸载失败（lockdown）：%s", err->message];
        idevice_error_free(err);
        return NO;
    }
    return YES;
}

id plist_to_objc_object(plist_t plist) {
    switch (plist_get_node_type(plist)) {
        case PLIST_NONE: {
            return [NSNull null];
        }
        case PLIST_BOOLEAN: {
            uint8_t val = 0;
            plist_get_bool_val(plist, &val);
            return @(!!val);
        }
        case PLIST_INT: {
            uint64_t val = 0;
            plist_get_uint_val(plist, &val);
            return @(val);
        }
        case PLIST_REAL: {
            double val = 0.0;
            plist_get_real_val(plist, &val);
            return @(val);
        }
        case PLIST_STRING: {
            char *str = NULL;
            plist_get_string_val(plist, &str);
            NSString *result = str ? @(str) : nil;
            free(str);
            return result;
        }
        case PLIST_ARRAY: {
            uint32_t size = plist_array_get_size(plist);
            NSMutableArray *array = [NSMutableArray arrayWithCapacity:size];
            for (uint32_t i = 0; i < size; i++) {
                plist_t item = plist_array_get_item(plist, i);
                [array addObject:plist_to_objc_object(item) ?: [NSNull null]];
            }
            return array;
        }
        case PLIST_DICT: {
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            plist_dict_iter it = NULL;
            plist_dict_new_iter(plist, &it);
            char *key = NULL;
            plist_t value = NULL;
            while (plist_dict_next_item(plist, it, &key, &value), value) {
                id objValue = plist_to_objc_object(value) ?: [NSNull null];
                if (key) {
                    dict[@(key)] = objValue;
                    free(key);
                }
            }
            free(it);
            return dict;
        }
        case PLIST_DATE: {
            int64_t sec;
            plist_get_unix_date_val(plist, &sec);
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:sec];
            return date;
        }
        case PLIST_DATA: {
            char *data;
            uint64_t length = 0;
            plist_get_data_val(plist, &data, &length);
            NSData *nsdata = [NSData dataWithBytes:data length:length];
            free(data);
            return nsdata;
        }
        case PLIST_KEY: {
            char *str = NULL;
            plist_get_key_val(plist, &str);
            NSString *result = str ? @(str) : nil;
            free(str);
            return result;
        }
        case PLIST_UID: {
            // v0.3.673（task-7 发现15）：PLIST_UID 在协议里就是一个带类型的整数
            // （NSKeyedArchiver 的 $objects/$class 里到处都是），原来落到 default 返回 nil，
            // 让任何含 UID 的节点整体变 nil —— 上层若直接用它当字典 key 会抛异常
            // （见 getAllAppsInfo 的注释），这里是 nil 的**源头**，就地修掉。
            // 注意：本函数无 plist_get_uid_val 的包装，改用通用取值 + 释放。
            char *val = NULL;
            uint64_t length = 0;
            plist_get_data_val(plist, &val, &length);
            // plist_get_data_val 对 UID 节点取出来的是 8 字节大端 u64，这里按长度判断。
            if (val == NULL) return nil;
            uint64_t uid = 0;
            for (uint64_t i = 0; i < length && i < sizeof(uid); i++) {
                uid = (uid << 8) | (uint8_t)val[i];
            }
            free(val);
            return @(uid);
        }
        case PLIST_NULL:
        default:
            return nil;
    }
}

// (The JITEnableContext(App) category from upstream StikDebug is intentionally
// omitted here; TequilaDash uses its own TunnelContext which calls the plain C
// functions above directly.)
