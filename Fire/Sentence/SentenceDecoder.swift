//
//  SentenceDecoder.swift
//  Fire
//
//  整句 beam search 解码器（移植虎整句 expand_range / emit / dedup_limit /
//  select_exact_top / decode 增量复用 / build_prefix_evidence）。
//
//  选重符（与虎整句 speller alphabet 对齐，写进编码流）：
//  `;`=第2码 `'`=第3码 数字=第N码（0=第10），消耗 1..n 个键。
//  未跟选重符时（selectedRank=0）：整段边全 rank 参与；分段边在
//  allowDuplicateSingle 开时允许 rank1 + 单字重码，关时只允许 rank1。
//  显式选重的边不加 rank 轻罚、不加整码单字奖励（与 Lua 一致）。
//
//  编码以 [UInt8]（normalize 后保证全是 a-z;'0-9）贯穿解码。
//

import Foundation
import os
import Defaults

// MARK: - 词图状态

final class SentenceState {
    var score: Double
    /// 概率质量：剔除整码单字奖励后的分数，提前上屏证据只认它
    var massScore: Double
    let text: String
    let prev2: UInt32
    let prev1: UInt32
    let maxRank: Int
    let previous: SentenceState?
    let rawLength: Int
    let edgeCount: Int
    /// supplement 匹配器状态（虎整句 supplement_state，节点索引；整段奖励
    /// 进 score 不进 massScore）
    var supplementState: Int
    var supplementScore: Double

    init(score: Double, massScore: Double, text: String, prev2: UInt32, prev1: UInt32,
         maxRank: Int, previous: SentenceState?, rawLength: Int, edgeCount: Int,
         supplementState: Int = 0, supplementScore: Double = 0) {
        self.score = score
        self.massScore = massScore
        self.text = text
        self.prev2 = prev2
        self.prev1 = prev1
        self.maxRank = maxRank
        self.previous = previous
        self.rawLength = rawLength
        self.edgeCount = edgeCount
        self.supplementState = supplementState
        self.supplementScore = supplementScore
    }
}

@inline(__always)
func sentenceLogsumexp(_ left: Double, _ right: Double) -> Double {
    let maximum = max(left, right)
    return maximum + Foundation.log(Foundation.exp(left - maximum) + Foundation.exp(right - maximum))
}

@inline(__always)
func beamLimitAt(_ rawLength: Int) -> Int {
    rawLength > SentenceConfig.longInputFullBeamLength
        ? SentenceConfig.longInputBeamWidth
        : SentenceConfig.beamWidth
}

// MARK: - 选重符（Lua parse_selector / trailing_selector_span / has_selection_suffix）

enum Selector {
    /// 码边结束位置 codeEnd 之后的选重符：返回 (rank, 消耗到的位置)。
    /// 数字可连打（"12" = 第12码），"0" = 第10。
    static func parse(_ raw: [UInt8], _ codeEnd: Int) -> (rank: Int, consumedEnd: Int) {
        guard codeEnd < raw.count else { return (0, codeEnd) }
        let mark = raw[codeEnd]
        if mark == 0x3B { return (2, codeEnd + 1) } // ';'
        if mark == 0x27 { return (3, codeEnd + 1) } // '''
        if mark >= 0x30 && mark <= 0x39 {            // 数字
            var end = codeEnd
            while end < raw.count, raw[end] >= 0x30, raw[end] <= 0x39 {
                end += 1
            }
            let token = String(decoding: raw[codeEnd..<end], as: UTF8.self)
            if token == "0" { return (10, end) }
            return (Int(token) ?? 0, end)
        }
        return (0, codeEnd)
    }

    /// 尾部连续选重符字节数（增量复用时 maxConsume 加宽用）
    static func trailingSpan(_ raw: [UInt8]) -> Int {
        var index = raw.count
        while index > 0 {
            let mark = raw[index - 1]
            if (mark >= 0x30 && mark <= 0x39) || mark == 0x3B || mark == 0x27 {
                index -= 1
            } else {
                break
            }
        }
        return raw.count - index
    }

    static func hasSelectionSuffix(_ raw: [UInt8]) -> Bool {
        for mark in raw {
            if (mark >= 0x30 && mark <= 0x39) || mark == 0x3B || mark == 0x27 {
                return true
            }
        }
        return false
    }
}

/// 边资格（Lua eligible_candidates）：
/// rank>0：只取该 rank。rank=0（无选重符）：整段边全收；
/// allowDuplicateSingle 开时允许 rank1 + 单字重码；关时只允许 rank1。
func eligibleEdges(_ edges: [SentenceEdge], selectedRank: Int,
                   wholeInputEdge: Bool, allowDuplicateSingle: Bool) -> [SentenceEdge] {
    if selectedRank > 0 {
        return edges.filter { $0.rank == selectedRank }
    }
    if wholeInputEdge {
        return edges
    }
    if allowDuplicateSingle {
        return edges.filter { $0.rank == 1 || $0.text.count == 1 }
    }
    return edges.filter { $0.rank == 1 }
}

// MARK: - 状态比较器（Lua current_state_comparator / state_better_*）

/// 词库序优先（整段单边场景）
func stateBetterRankFirst(_ left: SentenceState, _ right: SentenceState) -> Bool {
    if left.maxRank != right.maxRank { return left.maxRank < right.maxRank }
    if left.score == right.score { return left.text < right.text }
    return left.score > right.score
}

/// 分数优先（分段路径场景）
func stateBetterScoreFirst(_ left: SentenceState, _ right: SentenceState) -> Bool {
    if left.score == right.score {
        if left.maxRank != right.maxRank { return left.maxRank < right.maxRank }
        return left.text < right.text
    }
    return left.score > right.score
}

// MARK: - 最劣堆 top-k（Lua select_exact_top），O(n log k)

func selectExactTop(_ values: [SentenceState], limit: Int,
                    better: (SentenceState, SentenceState) -> Bool) -> [SentenceState] {
    guard limit > 0 else { return [] }
    var heap: [SentenceState] = []
    heap.reserveCapacity(limit)

    func siftUp(_ index: Int) {
        var index = index
        while index > 0 {
            let parent = (index - 1) / 2
            if better(heap[parent], heap[index]) {
                heap.swapAt(parent, index)
                index = parent
            } else {
                return
            }
        }
    }
    func siftDown(_ index: Int) {
        var index = index
        while true {
            let left = index * 2 + 1
            if left >= heap.count { return }
            var worse = left
            let right = left + 1
            if right < heap.count && better(heap[left], heap[right]) {
                worse = right
            }
            if better(heap[index], heap[worse]) {
                heap.swapAt(index, worse)
                index = worse
            } else {
                return
            }
        }
    }

    for item in values {
        if heap.count < limit {
            heap.append(item)
            siftUp(heap.count - 1)
        } else if better(item, heap[0]) {
            heap[0] = item
            siftDown(0)
        }
    }
    heap.sort(by: better)
    return heap
}

// MARK: - 桶（Lua bucket：扩展期散装、到阈值或 dedup 时按文本聚合成冻结桶）

final class SentenceBucket {
    private(set) var items: [SentenceState] = []
    private var aggregated = false
    private(set) var truncated = false

    var count: Int { items.count }

    /// 同文本的重复状态：合并概率质量到保留项， duplicateBetter 决定留哪条
    private func duplicateBetter(_ item: SentenceState, _ previous: SentenceState) -> Bool {
        if item.maxRank != previous.maxRank { return item.maxRank < previous.maxRank }
        if item.score != previous.score { return item.score > previous.score }
        return item.edgeCount < previous.edgeCount
    }

    private func addAggregated(_ item: SentenceState) {
        if let previousIndex = items.firstIndex(where: { $0.text == item.text }) {
            let previous = items[previousIndex]
            let combined = sentenceLogsumexp(previous.massScore, item.massScore)
            if duplicateBetter(item, previous) {
                item.massScore = combined
                items[previousIndex] = item
            } else {
                previous.massScore = combined
            }
        } else {
            items.append(item)
        }
    }

    func append(_ item: SentenceState) {
        if aggregated {
            addAggregated(item)
            return
        }
        items.append(item)
        if items.count >= SentenceConfig.aggregateDuringExpansionThreshold {
            aggregate()
        }
    }

    func aggregate() {
        if aggregated { return }
        var order: [String] = []
        var best: [String: SentenceState] = [:]
        var mass: [String: Double] = [:]
        for item in items {
            if mass[item.text] == nil {
                mass[item.text] = item.massScore
                order.append(item.text)
                best[item.text] = item
            } else {
                mass[item.text] = sentenceLogsumexp(mass[item.text]!, item.massScore)
                if duplicateBetter(item, best[item.text]!) {
                    best[item.text] = item
                }
            }
        }
        var merged: [SentenceState] = []
        merged.reserveCapacity(order.count)
        for text in order {
            let item = best[text]!
            item.massScore = mass[text]!
            merged.append(item)
        }
        items = merged
        aggregated = true
    }

    /// 聚合 + beam 截断（Lua dedup_limit），返回新桶
    func dedup(limit: Int, better: (SentenceState, SentenceState) -> Bool) -> SentenceBucket {
        let output = SentenceBucket()
        if truncated {
            output.truncated = true
        }
        var result = items
        let truncatedNow = result.count > limit
        if truncatedNow {
            output.truncated = true
            result = selectExactTop(result, limit: limit, better: better)
        }
        if aggregated {
            output.adoptAggregated(result)
        } else {
            // 未聚合过：先聚合散装状态（合并同文本质量）再排序
            output.aggregateFrom(result)
        }
        output.items.sort(by: better)
        return output
    }

    fileprivate func adoptAggregated(_ newItems: [SentenceState]) {
        items = newItems
        aggregated = true
    }

    fileprivate func aggregateFrom(_ source: [SentenceState]) {
        items = source
        aggregated = false
        aggregate()
    }
}

// MARK: - 解码器

final class SentenceDecoder {
    private let model = NgramModel.shared
    private let lexicon = SentenceLexicon.shared
    private let supplement = SentenceSupplement.shared

    /// 增量 lattice 缓存
    private var cachedRaw: [UInt8] = []
    private var cachedBuckets: [SentenceBucket?] = []
    /// 构建 lattice 时用的左上下文（自动上屏留存文本）；变了必须整体重解码
    private var cachedContext: String = ""
    /// lattice 构建时的词表代数；换词库后必须整体重解码
    private var cachedLexiconGeneration: Int = -1
    /// 单字单码开关变更也让增量缓存作废（rank 资格变了）
    private var cachedAllowDuplicate: Bool?

    /// 单字缓存：文本 -> [Unicode scalar]
    private var charCache: [String: [UInt32]] = [:]

    #if DEBUG
    /// DEBUG 增量校验抽检间隔（每 N 次增量解码全量对比一次；退格后必验）
    static let debugVerifyEvery = 8
    /// 跨会话共享计数：避免每个会话的校验都落在同一个码长上
    private static var incrementalDecodeCount = 0
    #endif

    @inline(__always)
    fileprivate func scalarsOf(_ text: String) -> [UInt32] {
        if let cached = charCache[text] { return cached }
        let scalars = text.unicodeScalars.map { $0.value }
        if charCache.count >= 16384 { charCache.removeAll(keepingCapacity: true) }
        charCache[text] = scalars
        return scalars
    }

    /// logp（模型未加载时返回 0，与虎整句无模型分支一致）
    @inline(__always)
    fileprivate func logp(prev2: UInt32, prev1: UInt32, target: UInt32) -> Double {
        model.loaded ? model.logp(prev2: prev2, prev1: prev1, target: target) : 0.0
    }

    func reset() {
        cachedRaw = []
        cachedBuckets = []
        cachedContext = ""
    }

    /// normalize：小写 + 去空白，保留选重符 a-z;'0-9（虎整句 alphabet 同源）
    static func normalize(_ raw: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            if value == 0x20 || value == 0x09 { continue }
            if value >= 0x41 && value <= 0x5A {
                bytes.append(UInt8(value + 32))
            } else if (value >= 0x61 && value <= 0x7A)      // a-z
                        || value == 0x3B || value == 0x27     // ; '
                        || (value >= 0x30 && value <= 0x39) { // 0-9
                bytes.append(UInt8(value))
            } else {
                return nil // 其它字符不参与整句
            }
        }
        return bytes
    }

    private static func hasLetter(_ raw: [UInt8]) -> Bool {
        for byte in raw where (97...122).contains(byte) {
            return true
        }
        return false
    }

    // MARK: - expand（Lua expand_range）

    private func expandRange(_ raw: [UInt8], _ buckets: inout [SentenceBucket?],
                             from fromPos: Int, length: Int,
                             minimumConsumedEnd: Int = -1,
                             allowDuplicateSingle: Bool) {
        var scratch: [UInt8] = []
        for position in fromPos..<length {
            guard var current = buckets[position] else { continue }
            current = current.dedup(limit: beamLimitAt(position), better: stateBetterScoreFirst)
            buckets[position] = current
            guard current.count > 0 else { continue }

            for codeLength in lexicon.lengths {
                let end = position + codeLength
                if end > length { continue }
                let selector = Selector.parse(raw, end)
                let consumedEnd = selector.consumedEnd
                if consumedEnd > length { continue }
                if consumedEnd <= minimumConsumedEnd { continue }
                // 短边门槛（虎整句同源规则）：length>1 时只允许"整段消耗"或
                // "消耗 ≥2 键"的边（按 consumedEnd-position，选重符计入段消耗）。
                if length > 1 && consumedEnd - position < 2 { continue }
                scratch = Array(raw[position..<end])
                let code = String(decoding: scratch, as: UTF8.self)
                guard let edges = lexicon.edges(for: code) else { continue }

                let wholeInputEdge = position == 0 && consumedEnd == length
                let selected = eligibleEdges(edges,
                                            selectedRank: selector.rank,
                                            wholeInputEdge: wholeInputEdge,
                                            allowDuplicateSingle: allowDuplicateSingle)
                if selected.isEmpty { continue }

                let hasSupplements = supplement.hasEntries
                for item in current.items {
                    for edge in selected {
                        var score = item.score
                        var prev2 = item.prev2
                        var prev1 = item.prev1
                        var supState = item.supplementState
                        var supAdded = 0.0
                        let edgeScalars = scalarsOf(edge.text)
                        let edgeChars = edge.text.map { $0 }
                        for (ci, scalar) in edgeScalars.enumerated() {
                            score += logp(prev2: prev2, prev1: prev1, target: scalar)
                            score += SentenceConfig.emittedCharacterReward
                            if hasSupplements {
                                let step = supplement.advance(state: supState, edgeChars[ci])
                                supState = step.state
                                score += step.reward
                                supAdded += step.reward
                            }
                            prev2 = prev1
                            prev1 = scalar
                        }
                        // 显式选重的边不加 rank 轻罚（Lua：selected_rank==0 才罚）
                        if selector.rank == 0 {
                            score -= SentenceConfig.rankPenalty * Foundation.log(Double(edge.rank))
                        }
                        // 整码最优单字奖励只加在 score，不进 massScore（置信度）
                        var massDelta = score - item.score
                        var singleRewardAdded = 0.0
                        if wholeInputEdge && selector.rank == 0
                            && edge.optimalSingle && edgeScalars.count == 1 {
                            singleRewardAdded = SentenceConfig.wholeInputSingleCharacterReward
                            score += singleRewardAdded
                            massDelta = score - item.score - supAdded - singleRewardAdded
                        } else {
                            massDelta -= supAdded
                        }
                        let state = SentenceState(
                            score: score,
                            massScore: item.massScore + massDelta,
                            text: item.text + edge.text,
                            prev2: prev2, prev1: prev1,
                            maxRank: Swift.max(item.maxRank, edge.rank),
                            previous: item,
                            rawLength: consumedEnd,
                            edgeCount: item.edgeCount + 1,
                            supplementState: supState,
                            supplementScore: item.supplementScore + supAdded)
                        let bucket = buckets[consumedEnd] ?? SentenceBucket()
                        bucket.append(state)
                        buckets[consumedEnd] = bucket
                    }
                }
            }
        }
    }

    // MARK: - evaluate / segmented

    fileprivate func evaluateState(_ item: SentenceState) -> SentenceCompleted {
        let endingAdjustment = logp(prev2: item.prev2, prev1: item.prev1, target: NgramModel.eos)
        return SentenceCompleted(
            score: item.score + endingAdjustment,
            confidenceScore: item.massScore + endingAdjustment,
            text: item.text,
            supplementScore: item.supplementScore,
            maxRank: Swift.max(1, item.maxRank),
            edgeCount: item.edgeCount,
            rawLength: item.rawLength,
            path: item)
    }

    private func segmentedFromPath(_ path: SentenceState?, raw: [UInt8]) -> String {
        var ends: [Int] = []
        var node: SentenceState? = path
        while let n = node, n.rawLength > 0 {
            ends.append(n.rawLength)
            node = n.previous
        }
        var pieces: [String] = []
        pieces.reserveCapacity(ends.count)
        var start = 0
        for finish in ends.reversed() {
            pieces.append(String(decoding: raw[start..<finish], as: UTF8.self))
            start = finish
        }
        return pieces.joined(separator: " ")
    }

    // MARK: - emit（Lua emit）

    fileprivate func emit(_ raw: [UInt8], _ buckets: inout [SentenceBucket?], length: Int,
                         includeEarlyCommit: Bool,
                         allowDuplicateSingle: Bool) -> SentenceDecodeResult {
        let completedBucket = (buckets[length] ?? SentenceBucket())
            .dedup(limit: beamLimitAt(length), better: stateBetterScoreFirst)
        buckets[length] = completedBucket

        var all: [SentenceCompleted] = []
        all.reserveCapacity(completedBucket.count)
        for state in completedBucket.items {
            var candidate = evaluateState(state)
            candidate.segmented = segmentedFromPath(state, raw: raw)
            all.append(candidate)
        }

        // 单字重码组句开 + 分段路径 → 分数竞争；否则保持词库序
        // （Lua prefer_score_over_lexicon_rank：allow 关时恒 rank-first）
        let hasSegmentedPath = all.contains {
            $0.path.previous != nil && $0.path.previous!.rawLength > 0
        }
        let better = (allowDuplicateSingle && hasSegmentedPath)
            ? stateBetterScoreFirst : stateBetterRankFirst
        var result = all
        if result.count > SentenceConfig.candidateLimit {
            // 最劣堆按 path 选，再按同一 better 映射回候选
            let states = selectExactTop(all.map { $0.path },
                                         limit: SentenceConfig.candidateLimit, better: better)
            var byIdentity = [ObjectIdentifier: SentenceCompleted]()
            for candidate in all { byIdentity[ObjectIdentifier(candidate.path)] = candidate }
            result = states.compactMap { byIdentity[ObjectIdentifier($0)] }
        } else {
            result.sort { better($0.path, $1.path) }
        }

        var evidence = SentenceEarlyEvidence()
        evidence.confidenceTruncated = completedBucket.truncated
        if includeEarlyCommit && !completedBucket.truncated {
            evidence = buildEarlyCommitEvidence(raw: raw, buckets: &buckets,
                                                visible: result)
        }
        return SentenceDecodeResult(candidates: result, evidence: evidence)
    }

    // MARK: - 提前上屏证据（Lua build_early_commit_evidence / build_prefix_evidence）

    private func buildEarlyCommitEvidence(
        raw: [UInt8], buckets: inout [SentenceBucket?],
        visible: [SentenceCompleted]
    ) -> SentenceEarlyEvidence {
        // pool：可见整句候选 + 不完整码尾的中间态
        var pool: [SentenceCompleted] = visible.filter { !$0.text.isEmpty }
        var mergedIncompleteTail = false

        let maximumTailLength = Swift.min(lexicon.maxCodeLength - 1, raw.count - 1)
        if maximumTailLength >= 1 {
            for tailLength in 1...maximumTailLength {
                let consumedLength = raw.count - tailLength
                guard incompleteCodeTail(raw[consumedLength..<raw.count]),
                      let partialBucket = buckets[consumedLength] else { continue }
                let partial = partialBucket.dedup(limit: beamLimitAt(consumedLength),
                                                  better: stateBetterScoreFirst)
                buckets[consumedLength] = partial
                var added = false
                for state in partial.items where !state.text.isEmpty {
                    pool.append(evaluateState(state))
                    added = true
                }
                if added {
                    mergedIncompleteTail = true
                    if partial.truncated {
                        var truncated = SentenceEarlyEvidence()
                        truncated.confidenceTruncated = true
                        return truncated
                    }
                }
            }
        }

        let prefixes = buildPrefixEvidence(pool)

        var proposal = ""
        var proposalShare = 0.0
        var proposalRawLength = 0
        var proposalChars = 0
        var rawLengths: [String: Int] = [:]

        var bestClosedPrefix: [String: SentencePrefixEvidence] = [:]
        for prefix in prefixes where prefix.boundaryClosed {
            if let existing = bestClosedPrefix[prefix.text] {
                if prefix.share > existing.share
                    || (prefix.share == existing.share && prefix.rawLength < existing.rawLength) {
                    bestClosedPrefix[prefix.text] = prefix
                }
            } else {
                bestClosedPrefix[prefix.text] = prefix
            }
        }
        for (text, prefix) in bestClosedPrefix {
            rawLengths[text] = prefix.rawLength
            if prefix.share >= SentenceConfig.earlyCommitMinimumShare {
                var replace = proposal.isEmpty
                if !replace {
                    if prefix.textCharCount != proposalChars {
                        replace = prefix.textCharCount > proposalChars
                    } else if prefix.share != proposalShare {
                        replace = prefix.share > proposalShare
                    } else {
                        replace = prefix.rawLength < proposalRawLength
                    }
                }
                if replace {
                    proposal = prefix.text
                    proposalShare = prefix.share
                    proposalRawLength = prefix.rawLength
                    proposalChars = prefix.textCharCount
                }
            }
        }

        return SentenceEarlyEvidence(
            prefixes: prefixes,
            proposal: proposal,
            proposalShare: proposalShare,
            rawLengths: rawLengths,
            neutralIncompleteTail: visible.isEmpty && mergedIncompleteTail,
            mergedIncompleteTail: mergedIncompleteTail,
            neutralLowConfidence: hasLowConfidenceCompletedGeneration(visible),
            confidenceTruncated: false)
    }

    /// 每个 (文字前缀, raw 边界) 的后验占比；boundary 质量每候选每边界计一次
    private func buildPrefixEvidence(_ pool: [SentenceCompleted]) -> [SentencePrefixEvidence] {
        guard !pool.isEmpty else { return [] }
        var maxScore = pool[0].confidenceScore
        for candidate in pool.dropFirst() where candidate.confidenceScore > maxScore {
            maxScore = candidate.confidenceScore
        }
        var total = 0.0
        var weights: [Double] = []
        weights.reserveCapacity(pool.count)
        for candidate in pool {
            let weight = Foundation.exp(candidate.confidenceScore - maxScore)
            weights.append(weight)
            total += weight
        }
        if total <= 0 { return [] }

        struct Entry { var text: String; var rawLength: Int; var weight: Double; var chars: Int }
        var entries: [Entry] = []
        var entryIndex: [String: Int] = [:]
        var boundaryMass: [Int: Double] = [:]

        for (i, candidate) in pool.enumerated() {
            let weight = weights[i]
            var state: SentenceState? = candidate.path
            while let node = state {
                if !node.text.isEmpty {
                    let key = "\(node.rawLength)\u{1F}" + node.text
                    if let index = entryIndex[key] {
                        entries[index].weight += weight
                    } else {
                        entryIndex[key] = entries.count
                        entries.append(Entry(text: node.text, rawLength: node.rawLength,
                                            weight: weight, chars: node.text.unicodeScalars.count))
                    }
                    // 路径上 raw 长度严格递增：每候选每边界恰好计一次
                    boundaryMass[node.rawLength, default: 0.0] += weight
                }
                state = node.previous
            }
        }

        return entries.map { entry in
            let boundaryShare = (boundaryMass[entry.rawLength] ?? 0.0) / total
            return SentencePrefixEvidence(
                text: entry.text,
                rawLength: entry.rawLength,
                share: entry.weight / total,
                boundaryShare: boundaryShare,
                boundaryClosed: boundaryShare >= SentenceConfig.earlyCommitClosedBoundaryShare,
                textCharCount: entry.chars)
        }
    }

    private func hasLowConfidenceCompletedGeneration(_ candidates: [SentenceCompleted]) -> Bool {
        if candidates.isEmpty { return false }
        var maxScore = candidates[0].confidenceScore
        for candidate in candidates.dropFirst() where candidate.confidenceScore > maxScore {
            maxScore = candidate.confidenceScore
        }
        var total = 0.0
        for candidate in candidates {
            total += Foundation.exp(candidate.confidenceScore - maxScore)
        }
        return total > 0 && 1.0 / total < SentenceConfig.earlyCommitMinimumShare
    }

    private func incompleteCodeTail(_ tail: ArraySlice<UInt8>) -> Bool {
        if tail.isEmpty { return false }
        if !SentenceDecoder.hasLetter(Array(tail)) { return false }
        let tailString = String(decoding: tail, as: UTF8.self)
        if !lexicon.isProperPrefix(tailString) { return false }
        return tailString.count < 2 || lexicon.edges(for: tailString) == nil
    }

    // MARK: - 解码入口（Lua decode：增量 lattice 复用）

    /// 整句解码。append：从 `oldN + 1 - maxConsume` 起扩展并禁止产生
    /// consumedEnd ≤ oldN 的新边；delete：直接砍尾部桶。
    /// context：自动上屏留存的左上下文文字（「N-gram留存信息数」）。
    /// 只喂给 n-gram 与 supplement 做历史（prev2/prev1 seed + AC 状态推进），
    /// 不进候选文字、不计 score/mass——左上下文对同一输入下所有候选同等生效。
    func decode(_ rawCode: String, includeEarlyCommit: Bool = false,
                context: String = "") -> SentenceDecodeResult {
        let allowDuplicate = Defaults[.enableSentenceAllowDuplicateSingle]
        guard let raw = SentenceDecoder.normalize(rawCode), !raw.isEmpty,
              SentenceDecoder.hasLetter(raw),
              raw.count <= SentenceConfig.maxRawLength else {
            reset()
            return SentenceDecodeResult(candidates: [], evidence: SentenceEarlyEvidence())
        }
        let length = raw.count

        // 词表换代 / 单字单码开关变更后旧 lattice 失效，整体重解码；
        // supplement 加权词（用户词库）与词表同代刷新，保证两者不会错代混用
        if lexicon.generation != cachedLexiconGeneration || cachedAllowDuplicate != allowDuplicate {
            cachedRaw = []
            cachedBuckets = []
            cachedLexiconGeneration = lexicon.generation
            cachedAllowDuplicate = allowDuplicate
            supplement.refresh()
        }
        // 左上下文变了（新上屏/留存数调整）：旧 lattice 的历史全部错位，整体重解码
        if context != cachedContext {
            cachedRaw = []
            cachedBuckets = []
            cachedContext = context
        }

        let signpostID = OSSignpostID(log: .sentence)
        os_signpost(.begin, log: OSLog.sentence, name: "decode", signpostID: signpostID)
        defer { os_signpost(.end, log: OSLog.sentence, name: "decode", signpostID: signpostID) }

        var buckets: [SentenceBucket?]? = nil
        let oldRaw = cachedRaw
        let oldN = oldRaw.count
        // 本键是否走了增量复用（fresh 构建无需校验——它本身就是全量）
        var usedIncremental = false

        if oldN > 0 {
            if oldRaw == raw, cachedBuckets.count == length + 1 {
                buckets = cachedBuckets
                usedIncremental = true
            } else if oldN <= 4 || length <= 4 {
                buckets = nil
            } else if length > oldN, Array(raw.prefix(oldN)) == oldRaw {
                // 选重符可挂在任何码边后：追加一键可能激活旧位置的 rank2/3 边，
                // maxConsume 加上尾部选重符跨度（Lua trailing_selector_span）
                let maxConsume = lexicon.maxCodeLength + Selector.trailingSpan(raw)
                let fromPos = Swift.max(0, oldN + 1 - maxConsume)
                var reused = cachedBuckets
                if reused.count < length + 1 {
                    reused.append(contentsOf: repeatElement(nil, count: length + 1 - reused.count))
                }
                for index in (oldN + 1)...length {
                    reused[index] = SentenceBucket()
                }
                expandRange(raw, &reused, from: fromPos, length: length,
                           minimumConsumedEnd: oldN,
                           allowDuplicateSingle: allowDuplicate)
                buckets = reused
                usedIncremental = true
            } else if length < oldN, Array(oldRaw.prefix(length)) == raw {
                buckets = Array(cachedBuckets.prefix(length + 1))
                usedIncremental = true
            }
        }

        if buckets == nil {
            buckets = buildFreshBuckets(raw, allowDuplicateSingle: allowDuplicate,
                                        context: context)
        }

        var finalBuckets = buckets!
        let result = emit(raw, &finalBuckets, length: length,
                          includeEarlyCommit: includeEarlyCommit,
                          allowDuplicateSingle: allowDuplicate)

        cachedRaw = raw
        cachedBuckets = finalBuckets

        #if DEBUG
        // 增量一致性断言（虎整句 results_equal 思路）。增量复用出 bug 表现为
        // 长句偶尔跳字且极难复现。
        //
        // 性能闸门：decodeFull 是一次完整的冷解码（长编码下 20~80ms），
        // 原先每键必跑会把 Debug 按键延迟垫到 75~95ms/键。改为：
        //   1) 只在真正走了增量路径的解码上校验（fresh 构建本身就是全量，无对比意义）；
        //   2) 增量校验每 debugVerifyEvery 次抽检一次；
        //   3) 退格（length 变短）后必验一次——截尾缓存复用是最易错的分支；
        //   4) 校验不匹配时立刻断言，行为与原逻辑一致。
        Self.incrementalDecodeCount += 1
        let backspaced = length < oldN && oldN > 0
        let mustVerify = backspaced
            || (usedIncremental && Self.incrementalDecodeCount % Self.debugVerifyEvery == 0)
        if usedIncremental && mustVerify && length > 4 {
            let full = decodeFull(raw, includeEarlyCommit: includeEarlyCommit,
                                  allowDuplicateSingle: allowDuplicate, context: context)
            let incremental = result.candidates.map {
                "\($0.text)|\($0.segmented)|\($0.score)|\($0.confidenceScore)"
            }
            let complete = full.candidates.map {
                "\($0.text)|\($0.segmented)|\($0.score)|\($0.confidenceScore)"
            }
            assert(incremental == complete, "incremental decode mismatch raw=\(rawCode)")
        }
        #endif

        return result
    }

    private func buildFreshBuckets(_ raw: [UInt8], allowDuplicateSingle: Bool,
                                   context: String) -> [SentenceBucket?] {
        let length = raw.count
        var fresh: [SentenceBucket?] = Array(repeating: nil, count: length + 1)
        // 左上下文 seed：prev2/prev1 = 留存文本末尾两字（不足补 BOS），
        // supplement 匹配状态沿留存文本推进——跨上屏边界的新词也能接住。
        // 留存文字不产出候选、不计分，只做语言模型历史。
        var prev2 = NgramModel.bos
        var prev1 = NgramModel.bos
        var supState = 0
        if supplement.hasEntries {
            for ch in context {
                supState = supplement.advance(state: supState, ch).state
            }
        }
        for scalar in context.unicodeScalars.suffix(2) {
            prev2 = prev1
            prev1 = scalar.value
        }
        let root = SentenceBucket()
        root.append(SentenceState(score: 0, massScore: 0, text: "",
                                  prev2: prev2, prev1: prev1,
                                  maxRank: 1, previous: nil, rawLength: 0, edgeCount: 0,
                                  supplementState: supState))
        fresh[0] = root
        for index in 1...length {
            fresh[index] = SentenceBucket()
        }
        expandRange(raw, &fresh, from: 0, length: length,
                    allowDuplicateSingle: allowDuplicateSingle)
        return fresh
    }

    /// 全量解码（DEBUG 一致性校验用）
    fileprivate func decodeFull(_ raw: [UInt8], includeEarlyCommit: Bool,
                               allowDuplicateSingle: Bool,
                               context: String) -> SentenceDecodeResult {
        var fresh = buildFreshBuckets(raw, allowDuplicateSingle: allowDuplicateSingle,
                                       context: context)
        return emit(raw, &fresh, length: raw.count, includeEarlyCommit: includeEarlyCommit,
                    allowDuplicateSingle: allowDuplicateSingle)
    }
}

extension OSLog {
    static let sentence = OSLog(subsystem: "com.qwertyyb.fire", category: "sentence")
}
