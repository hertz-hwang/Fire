//
//  PinyinEngine.swift
//  Fire
//
//  拼音查询管线：敲的键 → 切分 →（不像话则纠错）→ 每个音节位置的多种写法 →
//  词级候选 + 整句候选 → 排序。参考实现 `engine/query/mod.rs::query_phonetic` 与
//  `ranking`（7 级排序键）的端口，双拼在前置一步 `ShuangpinScheme.decode` 后与全拼同路。
//
//  排序规则照参考实现（越小越靠前）：
//  1. 音节数与输入完全一致的词优先（`kaifa` → 开发 排在 开发者 前）
//  2. 覆盖输入字母多者优先（`kaif` → 开发者 排在 开 前）
//  3. 切分里非末尾的简拼音节少者优先（`kaifa` 按 `kai fa` 读的 开放 排在按 `kai f a` 读的 开放啊 前）
//  4. 最后一个音节完整匹配优先
//  5. 同一输入串下用户选过的次数
//  6. 上下文得分（字级 n-gram 给 `log P(词 | 上文)`，减掉模糊音 / 敲错代价，加对用户选择次数的对数加分）
//  7. 敲的原音节优先，词长短者优先，最后按字符串稳定排序保证结果可复现
//

import Foundation

/// 一条拼音候选。
struct PinyinCandidate {
    /// 文字。
    var text: String

    /// 编码回显（分段拼音，`kai'fa`）。
    var segmented: String

    /// 是整句候选（多词拼成）。
    var isSentence: Bool

    /// 排序用的最终分（词级 = 上下文分 + 用户加分 − 代价；整句 = 路径分）。
    var score: Double

    /// 覆盖的输入字母数（不含 `'`）。
    var coverage: Int

    /// 靠模糊音 / 敲错变体命中（候选拼音与敲的不同）。
    var altered: Bool
}

/// 一次拼音查询的产物。
struct PinyinQuery {
    /// 排好序的候选。
    var candidates: [PinyinCandidate]

    /// 用到的切分（回显与学习用）。
    var segmentations: [PinyinSegmentation]

    /// 切不动的尾巴（原始键）。
    var tail: String

    /// 组字区显示：分段后的拼音（双拼下是解出来的全拼），带 `'` 分隔。
    var marked: String

    /// 生效的拼写纠正（nil = 按原样读）。
    var correction: PinyinCorrection?

    /// 双拼解码结果（全拼为 nil）：上屏消耗要按它换算回键数。
    var decoded: ShuangpinDecoded?
}

/// 拼音查询引擎。
final class PinyinEngine {
    static let shared = PinyinEngine()

    private let lexicon = PinyinLexicon.shared
    let decoder = PinyinDecoder()

    /// 双拼方案；nil = 全拼。
    var scheme: ShuangpinScheme?

    /// 模糊音规则。
    var fuzzy = PinyinFuzzyRules.none

    /// 整段一处编辑的纠错开关。
    var correctionEnabled = true

    /// 音节级敲错变体开关（进整句词图）。
    var typoEnabled = true

    /// 进词图的敲错类别。只放「相邻换位 + 相邻换键」：漏敲 / 多敲一个键一个音节能变出
    /// 十几个写法，全放进去格子查词翻几倍，换来的读法多数不是用户要的——同一份 2742 句
    /// 句子集实测四类全开 42.2% / 13.8ms，只开换位+换键 42.9% / 6.4ms，只开换位
    /// 44.2% / 2.7ms（故意敲错的样本上也是开越少越好：30.5% > 29.7% > 29.5%）。
    /// 漏敲 / 多敲由整段一处编辑的纠错（`PinyinCorrector`）管，那条路不炸词图。
    var typoKinds: Set<PinyinTypoKind> = [.transpose, .substitute]

    /// 代价表（回放调参可整组换掉）。
    var costs = PinyinTypoCosts.standard

    /// 词的用户选择次数（用户词库 / 学习系统接入点，缺省全 0）。
    var weightProvider: (String) -> Int = { _ in 0 }

    /// 「在这串输入下选过某个词」的次数（学习系统接入点）。
    var choiceProvider: (String, String) -> Int = { _, _ in 0 }

    /// 个人敲错表：把 `typed` 敲成 `intended` 接受过几次。
    var typoCountProvider: (String, String) -> Int = { _, _ in 0 }

    /// 词级候选的排序与截断上限。
    static let maxCandidates = 60

    /// 组字区最多吸收多少个键：引擎每键整段重解，开销随音节数涨，
    /// 不封顶时长串能把主线程拖住。40 键 ≈ 20 个音节（双拼 20 个词），
    /// 比参考实现 `correction::MAX_LETTERS`（24）宽一倍，正常句子碰不到。
    static let maxRawKeys = 40

    /// 当前方案是否用到 `;` 键（微软 / 搜狗类的 `ing`）：用到时 `;` 进缓冲区而不是出标点
    var usesSemicolon: Bool { scheme?.usesSemicolon ?? false }

    /// 整句解码试几种切分（参考实现只取最优切分；Fire 的拼音码表没有词频、全靠字级模型分辨，
    /// 多留几条划分让模型自己挑更划算）。
    static var sentenceSegmentations = 4

    /// 用户选择次数加分系数与封顶（照参考实现 `ranking::WEIGHT_BONUS` / `WEIGHT_CAP`）。
    static let weightBonus = 0.5
    static let weightCap = 20

    /// 加分 = 系数 × ln(1 + min(次数, 封顶))。取对数又封顶，语境才还压得过它。
    static func weightBonus(_ count: Int) -> Double {
        weightBonus * log(1.0 + Double(min(count, weightCap)))
    }

    // MARK: - 查询

    /// 解析当前缓冲区并生成排好序的候选。空输入或完全切不动时返回 nil。
    func query(_ keys: String, leftContext: String = "") -> PinyinQuery? {
        guard !keys.isEmpty else { return nil }
        // 双拼先解成全拼（音节间已用 `'` 连好，切分没有歧义），之后与全拼同路；解不动的键当尾巴
        let decoded = scheme?.decode(keys)
        let scope = decoded.map { $0.pinyin } ?? keys
        guard !scope.isEmpty else {
            return PinyinQuery(candidates: [], segmentations: [], tail: keys, marked: keys,
                               correction: nil, decoded: decoded)
        }
        let parsed: ([PinyinSegmentation], String)
        if let segmentation = decoded?.segmentation {
            parsed = ([segmentation], decoded?.tail ?? "")
        } else if let segmentations = PinyinParser.segmentOrNil(scope) {
            parsed = (segmentations, "")
        } else if let (segmentations, tail) = segmentLongestPrefix(scope) {
            parsed = (segmentations, tail)
        } else {
            return nil
        }
        var segmentations = parsed.0
        var tail = parsed.1

        // 拼音「不像话」时试拼写纠错；纠正生效则按纠正后的切分查词，原串只用来记学习与显示
        let correction: PinyinCorrection?
        if correctionEnabled, decoded == nil,
           PinyinCorrector.unlikelyPinyin(segmentations.first, tail: tail)
            || PinyinCorrector.trailingSingleLetter(segmentations.first) {
            correction = findCorrection(scope)
        } else {
            correction = nil
        }
        if let correction {
            segmentations = [correction.segmentation]
            tail = ""
        }

        // 末尾是英文词（`woxiangxuehaorust`）这类混输在本期内不做：尾巴原样留着给组字区显示

        var candidates: [PinyinCandidate] = []
        var scored: [Scored] = []
        let logTotal = log(Double(max(lexicon.entryCount, 1)))
        _ = logTotal
        for segmentation in segmentations {
            let expanded = expandedPositions(segmentation, typos: correction == nil)
            let patterns = segmentation.patterns
            let count = patterns.count
            let last = patterns[count - 1]
            let positions = expanded.patterns
            let abbreviated = PinyinSegmentation.abbreviatedCount(patterns)
            // 词级候选只按敲的原样与模糊音查，敲错变体只进整句词图：
            // 词级排序把音节数对得上的排最前，敲错命中的词会把更长的原样词挤到后面
            for hit in lexicon.lookupPatternAlt(positions) {
                let syllables = hit.key.split(separator: " ").map(String.init)
                let fullLast = last.complete
                    && syllables.count == count
                    && syllables[count - 1] == patterns[count - 1].text
                scored.append(Scored(text: hit.text, syllables: syllables, exact: hit.exact,
                                     fullLast: fullLast, coverage: segmentation.letters,
                                     abbreviated: abbreviated, weight: weightProvider(hit.text),
                                     penalty: expanded.penalty(syllables)))
            }
            // 输入的前缀也出候选（`kaifazhe` → 开发、开），否则长句没法逐词上屏。
            // 只收音节数正好等于前缀长度的词，更长的词会与输入后面的音节冲突。
            if count > 1 {
                for prefixLength in stride(from: count - 1, through: 1, by: -1) {
                    let prefix = Array(positions[0 ..< prefixLength])
                    let prefixLetters = patterns[0 ..< prefixLength].reduce(0) { $0 + $1.text.count }
                    let prefixAbbreviated = PinyinSegmentation.abbreviatedCount(
                        Array(patterns[0 ..< prefixLength]))
                    for hit in lexicon.lookupExactAlt(prefix) {
                        let syllables = hit.key.split(separator: " ").map(String.init)
                        scored.append(Scored(text: hit.text, syllables: syllables, exact: false,
                                             fullLast: true, coverage: prefixLetters,
                                             abbreviated: prefixAbbreviated,
                                             weight: weightProvider(hit.text),
                                             penalty: expanded.penalty(syllables)))
                    }
                }
            }
        }

        let inputLetters = String(scope.filter { $0 != "'" })
        rank(&scored, limit: Self.maxCandidates, leftContext: leftContext, input: inputLetters)
        candidates.append(contentsOf: scored.map { item in
            PinyinCandidate(text: item.text, segmented: item.syllables.joined(separator: "'"),
                            isSentence: false, score: item.score, coverage: item.coverage,
                            altered: item.penalty > 0)
        })

        // 整句候选：至少两个音节才有（空格上屏的就是它）。
        // 不止解最优切分：词图按「音节格子」建，一条切分定死一种音节划分，
        // `xian` 取了 `xi an` 就读不到「先」这类整体词——前 K 种切分各解一遍、
        // 按分数合一条，才把码表里那些跨音节划分的长词都喂给语言模型（实测 K=1 → K=4
        // 在同一份句子集上首选命中率 +7 个点）。
        var sentences: [PinyinCandidate] = []
        for best in sentenceSegmentations(segmentations) {
            let sentencePositions = expandedPositions(best, typos: correction == nil)
            if let sentence = plainSentence(sentencePositions, best: best,
                                            leftContext: leftContext, existing: &candidates) {
                sentences.append(sentence)
            }
        }
        if let best = sentences.max(by: { $0.score < $1.score }) {
            // 中文优先：整句先进去占第一
            candidates.insert(best, at: 0)
        }
        return PinyinQuery(candidates: candidates, segmentations: segmentations, tail: tail,
                           marked: markedText(scope: scope, decoded: decoded, tail: tail,
                                              segmentations: segmentations, correction: correction),
                           correction: correction, decoded: decoded)
    }

    /// 参与整句解码的切分：只允许「每个音节都完整」的读法（末尾还没打完的那一个除外）。
    ///
    /// 简拼读法只在词级竞争，不进整句：`zhou xin` 也能切成 `z… hou xin`，让这种读法
    /// 进整句比分，等于允许「少敲几个字母」和「敲得通顺」抢同一个分数——实测
    /// `yilangxingchengxinnacuizhouxin` 会被它抢成「伊朗形成新纳粹之后心」。
    /// 用户真敲简拼时（`kf`）全部切分本来就只有简拼那一种，不受影响。
    private func sentenceSegmentations(_ all: [PinyinSegmentation]) -> [PinyinSegmentation] {
        let allowed = all.filter { segmentation in
            segmentation.innerAbbreviatedCount == 0
        }
        return Array((allowed.isEmpty ? Array(all.prefix(1)) : allowed)
            .prefix(Self.sentenceSegmentations))
    }

    /// 组字区显示的分段拼音。
    private func markedText(scope: String, decoded: ShuangpinDecoded?, tail: String,
                            segmentations: [PinyinSegmentation],
                            correction: PinyinCorrection?) -> String {
        if let decoded { return decoded.marked }
        if let correction { return correction.markedSegments().map(\.text).joined() }
        if let first = segmentations.first {
            return tail.isEmpty ? first.joined("'") : "\(first.joined("'"))'\(tail)"
        }
        return scope
    }

    /// 整段拼音的整句候选。`existing` 用来判断「敲的拼音本身就是一个词」时不许让改过的路径压过它。
    private func plainSentence(_ expanded: PinyinExpanded, best: PinyinSegmentation,
                               leftContext: String,
                               existing: inout [PinyinCandidate]) -> PinyinCandidate? {
        let patterns = best.patterns
        guard patterns.count >= 2 else { return nil }
        var paths = decoder.decode(positions: expanded.patterns,
                                   penaltyOf: { expanded.cost($0, $1) },
                                   leftContext: leftContext, limit: 2)
        // 不按原样读的路径（敲错边 / 模糊音）不许压过「敲的拼音本身就是一个词」：
        // `jineng` 按 `jin eng` 切时词图里没有 技能，敲错边读出 近藤
        if let top = paths.first, top.altered {
            let letters = best.concatenated
            let spelledExactly = existing.contains { $0.syllablesJoined == letters }
            if spelledExactly {
                paths = decoder.decode(positions: expanded.patterns,
                                       penaltyOf: { _, _ in 0 },
                                       leftContext: leftContext, limit: 2)
            }
        }
        guard let top = paths.first, top.syllableCount == patterns.count, !top.text.isEmpty else {
            return nil
        }
        // 整段本来就是一个词时不出整句（词级排序更可信）
        guard top.wordCount >= 2 else { return nil }
        let coverage = best.letters
        return PinyinCandidate(text: top.text, segmented: top.segmented, isSentence: true,
                               score: top.score, coverage: coverage, altered: top.altered)
    }

    // MARK: - 写法展开

    /// 每个位置的写法：敲的原样、模糊音，再加音节级敲错变体当带代价的边。
    /// 太短的输入、双拼、非末尾带简拼的切分不加敲错变体：短串一处编辑几乎总能凑出别的词，
    /// 双拼敲错一键换掉的是整个声母 / 韵母。不完整的位置本来就按前缀查，不加。
    private func expandedPositions(_ segmentation: PinyinSegmentation,
                                   typos: Bool) -> PinyinExpanded {
        let patterns = segmentation.patterns
        var expanded = fuzzy.expand(patterns)
        guard typos, typoEnabled, scheme == nil else { return expanded }
        let letters = segmentation.letters
        let innerAbbreviated = patterns.dropLast().contains { !$0.complete }
        if letters < PinyinCorrector.minLetters || innerAbbreviated { return expanded }
        for (index, pattern) in patterns.enumerated() where pattern.complete {
            for variant in PinyinTypo.variants(pattern.text, kinds: typoKinds) {
                let accepted = typoCountProvider(pattern.text, variant.text)
                expanded.pushAlternative(index, text: variant.text,
                                         cost: costs.typoCost(variant.kind, accepted: accepted))
            }
        }
        return expanded
    }

    // MARK: - 纠错

    /// 噪声信道选一条纠正：原串按原样能转出的整句得分 vs 纠正后的整句得分扣掉一次编辑的代价。
    private func findCorrection(_ scope: String) -> PinyinCorrection? {
        guard PinyinCorrector.eligible(scope) else { return nil }
        let (segmentations, tail) = segmentLongestPrefix(scope) ?? ([], "")
        let candidates: [PinyinCorrection]
        if PinyinCorrector.unlikelyPinyin(segmentations.first, tail: tail) {
            candidates = PinyinCorrector.candidates(scope)
        } else if PinyinCorrector.trailingSingleLetter(segmentations.first) {
            candidates = PinyinCorrector.transpositionCandidates(scope)
        } else {
            return nil
        }
        // 原串切不干净（有尾巴）就没有原样得分，任何能转出整句的纠正都胜出
        let rawScore: Double?
        if tail.isEmpty, let best = segmentations.first {
            rawScore = decoder.decode(positions: expandedPositions(best, typos: true).patterns,
                                      leftContext: "", limit: 1).first.flatMap { path in
                pathContainsPlaceholder(path, best) ? nil : path.score
            }
        } else {
            rawScore = nil
        }
        var best: (score: Double, undiscounted: Double, correction: PinyinCorrection)?
        for candidate in candidates {
            // 「删掉刚敲的最后一个字母」不算纠正：用户可能还没敲完
            if case .delete(let index, _) = candidate.edit, index + 1 == scope.count { continue }
            let patterns = candidate.segmentation.patterns
            let path = decoder.decode(positions: patterns.map { [$0] }, leftContext: "", limit: 1).first
            guard let path, path.syllableCount == patterns.count,
                  !pathContainsPlaceholder(path, candidate.segmentation) else { continue }
            let accepted = candidate.typoPair(consumed: candidate.corrected.count)
                .map { typoCountProvider($0.typed, $0.intended) } ?? 0
            let transpose = candidate.edit.isTranspose
            let score = path.score - costs.correctionCost(transpose: transpose, accepted: accepted)
            let undiscounted = path.score - costs.correctionCost(transpose: false, accepted: accepted)
            if best == nil || score > best!.score {
                best = (score, undiscounted, candidate)
            }
        }
        guard let found = best else { return nil }
        if let rawScore, found.score <= rawScore { return nil }
        return found.correction
    }

    /// 路径里有没有占位音节（词库查不到的读音）：纠正比分要求整句全部读得通。
    private func pathContainsPlaceholder(_ path: PinyinPath, _ segmentation: PinyinSegmentation) -> Bool {
        path.words.contains { word in
            word.syllables.count == 1 && !PinyinSyllables.isSyllable(word.syllables[0])
        }
    }

    /// 整段切不动时退到最长可切前缀（尾巴留着显示）。
    private func segmentLongestPrefix(_ text: String) -> ([PinyinSegmentation], String)? {
        if let segmentations = PinyinParser.segmentOrNil(text) { return (segmentations, "") }
        let letters = Array(text)
        for end in stride(from: letters.count - 1, through: 1, by: -1) {
            if let segmentations = PinyinParser.segmentOrNil(String(letters[0 ..< end])) {
                return (segmentations, String(letters[end...]))
            }
        }
        return nil
    }
}

// MARK: - 词级排序

private extension PinyinEngine {
    /// 一条待排序的词库命中（字段与参考实现 `ranking::Scored` 一一对应）。
    struct Scored {
        var text: String
        var syllables: [String]
        /// 音节数与查询模式长度一致
        var exact: Bool
        /// 输入的最后一个音节完整，且与词的对应音节相同
        var fullLast: Bool
        /// 词覆盖了输入开头多少个字母
        var coverage: Int
        /// 切分里非末尾的简拼音节数
        var abbreviated: Int
        /// 用户选择过的次数
        var weight: Int
        /// 模糊音 / 敲错变体命中的代价
        var penalty: Double
        /// 上下文得分（已含用户加分与代价）
        var score: Double = 0

        var altered: Bool { penalty > 0 }
    }

    /// 排序并按词文本去重（同一个词可能被多种切分命中，保留得分最高的一条），最多留 `limit` 条。
    func rank(_ items: inout [Scored], limit: Int, leftContext: String, input: String) {
        // 远超上限时先按结构键 + 上下文无关先验线性选出前面一段：参考实现这一步用词库词频，
        // 我们没有词频，用模型从 BOS 走一遍的一元分顶替。
        // 「先砍一刀」是必要的（单字母简拼一键命中上万条），但砍的口径不能是「谁词短谁留」：
        // `xi'an` 直查 666 条，按词长砍会把 西安 这类两字词整片砍掉，语言模型根本看不到它们
        // （实测 西安 连 60 条候选都进不去）。多留一倍给去重留余量。
        if items.count > limit * 4 {
            var cache: [String: Double] = [:]
            cache.reserveCapacity(items.count)
            func scoreOf(_ text: String) -> Double {
                if let hit = cache[text] { return hit }
                let value = decoder.wordPrior(text: text)
                cache[text] = value
                return value
            }
            let ordered: [Scored] = items.sorted { lhs, rhs in
                lhs.preselectBetter(than: rhs, prior: scoreOf)
            }
            items = Array(ordered.prefix(limit * 4))
        }
        for index in items.indices {
            let choice = choiceProvider(String(input.prefix(items[index].coverage)), items[index].text)
            items[index].score = contextScore(items[index], leftContext: leftContext)
                + PinyinEngine.weightBonus(items[index].weight + choice)
                - items[index].penalty
        }
        items.sort { lhs, rhs in lhs.sortBetter(than: rhs) }
        var seen = Set<String>()
        items = items.filter { seen.insert($0.text).inserted }
        if items.count > limit { items = Array(items.prefix(limit)) }
    }

    /// 上下文得分：字级 n-gram 给 `log P(词 | 上文)`。
    func contextScore(_ item: Scored, leftContext: String) -> Double {
        decoder.wordLogp(context: leftContext, text: item.text)
    }

}

private extension PinyinEngine.Scored {
    /// 预选键（不拿文本做平手项）：精确 > 覆盖多 > 简拼少 > 末音节完整 > 用户选过 > 先验高 > 原样 > 词短
    func preselectBetter(than other: PinyinEngine.Scored, prior: (String) -> Double) -> Bool {
        if exact != other.exact { return exact }
        if coverage != other.coverage { return coverage > other.coverage }
        if abbreviated != other.abbreviated { return abbreviated < other.abbreviated }
        if fullLast != other.fullLast { return fullLast }
        if weight != other.weight { return weight > other.weight }
        let lhsPrior = prior(text)
        let rhsPrior = prior(other.text)
        if lhsPrior != rhsPrior { return lhsPrior > rhsPrior }
        if altered != other.altered { return !altered }
        return text.count < other.text.count
    }

    /// 排序键，元组的顺序即规则（见文件头注释）。
    func sortBetter(than other: PinyinEngine.Scored) -> Bool {
        if exact != other.exact { return exact }
        if coverage != other.coverage { return coverage > other.coverage }
        if abbreviated != other.abbreviated { return abbreviated < other.abbreviated }
        if fullLast != other.fullLast { return fullLast }
        // 第六项：上下文得分（毫分取整才能比）
        let lhsScore = (score * 1000).rounded()
        let rhsScore = (other.score * 1000).rounded()
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        if altered != other.altered { return !altered }
        if text.count != other.text.count { return text.count < other.text.count }
        return text < other.text
    }
}

private extension PinyinSegmentation {
    /// 切分里非末尾的简拼（不完整）音节数。
    static func abbreviatedCount(_ patterns: [PinyinSyllablePattern]) -> Int {
        guard patterns.count > 1 else { return 0 }
        return patterns.dropLast().filter { !$0.complete }.count
    }
}

private extension PinyinCandidate {
    /// 候选自己的音节连写（判断「整段拼音本身就是一个词」用）。
    var syllablesJoined: String { segmented.replacingOccurrences(of: "'", with: "") }
}
