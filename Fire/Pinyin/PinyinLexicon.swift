//
//  PinyinLexicon.swift
//  Fire
//
//  拼音词库的**音节索引**：把「候选\t全拼」码表按音节序列重新组织，支持
//  「每个位置可以是完整音节、前缀或声母（简拼）」的查词：键数组上二分收窄，
//  命中键下的词目槽位整段进出。
//
//  词库来源可以是 `.hdict` 私有容器（内置那份，带词频列）或明文 txt，读法见 `HDict`；
//  行格式 `候选\t连写全拼[\t词频]`，词频降序写盘时「同码重码的常用次序」就是 `ordinal`。
//
//  为什么不能直接用现有的 SQLite 码表查询：那是「编码字符串 glob 前缀」的口径，
//  拼音要的是「按音节逐位匹配」——`kf`（简拼）要命中 开发(kai fa)、`zi` 要顺带命中
//  zhi 系的词，字符串前缀做不到。
//
//  两处口径要单独交代：
//  * 拼音码表只有连写全拼（`开发\tkaifa`），没有空格分好的音节列，
//    建索引时要自己切分；`xian` 这种能切成 `xian` / `xi an` 的码**每种切法都进索引**
//    （西安 / 先 都要各自的敲法查到），同键同词去重。
//  * 去重只按 (词, 码)：多音字（长 chang / zhang）的第二读法必须留着。
//
//  存储形状：`keys` 是**去重后**的音节序列（字典序），每个键指向 `slots` 里
//  连续的一段词目（同键内按词频降序 = 常用在前，没词频时退回文件序）。二分收窄因此只跑在键数组上，
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
    /// 该键是否只有一个音节（`exact` 的静态版本）。单字母查询要按它做键级剪枝，
    /// 不能每次都去 `keys[entry].contains(" ")`——`z` 下有十七万个键，光 String 访问
    /// 就是二十多毫秒。
    private var keyExact: [Bool] = []

    private(set) var loadedPath: String?
    private(set) var entryCount = 0
    /// 词表代数：换码表 / 重载后 +1，上层拿它作废缓存
    private(set) var generation = 0

    var isLoaded: Bool { !keys.isEmpty }

    /// 索引键数（同码多切法会 > 词条数，诊断用）
    var indexKeyCount: Int { keys.count }

    // MARK: - 载入

    /// 载入拼音码表。`.hdict` 私有容器（解压后也是行流）与明文 txt 同一套解析：
    /// `候选\t连写全拼[\t词频]`，`#` 注释与空行跳过，文件序 = rank。
    ///
    /// 词频只决定**同码重码的先后**（`ordinal` → 解码器的轻罚与格子截断都按它），
    /// 表里没带词频时恒为 0，比较退回文件序，行为与老拼音码表一致。
    @discardableResult
    func load(path: String) -> Bool {
        let started = Date()
        guard let text = HDict.tableText(path: path) else { return false }
        let head = HDict.header(at: path)
        // 容器声明「行已规范化且 (词,码) 已去重」时，逐行 trim 与去重集都能省：
        // 几十万条词条下这两段是载入开销的大头之一。手写明文表没这个标记，照旧逐行校验。
        let canonical = head?.hasCanonicalRows ?? false
        var pairs: [(text: String, code: String, weight: Int)] = []
        pairs.reserveCapacity(head.map { $0.entryCount + 1 } ?? 96_000)
        var seen = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            // maxSplits 2：第三列（词频）单独转数，不让它混进编码里当成字母比
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let word = canonical ? String(parts[0]) : parts[0].trimmingCharacters(in: .whitespaces)
            let code = canonical ? String(parts[1]) : parts[1].trimmingCharacters(in: .whitespaces)
            let weightField = parts.count > 2
                ? (canonical ? parts[2] : parts[2].trimmingCharacters(in: .whitespaces)[...]) : ""
            let weight = Int(weightField) ?? 0
            guard !word.isEmpty, !code.isEmpty, code.count <= 32 else { continue }
            guard code.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { continue }
            if !canonical {
                let identity = word + "\u{1}" + code
                if !seen.insert(identity).inserted { continue }
            }
            pairs.append((word, code, weight))
        }
        // 去重集只是建表期的临时内存，百万级词条下先腾掉再摊平，峰值小一截
        seen.removeAll(keepingCapacity: false)
        let parsedEntries = pairs.count
        // 摊平：(键, 词, 码表位置, 词频)
        var flat: [(key: String, text: String, rank: Int, weight: Int)] = []
        flat.reserveCapacity(pairs.count)
        var syllableCache: [String: [String]?] = [:]
        syllableCache.reserveCapacity(pairs.count / 2)
        for (index, pair) in pairs.enumerated() where index < Int(Int32.max) {
            guard let syllabifications = syllabify(pair.code, cache: &syllableCache) else { continue }
            for key in syllabifications {
                flat.append((key, pair.text, index + 1, pair.weight))
            }
        }
        pairs.removeAll(keepingCapacity: false)
        flat.sort { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            // 词频降序 = 常用在前；没带词频的表恒等，退回原来的文件序
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.text < rhs.text
        }
        var newKeys: [String] = []
        var newExact: [Bool] = []
        var newStart: [Int] = []
        var newCount: [Int] = []
        var texts: [String] = []
        var ranks: [Int] = []
        newKeys.reserveCapacity(flat.count)
        newExact.reserveCapacity(flat.count)
        var index = 0
        while index < flat.count {
            let key = flat[index].key
            newKeys.append(key)
            newExact.append(!key.contains(" "))
            newStart.append(texts.count)
            var seenText = Set<String>()
            while index < flat.count, flat[index].key == key {
                // 同键同词只留第一条（排过序：词频降序 → 文件序，第一条就是最常用那条）
                if seenText.insert(flat[index].text).inserted {
                    texts.append(flat[index].text)
                    ranks.append(flat[index].rank)
                }
                index += 1
            }
            newCount.append(texts.count - newStart.last!)
        }
        keys = newKeys
        keyExact = newExact
        slotStart = newStart
        slotCount = newCount
        slotTexts = texts
        slotRanks = ranks
        loadedPath = path
        entryCount = parsedEntries
        generation += 1
        pinyinLog("拼音词库载入 \(path)：词条 \(parsedEntries) / 索引键 \(keys.count) / 词目 \(texts.count)，"
            + "\(Int(Date().timeIntervalSince(started) * 1000))ms")
        // 容器头部写了词条数：解析结果对不上就是表被改坏 / 版本不匹配，当场喊出来
        if let head = head, head.entryCount != parsedEntries {
            pinyinLog("⚠️ \((path as NSString).lastPathComponent) 容器声明 \(head.entryCount) 条，"
                + "实际解析出 \(parsedEntries) 条（重复行或不合格行？）")
        }
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
    ///
    /// `limit` 只作用于「单个未完成音节」这一个病态分支（`z` 这种一个字母的简拼）：
    /// 该分支的区间能扫出十几万条词目，而排序只关心最常用的几百条。给了上限时按
    /// 排序键（精确 > 词库名次 > 词短）留前 `limit` 条，其余不再实例化。
    func lookupPatternAlt(_ positions: [[PinyinSyllablePattern]],
                          limit: Int = .max) -> [PinyinMatch] {
        lookup(positions, exactOnly: false, limit: limit)
    }

    /// 只要音节数正好等于位置数的词。
    func lookupExactAlt(_ positions: [[PinyinSyllablePattern]]) -> [PinyinMatch] {
        lookup(positions, exactOnly: true, limit: .max)
    }

    private func lookup(_ positions: [[PinyinSyllablePattern]], exactOnly: Bool,
                        limit: Int) -> [PinyinMatch] {
        var matches: [PinyinMatch] = []
        guard !positions.isEmpty, positions.allSatisfy({ !$0.isEmpty }), !keys.isEmpty else {
            return matches
        }
        // 单键未完成音节：`narrow` 的「前缀且是最后一个」分支会把区间里每个键的
        // 全部词目都推进来。一个字母命中十几万条，这里改成有界 top-K。
        if limit != .max, !exactOnly, positions.count == 1, positions[0].count == 1,
           let only = positions[0].first, !only.complete {
            return topMatches(prefix: PinyinSyllables.canonical(only.text), limit: limit)
        }
        var prefix = ""
        narrow(positions, depth: 0, prefix: &prefix, range: 0 ..< keys.count,
               exactOnly: exactOnly, out: &matches)
        return matches
    }

    /// 一个未完成音节前缀下、按排序键最优的前 `limit` 条词目。
    /// 与 `narrow` 的 `(false, true)` 分支口径一致：`exact` 表示该键就是单个音节。
    private func topMatches(prefix: String, limit: Int) -> [PinyinMatch] {
        guard limit > 0 else { return [] }
        let sub = prefixRange(prefix, 0 ..< keys.count)
        guard !sub.isEmpty else { return [] }
        var heap = MatchHeap(limit: limit)
        for entry in sub {
            let start = slotStart[entry]
            let count = slotCount[entry]
            let exact = keyExact[entry]
            // 键级剪枝：先取键内最小名次。它都赢不了堆顶的键，整键跳过，
            // 连 keys[entry] 都不用取。多词目键逐个取 min（词目不多，一次线性扫）。
            var bestRank = slotRanks[start]
            if count > 1 {
                for slot in start + 1 ..< start + count {
                    bestRank = min(bestRank, slotRanks[slot])
                }
            }
            guard heap.accepts(rank: bestRank, exact: exact) else { continue }
            let key = keys[entry]
            for slot in start ..< start + count {
                let rank = slotRanks[slot]
                // 先只比 rank / exact：一个字母下十几万个词目，绝大多数在根节点
                // 面前直接出局，没必要为它们构造 PinyinMatch。
                guard heap.accepts(rank: rank, exact: exact) else { continue }
                heap.offer(PinyinMatch(text: slotTexts[slot], key: key,
                                       rank: rank,
                                       ordinal: slot - start + 1,
                                       exact: exact))
            }
        }
        return heap.items
    }

    /// 固定容量的最大堆（堆顶是当前保留集合里排序最差的一条）。
    /// 比较口径对齐 `PinyinEngine.Scored.preselectBetter` 里词表能看到的几项。
    private struct MatchHeap {
        private(set) var items: [PinyinMatch] = []
        private let limit: Int
        /// 堆顶（当前最差一条）的比较键。单独存一份，`accepts` 每槽都读，
        /// 直接取 `items[0]` 会整份拷贝 PinyinMatch（两个 String 的 retain/release）。
        private var rootExact = false
        private var rootRank = Int.max

        init(limit: Int) {
            self.limit = limit
            items.reserveCapacity(min(limit, 4096))
        }

        /// 只在「可能进保留集合」时才让调用方构造 PinyinMatch；等 rank 的交给
        /// `offer` 用词长做最后裁决。
        func accepts(rank: Int, exact: Bool) -> Bool {
            guard items.count >= limit else { return true }
            if exact != rootExact { return exact }
            return rank <= rootRank
        }

        private mutating func refreshRoot() {
            guard let root = items.first else { return }
            rootExact = root.exact
            rootRank = root.rank
        }

        mutating func offer(_ match: PinyinMatch) {
            if items.count < limit {
                items.append(match)
                siftUp(items.count - 1)
            } else if Self.better(match, than: items[0]) {
                items[0] = match
                siftDown(0)
            }
            refreshRoot()
        }

        private static func better(_ a: PinyinMatch, than b: PinyinMatch) -> Bool {
            if a.exact != b.exact { return a.exact }
            if a.rank != b.rank { return a.rank < b.rank }
            return a.text.count < b.text.count
        }

        private func worse(_ a: PinyinMatch, than b: PinyinMatch) -> Bool {
            Self.better(b, than: a)
        }

        private mutating func siftUp(_ index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                guard worse(items[child], than: items[parent]) else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }

        private mutating func siftDown(_ index: Int) {
            var parent = index
            while true {
                let left = parent * 2 + 1
                guard left < items.count else { break }
                let right = left + 1
                var worst = left
                if right < items.count, worse(items[right], than: items[left]) {
                    worst = right
                }
                guard worse(items[worst], than: items[parent]) else { break }
                items.swapAt(parent, worst)
                parent = worst
            }
        }
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
