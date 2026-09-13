//
//  CorrectionPairs.swift
//  Fire
//
//  通道 C1：胜负纠错对（判别式反馈的在线层）。
//
//  用户选了 rank ≥ 1 的候选（首选被"骗"了）时记录：
//    键 = (语境末 ≤2 字, 整句原码) → { 所选词 +1 胜, 被弃首选 +1 负 }
//  下次同语境同原码解码时（emit 阶段），对整句候选按边际计分：
//
//      bonus(text) = clamp( w·(wins − λ·losses) / (wins+losses+K), ±cap )
//
//  关键点：被弃首选是显式负证据——"上次骗过我的首选"被精准降权但永不封死；
//  胜负都会随时间全局衰减，过时的纠错自然淡出。
//
//  新鲜度：条目常驻内存（写入即时生效，emit 每次解码读取），持久化由
//  LearnerCenter 防抖批量落库（崩溃最多丢一个防抖窗口的纠错，可再学习）。
//

import Foundation

final class CorrectionStore {
    struct Entry {
        var wins: Double
        var losses: Double
    }

    /// ctx → code → word → 条目
    private(set) var entries: [String: [String: [String: Entry]]] = [:]

    /// 全局日历衰减：最后衰减到的天
    private(set) var lastDecayDay: Int
    private let halfLifeDays: Double

    // 落库簿记（LearningStore 消费后清空）
    var dirtyKeys = Set<String>()      // "ctx\u{1F}code\u{1F}word"
    var deletedKeys = Set<String>()

    init(halfLifeDays: Double = 30.0) {
        self.halfLifeDays = halfLifeDays
        self.lastDecayDay = learningDayNumber()
    }

    /// 启动导入：LearningStore 从库里读回的条目装入
    func importEntry(ctx: String, code: String, word: String, wins: Double, losses: Double) {
        entries[ctx, default: [:]][code, default: [:]][word] = Entry(wins: wins, losses: losses)
    }

    func importLastDecayDay(_ day: Int) {
        lastDecayDay = day
    }

    var isEmpty: Bool { entries.isEmpty }

    var entryCount: Int {
        entries.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
    }

    // MARK: 跨天衰减

    private func applyDailyDecayIfNeeded(today: Int) {
        guard today > lastDecayDay else { return }
        let factor = Foundation.pow(0.5, Double(today - lastDecayDay) / halfLifeDays)
        if factor < 1.0 {
            for (ctx, codes) in entries {
                for (code, words) in codes {
                    for (word, entry) in words {
                        entries[ctx]?[code]?[word] = Entry(
                            wins: entry.wins * factor, losses: entry.losses * factor)
                    }
                }
            }
            dirtyKeys.formUnion(allKeys())
        }
        lastDecayDay = today
    }

    private func allKeys() -> Set<String> {
        var keys = Set<String>()
        for (ctx, codes) in entries {
            for (code, words) in codes {
                for word in words.keys {
                    keys.insert("\(ctx)\u{1F}\(code)\u{1F}\(word)")
                }
            }
        }
        return keys
    }

    // MARK: 记录

    /// 一次纠错：chosenText 胜 +1，rejectedTopText 负 +1。
    /// code 为 normalize 后的整句原码；ctx 为语境末 ≤2 字（可为空）。
    func record(ctx: String, code: String, chosenText: String, rejectedTopText: String) {
        guard !code.isEmpty, chosenText != rejectedTopText else { return }
        let today = learningDayNumber()
        applyDailyDecayIfNeeded(today: today)
        bump(ctx: ctx, code: code, word: chosenText, winsDelta: 1, lossesDelta: 0)
        if !rejectedTopText.isEmpty {
            bump(ctx: ctx, code: code, word: rejectedTopText, winsDelta: 0, lossesDelta: 1)
        }
    }

    /// 撤销一条纠错（多级撤销时与记录一一对应）
    func unrecord(ctx: String, code: String, chosenText: String, rejectedTopText: String) {
        guard !code.isEmpty else { return }
        let today = learningDayNumber()
        applyDailyDecayIfNeeded(today: today)
        bump(ctx: ctx, code: code, word: chosenText, winsDelta: -1, lossesDelta: 0)
        if !rejectedTopText.isEmpty {
            bump(ctx: ctx, code: code, word: rejectedTopText, winsDelta: 0, lossesDelta: -1)
        }
    }

    private func bump(ctx: String, code: String, word: String,
                      winsDelta: Double, lossesDelta: Double) {
        let key = "\(ctx)\u{1F}\(code)\u{1F}\(word)"
        defer {
            dirtyKeys.insert(key)
            deletedKeys.remove(key)
        }
        guard var entry = entries[ctx]?[code]?[word] else {
            let wins = Swift.max(0, winsDelta)
            let losses = Swift.max(0, lossesDelta)
            if wins > 0 || losses > 0 {
                entries[ctx, default: [:]][code, default: [:]][word] = Entry(wins: wins, losses: losses)
            }
            return
        }
        entry.wins = Swift.max(0, entry.wins + winsDelta)
        entry.losses = Swift.max(0, entry.losses + lossesDelta)
        if entry.wins <= 0 && entry.losses <= 0 {
            entries[ctx]?[code]?.removeValue(forKey: word)
            if entries[ctx]?[code]?.isEmpty == true { entries[ctx]?.removeValue(forKey: code) }
            if entries[ctx]?.isEmpty == true { entries.removeValue(forKey: ctx) }
            dirtyKeys.remove(key)
            deletedKeys.insert(key)
        } else {
            entries[ctx, default: [:]][code, default: [:]][word] = entry
        }
    }

    /// 解码端查询：该 (ctx, code) 下的全部词条（每次解码最多一次，热路径）
    func entriesFor(ctx: String, code: String) -> [String: Entry]? {
        entries[ctx]?[code]
    }

    // MARK: 清扫

    /// 胜+负低于阈值的条目遗忘；总量超限时按总证据量从低到高淘汰约 10%
    @discardableResult
    func sweep(tuning: LearningTuning) -> Bool {
        let today = learningDayNumber()
        applyDailyDecayIfNeeded(today: today)
        let threshold = 0.3
        var changed = false
        for (ctx, codes) in entries {
            for (code, words) in codes {
                for (word, entry) in words where entry.wins + entry.losses < threshold {
                    entries[ctx]?[code]?.removeValue(forKey: word)
                    let key = "\(ctx)\u{1F}\(code)\u{1F}\(word)"
                    dirtyKeys.remove(key)
                    deletedKeys.insert(key)
                    changed = true
                }
                if entries[ctx]?[code]?.isEmpty == true {
                    entries[ctx]?.removeValue(forKey: code)
                }
            }
            if entries[ctx]?.isEmpty == true {
                entries.removeValue(forKey: ctx)
            }
        }
        let total = entryCount
        if total > tuning.correctionMaxEntries {
            var ranked: [(ctx: String, code: String, word: String, value: Double)] = []
            for (ctx, codes) in entries {
                for (code, words) in codes {
                    for (word, entry) in words {
                        ranked.append((ctx, code, word, entry.wins + entry.losses))
                    }
                }
            }
            ranked.sort { $0.value < $1.value }
            let dropCount = total - tuning.correctionMaxEntries + tuning.correctionMaxEntries / 10
            for item in ranked.prefix(dropCount) {
                entries[item.ctx]?[item.code]?.removeValue(forKey: item.word)
                let key = "\(item.ctx)\u{1F}\(item.code)\u{1F}\(item.word)"
                dirtyKeys.remove(key)
                deletedKeys.insert(key)
            }
            changed = true
        }
        return changed
    }

    /// 边际计分：该词条相对"被弃首选"的净证据强度
    static func bonus(wins: Double, losses: Double, tuning: LearningTuning) -> Double {
        let total = wins + losses
        guard total > 0 else { return 0 }
        let weight = tuning.correctionWeight * tuning.strength
        let raw = weight * (wins - tuning.correctionLossLambda * losses)
            / (total + tuning.correctionK)
        return Swift.max(-tuning.correctionCap, Swift.min(tuning.correctionCap, raw))
    }
}
