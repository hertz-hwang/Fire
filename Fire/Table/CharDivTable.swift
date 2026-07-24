//
//  CharDivTable.swift
//  Fire
//
//  Created by Kiro on 2026/7/24.
//  Copyright © 2026 qwertyyb. All rights reserved.
//

import Foundation
import Defaults

struct CharDivInfo {
    let char: String
    let roots: String
    let radicalCode: String
    let pinyin: [String]
    let unicodeArea: String
    let fullCode: String
}

class CharDivTable {
    static let shared = CharDivTable()

    private var table: [String: CharDivInfo] = [:]
    private var loadedPath: String?

    private init() {}

    private func parseLine(_ line: String) -> CharDivInfo? {
        if line.isEmpty || line.hasPrefix("#") {
            return nil
        }
        let columns = line.components(separatedBy: "\t")
        guard columns.count == 3 else { return nil }

        let char = columns[0]
        var mid = columns[1]
        guard mid.hasPrefix("("), mid.hasSuffix(")") else { return nil }
        mid.removeFirst()
        mid.removeLast()
        let parts = mid.components(separatedBy: ",")
        guard parts.count == 4 else { return nil }

        let pinyin = parts[2].isEmpty ? [] : parts[2].components(separatedBy: "_")

        return CharDivInfo(
            char: char,
            roots: parts[0],
            radicalCode: parts[1],
            pinyin: pinyin,
            unicodeArea: parts[3],
            fullCode: columns[2]
        )
    }

    private func load(path: String) -> [String: CharDivInfo] {
        guard !path.isEmpty,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        var result: [String: CharDivInfo] = [:]
        content.enumerateLines { line, _ in
            if let info = self.parseLine(line) {
                result[info.char] = info
            }
        }
        return result
    }

    func reload() {
        let path = Defaults[.charDivTablePath]
        table = load(path: path)
        loadedPath = path
        fireLog("[CharDivTable] reloaded, path: \(path), count: \(table.count)")
    }

    func lookup(_ char: String) -> CharDivInfo? {
        let path = Defaults[.charDivTablePath]
        if loadedPath != path {
            reload()
        }
        return table[char]
    }
}
