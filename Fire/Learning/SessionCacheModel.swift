//
//  SessionCacheModel.swift
//  Fire
//
//  通道 A：会话缓存语言模型（Kuhn & De Mori cache LM 的轻量版）。
//  滚动窗口内的字符一元/二元精确计数——旧字符随窗口滑出自动失效，
//  新近度效果由窗口有界性天然产生，无须额外衰减。
//
//  生命周期挂在 SentenceDecoder（per-controller 会话）上：
//  跨 clean()/自动上屏存活（同 contextSegments 语义），切换输入框时清空。
//  只加持不惩罚：命中给正奖励，未命中为零。
//

import Foundation

final class SessionCacheModel {
    private var window: [UInt32] = []
    /// 一元计数（窗口内精确计数）
    private var unigramCounts: [UInt32: Int] = [:]
    /// 二元触发计数 pack2(prev1, target)
    private var bigramCounts: [UInt64: Int] = [:]

    private let limit: Int

    init(limit: Int = 1500) {
        self.limit = max(64, limit)
    }

    var isEmpty: Bool { window.isEmpty }

    var charCount: Int { window.count }

    /// 记录一段已插入文档的文字（insertText 单一漏斗调用）
    func record(_ text: String) {
        for scalar in text.unicodeScalars {
            append(scalar.value)
        }
    }

    /// 撤销：从窗口尾部回退一段文字。尾部不匹配时保守忽略
    ///（中间可能已插入其它内容，窗口近似语义允许误差）
    func removeLast(_ text: String) {
        let scalars = Array(text.unicodeScalars.reversed()).map { $0.value }
        for value in scalars {
            guard let last = window.last, last == value else { return }
            window.removeLast()
            bumpUnigram(value, by: -1)
            if let prevTail = window.last {
                // 被弹元素入窗时记的二元配对是 (前驱 → 它)
                bumpBigram(prev: prevTail, target: value, by: -1)
            }
        }
    }

    /// 清空（切换输入框/客户端时）
    func clear() {
        window.removeAll(keepingCapacity: true)
        unigramCounts.removeAll(keepingCapacity: true)
        bigramCounts.removeAll(keepingCapacity: true)
    }

    /// 解码期加分：`w · clamp(log(1+c2) + f·log(1+c1), 0, cap)`。
    /// c2 = 二元触发 (prev1, target) 计数，c1 = 一元触发计数。
    @inline(__always)
    func reward(prev1: UInt32, target: UInt32, weight: Double,
                maxReward: Double, unigramFactor: Double) -> Double {
        var value = 0.0
        if let c2 = bigramCounts[NgramModel.pack2(UInt64(prev1), UInt64(target))], c2 > 0 {
            value += Foundation.log(1.0 + Double(c2))
        }
        if let c1 = unigramCounts[target], c1 > 0 {
            value += unigramFactor * Foundation.log(1.0 + Double(c1))
        }
        guard value > 0 else { return 0.0 }
        let capped = Swift.min(maxReward, value)
        return weight * capped
    }

    // MARK: - 私有

    private func append(_ value: UInt32) {
        let prev1 = window.last
        window.append(value)
        bumpUnigram(value, by: 1)
        if let p = prev1 {
            bumpBigram(prev: p, target: value, by: 1)
        }
        if window.count > limit {
            evictOldest()
        }
    }

    /// 窗口头部滑出：老元素的一元退掉，它作为前驱的二元 (oldest → 新首) 同时失效
    private func evictOldest() {
        let oldest = window.removeFirst()
        bumpUnigram(oldest, by: -1)
        if let successor = window.first {
            bumpBigram(prev: oldest, target: successor, by: -1)
        }
    }

    private func bumpUnigram(_ value: UInt32, by delta: Int) {
        let next = (unigramCounts[value] ?? 0) + delta
        if next <= 0 {
            unigramCounts.removeValue(forKey: value)
        } else {
            unigramCounts[value] = next
        }
    }

    private func bumpBigram(prev: UInt32, target: UInt32, by delta: Int) {
        let key = NgramModel.pack2(UInt64(prev), UInt64(target))
        let next = (bigramCounts[key] ?? 0) + delta
        if next <= 0 {
            bigramCounts.removeValue(forKey: key)
        } else {
            bigramCounts[key] = next
        }
    }
}
