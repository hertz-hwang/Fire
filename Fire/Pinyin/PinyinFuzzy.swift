//
//  PinyinFuzzy.swift
//  Fire
//
//  模糊音：把一个音节的查询条件扩成同一位置的多种写法。
//  参考实现 `ref-core/src/fuzzy/{rules,expanded}.rs` 的端口，规则集合、叠加方式、
//  代价（ln 2 = 词频减半）与「前缀写法互不覆盖」的处理逐条对齐。
//

import Foundation

/// 一个音节的查询条件：完整音节要求相等，否则只要求前缀（简拼、未打完的音节）。
struct PinyinSyllablePattern: Hashable {
    /// 用户敲的字母（已按 ü 写法归一）。
    var text: String

    /// 为真时要求音节与 `text` 完全相等，否则只要求以 `text` 开头。
    var complete: Bool

    static func full(_ text: String) -> PinyinSyllablePattern {
        PinyinSyllablePattern(text: PinyinSyllables.canonical(text), complete: true)
    }

    static func prefix(_ text: String) -> PinyinSyllablePattern {
        PinyinSyllablePattern(text: PinyinSyllables.canonical(text), complete: false)
    }

    /// 词库里的音节 `syllable` 是否满足这个条件。
    func accepts(_ syllable: String) -> Bool {
        let mine = PinyinSyllables.canonical(text)
        let other = PinyinSyllables.canonical(syllable)
        return complete ? other == mine : other.hasPrefix(mine)
    }
}

/// 模糊音规则（9 条，缺省全关）。与设置面板一一对应。
struct PinyinFuzzyRules: Hashable, Codable {
    /// z ↔ zh
    var zZh = false
    /// c ↔ ch
    var cCh = false
    /// s ↔ sh
    var sSh = false
    /// n ↔ l
    var nL = false
    /// f ↔ h
    var fH = false
    /// l ↔ r
    var lR = false
    /// an ↔ ang（含 ian / iang、uan / uang）
    var anAng = false
    /// en ↔ eng
    var enEng = false
    /// in ↔ ing
    var inIng = false

    /// 模糊音命中的扣分（词频减半），与词级排序、整句词图共用同一口径。
    static let penalty = log(2.0)

    static let none = PinyinFuzzyRules()

    static let all: PinyinFuzzyRules = {
        var rules = PinyinFuzzyRules()
        rules.zZh = true; rules.cCh = true; rules.sSh = true
        rules.nL = true; rules.fH = true; rules.lR = true
        rules.anAng = true; rules.enEng = true; rules.inIng = true
        return rules
    }()

    var any: Bool { self != PinyinFuzzyRules.none }

    /// 全部规则名（设置面板顺序）。
    static let names: [String] = ["z_zh", "c_ch", "s_sh", "n_l", "f_h", "l_r",
                                 "an_ang", "en_eng", "in_ing"]

    var enabledCount: Int {
        [zZh, cCh, sSh, nL, fH, lR, anAng, enEng, inIng].filter { $0 }.count
    }

    /// 一个音节的全部写法，第一个是敲的原文；没开模糊音就只有它自己。
    /// 规则之间可以叠加（zhen → zeng），跑到不再增长为止。
    func alternatives(_ pattern: PinyinSyllablePattern) -> [String] {
        var forms = [pattern.text]
        guard any else { return forms }
        // 规则集很小，两轮就收敛
        var index = 0
        while index < forms.count {
            let current = forms[index]
            for candidate in applyOnce(current, complete: pattern.complete) where !forms.contains(candidate) {
                forms.append(candidate)
            }
            index += 1
        }
        if !pattern.complete {
            // 前缀之间去覆盖：被别的更短前缀包含的去掉
            let snapshot = forms
            forms = forms.filter { form in
                !snapshot.contains { other in other != form && form.hasPrefix(other) }
            }
            // 原文若被去掉了，把覆盖它的那个放到第一位，保证第一种写法仍能匹配原文能匹配的
            if forms.first != pattern.text,
               let position = forms.firstIndex(where: { pattern.text.hasPrefix($0) }) {
                forms.swapAt(0, position)
            }
        }
        return forms
    }

    /// `syllable` 是不是 `typed` 按当前规则的一种模糊写法（不含它自己）。
    func isVariant(typed: String, syllable: String) -> Bool {
        guard PinyinSyllables.canonical(typed) != PinyinSyllables.canonical(syllable) else { return false }
        return alternatives(PinyinSyllablePattern.full(typed))
            .contains { PinyinSyllables.canonical($0) == PinyinSyllables.canonical(syllable) }
    }

    /// 把一串模式扩展成每个位置的多种写法（第一种是用户敲的，代价 0；模糊音写法扣 [`penalty`]）。
    func expand(_ patterns: [PinyinSyllablePattern]) -> PinyinExpanded {
        PinyinExpanded(positions: patterns.map { pattern in
            let forms = alternatives(pattern)
                .enumerated()
                .map { (text: $0.element, cost: $0.offset == 0 ? 0.0 : PinyinFuzzyRules.penalty) }
            return PinyinExpanded.Position(forms: forms, complete: pattern.complete)
        })
    }

    /// 对一种写法各套一次规则得到的新写法（不合法的在这里过滤掉）。
    private func applyOnce(_ form: String, complete: Bool) -> [String] {
        var out: [String] = []
        func swapInitial(_ a: String, _ b: String) {
            if form.hasPrefix(a) {
                out.append(b + form.dropFirst(a.count))
            } else if form.hasPrefix(b) {
                out.append(a + form.dropFirst(b.count))
            }
        }
        // 先比双字母声母，`sh` 不能被当成 `s` 处理
        if zZh { swapInitial("zh", "z") }
        if cCh { swapInitial("ch", "c") }
        if sSh { swapInitial("sh", "s") }
        if nL { swapInitial("n", "l") }
        if fH { swapInitial("f", "h") }
        if lR { swapInitial("l", "r") }
        if complete {
            func swapFinal(_ a: String, _ b: String) {
                if form.hasSuffix(a) {
                    out.append(String(form.dropLast(a.count)) + b)
                } else if form.hasSuffix(b) {
                    out.append(String(form.dropLast(b.count)) + a)
                }
            }
            // 先比长的：`ang` 结尾的不能再被当成 `an`
            if anAng { swapFinal("ang", "an") }
            if enEng { swapFinal("eng", "en") }
            if inIng { swapFinal("ing", "in") }
        }
        return out.filter { form2 in
            !form2.isEmpty && form2 != form
                && (complete
                    ? PinyinSyllables.isSyllable(form2)
                    : PinyinSyllables.isSyllable(form2) || PinyinSyllables.isSyllablePrefix(form2))
        }
    }
}

/// 一串模式扩展后的结果：每个位置若干写法，第一种是用户敲的（代价 0），
/// 其余是模糊音（扣 ln 2）或敲错变体（按类别与个人敲错表定代价）。
struct PinyinExpanded {
    /// 某个位置的写法与「是否完整音节」（同一位置的写法完整性相同）。
    struct Position {
        var forms: [(text: String, cost: Double)]
        var complete: Bool
    }

    private(set) var positions: [Position]

    /// 有没有任何一个位置带了敲的原样以外的写法：没有就不必逐条命中算代价。
    private(set) var hasAlternatives: Bool

    init(positions: [Position]) {
        self.positions = positions
        self.hasAlternatives = positions.contains { $0.forms.count > 1 }
    }

    var count: Int { positions.count }

    /// 给 `index` 位置加一种写法；已有同样写法时只留代价低的那个。不完整的位置（简拼、前缀）不加。
    mutating func pushAlternative(_ index: Int, text: String, cost: Double) {
        guard index < positions.count, positions[index].complete else { return }
        if let slot = positions[index].forms.firstIndex(where: { $0.text == text }) {
            positions[index].forms[slot].cost = min(positions[index].forms[slot].cost, cost)
        } else {
            positions[index].forms.append((text, cost))
        }
        hasAlternatives = true
    }

    /// 每个位置的查询条件。
    var patterns: [[PinyinSyllablePattern]] {
        positions.map { position in
            position.forms.map { PinyinSyllablePattern(text: $0.text, complete: position.complete) }
        }
    }

    /// `index` 位置命中音节 `syllable` 的代价：敲的原样 0，模糊音 / 敲错变体按写法记的代价；
    /// 哪种写法都对不上（不该发生）算 0。
    func cost(_ index: Int, _ syllable: String) -> Double {
        guard index < positions.count else { return 0 }
        let position = positions[index]
        for form in position.forms
        where PinyinSyllablePattern(text: form.text, complete: position.complete).accepts(syllable) {
            return form.cost
        }
        return 0
    }

    /// 一条命中的总代价：各位置代价之和。没有任何替代写法时直接 0。
    func penalty(_ syllables: [String]) -> Double {
        guard hasAlternatives else { return 0 }
        var total = 0.0
        for (index, syllable) in syllables.enumerated() { total += cost(index, syllable) }
        return total
    }
}

extension PinyinSegmentation {
    /// 切分 → 每个音节的查询条件（ü 写法已归一）。
    var patterns: [PinyinSyllablePattern] {
        syllables.map { PinyinSyllablePattern(text: PinyinSyllables.canonical($0.text),
                                              complete: $0.complete) }
    }
}
