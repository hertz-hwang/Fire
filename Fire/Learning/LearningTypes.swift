//
//  LearningTypes.swift
//  Fire
//
//  学习系统的共享类型：提交信号、调参常量、解码端只读快照。
//
//  设计约束（与 SentenceDecoder 的 massScore 语义对齐）：
//  - 学习项只进排序 score，永不进 massScore（自动上屏证据的校准不动）；
//  - 无数据/关闭时解码路径与未接入学习系统逐位一致（快路径零开销）；
//  - 学习只重排词表已有边，不产生新候选。
//

import Foundation
import Defaults

/// 一次上屏的学习信号（从 candidateInserted / commitUndone 通知解析）。
struct CommitSignal {
    let text: String
    /// 原始编码（normalize 前，学习端自行 normalize）
    let code: String
    /// 候选类型（wb/py/user/sentence）
    let type: String
    /// 可见候选列表中的命中序号（0 = 首选；自动上屏恒为 0）
    let rank: Int
    /// 被放弃的首选文字（rank == 0 时为空串）
    let top1Text: String
    /// 会话上下文末尾 ≤2 字（纠错对语境键）
    let ctx: String
    let appBundleId: String
    /// 上屏时间（衰减计算用）
    let timestamp: Date
    /// 是否撤销信号（撤销 = 负样本，计数回退）
    let undone: Bool

    /// 是否值得进字符级 n-gram：跳过占位与纯 ASCII（原样上屏的英文/编码串）
    var hasLearnableChars: Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}

/// 学习通道调参常量。ReplayTuner 离线回放调出的参数档可整体替换
/// （阶段 5），在线只读这一份。
struct LearningTuning {
    // ---- 通道 B：字符级用户 n-gram（置信度门控插值）----
    /// 插值权重上限：用户数据再自信也压不死通用模型
    var userNgramAlphaMax: Double = 0.35
    /// α = c(ctx)/(c(ctx)+K)：该上下文见得越多越信用户数据
    var userNgramContextK: Double = 8.0
    /// 用户三元计数的绝对折扣 D（向用户二元回退）
    var userNgramTrigramD: Double = 4.0
    /// 用户二元计数的绝对折扣 D（向用户一元回退）
    var userNgramBigramD: Double = 2.0
    /// 用户一元向通用一元回退的质量 K
    var userNgramUnigramK: Double = 4.0
    /// 计数半衰期（天）：久远的习惯自然淡出
    var userNgramHalfLifeDays: Double = 30.0
    /// 清扫阈值：衰减后计数低于它即遗忘
    var userNgramMinCount: Double = 1.5
    /// 条目容量上限（超过按衰减后计数从低到高淘汰）
    var userNgramMaxEntries: Int = 200_000

    // ---- 通道 A：会话缓存 ----
    /// 窗口大小（字符数）：近似"当前正在写的内容"
    var cacheWindowLimit: Int = 1500
    var cacheWeight: Double = 0.8
    /// 单字奖励上限：缓存只加持不惩罚，且封顶防止淹没通用模型
    var cacheMaxReward: Double = 1.5
    /// 一元触发相对二元触发的权重
    var cacheUnigramFactor: Double = 0.6

    // ---- 通道 C1：胜负纠错对 ----
    var correctionWeight: Double = 1.2
    /// 负证据（被弃首选）相对正证据的强度
    var correctionLossLambda: Double = 0.6
    /// 边际计分的平滑分母
    var correctionK: Double = 2.0
    /// 单项纠错加分的绝对上限
    var correctionCap: Double = 4.0
    /// 纠错对条目容量上限
    var correctionMaxEntries: Int = 50_000

    /// 用户强度滑杆（0.2~2.0），线性缩放各通道权重
    var strength: Double = 1.0

    static func fromDefaults() -> LearningTuning {
        var tuning = LearningTuning()
        var s = Defaults[.learningStrength]
        if s < 0.2 { s = 0.2 }
        if s > 2.0 { s = 2.0 }
        tuning.strength = s
        return tuning
    }
}

/// 解码端消费的只读快照。LearnerCenter 在防抖 flush 后整体替换，
/// generation 换代时 decoder 作废增量 lattice。
final class LearningSnapshot {
    static let empty = LearningSnapshot(generation: 0, ngram: nil)

    let generation: Int
    /// 通道 B 数据（nil = 无用户 n-gram，解码走纯通用模型快路径）
    let ngram: UserCharNgramData?

    init(generation: Int, ngram: UserCharNgramData?) {
        self.generation = generation
        self.ngram = ngram
    }
}
