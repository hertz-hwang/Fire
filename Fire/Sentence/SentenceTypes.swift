//
//  SentenceTypes.swift
//  Fire
//
//  整句解码的共享数据类型与常量（移植自虎整句 tiger_sentence.lua）。
//

import Foundation
import Defaults

/// 整句引擎常量，集中照搬虎整句 tiger_sentence.lua 的同名配置，不散落魔法数。
enum SentenceConfig {
    /// beam 宽度
    static let beamWidth = 200
    /// 超过该码长后收窄 beam（长输入跟手的关键）
    /// 实测（真实 528MB 模型 + 琉璃码表，逐键微基准）：全 beam 的解码开销在
    /// len≈20 处越过 2ms、len≥24 起每键 5~25ms（冷解码更高），是长编码卡顿的
    /// 结构性来源。阈值 24→12 后 len≥12 即用窄 beam，逐键回到 ~1ms；
    /// 质量护栏：40 句真实语料探针 top 候选无回归（见 tmp/bench A/B 记录）。
    static let longInputFullBeamLength = 12
    static let longInputBeamWidth = 48
    /// 输出候选上限
    static let candidateLimit = 20
    /// 组字区编码上限——自动上屏开启时 64（≈16 个五笔字，临近上限有概率兜底
    /// 上屏托底，见 nearCapCommitGenerations）；关闭时 256（无兜底的长串手动
    /// 整句，放宽到 256，触顶后新键交回系统）。
    static let autoCommitMaxRawLength = 64
    static let manualMaxRawLength = 256
    static var maxRawLength: Int {
        Defaults[.enableSentenceAutoCommit] ? autoCommitMaxRawLength : manualMaxRawLength
    }
    /// 非首选词轻罚系数
    static let rankPenalty = 0.03
    /// 出字奖励，鼓励全覆盖
    static let emittedCharacterReward = 2.0
    /// 整段命中单一最优单字边的额外奖励
    static let wholeInputSingleCharacterReward = 5.0
    /// 语境压倒性领先阈值（nat）：整码单字重码本该按词库序出字，但左上下文
    /// 非空且模型对某个非首选字的领先超过此值时，改由分数裁决。
    /// 3 nat ≈ 后验 20:1（等价 p(挑战者)/p(码表首选) ≥ 0.95），是"模型确实在
    /// 说话"而不是"排序抖动"的量级：实测（琉璃码表 + mobile 模型，3000 组
    /// 真实码×单字语境）分差中位 2.33、p90 9.53，3 nat 放行 3.8% 的解码。
    static let contextDecisiveLeadNats = 3.0

    // ---- 提前上屏（概率型）----
    /// 前缀成为合格证据的后验占比门槛
    static let earlyCommitMinimumShare = 0.995
    /// 超强确认门槛
    static let earlyCommitStrongShare = 0.99999
    /// 边界闭合门槛
    static let earlyCommitClosedBoundaryShare = 0.99999
    /// 成熟所需连续代数
    static let earlyCommitRequiredEvidence = 3
    /// 连续超强确认可提前成熟
    static let earlyCommitRequiredStrong = 2
    /// 中性间隔最多保留代数（不计证据）
    static let earlyCommitMaximumNeutralGap = 3
    /// 自动上屏后组字区至少保留的键数
    static let earlyCommitRetainedRawLength = 3
    /// 前 4 键永不计入证据
    static let firstKeysImmunity = 4

    // ---- 临近组字区上限的兜底上屏（仅自动上屏开启时有意义）----
    /// 距上限还有这么多代（代 = 键，同 evidence 计数口径）时，若概率/空码
    /// 上屏都未触发，则调低前缀置信阈值并免除成熟代数，立即上屏最优前缀，
    /// 赶在触顶拒键（键漏给系统）之前出字。
    static let nearCapCommitGenerations = 5
    /// 兜底用的前缀置信阈值（正常为 earlyCommitMinimumShare）
    static let nearCapMinimumShare = 0.9

    /// 桶扩张期间提前聚合的阈值
    static let aggregateDuringExpansionThreshold = 128
    /// logp / observed 环形缓存容量
    static let logpCacheLimit = 32768
    static let observedCacheLimit = 32768

    /// 拼音模式码长上限（py_table 有 20 键长条目，全放进去分支太宽）
    static let pinyinMaxCodeLength = 12
    /// 拼音模式每码参与组句的边数上限（建表时截断）。
    /// 拼音码表是自然重码结构：`yi` 有 577 个单字、`shijie` 命中 756 条边，
    /// 单字重码组句（allowDuplicateSingle）放开全 rank 时每个位置扇出上百条边，
    /// beam 扩展组合爆炸——实测 5 键起每键 1~3 秒。建表时截到每码前 8 条
    /// 后逐键回到 avg 6~9ms（cap 12/20 实测 avg 仍 15~55ms，8 是拐点）；
    /// 候选栏最多 9 项一页，8 个重码不影响组句质量探针。
    /// 显式选重（`;`/数字）也只能选中截断范围内的 rank。
    static let pinyinEdgeMaxRank = 8
    /// 码表模式码长硬上限（用户自定义长码保护）
    static let wubiMaxCodeLength = 8
}

/// 词图边：一个词条消耗 len(code) 个键。rank = 词库内同码序号（1 起）。
struct SentenceEdge {
    let text: String
    let rank: Int
    /// 是否是该字的"最优输入码"（最短码），整段命中单字时给额外奖励
    var optimalSingle: Bool = false
}

/// 打分维度拆解（候选栏「显示打分」用）。各项之和恒等于候选的 score。
struct SentenceScoreDimensions {
    /// 通用ngram：通用模型逐字 logp + 结尾 EOS logp
    var generalNgram: Double = 0
    /// 用户ngram：学习通道 B 插值相对通用模型的增量（含 EOS）
    var userNgram: Double = 0
    /// 会话缓存：学习通道 A 加分
    var sessionCache: Double = 0
    /// 加权词：supplement 匹配奖励
    var supplement: Double = 0
    /// 纠错：学习通道 C1 纠错对加分
    var correction: Double = 0
    /// 组句项：出字奖励、词库序轻罚、整码单字奖励等 beam 结构项
    var structural: Double = 0

    /// 候选栏打分串：非零维度按固定顺序拼接（两位小数，正值带 + 号）
    func displayText() -> String {
        var parts: [String] = []
        func append(_ label: String, _ value: Double) {
            guard abs(value) >= 0.005 else { return }
            let sign = value < 0 ? "" : "+"
            parts.append("\(label):\(sign)\(String(format: "%.2f", value))")
        }
        append("通用ngram", generalNgram)
        append("用户ngram", userNgram)
        append("会话缓存", sessionCache)
        append("加权词", supplement)
        append("纠错", correction)
        append("组句项", structural)
        return parts.joined(separator: " ")
    }
}

/// 解码输出候选。path 链回溯出分段码。
final class SentenceCompleted {
    var score: Double
    var confidenceScore: Double
    let text: String
    var supplementScore: Double
    let maxRank: Int
    let edgeCount: Int
    let rawLength: Int
    let path: SentenceState
    var segmented: String
    /// 各维度得分拆解（与 score 同步累计）
    var dimensions: SentenceScoreDimensions

    init(score: Double, confidenceScore: Double, text: String,
         supplementScore: Double, maxRank: Int, edgeCount: Int,
         rawLength: Int, path: SentenceState, segmented: String = "",
         dimensions: SentenceScoreDimensions = SentenceScoreDimensions()) {
        self.score = score
        self.confidenceScore = confidenceScore
        self.text = text
        self.supplementScore = supplementScore
        self.maxRank = maxRank
        self.edgeCount = edgeCount
        self.rawLength = rawLength
        self.path = path
        self.segmented = segmented
        self.dimensions = dimensions
    }
}

/// 前缀证据：某个 (文字前缀, raw 边界) 在后验中的占比。
struct SentencePrefixEvidence {
    let text: String
    let rawLength: Int
    let share: Double
    let boundaryShare: Double
    let boundaryClosed: Bool
    let textCharCount: Int
}

/// 提前上屏证据集合（一次 decode 的产物）。
struct SentenceEarlyEvidence {
    var prefixes: [SentencePrefixEvidence] = []
    var proposal: String = ""
    var proposalShare: Double = 0.0
    var rawLengths: [String: Int] = [:]
    var neutralIncompleteTail: Bool = false
    var mergedIncompleteTail: Bool = false
    var neutralLowConfidence: Bool = false
    var confidenceTruncated: Bool = false
}

/// 每个 (文字前缀, raw 边界) 一个独立 tracker。
final class SentenceTracker {
    let text: String
    let textCharCount: Int
    let rawLength: Int
    var evidenceCount: Int = 0
    var strongCount: Int = 0
    var gapCount: Int = 0
    var lastShare: Double = 0.0

    init(text: String, textCharCount: Int, rawLength: Int) {
        self.text = text
        self.textCharCount = textCharCount
        self.rawLength = rawLength
    }
}

/// 空码上屏的挂起捕获。
struct SentenceEmptyPending {
    let candidateText: String
    let committedText: String
    let baseRawLength: Int
    let lastSegmentStart: Int
}

/// 一次 decode 的结果（候选 + 提前上屏证据）。
struct SentenceDecodeResult {
    var candidates: [SentenceCompleted]
    var evidence: SentenceEarlyEvidence
    /// 本次顺序是被「语境压倒性领先」例外改的（整码单字重码本该按词库序）。
    /// 置位时 rank1 已不是用户看见的首选，依赖"隐式首选 = rank≤1"的兜底路径
    /// （空码上屏）必须换一套资格口径，否则会显示 A 上屏 B。
    var orderedByContextLead: Bool = false
}

/// 整句自动上屏的结果：上屏文字 + 组字区保留的原始编码。
struct SentenceAutoCommit {
    let text: String
    let retainedRaw: String
}
