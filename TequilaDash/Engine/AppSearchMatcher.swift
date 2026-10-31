//
//  AppSearchMatcher.swift
//  TequilaDash
//
//  应用列表搜索匹配器（「拉起应用」/「启用 JIT」共用）.
//
//  为什么不只做子串：用户搜 "siro" 想找 "Siri"（o 与 i 相邻的击键误差），
//  纯 contains 匹配不到，页面只给「没有匹配的应用」—— 实测 2026-10-30（v0.3.725）.
//
//  三层匹配，结果按层稳定排序（同层保持调用方已有的排序，本仓列表按名称升序传入）：
//   1. 精确子串（既有行为，零回归）
//   2. 容错拼写：对名称分词 / Bundle ID 末段做 Levenshtein 距离 <= 1（查询长度 >= 4 才启用，
//      避免两三个字母的查询把列表拖成模糊匹配）
//   3. 子序列（跳字符匹配）："wsp" 命中 WhatsApp 这类首字母缩写输入习惯
//

import Foundation

enum AppSearchMatcher {

    /// 按三层策略过滤；`query` 为空原样返回.
    static func filter(_ apps: [JITAppInfo], query: String) -> [JITAppInfo] {
        let q = normalize(query)
        guard !q.isEmpty else { return apps }

        var exact: [JITAppInfo] = []
        var fuzzy: [JITAppInfo] = []
        var subseq: [JITAppInfo] = []

        for app in apps {
            let name = normalize(app.name)
            let bundle = normalize(app.bundleID)
            let bundleLeaf = bundle.split(separator: ".").last.map(String.init) ?? bundle

            if name.contains(q) || bundle.contains(q) {
                exact.append(app)
                continue
            }
            if q.count >= 4 {
                let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." }).map(String.init) + [bundleLeaf]
                if words.contains(where: { levenshtein($0, q) <= 1 }) {
                    fuzzy.append(app)
                    continue
                }
            }
            if isSubsequence(q, of: name) || isSubsequence(q, of: bundleLeaf) {
                subseq.append(app)
            }
        }
        return exact + fuzzy + subseq
    }

    // MARK: - 私有

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// 子序列判断：`q` 的字符按序出现在 `target` 中（不必连续）.
    private static func isSubsequence(_ q: String, of target: String) -> Bool {
        guard !q.isEmpty else { return false }
        var index = target.startIndex
        for ch in q {
            if index == target.endIndex { return false }
            while index < target.endIndex, target[index] != ch { index = target.index(after: index) }
            if index == target.endIndex { return false }
            index = target.index(after: index)
        }
        return true
    }

    /// 经典 DP Levenshtein 距离（两串都很短，O(n*m) 足够；带行最小值早退）.
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(min(current[j - 1] + 1, previous[j] + 1), previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            // 早退：这一行最小值都已超过 1，后续不可能再降（调用方只关心 <= 1）.
            if rowMin > 1 { return rowMin }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
