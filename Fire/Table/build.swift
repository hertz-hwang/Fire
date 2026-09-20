//
//  build.swift
//  Fire
//
//  Created by 虚幻 on 2020/10/24.
//  Copyright © 2020 qwertyyb. All rights reserved.
//

import AppKit
import Defaults

func getDatabaseURL () -> URL {
    guard let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return URL(fileURLWithPath: "")
    }
    let appDir = supportDir.appendingPathComponent(Bundle.main.bundleIdentifier!)
    if !FileManager.default.fileExists(atPath: appDir.path) {
        print("create support directory")
        try? FileManager.default.createDirectory(
            atPath: appDir.path,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    let dbURL = appDir.appendingPathComponent("dict.sqlite")
    return dbURL
}

func execTableBuilder(arguments: [String]) -> Bool {
    guard var url = Bundle.main.executableURL else {
        return false
    }
    url.deleteLastPathComponent()
    url = url.appendingPathComponent("TableBuilder")
    let task = Process()
    task.launchPath = url.path
    task.arguments = arguments
    task.launch()
    task.waitUntilExit()
    if task.terminationStatus == .zero {
        print("exec successfully")
        return true
    } else {
        print("exec fail")
        return false
    }
}

/// 进 sqlite 混输索引的拼音词条上限。
///
/// 五笔拼音混输走的是 `wb_py_dict` 的 `query glob 'xxx*'`：`group by text` 要聚合全部
/// 命中行，所以每次敲键的开销正比于「以这几个键开头的词条数」，而不是候选框那几条。
/// 四十多万条全量进表后，单字母查询从 2.7ms 顶到 32ms，混输每一键都要付这笔钱；
/// 取词频最高的 15 万条（旧明文表是 8.2 万条）把每一键拉回旧量级，混输本来也只需要常词。
/// 拼音模式不吃这一刀：它查 `.hdict` 建的音节索引（`PinyinLexicon`），整词库全用得上。
let mixedInputDictRows = 150_000

func buildTable(txtPath: String, tableName: String = "wb_dict", sqliteRowLimit: Int = 0) -> Bool {
    var dbTempURL = getDatabaseURL()
    dbTempURL.appendPathExtension("ing")
    // 两个理由要先把码表落一份明文：
    //   1. `.hdict` 容器 —— TableBuilder 只认两列明文（第三列词频会被它的行格式校验
    //      当成非法编码、整表判空），先剥列导出；词频不进 sqlite，同码重码的次序
    //      靠行 id（= 容器里的词频降序），与拼音侧的 rank 同一口径。
    //   2. `sqliteRowLimit` —— 只收最常用的前 N 条（见 `mixedInputDictRows`）。
    var exported: URL?
    var sourcePath = txtPath
    if sqliteRowLimit > 0 || HDict.isHDict(path: txtPath) {
        let dump = dbTempURL.deletingLastPathComponent()
            .appendingPathComponent("table-src-\(tableName).txt")
        guard let rows = HDict.exportText(at: txtPath, columns: 2, to: dump,
                                          limit: sqliteRowLimit) else {
            print("[Fire] 码表导出失败：\(txtPath)")
            return false
        }
        print("[Fire] \((txtPath as NSString).lastPathComponent) → \(tableName) 导出 \(rows) 行")
        exported = dump
        sourcePath = dump.path
    }
    defer { if let exported = exported { try? FileManager.default.removeItem(at: exported) } }
    return execTableBuilder(arguments: [
        "--create-dict",
        sourcePath,
        tableName,
        dbTempURL.path
    ])
}

func combineTableList(wbTable: String = "wb_dict", pyTable: String = "py_dict") -> Bool {
    var dbTempURL = getDatabaseURL()
    dbTempURL.appendPathExtension("ing")
    return execTableBuilder(arguments: [
        "--combine-dict",
        dbTempURL.path,
        wbTable,
        pyTable
    ])
}

func beforeBuildDict() {
    var dbTempURL = getDatabaseURL()
    dbTempURL.appendPathExtension("ing")
    try? FileManager.default.removeItem(at: dbTempURL)
}

func afterBuildDict() {
    print("update dict with new")
    var bkURL = getDatabaseURL()
    bkURL.appendPathExtension("bk")

    let dbURL = getDatabaseURL()

    try? FileManager.default.removeItem(at: bkURL)
    try? FileManager.default.moveItem(at: dbURL, to: bkURL)
    try? FileManager.default.moveItem(at: getDatabaseURL().appendingPathExtension("ing"), to: dbURL)
}

func buildDict() {
    beforeBuildDict()

    let wbPath = Defaults[.wbTablePath]
    let pyPath = Defaults[.pyTablePath]

    let wb = buildTable(txtPath: wbPath, tableName: "wb_dict")
    let py = buildTable(txtPath: pyPath, tableName: "py_dict", sqliteRowLimit: mixedInputDictRows)
    let cb = combineTableList(wbTable: "wb_dict", pyTable: "py_dict")

    print(wb, py, cb)
    if wb && py && cb {
        afterBuildDict()
    }
}

func hasDict() -> Bool {
    return FileManager.default.fileExists(atPath: getDatabaseURL().path)
}
