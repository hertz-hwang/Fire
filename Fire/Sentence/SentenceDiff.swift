//
//  SentenceDiff.swift
//  Fire
//
//  整句候选与首选的字符级差异比对（git diff 风格三色渲染的基础）。
//

import Foundation
import SwiftUI

/// 差异片段的归类：候选侧文字的每一段相对首选（base）的差异类型
enum SentenceDiffKind {
    /// 与首选相同，走主题文字色
    case equal
    /// 等长替换（git diff 里同位置的改写），橙色
    case modified
    /// 候选比首选少字（删除主导的变更块），红色
    case deleted
    /// 候选比首选多字（新增主导的变更块），绿色
    case inserted

    /// git diff 风格配色，浅色/深色主题各自适配
    func color(colorScheme: ColorScheme) -> Color {
        func palette(_ light: String, _ dark: String) -> Color {
            // 十六进制字面量必然可解析，兜底一个橙色避免编译器强迫展开
            let data = ColorData(hex: colorScheme == .dark ? dark : light)
                ?? ColorData(red: 0.89, green: 0.38, blue: 0.04, opacity: 1)
            return Color(data)
        }
        switch self {
        case .equal: return .primary
        case .modified: return palette("#E36209", "#F0883E")
        case .deleted: return palette("#CB2431", "#F85149")
        case .inserted: return palette("#1A7F37", "#3FB950")
        }
    }
}

/// 候选侧文字的一个片段：text 连续、差异类型一致
struct SentenceDiffSegment: Equatable {
    let text: String
    let kind: SentenceDiffKind
}

/// 字符级 diff（LCS 对齐），old = 首选文字，new = 候选文字。
/// 相邻的删/插合并为一个变更块，按块的净长度差归类：
/// 等长 → modified；候选侧短 → deleted；候选侧长 → inserted。
/// 候选侧为空的纯删除块没有可渲染的字符，直接丢弃。
func sentenceDiff(base: String, candidate: String) -> [SentenceDiffSegment] {
    let old = Array(base)
    let new = Array(candidate)
    guard !old.isEmpty || !new.isEmpty else { return [] }

    // LCS 长度表。整句 ≤ 64 字 × 每页 ≤ 10 个候选，每键 DP 开销可忽略
    var lcs = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
    if !old.isEmpty && !new.isEmpty {
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                if old[i] == new[j] {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
    }

    // 回溯出编辑脚本，再聚合成片段：equal 两侧推进，delete/insert 单侧推进
    var segments: [SentenceDiffSegment] = []
    var equalBuf = ""
    var oldRun = "" // 首选侧被替换/删除的字符
    var newRun = "" // 候选侧替换/新增的字符

    func flushEqual() {
        guard !equalBuf.isEmpty else { return }
        segments.append(SentenceDiffSegment(text: equalBuf, kind: .equal))
        equalBuf = ""
    }

    func flushChange() {
        guard !oldRun.isEmpty || !newRun.isEmpty else { return }
        let kind: SentenceDiffKind
        if newRun.count == oldRun.count {
            kind = .modified
        } else if newRun.count < oldRun.count {
            kind = .deleted
        } else {
            kind = .inserted
        }
        if !newRun.isEmpty {
            segments.append(SentenceDiffSegment(text: newRun, kind: kind))
        }
        oldRun = ""
        newRun = ""
    }

    var i = 0
    var j = 0
    while i < old.count && j < new.count {
        if old[i] == new[j] {
            flushChange()
            equalBuf.append(old[i])
            i += 1
            j += 1
        } else if lcs[i + 1][j] >= lcs[i][j + 1] {
            flushEqual()
            oldRun.append(old[i])
            i += 1
        } else {
            flushEqual()
            newRun.append(new[j])
            j += 1
        }
    }
    while i < old.count {
        flushEqual()
        oldRun.append(old[i])
        i += 1
    }
    while j < new.count {
        flushEqual()
        newRun.append(new[j])
        j += 1
    }
    flushChange()
    flushEqual()
    return segments
}
