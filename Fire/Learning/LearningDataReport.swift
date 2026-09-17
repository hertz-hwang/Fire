//
//  LearningDataReport.swift
//  Fire
//
//  「查看学习数据」窗口的只读数据载体：把学习系统内存里的计数表
//  （通道 B 字符 n-gram、通道 C1 胜负纠错对）拍平成可直接渲染的行。
//
//  这里只有数据类型与键的编解码，不碰任何存储：取数由
//  LearnerCenter.inspectData 在 fire.learning 串行队列上完成，
//  本文件的静态方法均为纯函数，可在任意线程调用。
//

import Foundation

/// 一次取数的完整结果：四张表 + 汇总信息
///
/// 行按计数降序、各表截断到 limit；`*Entries` 是库里的实际条目数，
/// `*Total` 是当前过滤条件下的匹配数（截断前），界面据此区分
/// 「存量多少」和「这次匹配到多少」。
struct LearningDataReport {
    // MARK: 行模型

    /// 通道 B 一元：某个字被学到的次数
    struct CharRow: Identifiable {
        let char: String
        let count: Double
        var id: String { char }
    }

    /// 通道 B 二元：前字 → 后字
    struct BigramRow: Identifiable {
        let prev: String
        let next: String
        let count: Double
        /// 前字作为上下文的总次数（条件概率分母）
        let total: Double
        var id: String { "\(prev)\u{1F}\(next)" }
    }

    /// 通道 B 三元：前两个字 → 后字
    struct TrigramRow: Identifiable {
        let ctx: String
        let next: String
        let count: Double
        let total: Double
        var id: String { "\(ctx)\u{1F}\(next)" }
    }

    /// 通道 C1 纠错对：某语境某码下的一条胜负证据
    struct CorrectionRow: Identifiable {
        let ctx: String
        let code: String
        let word: String
        let wins: Double
        let losses: Double
        /// 当前生效的边际计分（正 = 加持该词条，负 = 降权）
        let bonus: Double
        var id: String { "\(ctx)\u{1F}\(code)\u{1F}\(word)" }
    }

    // MARK: 表数据

    var chars: [CharRow] = []
    var bigrams: [BigramRow] = []
    var trigrams: [TrigramRow] = []
    var corrections: [CorrectionRow] = []

    // MARK: 汇总

    /// 库里实际的条目数（不受过滤条件影响）
    var charEntries: Int = 0
    var bigramEntries: Int = 0
    var trigramEntries: Int = 0
    var correctionEntries: Int = 0

    /// 当前过滤条件下的匹配条目数（截断前）
    var charTotal: Int = 0
    var bigramTotal: Int = 0
    var trigramTotal: Int = 0
    var correctionTotal: Int = 0

    /// 一元总质量：累计学到的字符转移量（占比列的分母）
    var unigramMass: Double = 0

    var isEmpty: Bool {
        chars.isEmpty && bigrams.isEmpty && trigrams.isEmpty && corrections.isEmpty
    }

    // MARK: - 键编解码与显示

    /// 句首哨兵的显示文本（BOS 是不可打印控制符）
    static let bosText = "句首"

    /// 码点 → 显示文本
    static func text(for value: UInt32) -> String {
        if value == NgramModel.bos { return bosText }
        guard let scalar = UnicodeScalar(value) else { return "?" }
        return String(scalar)
    }

    /// pack2 键 → (前字, 后字)。与 NgramModel.pack2 的 first·2^21 + second 互逆
    static func unpackBigram(_ key: UInt64) -> (prev: UInt32, next: UInt32) {
        (UInt32(truncatingIfNeeded: key / NgramModel.shift),
         UInt32(truncatingIfNeeded: key % NgramModel.shift))
    }

    /// pack3 键 → (前二字, 前一字, 后字)
    static func unpackTrigram(_ key: UInt64) -> (prev2: UInt32, prev1: UInt32, next: UInt32) {
        let next = UInt32(truncatingIfNeeded: key % NgramModel.shift)
        let head = key / NgramModel.shift
        return (UInt32(truncatingIfNeeded: head / NgramModel.shift),
                UInt32(truncatingIfNeeded: head % NgramModel.shift),
                next)
    }

    /// 三元的语境文本：两个字并排，句首哨兵用「句首」占位
    static func contextText(prev2: UInt32, prev1: UInt32) -> String {
        text(for: prev2) + text(for: prev1)
    }
}
