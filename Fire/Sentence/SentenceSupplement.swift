//
//  SentenceSupplement.swift
//  Fire
//
//  整句加权词匹配器（移植虎整句 tiger_sentence.supplement 的 Aho–Corasick）。
//  词源已并入用户词库：DictManager 里带 weight 的用户词（`[权重] 词条` 行）。
//  命中时按权重给解码加分：reward = 9 + 2·ln(w/1000)，钳位 [0, 16]。
//  与虎整句一致：加分进 score 但不进 massScore（置信度不吃人工权重）。
//

import Foundation

final class SentenceSupplement {
    static let shared = SentenceSupplement()

    // 与 Lua 常量一致
    private static let baselineReward = 9.0
    private static let weightScale = 2.0
    private static let baselineWeight = 1000.0
    private static let maximumReward = 16.0

    /// 词库来源（app 里接 DictManager 用户词；harness 可注入）
    var entriesProvider: () -> [(text: String, weight: Int)] = { [] }

    private struct Node {
        var transitions: [Character: Int] = [:]
        var failure: Int = 0
        var reward: Double = 0.0
    }

    private var nodes: [Node] = [Node()]
    private(set) var count: Int = 0

    private init() {}

    var hasEntries: Bool { count > 0 }

    static func reward(forWeight weight: Int) -> Double {
        let bounded = Swift.max(1, Swift.min(1_000_000_000, weight))
        let reward = baselineReward + weightScale * Foundation.log(Double(bounded) / baselineWeight)
        return Swift.max(0.0, Swift.min(maximumReward, reward))
    }

    /// 从用户词库重载匹配器（generation 换代/词库变更后调用）
    func refresh() {
        refresh(entries: entriesProvider())
    }

    func refresh(entries: [(text: String, weight: Int)]) {
        var built: [Node] = [Node()]
        var inserted = 0
        for (text, weight) in entries {
            let reward = Self.reward(forWeight: weight)
            guard !text.isEmpty, reward > 0 else { continue }
            var state = 0
            for ch in text {
                if let next = built[state].transitions[ch] {
                    state = next
                } else {
                    built.append(Node())
                    let newIndex = built.count - 1
                    built[state].transitions[ch] = newIndex
                    state = newIndex
                }
            }
            built[state].reward = Swift.max(built[state].reward, reward)
            inserted += 1
        }

        // BFS 建 failure 链（Lua supplement.build 同构）
        var queue: [Int] = []
        for child in built[0].transitions.values {
            built[child].failure = 0
            queue.append(child)
        }
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for (ch, child) in built[current].transitions {
                var fallback = built[current].failure
                while fallback != 0 && built[fallback].transitions[ch] == nil {
                    fallback = built[fallback].failure
                }
                let target = built[fallback].transitions[ch]
                built[child].failure = (target != nil && target != child) ? target! : 0
                built[child].reward = Swift.max(built[child].reward,
                                                built[built[child].failure].reward)
                queue.append(child)
            }
        }

        nodes = built
        count = inserted
        if inserted > 0 {
            NSLog("[SentenceSupplement] loaded %d entries (%d nodes)", inserted, built.count)
        }
    }

    /// 逐字推进（Lua supplement.advance）：返回 (新状态, 本字奖励)
    func advance(state: Int, _ ch: Character) -> (state: Int, reward: Double) {
        guard count > 0 else { return (0, 0.0) }
        var current = (state >= 0 && state < nodes.count) ? state : 0
        while current != 0 && nodes[current].transitions[ch] == nil {
            current = nodes[current].failure
        }
        current = nodes[current].transitions[ch] ?? 0
        return (current, nodes[current].reward)
    }
}
