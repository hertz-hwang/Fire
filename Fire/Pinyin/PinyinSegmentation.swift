//
//  PinyinSegmentation.swift
//  Fire
//
//  拼音切分：把无分隔的拼音串切成音节序列。
//  参考实现 `ref-core/src/parser/mod.rs` 的端口，DP、排序键、上限逐项对齐：
//  支持全拼、简拼（声母缩写 `kf` → `k f`）与两者混用（`kaif`、`kfa`），
//  输入允许用 `'` 强制分隔（`xi'an`）；末尾允许一个未打完的音节前缀（`zho`）。
//  每种切分里每个音节标记是否完整——查词时完整音节精确匹配、不完整音节按前缀匹配。
//

import Foundation

/// 切分出的一个音节。
struct PinyinSyllable: Hashable {
    /// 用户敲的字母。
    var text: String

    /// 是完整音节；否则是声母（简拼 `k`）或未打完的前缀（`zho`）。
    var complete: Bool

    static func full(_ text: String) -> PinyinSyllable { PinyinSyllable(text: text, complete: true) }
    static func partial(_ text: String) -> PinyinSyllable { PinyinSyllable(text: text, complete: false) }
}

/// 一种切分方式。
struct PinyinSegmentation: Hashable {
    /// 音节，顺序与输入一致。
    var syllables: [PinyinSyllable]

    /// 覆盖的输入字母数（不含 `'`）。
    var letters: Int { syllables.reduce(0) { $0 + $1.text.count } }

    var incompleteCount: Int { syllables.filter { !$0.complete }.count }

    var lastIsPartial: Bool { syllables.last.map { !$0.complete } ?? false }

    /// 非末尾（不含最后一个音节）里有几个不完整音节：
    /// `kai f a` 这种「本来就不是用户敲的原话」的切法靠它识别。
    var innerAbbreviatedCount: Int {
        guard syllables.count > 1 else { return 0 }
        return syllables.dropLast().filter { !$0.complete }.count
    }

    /// 用分隔符连接各音节：`kai'fa`、`k'f`。
    func joined(_ separator: String) -> String {
        syllables.map(\.text).joined(separator: separator)
    }

    /// 去掉所有分隔符的连写：`kaifa`。
    var concatenated: String { syllables.map(\.text).joined() }

    /// 调试/显示用：`kai fa…`（残缺音节带省略号）。
    var display: String {
        syllables.map { $0.complete ? $0.text : "\($0.text)…" }.joined(separator: " ")
    }
}

/// 切分输入不合法的种类（与参考实现 `ParseError` 同口径）。
enum PinyinParseError: Error, Equatable {
    case empty
    case invalidCharacter(position: Int, character: Character)
    case noSegmentation
}

/// 拼音切分器。
enum PinyinParser {
    /// 切分上限。简拼让歧义切分数量指数增长，每个位置只保留这么多种最优切分。
    static let maxSegmentations = 8

    /// 切分。返回按「音节少、不完整音节少、前面的音节长」排序的切分，最多
    /// [`maxSegmentations`] 种；输入不合法时抛错。
    static func segment(_ input: String) throws -> [PinyinSegmentation] {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw PinyinParseError.empty }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(trimmed.count)
        for (position, ch) in trimmed.unicodeScalars.enumerated() {
            let value = ch.value
            guard (value >= 97 && value <= 122) || ch == "'" else {
                throw PinyinParseError.invalidCharacter(position: position + 1, character: Character(ch))
            }
            bytes.append(UInt8(value))
        }

        // 按 `'` 切成若干段，各段独立切分后做笛卡尔积；只有最后一段允许残缺音节。
        var results = [PinyinSegmentation(syllables: [])]
        var index = 0
        var sawChunk = false
        while index < bytes.count {
            // 跳过连续分隔符（空段直接忽略，与参考实现 `filter(!c.is_empty())` 一致）
            if bytes[index] == 39 { index += 1; continue }
            var end = index
            while end < bytes.count, bytes[end] != 39 { end += 1 }
            sawChunk = true
            let options = segmentChunk(bytes, from: index, to: end, allowPartial: end == bytes.count)
            guard !options.isEmpty else { throw PinyinParseError.noSegmentation }
            var next: [PinyinSegmentation] = []
            next.reserveCapacity(results.count * options.count)
            for base in results {
                for option in options {
                    next.append(PinyinSegmentation(syllables: base.syllables + option.syllables))
                }
            }
            results = next
            index = end
        }
        guard sawChunk else { throw PinyinParseError.noSegmentation }
        prune(&results)
        return results
    }

    /// 切分；失败返回空数组（高频路径用，省掉异常与可选包装）
    static func segmentOrNil(_ input: String) -> [PinyinSegmentation]? {
        do { return try segment(input) } catch { return nil }
    }

    /// `text` 能否切成每个音节都完整的拼音。只回答是否，不产生切分、不分配音节：
    /// 纠错要对上千个变体逐个问这个问题，先用它过滤，剩下的几个再做真正的切分。
    /// 只认小写字母。
    static func isFullySegmentable(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        let n = bytes.count
        guard n > 0 else { return false }
        for byte in bytes where byte < 97 || byte > 122 { return false }
        var reachable = [Bool](repeating: false, count: n + 1)
        reachable[0] = true
        for start in 0 ..< n where reachable[start] {
            for length in PinyinSyllables.syllableLengths(bytes, start) {
                reachable[start + length] = true
            }
        }
        return reachable[n]
    }

    /// 排序并截断到 [`maxSegmentations`]。
    /// 排序键：音节少的优先 → 同音节数时不完整音节少的优先 → 再同则前面的音节越长越优先
    /// （贪心的结果排最前）。Swift 的 `sorted` 不保证稳定，这里显式带上原始下标，
    /// 让同分切分保持 DP 插入顺序——候选栏顺序必须可复现。
    static func prune(_ segmentations: inout [PinyinSegmentation]) {
        let decorated = segmentations.enumerated().map { (index: $0.offset, value: $0.element) }
        let sorted = decorated.sorted { lhs, rhs in
            if lhs.value.syllables.count != rhs.value.syllables.count {
                return lhs.value.syllables.count < rhs.value.syllables.count
            }
            if lhs.value.incompleteCount != rhs.value.incompleteCount {
                return lhs.value.incompleteCount < rhs.value.incompleteCount
            }
            if lhs.value.sortKeyIsBetter(than: rhs.value) { return true }
            if rhs.value.sortKeyIsBetter(than: lhs.value) { return false }
            return lhs.index < rhs.index
        }
        var result: [PinyinSegmentation] = []
        result.reserveCapacity(min(sorted.count, maxSegmentations))
        for item in sorted {
            // 与参考实现 `dedup` 一致：只去掉相邻重复（同键不同值的切分不折叠）
            if result.last == item.value { continue }
            result.append(item.value)
            if result.count == maxSegmentations { break }
        }
        segmentations = result
    }

    /// 一串连写拼音的**全部完整音节切法**（不含简拼 / 残缺），最多 `limit` 种，长的音节先试。
    ///
    /// 建拼音索引时给每条码表项用：`xian` 要同时进 `xian` 与 `xi an` 两个键，
    /// 否则「西安」查不到。与 [`segment`] 的区别是这里只要「每个音节都完整」的切法，
    /// 因此不必做保留多种前缀切分的 DP、也不排切分序——建索引要跑八万多次，
    /// 省掉的正是那部分（同一份码表：DP 版 1.3s，这里 0.1s）。
    static func syllabifications(_ code: String, limit: Int) -> [[String]] {
        let bytes = Array(code.utf8)
        var results: [[String]] = []
        var current: [String] = []
        // 每个位置开头的合法音节长度（升序），先算一次省掉重复探测
        var lengths: [[Int]] = Array(repeating: [], count: bytes.count)
        for start in 0 ..< bytes.count {
            lengths[start] = PinyinSyllables.syllableLengths(bytes, start)
        }
        func walk(_ position: Int) {
            if results.count >= limit { return }
            if position == bytes.count {
                results.append(current)
                return
            }
            // 长音节先试：贪心读法（`xian` 整体）排在拆读法（`xi an`）前面
            for length in lengths[position].reversed() {
                current.append(String(decoding: bytes[position ..< position + length], as: UTF8.self))
                walk(position + length)
                current.removeLast()
                if results.count >= limit { return }
            }
        }
        walk(0)
        return results
    }

    /// 切分不含 `'` 的一段：按位置做动态规划，每个位置只保留最优的几种前缀切分。
    /// `allowPartial` 为真时末尾允许留一个残缺音节。
    private static func segmentChunk(_ bytes: [UInt8], from offset: Int, to end: Int,
                                     allowPartial: Bool) -> [PinyinSegmentation] {
        let n = end - offset
        guard n > 0 else { return [] }
        var best: [[PinyinSegmentation]] = Array(repeating: [], count: n + 1)
        best[0] = [PinyinSegmentation(syllables: [])]
        for start in 0 ..< n where !best[start].isEmpty {
            prune(&best[start])
            // (长度, 是否完整音节)：先全部合法音节长度（升序）
            var tokens: [(length: Int, complete: Bool)] = PinyinSyllables
                .syllableLengths(bytes, offset + start)
                .map { (length: $0, complete: true) }
            // 简拼：声母也算一个音节（不完整）；已经是完整音节长度的不重复加
            for length in PinyinSyllables.initialLengths(bytes, offset + start)
            where !tokens.contains(where: { $0.length == length && $0.complete }) {
                tokens.append((length: length, complete: false))
            }
            // 整个剩余部分作为未打完的音节（`zho` → zhong / zhou …）。
            // 它本身是完整音节或纯声母时已经在上面了。
            let restLength = n - start
            let restIsComplete = PinyinSyllables.isSyllable(bytes, offset + start, restLength)
            if allowPartial, restLength > 0, !restIsComplete,
               PinyinSyllables.isSyllablePrefix(bytes, offset + start, restLength),
               !tokens.contains(where: { $0.length == restLength && !$0.complete }) {
                tokens.append((length: restLength, complete: false))
            }
            for token in tokens {
                let text = pinyinText(bytes, offset + start, token.length)
                let syllable = token.complete ? PinyinSyllable.full(text) : PinyinSyllable.partial(text)
                for base in best[start] {
                    best[start + token.length].append(
                        PinyinSegmentation(syllables: base.syllables + [syllable])
                    )
                }
            }
        }
        var result = best[n]
        prune(&result)
        return result
    }

    /// 字节区间 → 拼音子串（输入已保证是 ASCII）
    private static func pinyinText(_ bytes: [UInt8], _ from: Int, _ length: Int) -> String {
        let slice = Array(bytes[from ..< from + length])
        return String(decoding: slice, as: UTF8.self)
    }
}

private extension PinyinSegmentation {
    /// 「前面的音节越长越优先」：逐位比长度，长者优先（参考实现 `Vec<Reverse(len)>` 的字典序）
    func sortKeyIsBetter(than other: PinyinSegmentation) -> Bool {
        let lhs = syllables.map { $0.text.count }
        let rhs = other.syllables.map { $0.text.count }
        for index in 0 ..< min(lhs.count, rhs.count) {
            if lhs[index] != rhs[index] { return lhs[index] > rhs[index] }
        }
        return false
    }
}
