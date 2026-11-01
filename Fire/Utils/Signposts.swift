//
//  Signposts.swift
//  Fire
//
//  按键热路径的 os_signpost 打点：Release 下不采集时开销可忽略，
//  用 Instruments 的 os_signpost 轨道即可看到「按键 → 组字区 → 候选窗」
//  各段的实际耗时。
//

import os

extension OSLog {
    /// 输入热路径：handle / mark / updateCandidates / setCandidates
    static let input = OSLog(subsystem: "com.qwertyyb.fire", category: "input")
}
