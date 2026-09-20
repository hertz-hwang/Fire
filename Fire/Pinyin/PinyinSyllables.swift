//
//  PinyinSyllables.swift
//  Fire
//
//  普通话音节表与查表：全拼切分、双拼拼写合法性的唯一事实来源。
//  音节表逐条录入，查表只认三种问法：是否完整音节、是否音节前缀、开头能当声母的长度。
//

import Foundation

/// 音节表与查表（无状态、纯函数，UI 与引擎共用）。
enum PinyinSyllables {
    /// 无声调的普通话合法音节表（含 ü 写作 v / ue 两种写法），按声母分组。
    /// 只放独立成字的音节，不含 `m` / `ng` / `hm` 这类叹词写法。
    static let all: [String] = [

        // 零声母
        "a", "ai", "an", "ang", "ao", "e", "ei", "en", "eng", "er", "o", "ou",
        "yi", "ya", "yao", "ye", "you", "yan", "yin", "yang", "ying", "yong", "yu", "yue", "yuan", "yun", "yo",
        "wu", "wa", "wo", "wai", "wei", "wan", "wen", "wang", "weng",
        // b p m f
        "ba", "bo", "bai", "bei", "bao", "ban", "ben", "bang", "beng", "bi", "bie", "biao", "bian", "bin", "bing", "bu",
        "pa", "po", "pai", "pei", "pao", "pou", "pan", "pen", "pang", "peng", "pi", "pie", "piao", "pian", "pin", "ping", "pu",
        "ma", "mo", "me", "mai", "mei", "mao", "mou", "man", "men", "mang", "meng", "mi", "mie", "miao", "miu", "mian", "min", "ming", "mu",
        "fa", "fo", "fei", "fou", "fan", "fen", "fang", "feng", "fu",
        // d t n l
        "da", "de", "dai", "dei", "dao", "dou", "dan", "den", "dang", "deng", "dong", "di", "dia", "die", "diao", "diu", "dian", "ding", "du", "duo", "dui", "duan", "dun",
        "ta", "te", "tai", "tao", "tou", "tan", "tang", "teng", "tong", "ti", "tie", "tiao", "tian", "ting", "tu", "tuo", "tui", "tuan", "tun",
        "na", "ne", "nai", "nei", "nao", "nou", "nan", "nen", "nang", "neng", "nong", "ni", "nie", "niao", "niu", "nian", "nin", "niang", "ning", "nu", "nuo", "nuan", "nun", "nv", "nve", "nue",
        "la", "le", "lai", "lei", "lao", "lou", "lan", "lang", "leng", "long", "li", "lia", "lie", "liao", "liu", "lian", "lin", "liang", "ling", "lu", "luo", "luan", "lun", "lv", "lve", "lue", "lo",
        // g k h
        "ga", "ge", "gai", "gei", "gao", "gou", "gan", "gen", "gang", "geng", "gong", "gu", "gua", "guo", "guai", "gui", "guan", "gun", "guang",
        "ka", "ke", "kai", "kei", "kao", "kou", "kan", "ken", "kang", "keng", "kong", "ku", "kua", "kuo", "kuai", "kui", "kuan", "kun", "kuang",
        "ha", "he", "hai", "hei", "hao", "hou", "han", "hen", "hang", "heng", "hong", "hu", "hua", "huo", "huai", "hui", "huan", "hun", "huang",
        // j q x
        "ji", "jia", "jie", "jiao", "jiu", "jian", "jin", "jiang", "jing", "jiong", "ju", "jue", "juan", "jun",
        "qi", "qia", "qie", "qiao", "qiu", "qian", "qin", "qiang", "qing", "qiong", "qu", "que", "quan", "qun",
        "xi", "xia", "xie", "xiao", "xiu", "xian", "xin", "xiang", "xing", "xiong", "xu", "xue", "xuan", "xun",
        // zh ch sh r
        "zha", "zhe", "zhi", "zhai", "zhei", "zhao", "zhou", "zhan", "zhen", "zhang", "zheng", "zhong", "zhu", "zhua", "zhuo", "zhuai", "zhui", "zhuan", "zhun", "zhuang",
        "cha", "che", "chi", "chai", "chao", "chou", "chan", "chen", "chang", "cheng", "chong", "chu", "chua", "chuo", "chuai", "chui", "chuan", "chun", "chuang",
        "sha", "she", "shi", "shai", "shei", "shao", "shou", "shan", "shen", "shang", "sheng", "shu", "shua", "shuo", "shuai", "shui", "shuan", "shun", "shuang",
        "re", "ri", "rao", "rou", "ran", "ren", "rang", "reng", "rong", "ru", "rua", "ruo", "rui", "ruan", "run",
        // z c s
        "za", "ze", "zi", "zai", "zei", "zao", "zou", "zan", "zen", "zang", "zeng", "zong", "zu", "zuo", "zui", "zuan", "zun",
        "ca", "ce", "ci", "cai", "cao", "cou", "can", "cen", "cang", "ceng", "cong", "cu", "cuo", "cui", "cuan", "cun",
        "sa", "se", "si", "sai", "sao", "sou", "san", "sen", "sang", "seng", "song", "su", "suo", "sui", "suan", "sun",

    ];

    /// 音节最长 6 个字母（zhuang / chuang / shuang）。
    static let maxLength = 6

    /// 简拼允许单独出现的声母。`y` / `w` 按拼音书写习惯也算。
    static let initials: [String] = [
        "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x",
        "zh", "ch", "sh", "r", "z", "c", "s", "y", "w",
    ]

    /// 全部韵母（音节剥掉最长声母后的剩余），双拼键位编辑器的韵元素清单。
    /// ü 在音节表里写作 `v` / `ue`，这里保留写法本身，键位表怎么映射由方案决定。
    /// 顺序：先按长度降序再按字典序，长的排前面，拖动面板更好读。
    static let finals: [String] = {
        var set = Set<String>()
        for syllable in all {
            let final = String(syllable.dropFirst(longestInitial(of: syllable).count))
            if !final.isEmpty { set.insert(final) }
        }
        return set.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }()

    /// 零声母音节（没有声母开头的那些），双拼键位编辑器的「零声母」分组。
    static let zeroInitialSyllables: [String] = {
        all.filter { longestInitial(of: $0).isEmpty }
    }()

    // MARK: - 打包

    /// 把至多 6 个 ASCII 字母打进一个 UInt64（大端、0 补齐）。
    /// 0 不是合法字母字节，因此「补零」不会和更长的串撞车：`a` 与 `aa` 的包装不同。
    /// 切分与双拼每个键都要问几百次「这几个字母是不是音节」，字符串哈希要逐字节走
    /// Swift 的 String 内部结构，打包成整数后是一次 Set<UInt64> 查找——逐键查询预算里
    /// 切分要占掉三成，这里省下来的就是候选栏的跟手度。
    @inline(__always)
    static func pack(_ bytes: [UInt8], _ from: Int, _ length: Int) -> UInt64 {
        var value: UInt64 = 0
        let end = min(from + length, bytes.count)
        var index = from
        while index < end {
            value = value << 8 | UInt64(bytes[index])
            index += 1
        }
        // 右侧补零到 6 字节，保证同长度同内容才是同键
        return value << (8 * (maxLength - (end - from)))
    }

    static func pack(_ text: String) -> UInt64 {
        pack(Array(text.utf8), 0, min(text.utf8.count, maxLength))
    }

    // MARK: - 查表

    static let packed: Set<UInt64> = Set(all.map(pack))

    /// 全部音节的**真**前缀（不含音节自身）。
    static let packedPrefixes: Set<UInt64> = {
        var set = Set<UInt64>()
        for syllable in all {
            let bytes = Array(syllable.utf8)
            for length in 1 ..< bytes.count {
                set.insert(pack(bytes, 0, length))
            }
        }
        return set
    }()

    /// `bytes[from..from+length]` 是不是完整音节。
    @inline(__always)
    static func isSyllable(_ bytes: [UInt8], _ from: Int, _ length: Int) -> Bool {
        length > 0 && length <= maxLength && packed.contains(pack(bytes, from, length))
    }

    static func isSyllable(_ text: String) -> Bool {
        packed.contains(pack(text))
    }

    /// `text` 是否为某个合法音节的**真**前缀（不包含它自己就是完整音节的情况）。
    static func isSyllablePrefix(_ text: String) -> Bool {
        packedPrefixes.contains(pack(text))
    }

    @inline(__always)
    static func isSyllablePrefix(_ bytes: [UInt8], _ from: Int, _ length: Int) -> Bool {
        length > 0 && packedPrefixes.contains(pack(bytes, from, length))
    }

    /// `rest` 开头能当声母的长度：`zh` 开头返回 `[2, 1]`（`zh` 与 `z` 都可能），
    /// `k` 返回 `[1]`，元音开头为空。**按 `initials` 表序返回**——切分 DP 里的
    /// 插入顺序靠它对齐，同分切分的先后（候选栏顺序）不能抖。
    static func initialLengths(_ bytes: [UInt8], _ from: Int) -> [Int] {
        var lengths: [Int] = []
        for initial in initials {
            let count = initial.utf8.count
            guard from + count <= bytes.count else { continue }
            var matched = true
            for (offset, byte) in initial.utf8.enumerated() where bytes[from + offset] != byte {
                matched = false
                break
            }
            if matched { lengths.append(count) }
        }
        return lengths
    }

    /// 以 `bytes[from...]` 开头的合法音节长度，升序；最多 [`maxLength`] 个。
    static func syllableLengths(_ bytes: [UInt8], _ from: Int) -> [Int] {
        var lengths: [Int] = []
        for length in 1 ... maxLength {
            guard from + length <= bytes.count else { break }
            if packed.contains(pack(bytes, from, length)) { lengths.append(length) }
        }
        return lengths
    }

    /// 音节开头最长的声母（`zhuang` → `zh`，`a` → `""`）。
    static func longestInitial(of syllable: String) -> String {
        var best = ""
        for initial in initials where syllable.hasPrefix(initial) && initial.count > best.count {
            best = initial
        }
        return best
    }

    /// `lue`/`nue` 与 `lve`/`nve` 是同一个音节的两种写法，查词与比读音前先归一。
    static func canonical(_ text: String) -> String {
        switch text {
        case "lue": return "lve"
        case "nue": return "nve"
        default: return text
        }
    }
}
