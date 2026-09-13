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
    // 单字重码组句（虎整句 tiger_sentence_allow_duplicate_single）：
    // 开启时分段路径允许同码非首选单字参与组句；多字非首选仍需显式选重
    static let enableSentenceAllowDuplicateSingle = Key<Bool>("enableSentenceAllowDuplicateSingle", default: true)
    // 整句 n-gram 模型覆盖路径（空表示用内置 Resources 里的模型）
    static let sentenceModelPath = Key<String>("sentenceModelPath", default: "")
    // N-gram留存信息数（0/1/2）：自动上屏后保留最近 N 次上屏文本的文字信息，
    // 作为后续组句的左上下文（否则「回」已上屏，接着打 gbmqbk 组不出承前的句子）
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
    static let jianQuanMode = Key<JianQuanMode>("jianQuanMode", default: JianQuanMode.normal)

    // 中英文切换配置
    // 禁止切换英文
    static let disableEnMode = Key<Bool>("diableEnMode", default: false)
    // 禁止;键临时英文模式
    static let disableTempEnMode = Key<Bool>("disableTempEnMode", default: false)
    // 切换英文模式的按键
    static let toggleInputModeKey = Key<ModifierKey>("toggleInputModeKey", default: ModifierKey.shift)
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

    init(code: String, text: String, type: CandidateType, label: String? = nil) {
        self.code = code
        self.text = text
        self.type = type
        self.label = label ?? text
    }
}

enum CodeMode: Int, CaseIterable, Decodable, Encodable, Defaults.Serializable {
    case wubi
    case pinyin
    case wubiPinyin
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
