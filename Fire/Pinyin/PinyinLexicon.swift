//
//  PinyinLexicon.swift
//  Fire
//
//  拼音词库的**音节索引**：把「候选\t全拼」码表按音节序列重新组织，支持
//  「每个位置可以是完整音节、前缀或声母（简拼）」的查词。参考实现 `ref-dictionary`
//  （`Dictionary::narrow` / `scan_range` / `prefix_range`）的端口。
//
//  为什么不能直接用现有的 SQLite 码表查询：那是「编码字符串 glob 前缀」的口径，
//  拼音要的是「按音节逐位匹配」——`kf`（简拼）要命中 开发(kai fa)、`zi` 要顺带命中
//  zhi 系的词，字符串前缀做不到。
//
//  与参考实现的两处必要差别：
//  * 参考实现词库自带空格分好的音节列，Fire 的拼音码表只有连写全拼（`开发\tkaifa`），
//    建索引时要自己切分；`xian` 这种能切成 `xian` / `xi an` 的码**每种切法都进索引**
//    （西安 / 先 都要各自的敲法查到），同键同词去重。
//  * 去重只按 (词, 码)：多音字（长 chang / zhang）的第二读法必须留着。
//
//  存储形状照参考实现：`keys` 是**去重后**的音节序列（字典序），每个键指向 `slots` 里
//  连续的一段词目（同键内按码表 rank 升序 = 常用在前）。二分收窄因此只跑在键数组上，
//  一个键的一堆同音词整体进出命中列表，不会像「一行一词」那样重复 N 次。
//

import Foundation

/// 一次查询命中的词目。
struct PinyinMatch: Hashable {
    /// 词。
    var text: String

    /// 词的音节（空格分隔，已归一 ü 写法）。
    var key: String

    /// 码表内的位置（1 起，文件序 = 常用序），同键内升序。
    var rank: Int

    /// 同码重码序号（1 起）：这个键下的第几个词 = 词库给的常用度次序。
    /// 打分按它罚轻罚（`rankPenalty × (ordinal − 1)`），格子截断也按它取前几条。
    var ordinal: Int

    /// 音节数与查询模式的长度一致（而不是以查询为前缀的更长词）。
    var exact: Bool
}

/// 按音节序列索引的拼音词库。
final class PinyinLexicon {
    static let shared = PinyinLexicon()

    /// 区间已经很小：直接逐键比对剩下的模式，比继续二分 + 递归便宜（全简拼时小块极多）。
    private static let linearScanLimit = 32

    /// 一条码表项能切出的音节写法上限（`xian` 两种，极少数长码更多；再多丢弃）。
    private static let maxSyllabificationsPerEntry = 4

    /// 一个词最多几个音节；更长的词库里有但极少，限制它让词图规模可控。
    static let maxWordSyllables = 8

    // MARK: 存储

    /// 去重后的音节序列键，字典序。
    private var keys: [String] = []

    /// 每个键的词目区间（指向 `slotTexts` / `slotRanks`）。
    private var slotStart: [Int] = []
    private var slotCount: [Int] = []
    private var slotTexts: [String] = []
    private var slotRanks: [Int] = []

    private(set) var loadedPath: String?
    private(set) var entryCount = 0
    /// 词表代数：换码表 / 重载后 +1，上层拿它作废缓存
    private(set) var generation = 0

    var isLoaded: Bool { !keys.isEmpty }

    /// 索引键数（同码多切法会 > 词条数，诊断用）
    var indexKeyCount: Int { keys.count }

    // MARK: - 载入

    /// 载入「候选\t编码」格式的拼音码表（前三行 # 元数据，# 注释与空行跳过）。
    @discardableResult
    func load(path: String) -> Bool {
        let started = Date()
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return false }
        var pairs: [(text: String, code: String)] = []
        pairs.reserveCapacity(96_000)
        var seen = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let word = parts[0].trimmingCharacters(in: .whitespaces)
            let code = parts[1].trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, !code.isEmpty, code.count <= 32 else { continue }
            guard code.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { continue }
            let identity = word + "\u{1}" + code
            if !seen.insert(identity).inserted { continue }
            pairs.append((word, code))
        }
        // 摊平：(键, 词, 码表位置)
        var flat: [(key: String, text: String, rank: Int)] = []
        flat.reserveCapacity(pairs.count)
        var syllableCache: [String: [String]?] = [:]
        syllableCache.reserveCapacity(pairs.count / 2)
        for (index, pair) in pairs.enumerated() where index < Int(Int32.max) {
            guard let syllabifications = syllabify(pair.code, cache: &syllableCache) else { continue }
            for key in syllabifications {
                flat.append((key, pair.text, index + 1))
            }
        }
        flat.sort { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.text < rhs.text
        }
        var newKeys: [String] = []
        var newStart: [Int] = []
        var newCount: [Int] = []
        var texts: [String] = []
        var ranks: [Int] = []
        newKeys.reserveCapacity(flat.count)
        var index = 0
        while index < flat.count {
            let key = flat[index].key
            newKeys.append(key)
            newStart.append(texts.count)
            var seenText = Set<String>()
            while index < flat.count, flat[index].key == key {
                // 同键同词只留 rank 最小者（排过序，第一个就是）
                if seenText.insert(flat[index].text).inserted {
                    texts.append(flat[index].text)
                    ranks.append(flat[index].rank)
                }
                index += 1
            }
            newCount.append(texts.count - newStart.last!)
        }
        keys = newKeys
        slotStart = newStart
        slotCount = newCount
        slotTexts = texts
        slotRanks = ranks
        loadedPath = path
        entryCount = pairs.count
        generation += 1
        pinyinLog("拼音词库载入 \(path)：词条 \(pairs.count) / 索引键 \(keys.count) / 词目 \(texts.count)，"
            + "\(Int(Date().timeIntervalSince(started) * 1000))ms")
        return true
    }

    /// 把连写全拼切成音节序列（全部合法切法，最多 `maxSyllabificationsPerEntry` 种）。
    /// 切不开（有切不动的字母、或音节数超上限）返回 nil——这种码表项进不了音节索引。
    /// 同一个码在表里反复出现（八万条词目约四万个不同码），结果按码缓存一次。
    private func syllabify(_ code: String, cache: inout [String: [String]?]) -> [String]? {
        if let cached = cache[code] { return cached }
        let result: [String]?
        if code.count > Self.maxWordSyllables * PinyinSyllables.maxLength {
            result = nil
        } else {
            let forms = PinyinParser.syllabifications(code, limit: Self.maxSyllabificationsPerEntry)
                .filter { $0.count <= Self.maxWordSyllables }
                .map { syllables in
                    syllables.map { PinyinSyllables.canonical($0) }.joined(separator: " ")
                }
            result = forms.isEmpty ? nil : forms
        }
        cache[code] = result
        return result
    }

    // MARK: - 查询

    /// 每个位置给多种写法（模糊音 / 敲错变体），命中音节数 ≥ 位置数、逐位满足其中一种写法的词。
    ///
    /// 同一位置的写法之间不能互相覆盖（前缀 `z` 已包含前缀 `zh`），否则命中会重复出现；
    /// `PinyinFuzzyRules.expand` 按这个契约生成写法，这里不去重。
    func lookupPatternAlt(_ positions: [[PinyinSyllablePattern]]) -> [PinyinMatch] {
        lookup(positions, exactOnly: false)
    }

    /// 只要音节数正好等于位置数的词。
    func lookupExactAlt(_ positions: [[PinyinSyllablePattern]]) -> [PinyinMatch] {
        lookup(positions, exactOnly: true)
    }

    private func lookup(_ positions: [[PinyinSyllablePattern]], exactOnly: Bool) -> [PinyinMatch] {
        var matches: [PinyinMatch] = []
        guard !positions.isEmpty, positions.allSatisfy({ !$0.isEmpty }), !keys.isEmpty else {
            return matches
        }
        var prefix = ""
        narrow(positions, depth: 0, prefix: &prefix, range: 0 ..< keys.count,
               exactOnly: exactOnly, out: &matches)
        return matches
    }

    /// 在 `range`（其中的键都以 `prefix` 开头，`prefix` 为空或以空格结尾）里按
    /// `positions[depth..]` 继续收窄。`exactOnly` 为真时只收音节数正好等于位置数的键。
    private func narrow(_ positions: [[PinyinSyllablePattern]], depth: Int, prefix: inout String,
                        range: Range<Int>, exactOnly: Bool, out: inout [PinyinMatch]) {
        let last = depth + 1 == positions.count
        let baseLength = prefix.count
        for current in positions[depth] {
            truncate(&prefix, baseLength)
            prefix += PinyinSyllables.canonical(current.text)
            let sub = prefixRange(prefix, range)
            if sub.isEmpty { continue }
            if sub.count <= Self.linearScanLimit {
                // 当前位置只按这一种写法比（`an` 的区间里也有 `ang…`，那些留给 `ang` 那一轮，否则重复）
                scanRange(current, rest: Array(positions[(depth + 1)...]), offset: baseLength,
                          range: sub, exactOnly: exactOnly, out: &out)
                continue
            }
            switch (current.complete, last) {
            // 完整且是最后一个：正好这个键的词精确命中，`键 + 空格` 开头的更长词也收
            case (true, true):
                if let first = sub.first, keys[first] == prefix {
                    pushKey(first, exact: true, out: &out)
                }
                if !exactOnly {
                    prefix += " "
                    for entry in prefixRange(prefix, sub) { pushKey(entry, exact: false, out: &out) }
                }
            // 完整且后面还有位置：直接下钻
            case (true, false):
                prefix += " "
                narrow(positions, depth: depth + 1, prefix: &prefix, range: prefixRange(prefix, sub),
                       exactOnly: exactOnly, out: &out)
            // 前缀且是最后一个、全都要：区间里全是命中，音节数正好等于位置数的才精确
            case (false, true) where !exactOnly:
                for entry in sub {
                    pushKey(entry, exact: !tail(keys[entry], from: baseLength).contains(" "), out: &out)
                }
            // 前缀且后面还有（或只要精确的）：按区间里实际出现的音节逐块进入
            default:
                var position = sub.lowerBound
                while position < sub.upperBound {
                    let key = keys[position]
                    let syllable = String(tail(key, from: baseLength).split(separator: " ").first ?? "")
                    truncate(&prefix, baseLength)
                    prefix += syllable
                    if last {
                        if key.count == prefix.count { pushKey(position, exact: true, out: &out) }
                        prefix += " "
                        position = max(prefixRange(prefix, position ..< sub.upperBound).upperBound,
                                       position + 1)
                        continue
                    }
                    prefix += " "
                    let block = prefixRange(prefix, position ..< sub.upperBound)
                    narrow(positions, depth: depth + 1, prefix: &prefix, range: block,
                           exactOnly: exactOnly, out: &out)
                    position = max(block.upperBound, position + 1)
                }
            }
        }
        truncate(&prefix, baseLength)
    }

    /// 截回某个字符长度（递归里 prefix 只会往后加，回退就靠它）
    private func truncate(_ prefix: inout String, _ length: Int) {
        if prefix.count > length { prefix.removeLast(prefix.count - length) }
    }

    /// 逐键比对：`range` 里每个键从字符偏移 `offset` 起，第一个音节满足 `first`、
    /// 后面依次满足 `rest` 各位置之一写法的才收。
    private func scanRange(_ first: PinyinSyllablePattern, rest: [[PinyinSyllablePattern]],
                           offset: Int, range: Range<Int>, exactOnly: Bool,
                           out: inout [PinyinMatch]) {
        for entry in range {
            let syllables = tail(keys[entry], from: offset).split(separator: " ").map(String.init)
            guard let head = syllables.first, first.accepts(head) else { continue }
            var accepted = true
            for (index, position) in rest.enumerated() {
                guard index + 1 < syllables.count,
                      position.contains(where: { $0.accepts(syllables[index + 1]) }) else {
                    accepted = false
                    break
                }
            }
            guard accepted else { continue }
            let exact = syllables.count == rest.count + 1
            if exact || !exactOnly { pushKey(entry, exact: exact, out: &out) }
        }
    }

    /// 把一个键下的全部词目追加为命中。
    private func pushKey(_ entry: Int, exact: Bool, out: inout [PinyinMatch]) {
        let key = keys[entry]
        let start = slotStart[entry]
        for slot in start ..< start + slotCount[entry] {
            out.append(PinyinMatch(text: slotTexts[slot], key: key, rank: slotRanks[slot],
                                   ordinal: slot - start + 1, exact: exact))
        }
    }

    /// `range` 里以 `prefix` 开头的键所在的子区间（可能为空）。
    private func prefixRange(_ prefix: String, _ range: Range<Int>) -> Range<Int> {
        var start = range.lowerBound
        var end = range.upperBound
        while start < end {                       // lower_bound
            let mid = start + (end - start) / 2
            if keys[mid] < prefix { start = mid + 1 } else { end = mid }
        }
        let lower = start
        end = range.upperBound
        while start < end {                       // 第一个不再以它为前缀的
            let mid = start + (end - start) / 2
            if keys[mid].hasPrefix(prefix) { start = mid + 1 } else { end = mid }
        }
        return lower ..< start
    }

    private func tail(_ key: String, from offset: Int) -> Substring {
        guard offset < key.count else { return "" }
        let start = key.index(key.startIndex, offsetBy: offset)
        return key[start...]
    }

    /// 线性扫描版查询：结果必须与 [`lookupPatternAlt`] / [`lookupExactAlt`] 逐条一致。
    /// 只给离线校验台做差分基准（`tmp/pinyin/lexicon`），运行时不走这条路。
    func lookupScan(_ positions: [[PinyinSyllablePattern]], exactOnly: Bool) -> [PinyinMatch] {
        var matches: [PinyinMatch] = []
        guard !positions.isEmpty, positions.allSatisfy({ !$0.isEmpty }) else { return matches }
        for entry in keys.indices {
            let syllables = keys[entry].split(separator: " ").map(String.init)
            var accepted = true
            for (depth, position) in positions.enumerated() {
                guard depth < syllables.count,
                      position.contains(where: { $0.accepts(syllables[depth]) }) else {
                    accepted = false
                    break
                }
            }
            guard accepted else { continue }
            let exact = syllables.count == positions.count
            if exact || !exactOnly { pushKey(entry, exact: exact, out: &matches) }
        }
        return matches
    }

    /// 某个音节序列下的词条目数（诊断重码深度用）。
    func entryCount(forSyllables syllables: [String]) -> Int {
        let key = syllables.joined(separator: " ")
        guard let index = keys.firstIndex(of: key) else { return 0 }
        return slotCount[index]
    }
}

/// 拼音侧日志（未接日志系统时静默；Release 也留一行）
func pinyinLog(_ message: String) {
    NSLog("Pinyin: %@", message)
}
