//
//  PinyinComposing.swift
//  Fire
//
//  引擎输出 → 组字区/候选栏要用的一帧：每条候选带「吃掉几个键」，外加组字区显示串。
//
//  为什么要有这一层：引擎按**拼音字母**记账（`coverage` = 这条候选覆盖了几个字母），
//  而控制器要按**敲的键**结算组字区。全拼下两者相同，双拼下一音节两键、
//  简拼下一音节一键，必须换算——换算错一位就会「上屏 A、组字区少删一个键」。
//  双拼的换算表就是解码结果本身（`ShuangpinDecoded.keys(forPinyinLength:)`：
//  整单元被盖住才算，紧跟其后的 `'` 一并算上）。
//

import Foundation

/// 一条可直接给候选栏用的拼音候选。
struct PinyinComposingCandidate {
    /// 文字。
    var text: String

    /// 编码回显（分段拼音，`kai'fa`；双拼下仍是全拼读法，用户看的是读音不是键位）。
    var code: String

    /// 上屏时消耗几个**敲的键**（不是字母）。
    var consumedKeys: Int

    /// 是否整句候选（多词拼成、覆盖全部已敲字母）。
    var isSentence: Bool

    /// 排序分（调试与「显示打分」用）。
    var score: Double

    /// 靠模糊音 / 敲错读出来的（候选栏可以标个记号，让用户知道这不是自己敲的原话）。
    var altered: Bool
}

/// 一帧组字状态。
struct PinyinComposing {
    var candidates: [PinyinComposingCandidate]
    /// 组字区显示（分段拼音，带 `'`；切不动的尾巴原样跟在后面）
    var marked: String
    /// 切不动的尾巴（原始键）
    var tail: String
    /// 生效的拼写纠正（用来在组字区划删除线）
    var correction: PinyinCorrection?
    /// 双拼解码结果（全拼为 nil）
    var decoded: ShuangpinDecoded?
}

extension PinyinEngine {
    /// 控制器入口：敲的键 → 一帧候选。
    func compose(_ keys: String, leftContext: String = "") -> PinyinComposing? {
        guard let query = query(keys, leftContext: leftContext) else { return nil }
        // 拼音字母数 → 敲的键数
        let lettersToKeys: (Int) -> Int
        if let decoded = query.decoded {
            lettersToKeys = { decoded.keys(forPinyinLetters: $0) }
        } else {
            // 全拼：候选覆盖的是去掉 `'` 的字母，键也一样（`'` 是用户自己敲的分隔符，
            // 它也占一个键位，得跟着一起吃掉，否则上屏一个词后组字区留个孤立撇号）
            let raw = Array(keys)
            lettersToKeys = { count in
                var seen = 0
                var index = 0
                while index < raw.count, seen < count {
                    if raw[index] != "'" { seen += 1 }
                    index += 1
                }
                // 紧接其后的分隔符一并吃掉
                while index < raw.count, raw[index] == "'" { index += 1 }
                return index
            }
        }
        var items: [PinyinComposingCandidate] = []
        items.reserveCapacity(query.candidates.count)
        for candidate in query.candidates {
            let consumed = max(1, lettersToKeys(candidate.coverage))
            items.append(PinyinComposingCandidate(text: candidate.text,
                                                  code: candidate.segmented,
                                                  consumedKeys: consumed,
                                                  isSentence: candidate.isSentence,
                                                  score: candidate.score,
                                                  altered: candidate.altered))
        }
        return PinyinComposing(candidates: items, marked: query.marked, tail: query.tail,
                               correction: query.correction, decoded: query.decoded)
    }
}

extension PinyinEngine {
    /// 作废所有缓存（换码表 / 换模型 / 学习数据换代）。
    func clearCaches() {
        decoder.clearCache()
    }

    /// 词表换代后按需作废（每次查询开头问一次，代次没变是两次整数比较的量级）
    func invalidateCachesIfNeeded() {
        decoder.invalidateLexiconGenerationIfNeeded()
    }
}
