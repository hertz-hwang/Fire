//
//  ShuangpinKeyEditor.swift
//  Fire
//
//  自定义双拼的键位编辑操作：把「拖一个韵母到某个键上」这类动作写成纯函数。
//
//  界面（`ShuangpinEditorView`）只负责渲染与转发，规则都在这里——
//  于是绑键/解绑/优先级/零声母重算/校验能脱离窗口单测（`tmp/pinyin/shuangpin`），
//  不必为了验证一条规则去手工点一遍键盘。
//

import Foundation

/// 键位编辑器背后的模型。
struct ShuangpinKeyEditor {
    /// 正在编辑的键位表
    var table: ShuangpinKeyTable
    /// 可敲的键：26 个小写字母，方案用到 `;` 时也算一个键位
    var keys: [String] { table.semicolon ? ShuangpinKeyEditor.alphabet + [";"] : ShuangpinKeyEditor.alphabet }

    static let alphabet = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p",
                           "a", "s", "d", "f", "g", "h", "j", "k", "l",
                           "z", "x", "c", "v", "b", "n", "m"]

    init(table: ShuangpinKeyTable) { self.table = table }

    var scheme: ShuangpinScheme { ShuangpinScheme(table: table) }

    /// 某个键上当前的韵母（按优先级）。
    /// 别命名成 `final(of:)`：`final` 是声明修饰关键字，调用点会被解析成属性而不是方法。
    func finals(of key: String) -> [String] { table.finals(for: key) }
    /// 某个键当前映射的声母（翘舌类才需要显式绑）
    func initial(of key: String) -> String? { table.mappedInitial(for: key) }

    // MARK: 绑韵母

    /// 把韵母绑到某个键，并放到该键的第一位（刚拖上来的默认最优先）。
    ///
    /// 一个韵母只允许存在于一个键上：允许它同时挂在两个键，`encode()`（音节 → 键）
    /// 就得按表序挑一个，用户会遇到「同一个音两个键都能打，但只有其中一个能编出来」，
    /// 那种键位没人能看懂。所以拖到新键 = 从旧键搬走。
    @discardableResult
    mutating func bind(final: String, to key: String) -> Bool {
        guard keys.contains(key), !final.isEmpty else { return false }
        // 已经排在这个键第一位就真没变化（注意要在摘走之前问：摘完再问永远答案是「没有」）
        if finals(of: key).first == final { return false }
        var finals = table.finals
        for index in finals.indices {
            finals[index].finals.removeAll { $0 == final }
        }
        if let index = finals.firstIndex(where: { $0.key == key }) {
            finals[index].finals.insert(final, at: 0)
        } else {
            let entry = ShuangpinFinalKey(key: key, finals: [final])
            // 新键按字母序插入：面板遍历与差分对比都靠稳定的顺序
            if let at = finals.firstIndex(where: { $0.key > key }) {
                finals.insert(entry, at: at)
            } else {
                finals.append(entry)
            }
        }
        table.finals = finals.filter { !$0.finals.isEmpty }
        return true
    }

    /// 摘掉某个键上的一个韵母（键上没韵母了就把这个键整条删掉）
    @discardableResult
    mutating func remove(final: String, from key: String) -> Bool {
        guard let index = table.finals.firstIndex(where: { $0.key == key }),
              table.finals[index].finals.contains(final) else { return false }
        table.finals[index].finals.removeAll { $0 == final }
        if table.finals[index].finals.isEmpty { table.finals.remove(at: index) }
        return true
    }

    /// 调整同一键上两个韵母的优先级顺序（相邻互换）
    @discardableResult
    mutating func moveFinal(in key: String, at index: Int, by delta: Int) -> Bool {
        guard let at = table.finals.firstIndex(where: { $0.key == key }) else { return false }
        let target = index + delta
        guard table.finals[at].finals.indices.contains(index),
              table.finals[at].finals.indices.contains(target) else { return false }
        table.finals[at].finals.swapAt(index, target)
        return true
    }

    // MARK: 绑声母

    /// 把翘舌声母绑到某个键（`v → zh`）。同样是一绑一走：一个声母只认一个键。
    @discardableResult
    mutating func bind(initial: String, to key: String) -> Bool {
        guard keys.contains(key), !initial.isEmpty else { return false }
        var initials = table.initials
        for index in initials.indices where initials[index].initial == initial {
            initials[index].initial = ""
        }
        initials.removeAll { $0.initial.isEmpty }
        if let index = initials.firstIndex(where: { $0.key == key }) {
            if initials[index].initial == initial { return false }
            initials[index].initial = initial
        } else {
            initials.append(ShuangpinInitialKey(key: key, initial: initial))
        }
        table.initials = initials
        return true
    }

    @discardableResult
    mutating func unbindInitial(_ key: String) -> Bool {
        let before = table.initials.count
        table.initials.removeAll { $0.key == key }
        return table.initials.count != before
    }

    // MARK: 零声母

    /// 按当前韵母键位重算零声母写法（与既有写法合并）
    mutating func deriveZeroInitials() {
        table.zeroInitials = scheme.derivingZeroInitials()
    }

    /// `;` 键参与不参与：微软 / 搜狗系把 `ing` 放在这里
    mutating func setUsesSemicolon(_ on: Bool) {
        table.semicolon = on
        if !on {
            table.initials.removeAll { $0.key == ";" }
            table.finals.removeAll { $0.key == ";" }
        }
    }

    // MARK: 校验

    /// 编不成两键的音节：这些音在这个方案下打不出来，是「保存了才发现」级别的问题。
    func unencodableSyllables() -> [String] {
        PinyinSyllables.all.filter { scheme.encode($0) == nil }
    }

    /// 没绑到任何键上的韵母（键盘图右上角的「还差这些」列表）。
    ///
    /// 要求清单不是「音节表里出现过的全部韵母」：`er` 只作为零声母音节存在，
    /// 没有任何「声母 + er」的音节要它，五套内置方案也都不给它键位
    /// （它走零声母的原样写法）。把它算成缺项，等于给每个自定义方案报一条假警。
    func unboundFinals() -> [String] {
        let bound = Set(table.boundFinals)
        return ShuangpinKeyEditor.requiredFinals.filter { !bound.contains($0) }
    }

    /// 必须给键位的韵母：至少在一个「带声母的音节」里出现过
    static let requiredFinals: [String] = {
        var set = Set<String>()
        for syllable in PinyinSyllables.all {
            let initial = PinyinSyllables.longestInitial(of: syllable)
            guard !initial.isEmpty else { continue }
            set.insert(String(syllable.dropFirst(initial.count)))
        }
        return PinyinSyllables.finals.filter { set.contains($0) }
    }()

    /// 没绑到键上的翘舌声母（`zh/ch/sh` 不绑就只能靠键位本身的字母，通常打不出翘舌）
    func unboundDigraphInitials() -> [String] {
        let bound = Set(table.initials.map(\.initial))
        return ["zh", "ch", "sh"].filter { !bound.contains($0) }
    }

    /// 有歧义的键位组合：同一对键既能当零声母写法、又能读成「声母 + 韵母」，
    /// 或者一对键对应多个零声母音节。参考实现对内置方案有同样的单测
    /// （`every_key_pair_is_unambiguous`），自定义方案更需要在保存前看见它。
    func ambiguousKeyPairs() -> [(keys: String, readings: [String])] {
        var result: [(String, [String])] = []
        for first in keys {
            guard scheme.initial(first) == nil else { continue }   // 能当声母的键交给下面一条判
            for second in keys {
                let zero = table.zeroInitials.filter {
                    $0.spellings.contains(first + second)
                }.map(\.syllable)
                if zero.count > 1 { result.append((first + second, zero)) }
            }
        }
        return result
    }

    /// 一键多音节风险：某个两键组合既能解成零声母写法、又能拼成合法音节。
    /// （内置方案里也普遍存在，参考实现的做法是零声母优先，不算错误，所以只报不拦）
    func collidingKeyPairs() -> [(keys: String, readings: [String])] {
        var result: [(String, [String])] = []
        for first in keys {
            for second in keys {
                let zero = table.zeroInitials
                    .filter { $0.spellings.contains(first + second) }
                    .map(\.syllable)
                guard !zero.isEmpty else { continue }
                var stripped = table
                stripped.zeroInitials = []
                let spelled = ShuangpinScheme(table: stripped).syllable(first, second)
                if let spelled, !zero.contains(spelled) {
                    result.append((first + second, zero + [spelled]))
                }
            }
        }
        return result
    }
}

/// 键位编辑器的拖拽负载：韵元素与声元素共用一条 onDrop 通道，靠前缀区分。
///
/// 编解码放在内核侧（而不是界面文件里）有两个理由：一是纯字符串函数，能脱窗单测
/// ——拖放这种交互没法在 CI 里点，唯一能证的就是「这串东西解出来是谁」；
/// 二是界面文件 import SwiftUI，拖进来就毁掉拼音内核「脱离 UI 单编单跑」的性质。
enum ShuangpinDragPayload {
    /// 拖的是哪类元素
    enum Element: Hashable {
        case final, initial

        var prefix: String { self == .final ? "fire-final:" : "fire-initial:" }
    }

    static func encode(_ element: Element, _ name: String) -> String {
        element.prefix + name
    }

    /// 从负载串解出「哪类元素 + 元素名」；不是本编辑器的负载返回 nil
    /// （从访达拖个文件进键盘不该改键位）
    static func decode(_ text: String) -> (element: Element, name: String)? {
        for element in [Element.final, .initial] {
            if text.hasPrefix(element.prefix) {
                return (element, String(text.dropFirst(element.prefix.count)))
            }
        }
        return nil
    }
}
