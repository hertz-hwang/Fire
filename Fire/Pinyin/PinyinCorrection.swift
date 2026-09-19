//
//  PinyinCorrection.swift
//  Fire
//
//  拼写纠错。参考实现 `ref-core/src/correction/*` 的端口，两条互补的路：
//
//  1. **整段一处编辑**（`PinyinCorrection.candidates`）：用户敲的拼音「不像话」时
//     （切不干净，或非末尾有简拼 / 残缺音节），试一处编辑（相邻换位、换一个字母、
//     多一个、少一个）能不能变成每个音节都完整的拼音。只产生候选纠正，挑哪一个由
//     `PinyinEngine` 用词库和语言模型定。
//  2. **音节级敲错变体**（`PinyinTypo.variants`）：每个完整音节一处编辑后仍合法的写法
//     进词图当带代价的边，代价按类别定（`PinyinTypoCosts`），用户接受过的可打折。
//

import Foundation

/// 一处编辑：把用户敲的串变成纠正后的串。下标是**纠正后**串里的位置（纯 ASCII 小写，字节即字符）。
enum PinyinEdit: Hashable {
    /// 原串这一位敲的是 `from`，纠正后换成了别的字母。
    case substitute(index: Int, from: Character)

    /// 原串在这一位多敲了 `removed`，纠正后没有它（`index` 是它在纠正后串里本该在的位置）。
    case delete(index: Int, removed: Character)

    /// 原串漏了一个字母，纠正后在 `index` 处多出一个。
    case insert(index: Int)

    /// 原串这一位与下一位敲反了（原来是 `first``second`，纠正后是 `second``first`）。
    case transpose(index: Int, first: Character, second: Character)

    /// 纠正后串开头 `correctedLen` 个字母对应原串开头多少个字母：候选按纠正后的音节消耗拼音，
    /// 消耗掉的原串长度要按这处编辑换算回去。
    func toOriginal(_ correctedLen: Int) -> Int {
        switch self {
        case .substitute, .transpose:
            return correctedLen
        // 多敲的字母紧贴在消耗掉的部分后面时一并吃掉，别把它留给下一段
        case .delete(let index, _) where index <= correctedLen:
            return correctedLen + 1
        case .delete:
            return correctedLen
        case .insert(let index) where index < correctedLen:
            return correctedLen - 1
        case .insert:
            return correctedLen
        }
    }

    /// 这处编辑是不是改在刚敲的最后一个键上：换掉最后一个字母、或在末尾补一个字母。
    /// 用户多半还没敲完，这种编辑凑出的完整拼音说明不了什么。
    func touchesLastLetter(_ correctedLen: Int) -> Bool {
        switch self {
        case .substitute(let index, _), .insert(let index):
            return index + 1 == correctedLen
        case .delete, .transpose:
            return false
        }
    }

    /// 要画删除线的原字母及其在纠正后串里的位置（画在这一位之前）；漏字没有可划的。
    func struck() -> (position: Int, text: String)? {
        switch self {
        case .substitute(let index, let from): return (index, String(from))
        case .delete(let index, let removed): return (index, String(removed))
        case .insert: return nil
        case .transpose(let index, let first, let second): return (index, "\(first)\(second)")
        }
    }

    var isTranspose: Bool {
        if case .transpose = self { return true }
        return false
    }
}

/// 一次拼写纠正：用户敲的串、纠正后的串、那一处编辑，以及纠正后串的完整音节切分。
struct PinyinCorrection {
    /// 用户敲的（作用域里的拼音，不含 `'`）。
    var original: String

    /// 纠正后的拼音。
    var corrected: String

    /// 从原串到纠正后串的那一处编辑。
    var edit: PinyinEdit

    /// 纠正后串的切分：每个音节都完整，或（相邻换位时）只有末尾一个还没敲完。
    var segmentation: PinyinSegmentation

    /// 这处编辑落在纠正后哪个音节里：返回 (敲的那段字母, 纠正后的音节)，给个人敲错表记；
    /// 多敲的字母算在它前面那个音节上。编辑处不在任何音节里 / 还没吃到编辑处时返回 nil。
    func typoPair(consumed: Int) -> (typed: String, intended: String)? {
        let at: Int
        switch edit {
        case .substitute(let index, _), .insert(let index), .transpose(let index, _, _):
            at = index
        case .delete(let index, _):
            at = max(0, index - 1)
        }
        guard at < consumed else { return nil }
        let originalChars = Array(original)
        var start = 0
        for syllable in segmentation.syllables {
            let end = start + syllable.text.count
            if at < end {
                // 编辑落在还没敲完的末尾音节里：还不知道用户要的是哪个音节，不记
                guard syllable.complete else { return nil }
                let typedStart = edit.toOriginal(start)
                let typedEnd = edit.toOriginal(end)
                guard typedStart < typedEnd, typedEnd <= originalChars.count else { return nil }
                let typed = String(originalChars[typedStart ..< typedEnd])
                guard !typed.isEmpty, typed != syllable.text else { return nil }
                return (typed, syllable.text)
            }
            start = end
        }
        return nil
    }

    /// 组字区的分段显示：纠正后的切分拼音（`'` 连接），被改掉的原字母插在它原来的位置。
    /// `nihooma` → `ni'h` + ~~o~~ + `ao'ma`。
    func markedSegments() -> [(text: String, corrected: Bool)] {
        let display = segmentation.joined("'")
        guard let (at, struck) = edit.struck() else { return [(display, false)] }
        // 纠正后串的字母下标 → 显示串（含 `'`）的下标
        let chars = Array(display)
        var split = chars.count
        var letters = 0
        var scanned = 0
        for ch in chars {
            if ch == "'" { scanned += 1; continue }
            if letters == at { split = scanned; break }
            letters += 1
            scanned += 1
        }
        var segments: [(text: String, corrected: Bool)] = []
        if split > 0 { segments.append((String(chars[0 ..< split]), false)) }
        segments.append((struck, true))
        if split < chars.count { segments.append((String(chars[split...]), false)) }
        return segments
    }
}

/// 一类敲错，决定它在词图里的代价。
enum PinyinTypoKind: Int, Hashable, CaseIterable {
    /// 相邻两键敲反了（`shou` → `shuo`）。
    case transpose
    /// 敲到了旁边的键（`ni` → `mi`）。不相邻的键不算敲错（那是读音问题，模糊音管）。
    case substitute
    /// 多敲了一个键（`gang` → `gan`）。
    case extra
    /// 少敲了一个键（`gan` → `guan`）。
    case missing
}

/// 敲错纠正的代价（log 概率的扣分）。缺省值照搬参考实现 `TypoCosts::DEFAULT`。
struct PinyinTypoCosts: Hashable {
    var transpose = 5.0
    var substitute = 5.0
    var extra = 5.5
    var missing = 5.5
    /// 个人敲错表最多给一条边减多少代价
    var discountCap = 3.0
    /// 整段一处编辑的纠错代价：纠正后的整句得分要比原样转出的高出这么多才纠
    var correctionPenalty = 5.0
    /// 整段纠错里相邻换位比别的编辑便宜多少
    var correctionTransposeDiscount = 1.0

    static let standard = PinyinTypoCosts()

    func cost(_ kind: PinyinTypoKind) -> Double {
        switch kind {
        case .transpose: return transpose
        case .substitute: return substitute
        case .extra: return extra
        case .missing: return missing
        }
    }

    /// 词图里一条敲错边的代价：类别的基础代价按个人敲错表打折。
    func typoCost(_ kind: PinyinTypoKind, accepted: Int) -> Double {
        discounted(cost(kind), accepted: accepted)
    }

    /// 整段一处编辑的纠错代价：相邻换位先减折扣，再按个人敲错表打折。
    func correctionCost(transpose: Bool, accepted: Int) -> Double {
        let base = transpose ? correctionPenalty - correctionTransposeDiscount : correctionPenalty
        return discounted(base, accepted: accepted)
    }

    /// `base` 代价减去个人折扣：折扣 = min(ln(1 + 接受过的次数), discountCap)。
    func discounted(_ base: Double, accepted: Int) -> Double {
        base - min(log(1.0 + Double(min(accepted, Int(1e9)))), discountCap)
    }
}

/// 拼音纠错（整段一处编辑）的入口。
enum PinyinCorrector {
    /// 少于这么多字母不纠：短串的一处编辑几乎总能凑出别的合法拼音，误纠比不纠更烦。
    static let minLetters = 4

    /// 多于这么多字母不纠：变体数量随长度线性涨，而且这么长多半是整句简拼。
    static let maxLetters = 24

    /// 这段输入是否值得试纠错：纯小写字母、长度在范围内。
    static func eligible(_ input: String) -> Bool {
        (minLetters ... maxLetters).contains(input.count)
            && input.unicodeScalars.allSatisfy { $0.value >= 97 && $0.value <= 122 }
    }

    /// 切出来的拼音「不像话」：有切不动的尾巴，或非末尾的音节里有简拼 / 残缺。
    static func unlikelyPinyin(_ best: PinyinSegmentation?, tail: String) -> Bool {
        if !tail.isEmpty { return true }
        return (best?.innerAbbreviatedCount ?? 0) > 0
    }

    /// 切出来的拼音末尾是个单字母（`mingtai'n`）：可能是合法简拼，也可能是相邻两键敲反了。
    static func trailingSingleLetter(_ best: PinyinSegmentation?) -> Bool {
        guard let best, best.syllables.count >= 2 else { return false }
        return best.syllables.last?.text.count == 1
    }

    /// `text` 能否切成每个音节都完整的拼音；能就返回音节最少的那种切分。
    static func completeSegmentation(_ text: String) -> PinyinSegmentation? {
        PinyinParser.segmentOrNil(text)?.first { $0.incompleteCount == 0 }
    }

    /// `text` 能否切成「每个音节都完整，或只有末尾一个没敲完」的拼音，按解析器的偏好取第一种：
    /// `mingt` → `ming t…`，`mingtia` → `ming tia…`。末尾没敲完时至少要有一个完整音节在前。
    static func looseSegmentation(_ text: String) -> PinyinSegmentation? {
        PinyinParser.segmentOrNil(text)?.first { segmentation in
            segmentation.incompleteCount == 0
                || (segmentation.syllables.count >= 2
                    && segmentation.incompleteCount == 1 && segmentation.lastIsPartial)
        }
    }

    /// `input` 的全部候选纠正：一处编辑之后能完整切分的变体，顺序同 [`variants`]（换位最先）。
    static func candidates(_ input: String) -> [PinyinCorrection] {
        candidatesFrom(input, variants(input))
    }

    /// 只试相邻换位的候选纠正（末尾单字母那种「像话但可疑」的输入用）。
    static func transpositionCandidates(_ input: String) -> [PinyinCorrection] {
        candidatesFrom(input, variants(input).filter { $0.edit.isTranspose })
    }

    private static func candidatesFrom(_ input: String,
                                       _ edits: [(edit: PinyinEdit, text: String)]) -> [PinyinCorrection] {
        guard eligible(input) else { return [] }
        let found: [PinyinCorrection] = edits.compactMap { item in
            // 相邻换位的变体允许末尾音节没敲完；其余先用无分配的「能否完整切分」挡掉绝大多数
            let segmentation: PinyinSegmentation?
            if item.edit.isTranspose {
                segmentation = looseSegmentation(item.text)
            } else if PinyinParser.isFullySegmentable(item.text) {
                segmentation = completeSegmentation(item.text)
            } else {
                segmentation = nil
            }
            guard let segmentation else { return nil }
            return PinyinCorrection(original: input, corrected: item.text,
                                    edit: item.edit, segmentation: segmentation)
        }
        // 凑得出「每个音节都完整」的变体时只在这些里挑，末尾没敲完的不参与：残尾按前缀能匹配到
        // 高频词，得分往往压过整段完整的纠正。末尾是落单单字母的完整变体不算数，只有一个音节的
        // 也不算数，改在刚敲的最后一个键上的也不算数。
        let settled = found.contains { correction in
            correction.segmentation.incompleteCount == 0
                && correction.segmentation.syllables.count >= 2
                && !trailingSingleLetter(correction.segmentation)
                && !correction.edit.touchesLastLetter(correction.corrected.count)
        }
        return settled
            ? found.filter { $0.segmentation.incompleteCount == 0 }
            : found
    }

    /// `input` 的全部一处编辑变体：先换位，再替换、删除、插入。`input` 必须是纯小写字母。
    static func variants(_ input: String) -> [(edit: PinyinEdit, text: String)] {
        let bytes = Array(input.utf8)
        let n = bytes.count
        var out: [(edit: PinyinEdit, text: String)] = []
        out.reserveCapacity(n * 55)
        if n > 1 {
            for index in 0 ..< n - 1 where bytes[index] != bytes[index + 1] {
                var swapped = bytes
                swapped.swapAt(index, index + 1)
                out.append((.transpose(index: index,
                                       first: Character(UnicodeScalar(bytes[index])),
                                       second: Character(UnicodeScalar(bytes[index + 1]))),
                            ascii(swapped)))
            }
        }
        for index in 0 ..< n {
            for letter in UInt8(97) ... 122 where letter != bytes[index] {
                var next = bytes
                next[index] = letter
                out.append((.substitute(index: index, from: Character(UnicodeScalar(bytes[index]))),
                            ascii(next)))
            }
        }
        for index in 0 ..< n {
            var next = bytes
            next.remove(at: index)
            out.append((.delete(index: index, removed: Character(UnicodeScalar(bytes[index]))),
                        ascii(next)))
        }
        for index in 0 ... n {
            for letter in UInt8(97) ... 122 {
                var next = bytes
                next.insert(letter, at: index)
                out.append((.insert(index: index), ascii(next)))
            }
        }
        return out
    }

    private static func ascii(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

/// 音节级的敲错变体：一个完整音节一处编辑（相邻两键换位、敲到相邻键、多键、少键）
/// 之后还是合法音节的那些写法。表按音节表一次算好：每个音节的变体几十个，全部音节几千条。
///
/// 词图里每个完整音节除了敲的原样，还按这些变体查词，命中的词扣掉相应代价，
/// 让「每个音节都合法、整句却不通」的输入（`meiganxi`）也能出 没关系。
/// 整段一处编辑的纠错管切不干净的输入，两者互补。
enum PinyinTypo {
    /// QWERTY 三排字母，算相邻键用。
    static let rows: [String] = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    /// 两个字母在键盘上是否相邻（同排隔壁，或上下排错位挨着的两个）。
    static func adjacent(_ a: Character, _ b: Character) -> Bool {
        guard let (rowA, colA) = position(a), let (rowB, colB) = position(b) else { return false }
        if rowA == rowB { return abs(colA - colB) == 1 }
        guard abs(rowA - rowB) == 1 else { return false }
        // 下一排整体向右错开半个键：上排第 i 个键的下面是下排第 i−1 与第 i 个
        let (upper, lower) = rowA < rowB ? (colA, colB) : (colB, colA)
        return lower == upper || lower + 1 == upper
    }

    private static func position(_ letter: Character) -> (Int, Int)? {
        for (row, keys) in rows.enumerated() {
            for (col, ch) in keys.enumerated() where ch == letter { return (row, col) }
        }
        return nil
    }

    /// 全部音节的敲错变体：音节 → (变体, 类别)。同一变体只留代价最低的类别。
    static let table: [String: [(text: String, kind: PinyinTypoKind)]] = {
        var built: [String: [(text: String, kind: PinyinTypoKind)]] = [:]
        built.reserveCapacity(PinyinSyllables.all.count)
        for syllable in PinyinSyllables.all { built[syllable] = computeVariants(syllable) }
        return built
    }()

    /// `syllable` 的敲错变体；不是完整音节（简拼、没打完的前缀）或单字母音节没有变体。
    static func variants(_ syllable: String) -> [(text: String, kind: PinyinTypoKind)] {
        table[syllable] ?? []
    }

    /// 只取某几类敲错变体（词图扇出上限：漏敲/多敲一个键能变出十几个写法，
    /// 每个都进词图会让一次查询的格子查词翻几倍；换位与相邻换键才是真实的手滑主力）。
    static func variants(_ syllable: String, kinds: Set<PinyinTypoKind>) -> [(text: String, kind: PinyinTypoKind)] {
        let all = table[syllable] ?? []
        guard kinds.count < PinyinTypoKind.allCases.count else { return all }
        return all.filter { kinds.contains($0.kind) }
    }

    /// 把 `typed` 敲成 `intended` 属于哪类敲错；不是一处敲错返回 nil。
    static func kind(_ typed: String, _ intended: String) -> PinyinTypoKind? {
        variants(typed).first { $0.text == intended }?.kind
    }

    /// `intended` 是不是 `typed` 的一处敲错变体。
    static func isVariant(typed: String, intended: String) -> Bool {
        kind(typed, intended) != nil
    }

    /// 一个音节的全部一处编辑（换键只算相邻键）里仍是合法音节的那些。
    /// 单字母音节（`a` / `e` / `o`）不算：一键之差就是另一个字，谈不上敲错。
    static func computeVariants(_ syllable: String) -> [(text: String, kind: PinyinTypoKind)] {
        let bytes = Array(syllable.utf8)
        let n = bytes.count
        var found: [(text: String, kind: PinyinTypoKind)] = []
        guard n >= 2 else { return found }
        let costs = PinyinTypoCosts.standard
        func push(_ text: String, _ kind: PinyinTypoKind) {
            guard text != syllable, PinyinSyllables.isSyllable(text) else { return }
            if let slot = found.firstIndex(where: { $0.text == text }) {
                if costs.cost(kind) < costs.cost(found[slot].kind) { found[slot].kind = kind }
            } else {
                found.append((text, kind))
            }
        }
        for index in 0 ..< n - 1 where bytes[index] != bytes[index + 1] {
            var swapped = bytes
            swapped.swapAt(index, index + 1)
            push(String(decoding: swapped, as: UTF8.self), .transpose)
        }
        for index in 0 ..< n {
            for letter in UInt8(97) ... 122 where letter != bytes[index] {
                guard adjacent(Character(UnicodeScalar(bytes[index])),
                               Character(UnicodeScalar(letter))) else { continue }
                var next = bytes
                next[index] = letter
                push(String(decoding: next, as: UTF8.self), .substitute)
            }
        }
        for index in 0 ..< n {
            var next = bytes
            next.remove(at: index)
            push(String(decoding: next, as: UTF8.self), .extra)
        }
        for index in 0 ... n {
            for letter in UInt8(97) ... 122 {
                var next = bytes
                next.insert(letter, at: index)
                push(String(decoding: next, as: UTF8.self), .missing)
            }
        }
        return found
    }
}
