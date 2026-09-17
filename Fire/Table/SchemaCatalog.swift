//
//  SchemaCatalog.swift
//  Fire
//
//  内置码表目录（Resources/schemas/）扫描：读取每份码表头部三行元数据
//  （#name= / #describe= / #author=），供设置面板生成「码表」下拉选项，
//  并以悬浮提示展示 describe/author。
//
//  码表统一格式：前三行 # 元数据注释，其后每行「候选\t编码」
//  （见 scripts/normalize_schemas.py）。
//

import Foundation
import Defaults

struct SchemaTableInfo: Identifiable, Hashable {
    let name: String
    let describe: String
    let author: String
    let path: String
    /// 码表头部 #visible=（缺省视为可见）：0 不进「码表」下拉，
    /// 如全拼（编码方案选拼音即支持）、整句方案码表（整句开关自动路由）
    let visible: Bool

    var id: String { path }

    /// 悬浮提示内容：描述 + 作者两行
    var tooltip: String {
        var lines: [String] = []
        if !describe.isEmpty { lines.append(describe) }
        if !author.isEmpty { lines.append("作者：\(author)") }
        return lines.joined(separator: "\n")
    }
}

enum SchemaCatalog {
    /// 码表文件扩展名（内容格式一致，仅后缀不同）
    static let supportedExtensions: Set<String> = ["txt", "yaml", "yml", "toml", "conf"]

    /// bundle 内置码表目录 Resources/schemas
    static var schemasDirectory: String {
        Bundle.main.resourceURL?.appendingPathComponent("schemas").path ?? ""
    }

    /// 当前所选码表能否走整句：仅虎/琉璃/琉璃-友版方案有配套整句码表。
    /// 判定口径与 SentenceLexicon.resolveCodesFileName 一致：
    /// 文件名方案标记 → 内容嗅探（高频标记单字的码空间），两者都
    /// 不命中（五笔86/98、潇湘等）即无整句资源，设置面板禁用「整句」。
    static func supportsSentence(selectedTablePath: String) -> Bool {
        let name = (selectedTablePath as NSString).lastPathComponent.lowercased()
        var codesName: String?
        // 友版文件名含 "liuli" 子串，须先于琉璃分支判定
        if name.contains("amrfliuli") || name.contains("友版") {
            codesName = "sentence-codes-amrfliuli.txt"
        } else if name.contains("tiger") || name.contains("虎") {
            codesName = "sentence-codes-tiger.txt"
        } else if name.contains("liuli") || name.contains("琉璃") || name.contains("小叮当") {
            codesName = "sentence-codes-liuli.txt"
        } else {
            // 内容嗅探：琉璃空间 {的:d,是:j} 虎码空间 {的:u,是:o}
            let marks: [(ch: String, liuli: String, tiger: String)] = [
                ("的", "d", "u"), ("是", "j", "o"), ("不", "k", "c"),
                ("了", "l", "r"), ("我", "w", "t"),
            ]
            var liuliHits = 0
            var tigerHits = 0
            if let head = readHead(selectedTablePath, bytes: 65536) {
                for line in head.split(separator: "\n", omittingEmptySubsequences: true) {
                    let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2 else { continue }
                    let text = parts[0]
                    let code = parts[1].trimmingCharacters(in: .whitespaces)
                    for m in marks where text == m.ch {
                        if code == m.liuli { liuliHits += 1 }
                        if code == m.tiger { tigerHits += 1 }
                    }
                    if liuliHits >= 2 || tigerHits >= 2 { break }
                }
            }
            if liuliHits >= 2 && liuliHits > tigerHits {
                codesName = "sentence-codes-liuli.txt"
            } else if tigerHits >= 2 {
                codesName = "sentence-codes-tiger.txt"
            }
        }
        guard let codes = codesName else { return false }
        if FileManager.default.fileExists(atPath: schemasDirectory.appending("/" + codes)) {
            return true
        }
        if let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return FileManager.default.fileExists(
                atPath: supportDir
                    .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Fire")
                    .appendingPathComponent(codes).path
            )
        }
        return false
    }

    /// 扫描内置码表目录，按文件名排序；无 #name 头或 #visible=0 的文件不进选项
    static func builtinTables() -> [SchemaTableInfo] {
        let dir = schemasDirectory
        guard !dir.isEmpty,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: nil
              ) else {
            return []
        }
        return entries
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { meta(path: $0.path) }
            .filter { $0.visible }
    }

    /// 只读文件头部解析元数据；首个非 # 行即停止。
    /// #visible=（缺省视为 1/可见）：0 不进「码表」下拉
    static func meta(path: String) -> SchemaTableInfo? {
        guard let head = readHead(path) else { return nil }

        var name = ""
        var describe = ""
        var author = ""
        var visible = true
        for rawLine in head.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if !line.hasPrefix("#") { break }
            let body = String(line.dropFirst())
            guard let eq = body.firstIndex(of: "=") else { continue }
            let key = String(body[body.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(body[body.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key.lowercased() {
            case "name": name = value
            case "describe": describe = value
            case "author": author = value
            case "visible": visible = value != "0"
            default: break
            }
        }
        guard !name.isEmpty else { return nil }
        return SchemaTableInfo(name: name, describe: describe, author: author,
                               path: path, visible: visible)
    }

    /// 安全读取头部：固定字节数会在 UTF-8 多字节汉字中间劈开
    /// （虎码单字/五笔86版等曾因此在 4096 边界整段解码失败、选项丢失），
    /// 须截到最后一个完整换行再解码。
    private static func readHead(_ path: String, bytes: Int = 8192) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes), !data.isEmpty else { return nil }
        var prefix = data
        if data.count == bytes, let nl = prefix.lastIndex(of: 0x0A) {
            prefix = prefix.subdata(in: prefix.startIndex..<prefix.index(after: nl))
        }
        return String(data: prefix, encoding: .utf8)
    }

    /// 路径是否指向内置码表（目录内文件）
    static func isBuiltin(path: String) -> Bool {
        let dir = schemasDirectory
        guard !path.isEmpty, !dir.isEmpty else { return false }
        return (path as NSString).deletingLastPathComponent == dir
    }

    /// 路径是否指向下拉可见的内置码表：#visible=0 的内置码表
    /// （全拼、整句方案码表等）按「自定义码表」归类显示
    static func isSelectableBuiltin(path: String) -> Bool {
        guard isBuiltin(path: path) else { return false }
        guard let info = meta(path: path) else { return true }
        return info.visible
    }

    /// 老版本把码表平铺在 Resources 根：升级后持久化的旧路径已失效。
    /// 仅迁移仍指向旧 bundle 内置码表的旧值（用户自选的本地码表不动）；
    /// 目标文件不可用时回落默认内置码表。
    static func migrateLegacyTablePaths() {
        let resourceDir = Bundle.main.resourceURL?.path ?? ""
        guard !resourceDir.isEmpty else { return }
        func migrate(_ key: Defaults.Key<String>, fallbackName: String) {
            let path = Defaults[key]
            if path.isEmpty {
                Defaults[key] = schemasDirectory.appending("/" + fallbackName)
                return
            }
            if FileManager.default.fileExists(atPath: path) { return }
            // 路径已失效：仅当旧值曾指向 bundle（老版内置码表平铺在 Resources 根）
            // 或旧目录整体已不存在时才迁移，用户自选且仍存在的本地码表不动
            let legacyBuiltin = (path as NSString).deletingLastPathComponent == resourceDir
                || !FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent)
            let name = legacyBuiltin ? (path as NSString).lastPathComponent : fallbackName
            let candidate = schemasDirectory.appending("/" + name)
            if !name.isEmpty, FileManager.default.fileExists(atPath: candidate) {
                Defaults[key] = candidate
            } else if legacyBuiltin {
                Defaults[key] = schemasDirectory.appending("/" + fallbackName)
            }
        }
        migrate(.wbTablePath, fallbackName: "tiger_table.txt")
        migrate(.pyTablePath, fallbackName: "py_table.txt")
    }
}
