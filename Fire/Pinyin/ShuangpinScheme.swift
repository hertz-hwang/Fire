//
//  ShuangpinScheme.swift
//  Fire
//
//  双拼解码：两键一音节，第一键声母、第二键韵母，零声母另有约定。
//  键位表是运行时值（见 `ShuangpinKeyTable`），本文件只按表把键翻成拼音。
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

    /// 消耗开头 `letters` 个**拼音字母**（不含 `'`）需要敲多少个键。
    ///
    /// 词级候选的 `coverage` 数的是字母（不同切分之间才可比），而组字区按键结算，
    /// 中间还夹着 `'`：直接拿字母数当字节偏移，`ni\'hao` 会算成 2 个键而不是 4 个，
    /// 上屏「你好」后组字区剩一堆键。所以这里逐单元累加字母数，而不是比字节下标。
    func keys(forPinyinLetters letters: Int) -> Int {
        var keys = 0
        var seen = 0
        var pendingSeparators = 0
        for unit in units {
            if unit.isSeparator {
                pendingSeparators += unit.keys.count
                continue
            }
            guard seen + unit.pinyin.count <= letters else { break }
            seen += unit.pinyin.count
            keys += pendingSeparators + unit.keys.count
            pendingSeparators = 0
        }
        // 字母正好消耗到末尾时，后面紧跟的 `'` 也一起吃掉
        if seen == letters { keys += pendingSeparators }
        return keys
    }

    /// [`pinyin`] 开头 `pinyinLen` 个字母（按连接串的字节位算）对应多少个键：整单元被盖住才算，
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

    /// 键 `key` 当声母时是什么：显式映射优先（含墓碑——`""` 表示这键被拖走/禁用，
    /// 不再当声母），没映射的辅音（含 y w）是字母自己，元音键与 `;` 不是声母。
    func initial(_ key: String) -> String? {
        if let mapped = table.mappedInitial(for: key) { return mapped.isEmpty ? nil : mapped }
        return PinyinSyllables.initials.first { $0.count == 1 && $0.hasPrefix(key) }
    }

    /// 当前由哪个键表示这个声母：显式绑定优先，否则是字母本身（该键没被拖走/禁用时）。
    /// nil = 没有任何键表示它（被搬走又被解绑），以它为声母的音节打不出来。
    func key(forInitial initial: String) -> String? {
        if let mapped = table.initials.first(where: { $0.initial == initial })?.key { return mapped }
        return initial.count == 1 && self.initial(initial) == initial ? initial : nil
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
        guard let first = key(forInitial: initial) else { return nil }
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

    /// 按当前键位重算零声母两键写法，与既有写法**合并**（不丢 o 前缀式的方案）。
    ///
    /// 自定义方案最容易漏的就是这一栏：漏了之后 `a` / `ai` / `ang` 全打不出来。规则是
    /// 从五套内置表反推出来的两条：
    /// * 原样两字母（`ai` 就敲 `ai`）——单字母音节双写（`a` → `aa`）；
    /// * 首字母 + 该韵母所在的键（`ang` → `a` + 绑着 `ang` 的 `h` = `ah`）。
    /// 拿小鹤 / 自然码的韵母键位跑一遍，推出的写法与内置表里手写的逐条一致。
    func derivingZeroInitials() -> [ShuangpinZeroSyllable] {
        var result = table.zeroInitials
        for syllable in PinyinSyllables.zeroInitialSyllables {
            var derived: [String] = []
            if syllable.count == 1 {
                // 单元音音节双写（`a` → `aa`）
                derived.append(syllable + syllable)
            } else if syllable.count == 2 {
                // 两个字母的零声母音节可以原样敲（`ai` 就敲 `ai`）
                derived.append(syllable)
            }
            // 韵母可能是整个音节（`ai` 绑在 d）也可能是尾段（`i` 绑在 i），两种都试；
            // `ang` / `eng` 这三个字母的音节只能走这条（`a` + 绑着 `ang` 的 `h` = `ah`）
            for final in [String(syllable.dropFirst()), syllable] {
                for entry in table.finals where entry.finals.contains(final) {
                    derived.append(String(syllable.first!) + entry.key)
                }
            }
            let existing = result.first { $0.syllable == syllable }?.spellings ?? []
            var merged = existing
            for spelling in derived where !merged.contains(spelling) { merged.append(spelling) }
            guard !merged.isEmpty else { continue }
            if let index = result.firstIndex(where: { $0.syllable == syllable }) {
                result[index].spellings = merged
            } else {
                result.append(ShuangpinZeroSyllable(syllable: syllable, spellings: merged))
            }
        }
        return result
    }

    /// 落单的一键代表的前缀：声母键是声母，元音键是元音本身（`a` 后面可能是 ai / an / ang / ao）。
    func partial(_ key: String) -> String? {
        if let initial = initial(key) { return initial }
        if let override = table.partialOverrides?[key] { return override }
        return ["a", "e", "o"].contains(key) ? key : nil
    }
}
