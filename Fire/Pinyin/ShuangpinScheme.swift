//
//  ShuangpinScheme.swift
//  Fire
//
//  双拼解码：两键一音节，第一键声母、第二键韵母，零声母另有约定。
//  参考实现 `ref-core/src/shuangpin/{scheme,decoded,unit}.rs` 的端口。
//
//  解码只做一件事：把敲的键翻成全拼（音节之间用 `'` 连上，切分因此没有歧义），
//  之后的切分、查词、整句、联想全部复用全拼的那一套；壳与词库都不知道双拼的存在。
//  上屏消耗按「音节对应几个键」换算回缓冲区（见 `keys(forPinyinLength:)`）。
//

import Foundation

/// 解码出的一个单元：一两个键对应的全拼。
struct ShuangpinUnit: Hashable {
    /// 敲的键（1 或 2 个字符；用户自己敲的 `'` 单独一个单元）。
    var keys: String

    /// 翻出来的全拼：两键是完整音节，落单的一键是声母（`v` → `zh`）或元音（`a`），`'` 为空。
    var pinyin: String

    /// 是否是完整音节（两键）。
    var complete: Bool

    static func separator() -> ShuangpinUnit {
        ShuangpinUnit(keys: "'", pinyin: "", complete: false)
    }

    var isSeparator: Bool { pinyin.isEmpty }
}

/// 一段双拼键解码的结果：能解的单元 + 解不动的尾巴。
struct ShuangpinDecoded: Hashable {
    /// 解出来的单元，按敲键顺序。
    var units: [ShuangpinUnit] = []

    /// 从第一个配不出音节的位置起的原始键，原样显示、不参与候选。
    var tail: String = ""

    /// 单元的全拼用 `'` 连成的串（分隔符单元不占位置），直接喂给全拼切分。
    var pinyin: String = ""

    init(units: [ShuangpinUnit] = [], tail: String = "") {
        var joined = ""
        for unit in units where !unit.isSeparator {
            if !joined.isEmpty { joined += "'" }
            joined += unit.pinyin
        }
        self.units = units
        self.tail = tail
        self.pinyin = joined
    }

    /// 全部键都解成了完整音节：没有尾巴、末尾没有落单的键。
    var isComplete: Bool {
        tail.isEmpty && units.allSatisfy { $0.complete || $0.isSeparator }
    }

    /// 末尾是不是一个落单的声母键：这时敲 `;`（微软 / 搜狗的 ing）应该进缓冲区而不是当标点。
    var pendingInitial: Bool {
        tail.isEmpty && units.last.map { !$0.complete && !$0.isSeparator } ?? false
    }

    /// 解出来的唯一切分：双拼两键一音节没有歧义，不必再走全拼切分（那会把 `zhong`
    /// 再拆出 `z… hong` 一类简拼切法）。落单的键是残缺音节。一个单元都没解出时为 nil。
    var segmentation: PinyinSegmentation? {
        let syllables = units.filter { !$0.isSeparator }.map { unit in
            unit.complete ? PinyinSyllable.full(unit.pinyin) : PinyinSyllable.partial(unit.pinyin)
        }
        guard !syllables.isEmpty else { return nil }
        return PinyinSegmentation(syllables: syllables)
    }

    /// 显示形式：全拼加上尾巴（`ni'bl`）。
    var marked: String {
        if pinyin.isEmpty { return tail }
        return tail.isEmpty ? pinyin : "\(pinyin)'\(tail)"
    }

    /// [`pinyin`] 开头 `pinyinLen` 个字母对应多少个键：整单元被盖住才算，
    /// 紧跟其后的 `'` 一并算上。
    func keys(forPinyinLength pinyinLen: Int) -> Int {
        var keys = 0
        var position = 0
        var first = true
        var pendingSeparators = 0
        for unit in units {
            if unit.isSeparator {
                pendingSeparators += unit.keys.count
                continue
            }
            let start = first ? 0 : position + 1
            let end = start + unit.pinyin.count
            if pinyinLen < end { break }
            keys += pendingSeparators + unit.keys.count
            pendingSeparators = 0
            position = end
            first = false
        }
        // 消耗到末尾时，后面紧跟的 `'` 也一起吃掉
        if keys > 0 { keys += pendingSeparators }
        return keys
    }
}

/// 一套双拼方案 = 一张键位表 + 拼写规则。内置方案与自定义方案同类。
struct ShuangpinScheme: Hashable {
    var table: ShuangpinKeyTable

    init(table: ShuangpinKeyTable) { self.table = table }

    /// 这套方案是否用到 `;` 键。
    var usesSemicolon: Bool { table.semicolon }

    /// `c` 是不是这套方案的键：小写字母，微软 / 搜狗再加 `;`。
    func isKey(_ character: Character) -> Bool {
        character.isLowercase && character.isASCII
            || (character == ";" && usesSemicolon)
    }

    /// 键 `key` 当声母时是什么：翘舌声母按方案映射，其他辅音（含 y w）是自己，
    /// 元音键与 `;` 不是声母。
    func initial(_ key: String) -> String? {
        if let mapped = table.mappedInitial(for: key) { return mapped }
        return PinyinSyllables.initials.first { $0.count == 1 && $0.hasPrefix(key) }
    }

    /// 键 `key` 当韵母时的候选韵母（按优先级）。
    func finals(_ key: String) -> [String] {
        table.finals(for: key)
    }

    /// 两个键拼成的音节；拼不出合法音节时为 nil。
    func syllable(_ first: String, _ second: String) -> String? {
        let pair = first + second
        for zero in table.zeroInitials where zero.spellings.contains(pair) {
            return zero.syllable
        }
        guard let initial = initial(first) else { return nil }
        for final in finals(second) {
            let candidate = initial + final
            if PinyinSyllables.isSyllable(candidate) { return candidate }
        }
        return nil
    }

    /// 一个全拼音节的主写法（两个键）。拆成声母 + 韵母后查表，零声母查零声母表。
    func encode(_ syllable: String) -> (first: String, second: String)? {
        if let zero = table.zeroInitials.first(where: { $0.syllable == syllable }),
           let spelling = zero.spellings.first, spelling.count == 2 {
            let chars = Array(spelling)
            return (String(chars[0]), String(chars[1]))
        }
        guard let initial = PinyinSyllables.initials
            .filter({ syllable.hasPrefix($0) })
            .max(by: { $0.count < $1.count }) else { return nil }
        let final = String(syllable.dropFirst(initial.count))
        let first = table.initials.first { $0.initial == initial }?.key ?? String(initial.first!)
        guard let second = table.finals.first(where: { $0.finals.contains(final) })?.key else {
            return nil
        }
        return (first, second)
    }

    /// 把敲的键翻成全拼。两键一组从左到右配对；配不出合法音节的位置起全部原样留作尾巴；
    /// 末尾落单的一键当声母（或元音）前缀；用户自己敲的 `'` 结束当前配对。
    func decode(_ keys: String) -> ShuangpinDecoded {
        let chars = Array(keys).map(String.init)
        var units: [ShuangpinUnit] = []
        var index = 0
        while index < chars.count {
            let first = chars[index]
            if first == "'" {
                units.append(.separator())
                index += 1
                continue
            }
            let second = index + 1 < chars.count && chars[index + 1] != "'" ? chars[index + 1] : nil
            let unit: ShuangpinUnit?
            if let second {
                unit = syllable(first, second).map {
                    ShuangpinUnit(keys: first + second, pinyin: $0, complete: true)
                }
            } else {
                unit = partial(first).map {
                    ShuangpinUnit(keys: first, pinyin: $0, complete: false)
                }
            }
            guard let unit else { break }
            index += unit.keys.count
            units.append(unit)
        }
        return ShuangpinDecoded(units: units, tail: chars[index...].joined())
    }

    /// 落单的一键代表的前缀：声母键是声母，元音键是元音本身（`a` 后面可能是 ai / an / ang / ao）。
    func partial(_ key: String) -> String? {
        if let initial = initial(key) { return initial }
        if let override = table.partialOverrides?[key] { return override }
        return ["a", "e", "o"].contains(key) ? key : nil
    }
}
