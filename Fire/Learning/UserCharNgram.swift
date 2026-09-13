//
//  UserCharNgram.swift
//  Fire
//
//  通道 B：持久化字符级用户 n-gram（bigram + trigram，全局日历衰减）。
//  与通用模型的关系是概率空间插值：
//
//      p_user(c|ctx) = 三元(绝对折扣 D3 向二元回退) → 二元(D2 向一元回退)
//                      → 一元(K 向通用一元回退)
//      α = min(αmax·强度, c(prev1) / (c(prev1) + K))
//      log p' = ln((1−α)·e^{base} + α·p_user)
//
//  该上下文从未见过时 α = 0，精确等于 base（快路径不付 exp/log）；
//  α 封顶保证用户数据永远压不死通用模型。
//
//  衰减模型：全局日历衰减——计数不带各自的触碰日，store 记录最后衰减日；
//  跨天后的首次触碰先把全表按 0.5^(Δ天/半衰期) 统一衰减，再累加新计数。
//  落库只 upsert 脏键 + delete 清扫键，无逐条目元数据。
//

import Foundation

// MARK: - 衰减与天数

/// 天序号（UTC 日界即可：只用于衰减量级）
@inline(__always)
func learningDayNumber(_ date: Date = Date()) -> Int {
    Int(date.timeIntervalSince1970) / 86_400
}

// MARK: - 可变存储（LearnerCenter 串行队列独占）

final class UserCharNgramStore {
    private(set) var unigrams: [UInt32: Double] = [:]
    /// pack2(prev1, target) → 计数
    private(set) var bigrams: [UInt64: Double] = [:]
    /// prev1 → 上下文总次数（条件概率分母）
    private(set) var bigramTotals: [UInt32: Double] = [:]
    /// pack3(prev2, prev1, target) → 计数
    private(set) var trigrams: [UInt64: Double] = [:]
    /// pack2(prev2, prev1) → 上下文总次数
    private(set) var trigramTotals: [UInt64: Double] = [:]
    /// 一元总质量（回退平滑分母）
    private(set) var unigramTotal: Double = 0

    /// 全局衰减簿记：最后衰减到的天
    private(set) var lastDecayDay: Int
    private let halfLifeDays: Double

    // 落库簿记（LearningStore 消费后清空）
    var dirtyUnigrams = Set<UInt32>()
    var dirtyBigrams = Set<UInt64>()
    var dirtyBigramTotals = Set<UInt32>()
    var dirtyTrigrams = Set<UInt64>()
    var dirtyTrigramTotals = Set<UInt64>()
    var unigramTotalDirty = false

    init(halfLifeDays: Double = 30.0) {
        self.halfLifeDays = halfLifeDays
        self.lastDecayDay = learningDayNumber()
    }

    /// 启动导入：LearningStore 从库里读回的计数整体装入
    ///（落库前已应用衰减；跨启动的天差由 lastDecayDay 接续处理）
    func importCounts(unigrams: [UInt32: Double],
                      bigrams: [UInt64: Double],
                      bigramTotals: [UInt32: Double],
                      trigrams: [UInt64: Double],
                      trigramTotals: [UInt64: Double],
                      unigramTotal: Double,
                      lastDecayDay: Int) {
        self.unigrams = unigrams
        self.bigrams = bigrams
        self.bigramTotals = bigramTotals
        self.trigrams = trigrams
        self.trigramTotals = trigramTotals
        self.unigramTotal = unigramTotal
        self.lastDecayDay = lastDecayDay
    }

    var isEmpty: Bool {
        unigrams.isEmpty && bigrams.isEmpty && trigrams.isEmpty
    }

    var entryCount: Int {
        unigrams.count + bigrams.count + trigrams.count
    }

    // MARK: 跨天衰减

    /// 跨天后首次触碰：全表按 0.5^(Δ天/半衰期) 统一衰减（每天至多一次）
    private func applyDailyDecayIfNeeded(today: Int) {
        guard today > lastDecayDay else { return }
        let factor = Foundation.pow(0.5, Double(today - lastDecayDay) / halfLifeDays)
        if factor < 1.0 {
            for key in unigrams.keys { unigrams[key] = (unigrams[key] ?? 0) * factor }
            for key in bigrams.keys { bigrams[key] = (bigrams[key] ?? 0) * factor }
            for key in bigramTotals.keys { bigramTotals[key] = (bigramTotals[key] ?? 0) * factor }
            for key in trigrams.keys { trigrams[key] = (trigrams[key] ?? 0) * factor }
            for key in trigramTotals.keys { trigramTotals[key] = (trigramTotals[key] ?? 0) * factor }
            unigramTotal *= factor
            // 全表数值变了，落库侧按全量重写处理
            markAllDirty()
        }
        lastDecayDay = today
    }

    private func markAllDirty() {
        dirtyUnigrams.formUnion(unigrams.keys)
        dirtyBigrams.formUnion(bigrams.keys)
        dirtyBigramTotals.formUnion(bigramTotals.keys)
        dirtyTrigrams.formUnion(trigrams.keys)
        dirtyTrigramTotals.formUnion(trigramTotals.keys)
        unigramTotalDirty = true
    }

    /// 全量标记脏（导入替换后整体重写库用）
    func markAllDirtyForPersist() {
        markAllDirty()
    }

    // MARK: 记录 / 回退

    /// 记录一段上屏文本的转移链（句首补 BOS，与通用模型一致）
    func record(_ text: String, times: Double = 1) {
        guard times > 0, !text.isEmpty else { return }
        let today = learningDayNumber()
        applyDailyDecayIfNeeded(today: today)
        var prev2 = NgramModel.bos
        var prev1 = NgramModel.bos
        for scalar in text.unicodeScalars {
            let target = scalar.value
            addTo(&unigrams, key: target, delta: times, dirty: &dirtyUnigrams)
            unigramTotal += times
            unigramTotalDirty = true
            addTo(&bigrams, key: NgramModel.pack2(UInt64(prev1), UInt64(target)),
                  delta: times, dirty: &dirtyBigrams)
            addTo(&bigramTotals, key: prev1, delta: times, dirty: &dirtyBigramTotals)
            addTo(&trigrams, key: NgramModel.pack3(UInt64(prev2), UInt64(prev1), UInt64(target)),
                  delta: times, dirty: &dirtyTrigrams)
            addTo(&trigramTotals, key: NgramModel.pack2(UInt64(prev2), UInt64(prev1)),
                  delta: times, dirty: &dirtyTrigramTotals)
            prev2 = prev1
            prev1 = target
        }
    }

    /// 撤销回退：对每条转移 −1（缺失条目忽略，计数不为负）
    func unrecord(_ text: String) {
        guard !text.isEmpty else { return }
        let today = learningDayNumber()
        applyDailyDecayIfNeeded(today: today)
        var prev2 = NgramModel.bos
        var prev1 = NgramModel.bos
        for scalar in text.unicodeScalars {
            let target = scalar.value
            addTo(&unigrams, key: target, delta: -1, dirty: &dirtyUnigrams)
            unigramTotal = Swift.max(0, unigramTotal - 1)
            unigramTotalDirty = true
            addTo(&bigrams, key: NgramModel.pack2(UInt64(prev1), UInt64(target)),
                  delta: -1, dirty: &dirtyBigrams)
            addTo(&bigramTotals, key: prev1, delta: -1, dirty: &dirtyBigramTotals)
            addTo(&trigrams, key: NgramModel.pack3(UInt64(prev2), UInt64(prev1), UInt64(target)),
                  delta: -1, dirty: &dirtyTrigrams)
            addTo(&trigramTotals, key: NgramModel.pack2(UInt64(prev2), UInt64(prev1)),
                  delta: -1, dirty: &dirtyTrigramTotals)
            prev2 = prev1
            prev1 = target
        }
    }

    @inline(__always)
    private func addTo<T: Hashable>(_ table: inout [T: Double], key: T,
                                    delta: Double, dirty: inout Set<T>) {
        let next = (table[key] ?? 0) + delta
        dirty.insert(key)
        if next <= 0 {
            table.removeValue(forKey: key)
        } else {
            table[key] = next
        }
    }

    // MARK: 清扫

    /// 衰减后低于 minCount 的条目遗忘；总量超上限时从低到高淘汰约 10%。
    /// 返回是否发生变动（清扫删除的键同时进入落库删除簿记）。
    @discardableResult
    func sweep(tuning: LearningTuning) -> Bool {
        let today = learningDayNumber()
        applyDailyDecayIfNeeded(today: today)
        var changed = false

        func prune<T: Hashable>(_ table: inout [T: Double], dirty: inout Set<T>,
                                deletes: inout Set<String>) {
            for (key, count) in table where count < tuning.userNgramMinCount {
                table.removeValue(forKey: key)
                dirty.remove(key)
                deletes.insert("\(key)")
                changed = true
            }
        }
        var deletesUnigram = Set<String>()
        var deletesBigram = Set<String>()
        var deletesBigramTotal = Set<String>()
        var deletesTrigram = Set<String>()
        var deletesTrigramTotal = Set<String>()
        prune(&unigrams, dirty: &dirtyUnigrams, deletes: &deletesUnigram)
        prune(&bigrams, dirty: &dirtyBigrams, deletes: &deletesBigram)
        prune(&bigramTotals, dirty: &dirtyBigramTotals, deletes: &deletesBigramTotal)
        prune(&trigrams, dirty: &dirtyTrigrams, deletes: &deletesTrigram)
        prune(&trigramTotals, dirty: &dirtyTrigramTotals, deletes: &deletesTrigramTotal)

        let total = entryCount
        if total > tuning.userNgramMaxEntries {
            var ranked: [(tag: Character, key: UInt64, value: Double)] = []
            ranked.reserveCapacity(total)
            for (key, value) in unigrams { ranked.append(("u", UInt64(key), value)) }
            for (key, value) in bigrams { ranked.append(("b", key, value)) }
            for (key, value) in trigrams { ranked.append(("t", key, value)) }
            ranked.sort { $0.value < $1.value }
            let dropCount = total - tuning.userNgramMaxEntries + tuning.userNgramMaxEntries / 10
            var dropped = 0
            for item in ranked {
                if dropped >= dropCount { break }
                switch item.tag {
                case "u":
                    let key = UInt32(truncatingIfNeeded: item.key)
                    unigrams.removeValue(forKey: key)
                    dirtyUnigrams.remove(key)
                    deletesUnigram.insert("\(key)")
                case "b":
                    bigrams.removeValue(forKey: item.key)
                    dirtyBigrams.remove(item.key)
                    deletesBigram.insert("\(item.key)")
                case "t":
                    trigrams.removeValue(forKey: item.key)
                    dirtyTrigrams.remove(item.key)
                    deletesTrigram.insert("\(item.key)")
                default: break
                }
                dropped += 1
            }
            changed = changed || dropped > 0
        }
        pendingDeletes = NgramDeletes(
            unigrams: deletesUnigram, bigrams: deletesBigram,
            bigramTotals: deletesBigramTotal, trigrams: deletesTrigram,
            trigramTotals: deletesTrigramTotal)
        return changed
    }

    /// 清扫产生的删除批（LearningStore 落库后清空）
    struct NgramDeletes {
        var unigrams: Set<String> = []
        var bigrams: Set<String> = []
        var bigramTotals: Set<String> = []
        var trigrams: Set<String> = []
        var trigramTotals: Set<String> = []
        var isEmpty: Bool {
            unigrams.isEmpty && bigrams.isEmpty && bigramTotals.isEmpty
                && trigrams.isEmpty && trigramTotals.isEmpty
        }
    }
    var pendingDeletes = NgramDeletes()

    // MARK: 快照

    /// 生成解码端只读快照（跨天衰减已在触碰时应用；再兜底一次防呆）
    func snapshotData(tuning: LearningTuning) -> UserCharNgramData? {
        guard hasData else { return nil }
        let today = learningDayNumber()
        applyDailyDecayIfNeeded(today: today)
        return UserCharNgramData(
            unigrams: unigrams,
            bigrams: bigrams,
            bigramTotals: bigramTotals,
            trigrams: trigrams,
            trigramTotals: trigramTotals,
            unigramTotal: unigramTotal)
    }

    private var hasData: Bool { unigramTotal > 0 || !unigrams.isEmpty }
}

// MARK: - 只读快照与插值数学

struct UserCharNgramData {
    var unigrams: [UInt32: Double]
    var bigrams: [UInt64: Double]
    var bigramTotals: [UInt32: Double]
    var trigrams: [UInt64: Double]
    var trigramTotals: [UInt64: Double]
    var unigramTotal: Double

    var hasData: Bool { unigramTotal > 0 || !unigrams.isEmpty }

    /// 把通用模型的 base logp 与用户概率插值。
    /// 返回 nil 表示该上下文无用户数据（α = 0），解码端直接用 base（快路径）。
    func blendedLogp(base: Double, prev2: UInt32, prev1: UInt32, target: UInt32,
                     tuning: LearningTuning, generalUnigram: Double) -> Double? {
        guard hasData else { return nil }
        let t2 = bigramTotals[prev1] ?? 0
        guard t2 > 0 else { return nil }
        let alpha = Swift.min(tuning.userNgramAlphaMax * tuning.strength,
                              t2 / (t2 + tuning.userNgramContextK))
        guard alpha > 0 else { return nil }

        // p_user 链：三元(折扣) → 二元(折扣) → 一元(向通用回退)
        let cu = unigrams[target] ?? 0
        let pUniUser = (cu + tuning.userNgramUnigramK * generalUnigram)
            / (unigramTotal + tuning.userNgramUnigramK)
        let c2 = bigrams[NgramModel.pack2(UInt64(prev1), UInt64(target))] ?? 0
        let pBiUser = (c2 + tuning.userNgramBigramD * pUniUser) / (t2 + tuning.userNgramBigramD)
        let ctxKey = NgramModel.pack2(UInt64(prev2), UInt64(prev1))
        let t3 = trigramTotals[ctxKey] ?? 0
        let c3 = trigrams[NgramModel.pack3(UInt64(prev2), UInt64(prev1), UInt64(target))] ?? 0
        let pUser = (c3 + tuning.userNgramTrigramD * pBiUser) / (t3 + tuning.userNgramTrigramD)

        let mixed = (1.0 - alpha) * Foundation.exp(base) + alpha * pUser
        return Foundation.log(Swift.max(mixed, 1e-300))
    }
}
