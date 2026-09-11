//
//  SentenceTypes.swift
//  Fire
//
//  整句解码的共享数据类型与常量（移植自虎整句 tiger_sentence.lua）。
//

import Foundation

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
    /// 组字区编码上限（≈16 个五笔字）
    static let maxRawLength = 64
    /// 非首选词轻罚系数
    static let rankPenalty = 0.03
    /// 出字奖励，鼓励全覆盖
    static let emittedCharacterReward = 2.0
    /// 整段命中单一最优单字边的额外奖励
    static let wholeInputSingleCharacterReward = 5.0

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

    init(score: Double, confidenceScore: Double, text: String,
         supplementScore: Double, maxRank: Int, edgeCount: Int,
         rawLength: Int, path: SentenceState, segmented: String = "") {
        self.score = score
        self.confidenceScore = confidenceScore
        self.text = text
        self.supplementScore = supplementScore
        self.maxRank = maxRank
        self.edgeCount = edgeCount
        self.rawLength = rawLength
        self.path = path
        self.segmented = segmented
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
}

/// 整句自动上屏的结果：上屏文字 + 组字区保留的原始编码。
struct SentenceAutoCommit {
    let text: String
    let retainedRaw: String
}
