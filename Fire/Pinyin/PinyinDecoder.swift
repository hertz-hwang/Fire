//
//  PinyinDecoder.swift
//  Fire
//
//  拼音词图上的整句解码：束搜索 + 逐字语言模型打分。
//
//  结构与参考实现 `sentence::viterbi::convert_paths` 同构（格子 = 覆盖若干个连续音节的词，
//  每格只留上下文无关分最高的几条，路径分 = 各步转移分之和），有两处按本项目的模型换了口径：
//
//  * **状态是末两字，不是前一个词**。参考实现的语言模型是词级 bigram（`log P(词|前词)`），
//    Fire 保留的是自己的字级三级插值 n-gram（`TCSKNM02`，`logp(prev2, prev1, 下一字)`），
//    转移分因此是「把这个词的逐字链接在末两字后面」，与形码整句那条路径同一套分数口径。
//    同一格里末两字相同的路径合并成一条（真 Viterbi），束宽只花在真正不同的上下文上。
//  * **格子的上下文无关先验用模型自己算**（从 BOS 走一遍逐字链）再按重码序号轻罚。
//    参考实现的词库带真实词频，用它排格子；拼音码表只有「文件序 = 常用序」，
//    同码内的序号在跨码比较（简拼格子一个字母下面几十个不同音节）时没有分辨力，
//    一元概率是本模型现成且更强的替身。
//

import Foundation

/// 词图上的一条路径（整句候选）。
struct PinyinPath {
    /// 整句文字。
    var text: String

    /// 逐词（用于分段码回显与「整句 vs 单词」判定）。
    var words: [PinyinWord]

    /// 总分：逐字 logp + 结尾 EOS − 重码轻罚 − 模糊音/敲错代价。
    var score: Double

    /// 路径上模糊音 / 敲错变体的代价之和（已从 `score` 里扣掉，另记一份给调用方判断路径是否原样）。
    var penalty: Double

    /// 覆盖的音节数。
    var syllableCount: Int

    /// 词数。
    var wordCount: Int { words.count }

    /// 不是敲的原样（走了模糊音 / 敲错边）。
    var altered: Bool { penalty > 0 }

    /// 分段码（`kai'fa`），给候选栏的编码行。
    var segmented: String { words.map { $0.syllables.joined(separator: " ") }.joined(separator: "'") }
}

/// 路径上的一个词。
struct PinyinWord: Hashable {
    var text: String
    var syllables: [String]
}

/// 拼音整句解码器。
final class PinyinDecoder {
    /// 每个格子最多留几个词（按上下文无关先验）。同音词很多，全留会让束搜索白费。
    static var spanCandidates = 8

    /// 有简拼位置的格子最多留几个词：`h` 下有 和 / 好 / 会 / 还 / 很 ……，
    /// 只留几个会把句子里要的那个挤掉，多留一些让语言模型去挑。
    static var abbreviatedSpanCandidates = 24

    /// 每个位置最多保留几条部分路径。
    static var beamWidth = 32

    /// 非首选词轻罚系数（与形码整句 `SentenceConfig.rankPenalty` 同值，同一套分数口径）。
    static let rankPenalty = 0.03

    /// 词库里没有的孤立音节用占位文字走通，扣这么多分：整句断不掉，但明显不如正常词。
    static let unknownLogProb = -30.0

    /// 一个词最多几个音节（与词库索引同一上限）。
    static let maxWordSyllables = PinyinLexicon.maxWordSyllables

    private let model = NgramModel.shared
    private let lexicon = PinyinLexicon.shared

    /// 格子缓存：敲键是增量的，每一键只有以它结尾的几个格子是新的。
    private var spanCache: [String: [SpanWord]] = [:]
    private var cachedLexiconGeneration = -1

    /// 一个格子（连续若干音节）里的候选词。
    struct SpanWord {
        var word: PinyinWord
        /// 词的 unicode 标量（逐字链打分用）
        var scalars: [UInt32]
        /// 词的自带尾部分数（第 3 字起的逐字 logp 之和，与上文无关）
        var tailScore: Double
        /// 上下文无关先验（从 BOS 走一遍）− 重码轻罚 − 写法代价
        var prior: Double
        /// 命中这个格子所用的写法代价（模糊音 / 敲错）
        var penalty: Double
        /// 重码序号（1 起）
        var ordinal: Int
    }

    private struct Node {
        /// 路径末尾两个字（字级语言模型的全部历史）
        var prev2: UInt32
        var prev1: UInt32
        var score: Double
        var penalty: Double
        /// 这一步的词从第几个音节开始
        var start: Int
        /// 前驱在 `nodes[start]` 里的下标
        var back: Int
        /// 这一步走出来的词（起点节点为 nil）
        var word: PinyinWord?
    }

    private var scalarCache: [String: [UInt32]] = [:]

    /// 占位音节（词库里查不到）的末两字
    private static func tailContext(of text: String, fallback: (UInt32, UInt32)) -> (UInt32, UInt32) {
        let scalars = Array(text.unicodeScalars.map(\.value))
        switch scalars.count {
        case 0: return fallback
        case 1: return (fallback.1, scalars[0])
        default: return (scalars[scalars.count - 2], scalars[scalars.count - 1])
        }
    }

    /// 词表换代后作废格子缓存
    private func ensureCacheValid() {
        if lexicon.generation != cachedLexiconGeneration {
            spanCache.removeAll()
            scalarCache.removeAll()
            cachedLexiconGeneration = lexicon.generation
        }
    }

    func clearCache() { spanCache.removeAll() }

    @inline(__always)
    private func logp(prev2: UInt32, prev1: UInt32, target: UInt32) -> Double {
        model.loaded ? model.logp(prev2: prev2, prev1: prev1, target: target) : 0.0
    }

    private func scalars(of text: String) -> [UInt32] {
        if let cached = scalarCache[text] { return cached }
        let scalars = text.unicodeScalars.map(\.value)
        if scalarCache.count >= 32_768 { scalarCache.removeAll(keepingCapacity: true) }
        scalarCache[text] = scalars
        return scalars
    }

    /// 词的自带尾部分数：第 3 个字起的逐字 logp（只有前两个字吃路径上下文）。
    private func tailScore(of scalars: [UInt32]) -> Double {
        guard scalars.count >= 3 else { return 0 }
        var total = 0.0
        for index in 2 ..< scalars.count {
            total += logp(prev2: scalars[index - 2], prev1: scalars[index - 1], target: scalars[index])
        }
        return total
    }

    /// 把词接在 (prev2, prev1) 后面的转移分（不含 EOS、不含轻罚与写法代价）。
    private func transition(prev2: UInt32, prev1: UInt32, scalars: [UInt32], tail: Double) -> Double {
        guard let first = scalars.first else { return 0 }
        var total = logp(prev2: prev2, prev1: prev1, target: first)
        if scalars.count >= 2 {
            total += logp(prev2: prev1, prev1: first, target: scalars[1]) + tail
        }
        return total
    }

    // MARK: - 解码

    /// 词图上的最优路径（可取前 `limit` 条，文字相同只留一条）。
    /// `positions` 每个位置是若干写法（第一种是敲的，其余是模糊音 / 敲错变体）；
    /// `penaltyOf(位置, 命中的音节)` 是那个位置命中这种写法要扣的分。
    func decode(positions: [[PinyinSyllablePattern]],
                penaltyOf: (Int, String) -> Double = { _, _ in 0 },
                leftContext: String = "",
                limit: Int = 4) -> [PinyinPath] {
        ensureCacheValid()
        let n = positions.count
        guard n > 0, limit > 0, lexicon.isLoaded else { return [] }

        var prev2 = NgramModel.bos
        var prev1 = NgramModel.bos
        for scalar in leftContext.unicodeScalars.suffix(2) {
            prev2 = prev1
            prev1 = scalar.value
        }

        // nodes[i]：覆盖前 i 个音节、以某个「末两字」结尾的部分路径；nodes[0] 是虚拟起点
        var nodes: [[Node]] = Array(repeating: [], count: n + 1)
        nodes[0] = [Node(prev2: prev2, prev1: prev1, score: 0, penalty: 0,
                         start: 0, back: 0, word: nil)]
        for start in 0 ..< n {
            prune(&nodes[start])
            guard !nodes[start].isEmpty else { continue }
            var any = false
            let furthest = min(n, start + Self.maxWordSyllables)
            for end in (start + 1) ... furthest {
                let span = Array(positions[start ..< end])
                let hits = spanWords(span, start: start, penaltyOf: penaltyOf)
                guard !hits.isEmpty else { continue }
                any = true
                for hit in hits {
                    var bestScore = -Double.infinity
                    var bestIndex = 0
                    for (index, previous) in nodes[start].enumerated() {
                        let total = previous.score + transition(prev2: previous.prev2,
                                                                prev1: previous.prev1,
                                                                scalars: hit.scalars,
                                                                tail: hit.tailScore)
                        if total > bestScore { bestScore = total; bestIndex = index }
                    }
                    let previous = nodes[start][bestIndex]
                    let wordScalars = hit.scalars
                    // 走完这个词之后的末两字：词内不足两字时要接在旧末字后面
                    // （单字词 (A,B)→(B,C)，漏掉这一步会让下一个词看到隔了一位的上文，
                    // 实测把「就有演奏国木吉他的经验」虚高 7 nat，整句首选因此跑偏）
                    nodes[end].append(Node(
                        prev2: wordScalars.count >= 2 ? wordScalars[wordScalars.count - 2] : previous.prev1,
                        prev1: wordScalars.last ?? previous.prev1,
                        // 写法代价（模糊音 / 敲错）在这里真扣进路径分：只用来排格子
                        // 会让「改一改就通顺」的读法无代价地压过用户敲的原话
                        score: bestScore - Double(hit.ordinal - 1) * Self.rankPenalty
                            - hit.penalty,
                        penalty: previous.penalty + hit.penalty,
                        start: start, back: bestIndex, word: hit.word))
                }
            }
            // 这个音节连单字都查不到：用音节本身占位，别让整句断掉
            if !any {
                let text = positions[start][0].text
                var bestScore = -Double.infinity
                var bestIndex = 0
                for (index, previous) in nodes[start].enumerated() where previous.score > bestScore {
                    bestScore = previous.score; bestIndex = index
                }
                let previous = nodes[start][bestIndex]
                let placeholder = PinyinWord(text: text, syllables: [text])
                let context = Self.tailContext(of: text, fallback: (previous.prev2, previous.prev1))
                nodes[start + 1].append(Node(prev2: context.0, prev1: context.1,
                                             score: bestScore + Self.unknownLogProb,
                                             penalty: previous.penalty,
                                             start: start, back: bestIndex, word: placeholder))
            }
        }
        prune(&nodes[n])

        var paths: [PinyinPath] = []
        var seen = Set<String>()
        for index in nodes[n].indices {
            let node = nodes[n][index]
            let words = backtrack(nodes, position: n, index: index)
            let text = words.map(\.text).joined()
            if text.isEmpty || seen.contains(text) { continue }
            seen.insert(text)
            // 结尾 EOS：整段消耗完才算「句子说完」，与形码整句同一口径
            let penalty = node.penalty
            let final = node.score + logp(prev2: node.prev2, prev1: node.prev1, target: NgramModel.eos)
            paths.append(PinyinPath(text: text, words: words, score: final, penalty: penalty,
                                    syllableCount: n))
            if paths.count >= limit { break }
        }
        // prune 按的是不含 EOS 的状态分，这里按含 EOS 的最终分重排
        paths.sort { $0.score > $1.score }
        return paths
    }

    /// 从 `nodes[position][index]` 回溯出词序列。
    private func backtrack(_ nodes: [[Node]], position: Int, index: Int) -> [PinyinWord] {
        var words: [PinyinWord] = []
        var position = position
        var index = index
        while position > 0 {
            let node = nodes[position][index]
            if let word = node.word { words.append(word) }
            position = node.start
            index = node.back
        }
        words.reverse()
        return words
    }

    /// 一个格子（连续若干音节）里的候选词。
    private func spanWords(_ span: [[PinyinSyllablePattern]], start: Int,
                           penaltyOf: (Int, String) -> Double) -> [SpanWord] {
        let key = spanKey(span, start: start)
        if let cached = spanCache[key] { return cached }
        let matches = lexicon.lookupExactAlt(span)
        let abbreviated = span.contains { position in position.contains { !$0.complete } }
        var scored: [SpanWord] = []
        scored.reserveCapacity(matches.count)
        for match in matches {
            let syllables = match.key.split(separator: " ").map(String.init)
            var penalty = 0.0
            for (offset, syllable) in syllables.enumerated() {
                penalty += penaltyOf(start + offset, syllable)
            }
            let scalars = scalars(of: match.text)
            let tail = tailScore(of: scalars)
            // 一元先验：从 BOS 走一遍逐字链（与路径上下文无关，格子内可比分）
            let prior = transition(prev2: NgramModel.bos, prev1: NgramModel.bos,
                                   scalars: scalars, tail: tail)
                - Double(match.ordinal - 1) * Self.rankPenalty
                - penalty
            scored.append(SpanWord(word: PinyinWord(text: match.text, syllables: syllables),
                                   scalars: scalars, tailScore: tail, prior: prior,
                                   penalty: penalty, ordinal: match.ordinal))
        }
        scored.sort { $0.prior > $1.prior }
        // 同一个词可能被多种切法命中，只留分高的那条
        var seen = Set<String>()
        let kept = scored.filter { seen.insert($0.word.text).inserted }
        let truncated = Array(kept.prefix(abbreviated ? Self.abbreviatedSpanCandidates
                                                     : Self.spanCandidates))
        spanCache[key] = truncated
        return truncated
    }

    /// 格子缓存键：起始位置 + 各位置写法（写法决定代价，位置决定代价落在哪）。
    private func spanKey(_ span: [[PinyinSyllablePattern]], start: Int) -> String {
        var key = "\(start)"
        for position in span {
            key += "|"
            for form in position { key += "\(form.complete ? form.text : "\(form.text)…")," }
        }
        return key
    }

    /// 同一格子里末两字相同的路径合并（只留分高的），再按分数留束宽。
    private func prune(_ nodes: inout [Node]) {
        var bestByContext: [UInt64: Int] = [:]
        var kept: [Node] = []
        kept.reserveCapacity(nodes.count)
        for node in nodes {
            let context = (UInt64(node.prev2) << 32) | UInt64(node.prev1)
            if let slot = bestByContext[context] {
                if node.score > kept[slot].score { kept[slot] = node }
            } else {
                bestByContext[context] = kept.count
                kept.append(node)
            }
        }
        kept.sort { $0.score > $1.score }
        if kept.count > Self.beamWidth { kept = Array(kept.prefix(Self.beamWidth)) }
        nodes = kept
    }
}

extension PinyinDecoder {
    /// 词在给定左上下文下的逐字 logp（`log P(词 | 上文末两字)`）：词级候选的上下文得分，
    /// 与整句路径同一套分数口径。参考实现词级排序里的 `transition_log_prob` 在本模型下的替身。
    func wordLogp(context: String, text: String) -> Double {
        var prev2 = NgramModel.bos
        var prev1 = NgramModel.bos
        for scalar in context.unicodeScalars.suffix(2) {
            prev2 = prev1
            prev1 = scalar.value
        }
        let scalars = scalars(of: text)
        var total = 0.0
        for scalar in scalars {
            total += logp(prev2: prev2, prev1: prev1, target: scalar)
            prev2 = prev1
            prev1 = scalar
        }
        return total
    }

    /// 词的上下文无关先验（从 BOS 走一遍逐字链）。
    func wordPrior(text: String) -> Double {
        let scalars = scalars(of: text)
        return transition(prev2: NgramModel.bos, prev1: NgramModel.bos,
                          scalars: scalars, tail: tailScore(of: scalars))
    }

    /// 词库是否收录某个音节序列（纠错比分用：纠正后的拼音至少得凑出一个词）。
    func hasSyllables(_ syllables: [String]) -> Bool {
        lexicon.lookupExactAlt(syllables.map { [PinyinSyllablePattern.full($0)] }).contains {
            !$0.text.isEmpty
        }
    }
}
