import SwiftUI

/// v0.3.298：爱思商店（专题 / 榜单）—— 走 `I4StoreClient` 的签名接口
struct AppStoreI4View: View {
    @State private var specials: [[String: Any]] = []
    @State private var apps: [[String: Any]] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var rank: I4StoreClient.Rank = .mustHave
    @State private var tab = 0

    var body: some View {
        List {
            Section {
                Picker("视图", selection: $tab) {
                    Text("专题").tag(0)
                    Text("榜单").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            if tab == 1 {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(I4StoreClient.Rank.allCases) { r in
                                Button {
                                    rank = r
                                    Task { await loadApps() }
                                } label: {
                                    Text(r.title)
                                        .font(.subheadline.weight(rank == r ? .semibold : .regular))
                                        .foregroundStyle(rank == r ? Color.white : Color.primary)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(rank == r ? AppTheme.accent : Color(.tertiarySystemFill), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }

            if loading {
                Section {
                    AppLoadingRow(title: "加载中…", level: .block)
                }
            } else if let errorText {
                Section {
                    // v0.3.x 批 3 错误态收敛：同构错误区统一到 AppErrorRow.
                    AppErrorRow(message: errorText, retry: { Task { await reload() } }, centered: true)
                        .padding(.vertical, 30)
                }
            } else if tab == 0 {
                specialSection
            } else {
                appSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("爱思商店")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading)
            }
        }
        .toastHost()
        .task { await reload() }
    }

    // MARK: 专题

    @ViewBuilder
    private var specialSection: some View {
        if specials.isEmpty {
            // v0.3.721：系统 ContentUnavailableView 收敛到 AppStateSection —— 同一张 Section 卡里
            // 的 loading / error 早就是 AppLoadingRow / AppErrorRow，只有 empty 还是系统件.
            AppStateSection(state: .empty("暂无专题",
                                          message: "签名成功后等待服务端返回专题列表.",
                                          icon: "square.stack.3d.up"))
        } else {
            Section("专题 · \(specials.count)") {
                ForEach(Array(specials.enumerated()), id: \.offset) { _, s in
                    NavigationLink {
                        I4SpecialAppsView(specialId: specialId(s), name: (s["name"] as? String) ?? "专题")
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: (s["icon"] as? String) ?? "")) { phase in
                                if case .success(let img) = phase { img.resizable().scaledToFill() }
                                else { Color(.tertiarySystemFill) }
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.button, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text((s["name"] as? String) ?? "—").font(.subheadline.weight(.medium)).lineLimit(1)
                                Text((s["introduce"] as? String) ?? "")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                if let c = s["scount"] as? NSNumber {
                                    Text("\(c.intValue) 款应用").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: 榜单

    @ViewBuilder
    private var appSection: some View {
        if apps.isEmpty {
            AppStateSection(state: .empty("该榜单暂无数据",
                                          message: "签名成功；remd 未返回条目.",
                                          icon: "square.grid.2x2"))
        } else {
            Section("\(rank.title) · \(apps.count)") {
                ForEach(Array(apps.enumerated()), id: \.offset) { idx, a in
                    HStack(spacing: 12) {
                        Text("\(idx + 1)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(idx < 3 ? AppTheme.pending : Color.secondary)
                            .frame(width: 22)
                        AsyncImage(url: URL(string: iconURL(a))) { phase in
                            if case .success(let img) = phase { img.resizable().scaledToFit() }
                            else { Color(.tertiarySystemFill) }
                        }
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(appName(a)).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text((a["desc"] as? String) ?? (a["introduce"] as? String) ?? "")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Button {
                            Task { await install(a) }
                        } label: {
                            // 与免登录商店统一为「获取」（这里是"定位包 → 下载 → 安装"，不是装已下载的包）
                            // Step 3 批 6-C：手写胶囊收编到共享 `SizePill` 的 `.regular` 档（caption + 10 / 5）；
                            // 字重 `.semibold` 与档位默认一致，底色 14% 用覆盖项钉住（默认 12%）.
                            SizePill(text: "获取",
                                     tint: AppTheme.categoryStore,
                                     level: .regular,
                                     fillOpacity: 0.14)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func specialId(_ s: [String: Any]) -> String {
        if let n = s["id"] as? NSNumber { return n.stringValue }
        if let str = s["id"] as? String { return str }
        return ""
    }

    private func iconURL(_ a: [String: Any]) -> String {
        (a["icon"] as? String) ?? (a["iconurl"] as? String) ?? (a["head"] as? String) ?? ""
    }

    private func appName(_ a: [String: Any]) -> String {
        (a["name"] as? String) ?? (a["appname"] as? String) ?? (a["title"] as? String) ?? "—"
    }

    // MARK: 安装

    /// 取详情 → 解析 manifest plist → 交给系统 itms-services
    private func install(_ a: [String: Any]) async {
        let bid = i4Value(a, keys: ["bundleid", "bundleId", "sourceid", "sourceId"])
        let name = i4Value(a, keys: ["name", "appname", "appName", "title"])
        guard !bid.isEmpty else {
            ToastCenter.shared.show("该条目缺少 Bundle ID，无法匹配安装包")
            return
        }
        do {
            guard let hit = await SourcePackageLocator.find(bundleId: bid, name: name) else {
                ToastCenter.shared.show("免登录源里没有该应用")
                return
            }
            let ipa = try await AppStoreInstallService.downloadIPA(
                urlString: hit.ipaURL,
                suggestedName: "\(bid)-\(hit.version ?? "x").ipa",
                onLog: { @Sendable line in LoginLogger.shared.log("[爱思源] \(line)", category: .i4Store) })
            await MainActor.run {
                // v0.3.393：**把两条链接一起写进台账** —— 这里是爱思源直装路径，
                // `hit` 手上就带着 `ipaURL`（下载直链）与 `itemId`（App Store trackId）。
                // 以前只传了前 6 个参数 → 「已下载」面板里「提取下载链接」「复制商店链接」都是「无」。
                IPADownloadLibrary.shared.record(fileURL: ipa,
                                                 displayName: name.isEmpty ? hit.name : name,
                                                 bundleId: bid,
                                                 version: hit.version,
                                                 iconURL: i4Value(a, keys: ["icon", "iconurl"]),
                                                 source: "爱思免登录",
                                                 sourceURL: hit.ipaURL,
                                                 storeItemId: hit.itemId)
            }
            try await AppStoreInstallService.installLocalIPA(
                ipa.path,
                onLog: { @Sendable line in LoginLogger.shared.log("[爱思源] \(line)", category: .i4Store) })
            IPADownloadLibrary.shared.markInstalled(fileName: ipa.lastPathComponent)
            ToastCenter.shared.show("已安装：\(name.isEmpty ? hit.name : name)")
        } catch {
            ToastCenter.shared.show("安装失败：\(error.localizedDescription)")
        }
    }

    // MARK: 加载

    private func reload() async {
        await loadSpecials()
        if tab == 1 { await loadApps() }
    }

    private func loadSpecials() async {
        loading = true
        errorText = nil
        do {
            specials = try await I4StoreClient.specialList()
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func loadApps() async {
        loading = true
        errorText = nil
        do {
            apps = try await I4StoreClient.appList(rank: rank)
            if apps.isEmpty { errorText = nil }
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }
}

/// v0.3.299：专题内的应用列表（`remd=2` + `specialid`）
///
/// 说明：爱思服务端对参数极敏感 —— `getAppList.xhtml` 仅在
/// `{pageSize, pageno, remd, sort}` 四参数时返回结构，多一个字段即返回空。
/// 专题内应用当前实测返回空数据（`{"app":{"id":-100}}` 或空体），
/// 因此本页在拿不到数据时给出**原始响应**，便于区分「签名/请求是否正确」与
/// 「服务端是否还有数据」，不作误导性展示。
struct I4SpecialAppsView: View {
    let specialId: String
    let name: String

    @State private var apps: [[String: Any]] = []
    @State private var raw = ""
    @State private var loading = true
    @State private var sort = 1

    var body: some View {
        List {
            Section {
                Picker("类型", selection: $sort) {
                    Text("应用专题").tag(1)
                    Text("游戏专题").tag(2)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            if loading {
                Section { AppLoadingRow(title: "读取中…", level: .block) }
            } else if apps.isEmpty {
                Section("服务端返回的原始响应") {
                    Text(raw.isEmpty ? "(空响应)" : raw)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    Text("签名请求已接受；该专题未返回条目.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("\(name) · \(apps.count) 款") {
                    ForEach(Array(apps.enumerated()), id: \.offset) { idx, a in
                        HStack(spacing: 12) {
                            Text("\(idx + 1)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            AsyncImage(url: URL(string: (a["icon"] as? String) ?? "")) { phase in
                                if case .success(let img) = phase { img.resizable().scaledToFit() }
                                else { Color(.tertiarySystemFill) }
                            }
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text((a["name"] as? String) ?? "—")
                                    .font(.subheadline.weight(.medium)).lineLimit(1)
                                Text((a["desc"] as? String) ?? (a["introduce"] as? String) ?? "")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Button {
                                Task { await install(a) }
                            } label: {
                                // 与免登录商店统一为「获取」（这里是"定位包 → 下载 → 安装"，不是装已下载的包）
                                // Step 3 批 6-C：手写胶囊收编到共享 `SizePill` 的 `.regular` 档（caption + 10 / 5）；
                                // 字重 `.semibold` 与档位默认一致，底色 14% 用覆盖项钉住（默认 12%）.
                                SizePill(text: "获取",
                                         tint: AppTheme.categoryStore,
                                         level: .regular,
                                         fillOpacity: 0.14)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toastHost()
        .task { await load() }
        .onChange(of: sort) { _, _ in Task { await load() } }
    }

    private func load() async {
        loading = true
        apps = []
        do {
            apps = try await I4StoreClient.specialApps(specialId: specialId, sort: sort)
            raw = try await I4StoreClient.specialAppsRaw(specialId: specialId, sort: sort)
        } catch {
            raw = "请求失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private func install(_ a: [String: Any]) async {
        let bid = i4Value(a, keys: ["bundleid", "bundleId", "sourceid", "sourceId"])
        let name = i4Value(a, keys: ["name", "appname", "appName", "title"])
        guard !bid.isEmpty else {
            ToastCenter.shared.show("该条目缺少 Bundle ID，无法匹配安装包")
            return
        }
        do {
            guard let hit = await SourcePackageLocator.find(bundleId: bid, name: name) else {
                ToastCenter.shared.show("免登录源里没有该应用")
                return
            }
            let ipa = try await AppStoreInstallService.downloadIPA(
                urlString: hit.ipaURL,
                suggestedName: "\(bid)-\(hit.version ?? "x").ipa",
                onLog: { @Sendable line in LoginLogger.shared.log("[爱思源] \(line)", category: .i4Store) })
            await MainActor.run {
                // v0.3.393：**把两条链接一起写进台账** —— 这里是爱思源直装路径，
                // `hit` 手上就带着 `ipaURL`（下载直链）与 `itemId`（App Store trackId）。
                // 以前只传了前 6 个参数 → 「已下载」面板里「提取下载链接」「复制商店链接」都是「无」。
                IPADownloadLibrary.shared.record(fileURL: ipa,
                                                 displayName: name.isEmpty ? hit.name : name,
                                                 bundleId: bid,
                                                 version: hit.version,
                                                 iconURL: i4Value(a, keys: ["icon", "iconurl"]),
                                                 source: "爱思免登录",
                                                 sourceURL: hit.ipaURL,
                                                 storeItemId: hit.itemId)
            }
            try await AppStoreInstallService.installLocalIPA(
                ipa.path,
                onLog: { @Sendable line in LoginLogger.shared.log("[爱思源] \(line)", category: .i4Store) })
            IPADownloadLibrary.shared.markInstalled(fileName: ipa.lastPathComponent)
            ToastCenter.shared.show("已安装：\(name.isEmpty ? hit.name : name)")
        } catch {
            ToastCenter.shared.show("安装失败：\(error.localizedDescription)")
        }
    }
}

/// 爱思接口返回的是 `[String: Any]`，字段名各接口大小写不一致 —— 按候选键依次取值。
private func i4Value(_ d: [String: Any], keys: [String]) -> String {
    for k in keys {
        if let v = d[k] as? String, !v.isEmpty { return v }
        if let n = d[k] as? NSNumber { return n.stringValue }
    }
    return ""
}
