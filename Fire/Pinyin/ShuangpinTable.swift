//
//  ShuangpinTable.swift
//  Fire
//
//  双拼键位表：键 → 声母、键 → 韵母（可多个，按优先级）、零声母音节 → 两键写法。
//
//  内置五套方案逐条照搬参考实现 `ref-core/src/shuangpin/table.rs`（按 Rime 的
//  `double_pinyin*.schema.yaml` 核对，搜狗来自 rime-ice 整理）。与参考实现有两点不同：
//
//  * 表是**运行时值**而非编译期常量——用户能在设置面板里拖拽改键，
//    自定义方案与内置方案走完全相同的解码路径。
//  * 三段映射一律存**有序数组**而不是字典：`syllable(first, second)` 与 `encode`
//    都是「按表序取第一个命中」，小浪的 `en` / `eng` 共用写法 `un` 就靠表序定胜负，
//    用户把同一个韵母绑到两个键时也要能稳定编回同一个键。字典的遍历序做不到这件事。
//

import Foundation

/// 声母键（键 → 声母）。
struct ShuangpinInitialKey: Codable, Hashable {
    var key: String
    var initial: String
}

/// 韵母键（键 → 韵母清单，按优先级）。
struct ShuangpinFinalKey: Codable, Hashable {
    var key: String
    var finals: [String]
}

/// 零声母写法（音节 → 两键写法，第一种是主写法）。
struct ShuangpinZeroSyllable: Codable, Hashable {
    var syllable: String
    var spellings: [String]
}

/// 一套双拼方案的键位表（可序列化，自定义方案就存这个）。
struct ShuangpinKeyTable: Codable, Hashable {
    /// 翘舌声母映射。只列与字母本身不同的声母，其余辅音键（含 `y` `w`）就是自己；
    /// 非声母键不在此列。
    var initials: [ShuangpinInitialKey] = []

    /// 韵母键 → 可能的韵母，按优先级排（同一键配同一声母能拼出两个合法音节时取前面的，
    /// 如 `lve` 先于 `lue`）。
    var finals: [ShuangpinFinalKey] = []

    /// 零声母音节 → 两键写法（可以有多种，第一种是主写法）。
    var zeroInitials: [ShuangpinZeroSyllable] = []

    /// 是否用到 `;` 键（微软 / 搜狗的 ing）。
    var semicolon: Bool = false

    /// 落单键的额外映射（小浪把 `u` 读作 `e`）。缺省不覆盖：声母键读声母，`a`/`e`/`o` 读自己。
    var partialOverrides: [String: String]?

    init(initials: [ShuangpinInitialKey] = [],
         finals: [ShuangpinFinalKey] = [],
         zeroInitials: [ShuangpinZeroSyllable] = [],
         semicolon: Bool = false,
         partialOverrides: [String: String]? = nil) {
        self.initials = initials
        self.finals = finals
        self.zeroInitials = zeroInitials
        self.semicolon = semicolon
        self.partialOverrides = partialOverrides
    }

    /// 三个占键的翘舌声母：小鹤、自然码、微软、搜狗一致。
    static let standardDigraphs: [ShuangpinInitialKey] = [
        .init(key: "v", initial: "zh"), .init(key: "i", initial: "ch"), .init(key: "u", initial: "sh"),
    ]

    /// 小浪双拼的翘舌声母：e 为 zh，i 为 ch，v 为 sh。
    static let xiaolangDigraphs: [ShuangpinInitialKey] = [
        .init(key: "e", initial: "zh"), .init(key: "i", initial: "ch"), .init(key: "v", initial: "sh"),
    ]

    /// 便捷构造：`(键, 声母)` / `(键, [韵母])` / `(音节, [写法])` 字面量。
    static func build(initials: [(String, String)], finals: [(String, [String])],
                      zeroInitials: [(String, [String])], semicolon: Bool = false,
                      partialOverrides: [String: String]? = nil) -> ShuangpinKeyTable {
        ShuangpinKeyTable(
            initials: initials.map { ShuangpinInitialKey(key: $0.0, initial: $0.1) },
            finals: finals.map { ShuangpinFinalKey(key: $0.0, finals: $0.1) },
            zeroInitials: zeroInitials.map { ShuangpinZeroSyllable(syllable: $0.0, spellings: $0.1) },
            semicolon: semicolon,
            partialOverrides: partialOverrides
        )
    }

    /// 某个键当韵母时的候选韵母（按优先级）。
    func finals(for key: String) -> [String] {
        finals.first { $0.key == key }?.finals ?? []
    }

    /// 某个韵母绑在哪些键上（表序）。自定义编辑器用它给元素标出已绑定的键。
    func keysBinding(final: String) -> [String] {
        finals.filter { $0.finals.contains(final) }.map(\.key)
    }

    /// 某个键当声母时的映射（表序第一个）。
    func mappedInitial(for key: String) -> String? {
        initials.first { $0.key == key }?.initial
    }

    /// 某个声母由哪些键表示。
    func keysBinding(initial: String) -> [String] {
        initials.filter { $0.initial == initial }.map(\.key)
    }

    /// 键位表里出现过的全部韵母（含重复），自定义编辑器的「已绑定」统计用。
    var boundFinals: [String] { finals.flatMap(\.finals) }
}

/// 五套内置方案的键位表（照参考实现表逐键核对）。
enum ShuangpinTables {
    /// 小鹤双拼。
    static let xiaohe = ShuangpinKeyTable.build(
        initials: ShuangpinKeyTable.standardDigraphs.map { ($0.key, $0.initial) },
        finals: [
            ("q", ["iu"]), ("w", ["ei"]), ("e", ["e"]), ("r", ["uan"]), ("t", ["ve", "ue"]),
            ("y", ["un"]), ("u", ["u"]), ("i", ["i"]), ("o", ["uo", "o"]), ("p", ["ie"]),
            ("a", ["a"]), ("s", ["iong", "ong"]), ("d", ["ai"]), ("f", ["en"]), ("g", ["eng"]),
            ("h", ["ang"]), ("j", ["an"]), ("k", ["ing", "uai"]), ("l", ["iang", "uang"]),
            ("z", ["ou"]), ("x", ["ia", "ua"]), ("c", ["ao"]), ("v", ["ui", "v"]), ("b", ["in"]),
            ("n", ["iao"]), ("m", ["ian"]),
        ],
        zeroInitials: [
            ("a", ["aa"]), ("ai", ["ai", "ad"]), ("an", ["an", "aj"]), ("ang", ["ah"]),
            ("ao", ["ao", "ac"]), ("e", ["ee"]), ("ei", ["ei", "ew"]), ("en", ["en", "ef"]),
            ("eng", ["eg"]), ("er", ["er"]), ("o", ["oo"]), ("ou", ["ou", "oz"]),
        ]
    )

    /// 自然码。
    static let ziranma = ShuangpinKeyTable.build(
        initials: ShuangpinKeyTable.standardDigraphs.map { ($0.key, $0.initial) },
        finals: [
            ("q", ["iu"]), ("w", ["ia", "ua"]), ("e", ["e"]), ("r", ["uan"]), ("t", ["ve", "ue"]),
            ("y", ["uai", "ing"]), ("u", ["u"]), ("i", ["i"]), ("o", ["uo", "o"]), ("p", ["un"]),
            ("a", ["a"]), ("s", ["iong", "ong"]), ("d", ["iang", "uang"]), ("f", ["en"]),
            ("g", ["eng"]), ("h", ["ang"]), ("j", ["an"]), ("k", ["ao"]), ("l", ["ai"]),
            ("z", ["ei"]), ("x", ["ie"]), ("c", ["iao"]), ("v", ["ui", "v"]), ("b", ["ou"]),
            ("n", ["in"]), ("m", ["ian"]),
        ],
        zeroInitials: [
            ("a", ["aa"]), ("ai", ["ai", "al"]), ("an", ["an", "aj"]), ("ang", ["ah"]),
            ("ao", ["ao", "ak"]), ("e", ["ee"]), ("ei", ["ei", "ez"]), ("en", ["en", "ef"]),
            ("eng", ["eg"]), ("er", ["er"]), ("o", ["oo"]), ("ou", ["ou", "ob"]),
        ]
    )

    /// 微软 / 搜狗共用的零声母写法：`o` 加韵母键，`a` / `e` 开头的也接受双写元音的写法。
    static let oPrefixZeroInitials: [(String, [String])] = [
        ("a", ["oa", "aa"]), ("ai", ["ol", "al"]), ("an", ["oj", "aj"]), ("ang", ["oh", "ah"]),
        ("ao", ["ok", "ak"]), ("e", ["oe", "ee"]), ("ei", ["oz", "ez"]), ("en", ["of", "ef"]),
        ("eng", ["og", "eg"]), ("er", ["or", "er"]), ("o", ["oo"]), ("ou", ["ob", "ou"]),
    ]

    /// 微软双拼：ü 在 `y`，üe 在 `t`（`v` 也认），ing 在 `;`。
    static let microsoft = ShuangpinKeyTable.build(
        initials: ShuangpinKeyTable.standardDigraphs.map { ($0.key, $0.initial) },
        finals: [
            ("q", ["iu"]), ("w", ["ia", "ua"]), ("e", ["e"]), ("r", ["uan"]), ("t", ["ve", "ue"]),
            ("y", ["uai", "v"]), ("u", ["u"]), ("i", ["i"]), ("o", ["uo", "o"]), ("p", ["un"]),
            ("a", ["a"]), ("s", ["iong", "ong"]), ("d", ["iang", "uang"]), ("f", ["en"]),
            ("g", ["eng"]), ("h", ["ang"]), ("j", ["an"]), ("k", ["ao"]), ("l", ["ai"]),
            (";", ["ing"]), ("z", ["ei"]), ("x", ["ie"]), ("c", ["iao"]), ("v", ["ui", "ve", "ue"]),
            ("b", ["ou"]), ("n", ["in"]), ("m", ["ian"]),
        ],
        zeroInitials: oPrefixZeroInitials,
        semicolon: true
    )

    /// 搜狗双拼：与微软只差 `v` 键不兼作 üe。
    static let sogou = ShuangpinKeyTable.build(
        initials: ShuangpinKeyTable.standardDigraphs.map { ($0.key, $0.initial) },
        finals: [
            ("q", ["iu"]), ("w", ["ia", "ua"]), ("e", ["e"]), ("r", ["uan"]), ("t", ["ve", "ue"]),
            ("y", ["uai", "v"]), ("u", ["u"]), ("i", ["i"]), ("o", ["uo", "o"]), ("p", ["un"]),
            ("a", ["a"]), ("s", ["iong", "ong"]), ("d", ["iang", "uang"]), ("f", ["en"]),
            ("g", ["eng"]), ("h", ["ang"]), ("j", ["an"]), ("k", ["ao"]), ("l", ["ai"]),
            (";", ["ing"]), ("z", ["ei"]), ("x", ["ie"]), ("c", ["iao"]), ("v", ["ui"]),
            ("b", ["ou"]), ("n", ["in"]), ("m", ["ian"]),
        ],
        zeroInitials: oPrefixZeroInitials,
        semicolon: true
    )

    /// 小浪双拼。
    static let xiaolang = ShuangpinKeyTable.build(
        initials: ShuangpinKeyTable.xiaolangDigraphs.map { ($0.key, $0.initial) },
        finals: [
            ("w", ["ei"]), ("e", ["e"]), ("r", ["ou"]), ("t", ["iu"]), ("y", ["un", "vn"]),
            ("u", ["u"]), ("i", ["i"]), ("o", ["uo", "o"]), ("p", ["ie"]), ("a", ["a"]),
            ("s", ["ao"]), ("d", ["ui", "in"]), ("f", ["ian", "ua"]), ("g", ["uan"]),
            ("h", ["ang"]), ("j", ["an", "iong"]), ("k", ["ai", "ia"]), ("l", ["ong"]),
            ("z", ["uang"]), ("x", ["v", "u"]), ("c", ["iao"]), ("v", ["uai", "ing"]),
            ("b", ["ve", "ue"]), ("n", ["eng"]), ("m", ["iang", "en"]),
        ],
        zeroInitials: [
            ("a", ["aa"]), ("ai", ["ai"]), ("an", ["an"]), ("ang", ["ah"]), ("ao", ["ao"]),
            ("e", ["uu"]), ("ei", ["ui"]), ("en", ["un"]), ("eng", ["un"]), ("er", ["ur"]),
            ("o", ["oo"]), ("ou", ["ou"]),
        ],
        partialOverrides: ["a": "a", "o": "o", "u": "e"]
    )

    /// 全部内置方案（自定义编辑器的「从此方案开始」列表）。
    static let presets: [(name: String, label: String, table: ShuangpinKeyTable)] = [
        ("xiaohe", "小鹤双拼", xiaohe),
        ("ziranma", "自然码", ziranma),
        ("microsoft", "微软双拼", microsoft),
        ("sogou", "搜狗双拼", sogou),
        ("xiaolang", "小浪双拼", xiaolang),
    ]
}
