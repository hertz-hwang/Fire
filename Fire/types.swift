//
//  types.swift
//  Fire
//
//  Created by 虚幻 on 2020/10/25.
//  Copyright © 2020 qwertyyb. All rights reserved.
//

import Foundation
import Defaults
import Sparkle
import SwiftUI

internal let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum CandidatesDirection: Int, Decodable, Encodable, Defaults.Serializable {
    case vertical
    case horizontal
}

enum ExtraCandidateSelectKeys: String, Codable, Defaults.Serializable {
    case disabled
    case semicolonQuote
    case commaPeriod
}

enum InputModeTipWindowType: Int, Decodable, Encodable, Defaults.Serializable {
    case followInput
    case centerScreen
    case none
}

// 应用切换时，显示输入模式框时机
enum AppInputModeTipShowTime: Int, Decodable, Encodable, Defaults.Serializable {
    case onlyChanged // 仅在切换后的输入模式与之前不一致时显示
    case always // 应用切换即显示，无论有没有变化
    case none // 不显示
}

// 候选框主题深浅模式：手动固定深/浅色，或跟随系统外观
enum ThemeAppearanceMode: Int, Codable, Defaults.Serializable {
    case followSystem // 跟随系统
    case light // 浅色主题
    case dark // 深色主题
}

enum ModifierKey: String, Codable, Defaults.Serializable {
  case shift
  case leftShift
  case rightShift
  case control
  case command
  case option
  case function
}

class ApplicationSettingItem: ObservableObject, Codable, Identifiable, Defaults.Serializable {
//    let identifier: String = ""

    @Published var bundleIdentifier: String = ""

    @Published var inputModeSetting: InputModeSetting = InputModeSetting.recentUsed {
        didSet {
            self.objectWillChange.send()
        }
    }

    var createdTimestamp: Int = 0

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case inputModeSetting
        case createdTimestamp
    }

    init(bundleId: String, inputMs: InputModeSetting) {
        bundleIdentifier = bundleId
        inputModeSetting = inputMs
        createdTimestamp = Int(Date().timeIntervalSince1970)
    }

    required init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try values.decode(String.self, forKey: .bundleIdentifier)
        inputModeSetting = try values.decode(InputModeSetting.self, forKey: .inputModeSetting)
        createdTimestamp = try values.decode(Int.self, forKey: .createdTimestamp)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(inputModeSetting, forKey: .inputModeSetting)
        try container.encode(createdTimestamp, forKey: .createdTimestamp)
    }
}

enum PunctuationMode: Codable, Defaults.Serializable {
    case enUs // 半角
    case zhhans // 全角
    case custom // 自定义
}

extension Defaults.Keys {
    static let zKeyQuery = Key<Bool>("zKeyQuery", default: true)
    static let zKeyRepeat = Key<Bool>("zKeyRepeat", default: true)
    static let candidatesDirection = Key<CandidatesDirection>(
        "candidatesDirection",
        default: CandidatesDirection.vertical
    )
    static let showCodeInWindow = Key<Bool>("showCodeInWindow", default: true)
    static let codeInWindowMode = Key<CodeInWindowMode>("codeInWindowMode", default: .inputCode)
    static let wubiCodeTip = Key<Bool>("wubiCodeTip", default: true)
    // 候选词悬浮拆分提示开关
    static let enableCharDivTip = Key<Bool>("enableCharDivTip", default: true)
    static let maxCodeLength = Key<Int>("maxCodeLength", default: 4)
    static let commitMode = Key<CommitMode>("commitMode", default: CommitMode.spaceCommit)
    static let emptyCodeDirectDelay = Key<Double>("emptyCodeDirectDelay", default: 0.3)
    // 整句模式（参考虎整句）：开启后最大码长/上屏模式失效，候选栏只出整句候选
    static let enableSentenceMode = Key<Bool>("enableSentenceMode", default: false)
    // 整句自动上屏：概率型提前上屏 + 空码自动上屏
    static let enableSentenceAutoCommit = Key<Bool>("enableSentenceAutoCommit", default: true)
    // 整句候选末尾显示各维度打分（通用ngram、用户ngram等，样式走主题配置）
    static let enableSentenceScore = Key<Bool>("enableSentenceScore", default: false)
    // 单字重码组句（虎整句 tiger_sentence_allow_duplicate_single）：
    // 开启时分段路径允许同码非首选单字参与组句；多字非首选仍需显式选重
    static let enableSentenceAllowDuplicateSingle = Key<Bool>("enableSentenceAllowDuplicateSingle", default: true)
    // 整句 n-gram 模型覆盖路径（空表示用内置 Resources 里的模型）
    static let sentenceModelPath = Key<String>("sentenceModelPath", default: "")
    // N-gram语境字数（0/1/2）：每次组字开始从光标插入点向前取最多 N 个汉字，
    // 作为后续组句的左上下文（否则「回」已上屏，接着打 gbmqbk 组不出承前的句子）。
    // 读不到输入框文本时（应用不支持取文本、无辅助功能权限）回落最近 N 段上屏文字
    static let sentenceContextDepth = Key<Int>("sentenceContextDepth", default: 1)
    static let enablePunctuationCandidateSelect = Key<Bool>(
        "enablePunctuationCandidateSelect",
        default: false
    )
    static let candidateCount = Key<Int>("candidateCount", default: 5)
    static let extraCandidateSelectKeys = Key<ExtraCandidateSelectKeys>(
        "extraCandidateSelectKeys",
        default: .semicolonQuote
    )
    static let codeMode = Key<CodeMode>("codeMode", default: CodeMode.wubiPinyin)
    // 拼音输入方式（编码方案=拼音时生效）：全拼 / 小鹤双拼 / 自然码双拼 / 自定义双拼
    static let pinyinLayout = Key<PinyinLayout>("pinyinLayout", default: PinyinLayout.fullPinyin)
    // 自定义双拼键位表（ShuangpinKeyTable 的 JSON）；空 = 未编辑过（按小鹤起步）
    static let pinyinCustomTable = Key<String>("pinyinCustomTable", default: "")
    // 拼音模糊音（PinyinFuzzyRules 的 JSON）；空 = 全关
    static let pinyinFuzzyRules = Key<String>("pinyinFuzzyRules", default: "")
    // 拼音敲错纠正：音节级换位/相邻换键进词图 + 整段一处编辑的纠错
    static let pinyinTypoCorrection = Key<Bool>("pinyinTypoCorrection", default: true)
    static let jianQuanMode = Key<JianQuanMode>("jianQuanMode", default: JianQuanMode.normal)

    // 中英文切换配置
    // 禁止切换英文
    static let disableEnMode = Key<Bool>("diableEnMode", default: false)
    // 禁止;键临时英文模式
    static let disableTempEnMode = Key<Bool>("disableTempEnMode", default: false)
    // 切换英文模式的按键
    static let toggleInputModeKey = Key<ModifierKey>("toggleInputModeKey", default: ModifierKey.shift)
    // 左Shift轻点切英文、右Shift轻点切中文（固定方向）；
    // 开启后左右Shift均不再参与中/英互相轮换，非Shift的轮换快捷键（如control）不受影响
    static let leftShiftToEnRightShiftToZh = Key<Bool>("leftShiftToEnRightShiftToZh", default: false)
    // 中英文切换提示弹窗位置
    static let inputModeTipWindowType = Key<InputModeTipWindowType>(
        "inputModeTipWindowType",
        default: InputModeTipWindowType.centerScreen
    )
    static let showInputModeStatus = Key<Bool>("showInputModeStatus", default: true)

    // 主题
    static let themeConfig = Key<ThemeConfig>("themeConfig", default: defaultThemeConfig)
    static let importedThemeConfig = Key<ThemeConfig?>("importedThemeConfig", default: nil)
    // 深浅主题模式：手动固定或跟随系统
    static let themeAppearanceMode = Key<ThemeAppearanceMode>(
        "themeAppearanceMode",
        default: ThemeAppearanceMode.followSystem
    )
    static let hideCandidatesWindow = Key<Bool>("hideCandidatesWindow", default: false)

    // 应用输入配置
    static let keepAppInputMode = Key<Bool>("keepAppInputMode", default: true)
    static let keepAppInputMode_keys = Key<[String]>("keepAppInputMode_keys", default: [])
    static let keepAppInputMode_cache = Key<[String: InputMode]>("keepAppInputMode_cache", default: [:])

    static let appInputModeTipShowTime = Key<AppInputModeTipShowTime>("appInputModeTipShowTime", default: .onlyChanged)
    static let appSettings = Key<[String: ApplicationSettingItem]>("AppSettings", default: [:])
    // 标点符号配置
    static let punctuationMode = Key<PunctuationMode>("punctuationMode", default: PunctuationMode.zhhans)
    static let customPunctuationSettings = Key<[String: String]>("customPunctuationSettings", default: punctuation)
    // 数字/字母后输入标点自动转为英文标点；连续输入两次相同标点则转为中文标点（如「3..」→「3。」）
    static let enableDotAfterNumber = Key<Bool>("enableDotAfterNumber", default: true)
    // 数字后输入"："自动转为":"
    static let enableColonAfterNumber = Key<Bool>("enableColonAfterNumber", default: true)
    static let enablePunctuationTopScreen = Key<Bool>("enablePunctuationTopScreen", default: false)
    // 在中文和英文之间插入空格，在中文输入模式下生效，也可在英文模式下输入英文再切到中文输入模式下输入中文时生效
    // 从中文模式输入中文后再切到英文输入模式下输入英文时生效
    static let enableWhitespaceBetweenZhEn = Key<Bool>("enableWhitespaceBetweenZhEn", default: false)

    // 快捷键
    static let openPreferencesShortcutModifier = Key<ModifierKey>(
        "openPreferencesShortcutModifier",
        default: ModifierKey.control
    )
    static let openPreferencesShortcutKey = Key<String>(
        "openPreferencesShortcutKey",
        default: "`"
    )
    static let undoCommitShortcutModifier = Key<ModifierKey>(
        "undoCommitShortcutModifier",
        default: ModifierKey.control
    )
    static let undoCommitShortcutKey = Key<String>(
        "undoCommitShortcutKey",
        default: "u"
    )
    // 清空编码串：直接丢弃当前未上屏的编码（不模拟ESC，避免与应用的ESC行为纠缠）
    static let clearCodeShortcutModifier = Key<ModifierKey>(
        "clearCodeShortcutModifier",
        default: ModifierKey.control
    )
    static let clearCodeShortcutKey = Key<String>(
        "clearCodeShortcutKey",
        default: "l"
    )

    static let wbTablePath = Key<String>(
        "wbTableURL",
        default: Bundle.main.resourceURL?.appendingPathComponent("schemas/tiger_table.txt").path
            ?? "")
    static let pyTablePath = Key<String>(
        "pyTableURL",
        default: Bundle.main.resourceURL?.appendingPathComponent("schemas/py_table.txt").path
            ?? "")
    // 拆分表，用于候选词悬浮提示拆分信息
    static let charDivTablePath = Key<String>(
        "charDivTableURL",
        default: Bundle.main.resourceURL?.appendingPathComponent("ll_div.txt").path
            ?? "")
    // 悬浮提示窗口中"拆分字根"文字使用的字体，空表示使用系统默认字体
    static let charDivRootFontName = Key<String>("charDivRootFontName", default: "")

    // 统计配置
    static let enableStatistics = Key<Bool>("enableStatistics", default: true)
    //            ^            ^         ^                ^
    //           Key          Type   UserDefaults name   Default value

    // 学习系统：从上屏/撤销信号中学习用户用词习惯，辅助整句 n-gram 模型
    // 总开关（关闭后既不记录新信号，解码也完全忽略学习数据）
    static let enableLearning = Key<Bool>("enableLearning", default: true)
    // 通道 B：持久化字符级用户 n-gram（置信度门控插值进通用模型）
    static let enableLearningUserNgram = Key<Bool>("enableLearningUserNgram", default: true)
    // 通道 A：会话缓存语言模型（最近上屏窗口内的字符/二元触发加分）
    static let enableLearningSessionCache = Key<Bool>("enableLearningSessionCache", default: true)
    // 通道 C1：胜负纠错对（选了非首选时记正/负证据，下次同码同语境生效）
    static let enableLearningCorrection = Key<Bool>("enableLearningCorrection", default: true)
    // 学习强度：线性缩放各通道加分权重与插值上限（0.2~2.0，1 为默认标定值）
    static let learningStrength = Key<Double>("learningStrength", default: 1.0)
}

enum InputMode: String, Defaults.Serializable {
    case zhhans
    case enUS
}

enum InputModeSetting: String, Codable {
    case zhhans
    case enUS
    case recentUsed
}

enum CandidateType: String {
    case wb // 五笔
    case py // 拼音
    case user // 用户词库
    case placeholder // 运行时类型，无匹配时表示占位
    case sentence // 整句候选（自动上屏与整句选择都计入统计）
}

struct Candidate: Hashable {
    let code: String
    let text: String
    let type: CandidateType
    let label: String
    /// 整句候选的打分显示串（「显示打分」开启时整句候选才有）
    let scoreText: String?

    init(code: String, text: String, type: CandidateType, label: String? = nil,
         scoreText: String? = nil) {
        self.code = code
        self.text = text
        self.type = type
        self.label = label ?? text
        self.scoreText = scoreText
    }
}

enum CodeMode: Int, CaseIterable, Decodable, Encodable, Defaults.Serializable {
    case wubi
    case pinyin
    case wubiPinyin
}

/// 拼音输入方式：全拼，或某种双拼（两键一音节）。
/// 双拼只改「键 → 音节」的映射，切分 / 查词 / 组句 / 排序全部复用全拼那套管线的
/// （参考实现 `shuangpin/mod.rs` 的原话：壳与词库都不知道双拼的存在），
/// 所以新增一种方案 = 加一张键位表，不是加一条管线。
enum PinyinLayout: Int, CaseIterable, Decodable, Encodable, Defaults.Serializable {
    case fullPinyin   // 全拼
    case xiaohe       // 小鹤双拼
    case ziranma      // 自然码双拼
    case custom       // 自定义双拼（键位表见 pinyinCustomTable）

    var label: String {
        switch self {
        case .fullPinyin: return "全拼"
        case .xiaohe: return "小鹤双拼"
        case .ziranma: return "自然码双拼"
        case .custom: return "自定义双拼"
        }
    }

    /// 是否双拼（组字区显示、上屏消耗都要按「音节对应几个键」换算）
    var isShuangpin: Bool { self != .fullPinyin }

    /// 该方式用的键位表；全拼为 nil。
    /// 自定义表 JSON 坏了不能让整个拼音方案打不出字：回落小鹤。
    var keyTable: ShuangpinKeyTable? {
        switch self {
        case .fullPinyin: return nil
        case .xiaohe: return ShuangpinTables.xiaohe
        case .ziranma: return ShuangpinTables.ziranma
        case .custom: return PinyinLayout.customKeyTable(from: Defaults[.pinyinCustomTable])
        }
    }

    /// 解析自定义键位表 JSON；失败回落小鹤（并在面板上提示）
    static func customKeyTable(from json: String) -> ShuangpinKeyTable {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let table = try? JSONDecoder().decode(ShuangpinKeyTable.self, from: data) else {
            return ShuangpinTables.xiaohe
        }
        return table
    }

    /// 自定义表当前是否有效（面板用来决定要不要显示「键位表读取失败」提示）
    static var customTableIsValid: Bool {
        let json = Defaults[.pinyinCustomTable]
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return false }
        return (try? JSONDecoder().decode(ShuangpinKeyTable.self, from: data)) != nil
    }
}

/// 拼音方案的锁定默认项：整句强制开、自动上屏强制关（统一空格上屏）、
/// 单字重码组句强制开、提示编码/z键查询/z键重复上屏强制关。
/// 设置面板置灰这些控件，此处保证运行时行为一致：
/// 启动时归一一次（覆盖老版本残留配置），切方案时由引擎再归一。
func enforcePinyinInputModeDefaults() {
    guard Defaults[.codeMode] == .pinyin else { return }
    if !Defaults[.enableSentenceMode] { Defaults[.enableSentenceMode] = true }
    if Defaults[.enableSentenceAutoCommit] { Defaults[.enableSentenceAutoCommit] = false }
    if Defaults[.commitMode] != .spaceCommit { Defaults[.commitMode] = .spaceCommit }
    if !Defaults[.enableSentenceAllowDuplicateSingle] { Defaults[.enableSentenceAllowDuplicateSingle] = true }
    if Defaults[.wubiCodeTip] { Defaults[.wubiCodeTip] = false }
    if Defaults[.zKeyQuery] { Defaults[.zKeyQuery] = false }
    if Defaults[.zKeyRepeat] { Defaults[.zKeyRepeat] = false }
}

/// 码表方案的整句资格归一：所选码表无配套整句码表（五笔86/98 等）时
/// 强制关闭整句——面板上该开关是灰的，运行态必须与之一致，
/// 否则老配置残留会把五笔按键码送进虎整句边表，整句全打不中。
func enforceTableSentenceSupport() {
    guard Defaults[.codeMode] == .wubi else { return }
    if Defaults[.enableSentenceMode],
       !SchemaCatalog.supportsSentence(selectedTablePath: Defaults[.wbTablePath]) {
        Defaults[.enableSentenceMode] = false
    }
}

enum CodeInWindowMode: Int, Decodable, Encodable, Defaults.Serializable {
    case inputCode      // 显示输入码（默认）
    case firstCandidate // 显示首选项
}

enum JianQuanMode: Int, CaseIterable, Decodable, Encodable, Defaults.Serializable {
    case normal      // 默认：按码表序显示简码、全码
    case quanAfterJian  // 出简让全：全码候选后置
    case noQuanIfJian   // 出简无全：全码候选取消
}

enum CommitMode: Int, CaseIterable, Decodable, Encodable, Defaults.Serializable {
    case spaceCommit     // 空格上屏
    case uniqueAtN       // N码唯一上屏
    case commitAtM       // 统一第M码顶
    case emptyCodePush   // 空码顶字上屏
    case emptyCodeDirect // 空码直接上屏
    case commitAtM2      // M二顶：第M码时上屏前二码首选
    case commitAtM3      // M三顶：第M码时上屏前三码首选
}

let punctuation: [String: String] = [
    ",": "，",
    ".": "。",
    "/": "/",
    ";": "；",
    "'": "‘",
    "[": "【",
    "]": "】",
    "`": "·",
    "!": "！",
    "@": "@",
    "#": "#",
    "$": "￥",
    "%": "%",
    "^": "^",
    "&": "&",
    "*": "*",
    "(": "（",
    ")": "）",
    "-": "-",
    "_": "_",
    "+": "+",
    "=": "=",
    "~": "~",
    "{": "「",
    "\\": "、",
    "|": "|",
    "}": "」",
    ":": "：",
    "\"": "“",
    "<": "《",
    ">": "》",
    "?": "？"
]

protocol ToastWindowProtocol {
    func show(_ text: String, position: NSPoint)
}
