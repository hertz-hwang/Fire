//
//  DictManager.swift
//  Fire
//
//  Created by 虚幻 on 2022/7/2.
//  Copyright © 2022 qwertyyb. All rights reserved.
//

import Foundation
import Defaults

class DictManager {
    static let shared = DictManager()
    static let userDictUpdated = Notification.Name("DictManager.userDictUpdated")

    let tempEnTriggerPunctuation: Character = ";"
    let userDictFilePath = NSSearchPathForDirectoriesInDomains(
        .applicationSupportDirectory,
        .userDomainMask, true).first! + "/" + Bundle.main.bundleIdentifier! + "/user-dict.txt"

    private var database: OpaquePointer?
    private var queryStatement: OpaquePointer?
    private var reverseLookupStatement: OpaquePointer?

    private init() {
        Defaults.observe(keys: .codeMode, .candidateCount) { () in
            self.prepareStatement()
        }
        .tieToLifetime(of: self)
        // 整句词图跟随编码模式/词库变化
        Defaults.observe(keys: .codeMode) { () in
            SentenceLexicon.shared.markDirty()
        }
        .tieToLifetime(of: self)
        NotificationCenter.default.addObserver(
            forName: DictManager.userDictUpdated, object: nil, queue: .main) { _ in
            SentenceLexicon.shared.markDirty()
        }
    }
    deinit {
        close()
    }
    func reinit() {
        close()
        prepareStatement()
    }
    func close() {
        invalidateUserDictCache()
        sqlite3_finalize(queryStatement)
        queryStatement = nil
        sqlite3_finalize(reverseLookupStatement)
        reverseLookupStatement = nil
        // 总数语句的 SQL 携带 codeMode 过滤，随 close/reinit 一并重建
        sqlite3_finalize(candidatesCountStatement)
        candidatesCountStatement = nil
        sqlite3_finalize(reverseCountStatement)
        reverseCountStatement = nil
        sqlite3_close_v2(database)
        sqlite3_shutdown()
        database = nil
    }

    private func getStatementSql() -> String {
        let codeMode = Defaults[.codeMode]
        // 比显示的候选词数量多查一个，以此判断有没有下一页；limit 通过 :limit 参数传入
        let sql = """
            select
                \(codeMode == .wubiPinyin ? "max(wbcode)" : "min(wbcode)"),
                text,
                type, min(query) as query
            from wb_py_dict
            where query glob :queryLike \(
                codeMode == .wubi ? "and type in ('wb', 'user')"
                                : codeMode == .pinyin ? "and type in ('py', 'user')" : "")
            group by text
            order by query, id
            limit :offset, :limit
        """
        return sql
    }

    private func prepareStatement() {
        invalidateUserDictCache()
        if database == nil {
            sqlite3_open_v2(getDatabaseURL().path, &database, SQLITE_OPEN_READWRITE, nil)
            sqlite3_exec(database, "PRAGMA case_sensitive_like=ON;", nil, nil, nil)
            migrateUserDictWeight()
        }
        if queryStatement != nil {
            sqlite3_finalize(queryStatement)
            queryStatement = nil
        }
        if sqlite3_prepare_v2(database, getStatementSql(), -1, &queryStatement, nil) == SQLITE_OK {
            print("prepare ok")
        } else if let err = sqlite3_errmsg(database) {
            print("prepare fail: \(err)")
        }
        prepareReverseLookupStatement()
    }

    private func prepareReverseLookupStatement() {
        if reverseLookupStatement != nil {
            sqlite3_finalize(reverseLookupStatement)
            reverseLookupStatement = nil
        }
        let candidateCount = Defaults[.candidateCount]
        let sql = """
            select min(wbcode), text, type, min(query) as query
            from wb_py_dict
            where query glob :queryLike and type = 'py'
            group by text
            order by query, id
            limit :offset, \(candidateCount + 1)
        """
        if sqlite3_prepare_v2(database, sql, -1, &reverseLookupStatement, nil) == SQLITE_OK {
            print("reverse lookup prepare ok")
        } else if let err = sqlite3_errmsg(database) {
            print("reverse lookup prepare fail: \(err)")
        }
    }

    private func getMinIdFromDictTable() -> Int {
        let sql = "select min(id) from wb_py_dict"
        var queryStmt: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &queryStmt, nil) == SQLITE_OK {
            if sqlite3_step(queryStmt) == SQLITE_ROW {
                let minId = sqlite3_column_int(queryStmt, 0)
                sqlite3_finalize(queryStmt)
                queryStmt = nil
                return Int(minId)
            }
        }
        fireLog("[Fire.getMinIdFromDictTable] errmsg: \(String(cString: sqlite3_errmsg(queryStmt)))")
        sqlite3_finalize(queryStmt)
        queryStmt = nil
        return 0
    }

    // 日期变量替换用的 formatter，复用而非每次 new（DateFormatter 创建开销大）
    private static let varDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy MM dd HH mm ss"
        return formatter
    }()

    private func replaceTextWithVars(_ text: String) -> String {
        // 绝大多数用户词不含 {xxx} 变量，直接跳过，避免每个候选都做日期格式化 + 6 次字符串替换
        guard text.contains("{") else { return text }
        let arr = DictManager.varDateFormatter.string(from: Date()).split(separator: " ")
        let vars: [String: String] = [
            "{yyyy}": String(arr[0]),
            "{MM}": String(arr[1]),
            "{dd}": String(arr[2]),
            "{HH}": String(arr[3]),
            "{mm}": String(arr[4]),
            "{ss}": String(arr[5])
        ]
        var newText = text
        vars.forEach { (key, val) in
            newText = newText.replacingOccurrences(of: key, with: val)
        }
        fireLog("[replaceTextWithVars] \(text), \(newText)")
        return newText
    }

    private func getQueryLike(_ origin: String) -> String {
        if origin.isEmpty {
            return origin
        }

        // 关闭提示编码时，精确匹配当前编码
        if !Defaults[.wubiCodeTip] {
            return origin
        }

        if !Defaults[.zKeyQuery] {
            return origin + "*"
        }

        // z键查询，z不能放在首位
        let first = origin.first!
        return String(first) + (String(origin.suffix(origin.count - 1))
            .replacingOccurrences(of: "z", with: "?")) + "*"
    }

    func punctuationCandidates(query: String) -> [Candidate] {
        let text = query.count == 1 ? query : String(query.suffix(query.count - 1))
        return [Candidate(
            code: query,
            text: text,
            type: .placeholder,
            label: "临时英文(空格输出半角符号,连敲;键两下输出全角符号)")]
    }

    // 批量查询每个字词在码表里的最短 wbcode 长度，用于简全模式判断
    private func getMinWbcodeLengthMap(texts: [String]) -> [String: Int] {
        guard !texts.isEmpty else { return [:] }
        let placeholders = texts.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT text, min(length(wbcode)) FROM wb_py_dict WHERE text IN (\(placeholders)) AND type IN ('wb', 'user') GROUP BY text"
        var stmt: OpaquePointer?
        var result = [String: Int]()
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            for (i, t) in texts.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), t, -1, SQLITE_TRANSIENT)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let text = String(cString: sqlite3_column_text(stmt, 0))
                let minLen = Int(sqlite3_column_int(stmt, 1))
                result[text] = minLen
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    func getCandidates(query: String = String(), page: Int = 1) -> (candidates: [Candidate], hasNext: Bool) {
        if query.count <= 0 {
            return ([], false)
        }
        if query.first == tempEnTriggerPunctuation {
            return (candidates: punctuationCandidates(query: query), hasNext: false)
        }
        fireLog("[DictManager] getCandidates origin: \(query)")
        let startTime = CFAbsoluteTimeGetCurrent()
        let queryLike = getQueryLike(query)
        var candidates: [Candidate] = []
        sqlite3_reset(queryStatement)
        sqlite3_clear_bindings(queryStatement)
        sqlite3_bind_text(queryStatement,
                        sqlite3_bind_parameter_index(queryStatement, ":code"),
                        query, -1,
                        SQLITE_TRANSIENT
        )
        sqlite3_bind_text(queryStatement,
                          sqlite3_bind_parameter_index(queryStatement, ":queryLike"),
                          queryLike, -1,
                          SQLITE_TRANSIENT
        )
        sqlite3_bind_int(queryStatement,
                         sqlite3_bind_parameter_index(queryStatement, ":offset"),
                         Int32((page - 1) * Defaults[.candidateCount])
        )
        let count = Defaults[.candidateCount]
        let jianQuanMode = Defaults[.jianQuanMode]
        // 出简让全/出简无全模式下多取数据，过滤后再截取
        let fetchLimit = jianQuanMode == .normal ? count + 1 : count * 4 + 1
        sqlite3_bind_int(queryStatement,
                         sqlite3_bind_parameter_index(queryStatement, ":limit"),
                         Int32(fetchLimit)
        )
        while sqlite3_step(queryStatement) == SQLITE_ROW {
            let code = String.init(cString: sqlite3_column_text(queryStatement, 0))
            var text = String.init(cString: sqlite3_column_text(queryStatement, 1))
            let type = CandidateType(rawValue: String.init(cString: sqlite3_column_text(queryStatement, 2)))!
            if type == .user {
                text = replaceTextWithVars(text)
            }
            let candidate = Candidate(code: code, text: text, type: type)
            candidates.append(candidate)
        }
        if jianQuanMode != .normal {
            let queryLen = query.count
            // 批量查询每个候选词在码表里的最短编码长度
            let texts = candidates.map { $0.text }
            let minCodeLenMap = getMinWbcodeLengthMap(texts: texts)
            switch jianQuanMode {
            case .quanAfterJian:
                let noJian = candidates.filter { (minCodeLenMap[$0.text] ?? queryLen) >= queryLen }
                let hasJian = candidates.filter { (minCodeLenMap[$0.text] ?? queryLen) < queryLen }
                candidates = noJian + hasJian
            case .noQuanIfJian:
                candidates = candidates.filter { (minCodeLenMap[$0.text] ?? queryLen) >= queryLen }
            default:
                break
            }
        }
        let allCount = candidates.count
        candidates = Array(candidates.prefix(count))

        if candidates.isEmpty {
            candidates.append(Candidate(code: query, text: query, type: CandidateType.placeholder))
        }
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        fireLog("[DictManager] getCandidates query: \(query) , duration: \(duration)")
        return (candidates, hasNext: allCount > count)
    }

    func getReverseLookupCandidates(query: String, page: Int = 1) -> (candidates: [Candidate], hasNext: Bool) {
        if query.isEmpty { return ([], false) }
        let queryLike = query + "*"
        var rawCandidates: [(wbcode: String, text: String)] = []
        sqlite3_reset(reverseLookupStatement)
        sqlite3_clear_bindings(reverseLookupStatement)
        sqlite3_bind_text(reverseLookupStatement,
                          sqlite3_bind_parameter_index(reverseLookupStatement, ":queryLike"),
                          queryLike, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(reverseLookupStatement,
                         sqlite3_bind_parameter_index(reverseLookupStatement, ":offset"),
                         Int32((page - 1) * Defaults[.candidateCount]))
        while sqlite3_step(reverseLookupStatement) == SQLITE_ROW {
            let wbcode = String(cString: sqlite3_column_text(reverseLookupStatement, 0))
            let text = String(cString: sqlite3_column_text(reverseLookupStatement, 1))
            rawCandidates.append((wbcode: wbcode, text: text))
        }
        let count = Defaults[.candidateCount]
        let allCount = rawCandidates.count
        let pageCandidates = Array(rawCandidates.prefix(count))

        // Collect all unique characters across all candidate texts for a single batch lookup
        var uniqueChars = Set<String>()
        for c in pageCandidates {
            c.text.unicodeScalars.forEach { uniqueChars.insert(String($0)) }
        }

        // One batch query to get the full wubi code (max = longest = full 4-char code) for each char
        var charCodeMap = [String: String]()
        if !uniqueChars.isEmpty {
            let placeholders = uniqueChars.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT text, max(wbcode) FROM wb_py_dict WHERE text IN (\(placeholders)) AND type='wb' GROUP BY text"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
                for (i, ch) in uniqueChars.enumerated() {
                    sqlite3_bind_text(stmt, Int32(i + 1), ch, -1, SQLITE_TRANSIENT)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let ch = String(cString: sqlite3_column_text(stmt, 0))
                    let code = String(cString: sqlite3_column_text(stmt, 1))
                    charCodeMap[ch] = code
                }
            }
            sqlite3_finalize(stmt)
        }

        let candidates = pageCandidates.map { raw -> Candidate in
            let charCodes = raw.text.unicodeScalars.compactMap { charCodeMap[String($0)] }
            // word-level code first, then individual char codes: "flol|flll olgu"
            let displayCode = raw.wbcode + (charCodes.isEmpty ? "" : " | " + charCodes.joined(separator: " "))
            return Candidate(code: displayCode, text: raw.text, type: .py)
        }
        return (candidates, hasNext: allCount > count)
    }

    /// 候选总数查询（页码指示用）：按 text 去重后的命中总数，结果按查询串缓存。
    /// 仅多页菜单才会调用，单页路径零开销。
    private var candidatesCountStatement: OpaquePointer?
    private var reverseCountStatement: OpaquePointer?
    private var candidatesCountCache: [String: Int] = [:]

    private func clearCandidatesCountCache() {
        candidatesCountCache.removeAll()
    }

    /// 常规码表候选总数：与 getStatementSql 同一过滤条件（query glob + codeMode 类型过滤）按 text 去重
    func getCandidatesCount(query: String) -> Int {
        if query.isEmpty { return 0 }
        let key = "c\(Defaults[.codeMode].rawValue)|\(query)"
        return cachedCandidatesCount(key: key, sql: {
            let codeMode = Defaults[.codeMode]
            return """
                select count(*) from (
                    select text from wb_py_dict
                    where query glob :queryLike \(
                        codeMode == .wubi ? "and type in ('wb', 'user')"
                        : codeMode == .pinyin ? "and type in ('py', 'user')" : "")
                    group by text
                )
                """
        }(), queryLike: getQueryLike(query), statement: &candidatesCountStatement)
    }

    /// 反查候选总数（拼音查五笔，type = 'py'）
    func getReverseLookupCandidatesCount(query: String) -> Int {
        if query.isEmpty { return 0 }
        let key = "r\(query)"
        return cachedCandidatesCount(
            key: key,
            sql: """
                select count(*) from (
                    select text from wb_py_dict
                    where query glob :queryLike and type = 'py'
                    group by text
                )
                """,
            queryLike: query + "*",
            statement: &reverseCountStatement)
    }

    private func cachedCandidatesCount(
        key: String, sql: String, queryLike: String,
        statement: inout OpaquePointer?
    ) -> Int {
        if let cached = candidatesCountCache[key] { return cached }
        if statement == nil {
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                fireLog("[DictManager] prepare count statement fail: \(String(cString: sqlite3_errmsg(database)))")
                return 0
            }
        }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement,
                          sqlite3_bind_parameter_index(statement, ":queryLike"),
                          queryLike, -1, SQLITE_TRANSIENT)
        var total = 0
        if sqlite3_step(statement) == SQLITE_ROW {
            total = Int(sqlite3_column_int(statement, 0))
        }
        // 缓存加上限，避免超长会话无限增长
        if candidatesCountCache.count > 512 {
            clearCandidatesCountCache()
        }
        candidatesCountCache[key] = total
        return total
    }

    func setCandidateToFirst(query: String, candidate: Candidate) {
        let newCandidate = Candidate(code: query, text: candidate.text, type: CandidateType.user)
        _ = prependCandidate(candidate: newCandidate)
        NotificationQueue.default.enqueue(Notification(name: DictManager.userDictUpdated), postingStyle: .whenIdle)
    }

    func prependCandidate(candidate: Candidate) -> Bool {
        // 顶置用户词：权重置 NULL（顶置本身就是最高优先级，不叠加整句权重）
        let sql = columnExists("weight")
            ? """
            insert into wb_py_dict(id, wbcode, text, type, query, weight)
            values (
                (select MIN(id) - 1 from wb_py_dict), :code, :text, :type, :code, NULL
            );
        """
            : """
            insert into wb_py_dict(id, wbcode, text, type, query)
            values (
                (select MIN(id) - 1 from wb_py_dict), :code, :text, :type, :code
            );
        """
        var insertStatement: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &insertStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(insertStatement,
                sqlite3_bind_parameter_index(insertStatement, ":code"),
                              candidate.code, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insertStatement,
                              sqlite3_bind_parameter_index(insertStatement, ":text"),
                              candidate.text, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insertStatement,
                              sqlite3_bind_parameter_index(insertStatement, ":type"),
                              CandidateType.user.rawValue, -1, SQLITE_TRANSIENT)
            if sqlite3_step(insertStatement) == SQLITE_DONE {
                sqlite3_finalize(insertStatement)
                insertStatement = nil
                invalidateUserDictCache()
                return true
            }
        }
        sqlite3_finalize(insertStatement)
        insertStatement = nil
        print("errmsg: \(String(cString: sqlite3_errmsg(database)!))")
        return false
    }

    func deleteCandidate(_ candidate: Candidate) {
        // candidate.code 实际取自 wb_py_dict 的 wbcode 列(见 getCandidates)
        // 按 text + wbcode 精确删除，可同时清掉同一字/词的 wb 与 py 记录
        let sql = "delete from wb_py_dict where text = :text and wbcode = :code"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt,
                              sqlite3_bind_parameter_index(stmt, ":text"),
                              candidate.text, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt,
                              sqlite3_bind_parameter_index(stmt, ":code"),
                              candidate.code, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[DictManager.deleteCandidate] errmsg: \(String(cString: sqlite3_errmsg(database)!))")
            }
        } else {
            print("[DictManager.deleteCandidate] prepare errmsg: \(String(cString: sqlite3_errmsg(database)!))")
        }
        sqlite3_finalize(stmt)
        stmt = nil
        invalidateUserDictCache()
        NotificationQueue.default.enqueue(Notification(name: DictManager.userDictUpdated), postingStyle: .whenIdle)
    }

    // 查询单个汉字的五笔全码(按长度降序取全码，避免拿到一码简码导致首根不全)
    func getCharFullWubiCode(_ char: String) -> String? {
        let sql = """
            select wbcode from wb_py_dict
            where text = :text and type = 'wb'
            order by length(wbcode) desc, id asc limit 1
        """
        var stmt: OpaquePointer?
        var result: String?
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt,
                              sqlite3_bind_parameter_index(stmt, ":text"),
                              char, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = String(cString: sqlite3_column_text(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        stmt = nil
        return result
    }

    // 按五笔词组取码规则为多字词生成编码：
    // 2 字: 字1前2 + 字2前2; 3 字: 字1首 + 字2首 + 字3前2; >=4 字: 字1首 + 字2首 + 字3首 + 末字首
    // 任一字查不到五笔码则返回 nil
    func makeWubiWordCode(for text: String) -> String? {
        let chars = text.map { String($0) }
        guard chars.count >= 2 else { return nil }
        let codes = chars.map { getCharFullWubiCode($0) }
        guard codes.allSatisfy({ $0 != nil }) else { return nil }
        let fullCodes = codes.compactMap { $0 }
        func prefix(_ code: String, _ n: Int) -> String {
            return String(code.prefix(n))
        }
        switch fullCodes.count {
        case 2:
            return prefix(fullCodes[0], 2) + prefix(fullCodes[1], 2)
        case 3:
            return prefix(fullCodes[0], 1) + prefix(fullCodes[1], 1) + prefix(fullCodes[2], 2)
        default:
            return prefix(fullCodes[0], 1) + prefix(fullCodes[1], 1)
                + prefix(fullCodes[2], 1) + prefix(fullCodes[fullCodes.count - 1], 1)
        }
    }

    func prependCandidates(candidates: [Candidate]) {
        if candidates.count <= 0 {
            return
        }
        // 2.1 先获取最小id
        let minId = getMinIdFromDictTable()
        // 2.2 添加对应id
        let values = candidates.enumerated().map { (n, candidate) in
            "(\(minId - candidates.count + n), '\(candidate.code)', '\(candidate.text)', '\(candidate.type)', '\(candidate.code)', NULL)"
        }.joined(separator: ",")
        let sql = """
            insert into wb_py_dict(id, wbcode, text, type, query, weight)
            values \(values)
        """
        sqlite3_exec(database, sql, nil, nil, nil)
        invalidateUserDictCache()
    }

    /// 用户词库批量入库（带可选权重）。code 为空的行只服务整句加权。
    /// 注意：表在 migrate 前没有 weight 列时回退到旧列集合。
    private func prependUserEntries(entries: [UserDictEntry]) {
        if entries.isEmpty { return }
        let hasWeight = columnExists("weight")
        let minId = getMinIdFromDictTable()
        let values = entries.enumerated().map { (n, entry) -> String in
            let code = entry.code.replacingOccurrences(of: "'", with: "''")
            let text = entry.text.replacingOccurrences(of: "'", with: "''")
            if hasWeight {
                let weightLiteral = entry.weight > 0 ? "\(entry.weight)" : "NULL"
                return "(\(minId - entries.count + n), '\(code)', '\(text)', '\(CandidateType.user.rawValue)', '\(code)', \(weightLiteral))"
            } else {
                return "(\(minId - entries.count + n), '\(code)', '\(text)', '\(CandidateType.user.rawValue)', '\(code)')"
            }
        }.joined(separator: ",")
        let columns = hasWeight ? "id, wbcode, text, type, query, weight" : "id, wbcode, text, type, query"
        sqlite3_exec(database, "insert into wb_py_dict(\(columns)) values \(values)", nil, nil, nil)
        invalidateUserDictCache()
    }

    private func columnExists(_ name: String) -> Bool {
        guard let database = database else { return false }
        var stmt: OpaquePointer?
        defer { if let stmt = stmt { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(wb_py_dict)", -1, &stmt, nil) == SQLITE_OK else { return false }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let col = sqlite3_column_text(stmt, 1), String(cString: col) == name { return true }
        }
        return false
    }

    /// 用户词权重列迁移：虎整句 supplement（词条 [权重]）并入用户词库，
    /// 权重存在 wb_py_dict.weight（NULL/0 = 默认 1000）。老库首次打开时补列。
    private func migrateUserDictWeight() {
        guard let database = database else { return }
        var stmt: OpaquePointer?
        defer { if let stmt = stmt { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(wb_py_dict)", -1, &stmt, nil) == SQLITE_OK else { return }
        var hasWeight = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1), String(cString: name) == "weight" {
                hasWeight = true
            }
        }
        if !hasWeight {
            sqlite3_exec(database, "ALTER TABLE wb_py_dict ADD COLUMN weight INTEGER", nil, nil, nil)
            print("[DictManager] migrated: wb_py_dict.weight added")
        }
    }

    /// 整句 supplement 查询：用户词文本 -> 权重（未设权重返回 nil）。
    /// 与虎整句 supplement.txt 同义：文本命中即参与匹配（与编码无关）。
    func getUserSupplementEntries() -> [(text: String, weight: Int)] {
        guard let database = database else { return [] }
        var result: [(String, Int)] = []
        var stmt: OpaquePointer?
        let sql = "select text, weight from wb_py_dict where type = '\(CandidateType.user.rawValue)' and weight is not null and weight > 0"
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let text = sqlite3_column_text(stmt, 0) {
                    result.append((String(cString: text), Int(sqlite3_column_int(stmt, 1))))
                }
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    /// 解析用户词库文本：`[权重] 编码 词条1 词条2 ……`，兼容老格式（无权重）。
    /// 行首首 token 是纯数字时视为整行权重（虎整句 supplement 的权重语义）；
    /// 只有权重没有编码时（如 `600 儿婿`），编码留空——普通候选不显示它，
    /// 整句 supplement 奖励仍生效。
    private struct UserDictEntry {
        let code: String
        let text: String
        let weight: Int
    }

    private func parseUserDict(_ dictContent: String) -> [UserDictEntry] {
        var entries: [UserDictEntry] = []
        for rawLine in dictContent.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let strs = line.split(whereSeparator: \.isWhitespace).map(String.init)
            var weight = 0 // 0 = 未显式设置（默认 1000）
            var tokens = strs
            if let first = strs.first, Int(first) != nil {
                let parsed = Int(first) ?? 0
                if parsed > 0 {
                    weight = parsed
                    tokens = Array(strs.dropFirst())
                } else {
                    // 权重非法（0/负数）：跳过该行（虎整句同规则）
                    continue
                }
            }
            guard !tokens.isEmpty else { continue }
            if weight > 0 && tokens.count == 1 {
                // `600 儿婿`：数字后只剩一个 token —— 纯 supplement 词条（无编码，
                // 普通候选不显示，整句加权生效）
                entries.append(UserDictEntry(code: "", text: tokens[0], weight: weight))
                continue
            }
            let code = tokens.first ?? ""
            for text in tokens.dropFirst() {
                entries.append(UserDictEntry(code: code, text: text, weight: weight))
            }
        }
        return entries
    }

    func updateUserDict(_ dictContent: String) {
        invalidateUserDictCache()
        // 1. 先删除之前的用户词库
        sqlite3_exec(database, "delete from wb_py_dict where type = '\(CandidateType.user.rawValue)'", nil, nil, nil)
        // 2. 添加用户词库（支持行首 [权重]）
        let entries = parseUserDict(dictContent)
        fireLog("[DictManager] updateUserDict entries: \(entries.count)")
        prependUserEntries(entries: entries)
        NotificationQueue.default.enqueue(Notification(name: DictManager.userDictUpdated), postingStyle: .whenIdle)
    }

    /// 编码精确匹配的用户词（含 {yyyy} 等日期变量替换），用于整句模式叠加
    /// 自定义短语（如 `date {yyyy}{MM}{dd}`）。只做整码精确匹配：整句模式下
    /// 候选栏归整句引擎，只有编码已被完整打全的自定义短语才值得置顶。
    ///
    /// 走内存快照（userDictRowsById）：整句模式下这两个用户查询每键都执行，
    /// 每次现场 prepare+step 是纯固定开销；用户词库变更点统一调
    /// invalidateUserDictCache()，快照与库的一致性窗口仅存在于"写库到失效调用"
    /// 之间（同线程顺序执行，实际为 0）。
    func getUserCandidates(matching query: String) -> [Candidate] {
        guard !query.isEmpty else { return [] }
        var candidates: [Candidate] = []
        for row in userDictSnapshot() where row.code == query {
            candidates.append(Candidate(code: row.code,
                                        text: replaceTextWithVars(row.text),
                                        type: .user))
            if candidates.count >= 10 { break }
        }
        return candidates
    }

    /// 是否存在以 query 为前缀（或相等）的用户码——整句自动上屏用它做保护：
    /// 编码还可能是用户自定义短语（如 `date {yyyy}{MM}{dd}`）的前缀时不提前上屏。
    /// 原 SQL 是 `query glob ?`（无法用索引，全表扫）；内存前缀判定 O(码数)，
    /// 用户码量级（≤几千）下为微秒级。语义对齐：GLOB 大小写敏感、
    /// 整句编码字符集（a-zA-Z0-9;'）不含 glob 元字符，前缀比较与 glob 等价。
    func hasUserDictPrefix(matching query: String) -> Bool {
        guard !query.isEmpty else { return false }
        for code in userDictCodesSnapshot() where code.hasPrefix(query) {
            return true
        }
        return false
    }

    // MARK: - 用户词库内存快照（整句热路径专用）

    private struct UserDictRow {
        let id: Int
        let code: String
        let text: String
    }
    /// 按 id 升序的全部用户词行（query 为空的纯加权词条也保留，
    /// 但 code 为空的行不会命中任何前缀/精确匹配——query <> '' 语义天然满足）
    private var userDictRowsCache: [UserDictRow]?
    /// 去重后的非空用户码集合（前缀扫描用，保持插入序= id 升序）
    private var userCodesCache: [String]?

    private func userDictSnapshot() -> [UserDictRow] {
        if let rows = userDictRowsCache { return rows }
        var rows: [UserDictRow] = []
        if let database = database {
            let sql = "select id, query, text from wb_py_dict where type = '\(CandidateType.user.rawValue)' order by id asc"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let code = String(cString: sqlite3_column_text(stmt, 1))
                    let text = String(cString: sqlite3_column_text(stmt, 2))
                    rows.append(UserDictRow(id: Int(sqlite3_column_int(stmt, 0)),
                                            code: code, text: text))
                }
            }
        }
        userDictRowsCache = rows
        var seen = Set<String>()
        var codes: [String] = []
        for row in rows where !row.code.isEmpty && !seen.contains(row.code) {
            seen.insert(row.code)
            codes.append(row.code)
        }
        userCodesCache = codes
        return rows
    }

    private func userDictCodesSnapshot() -> [String] {
        if let codes = userCodesCache { return codes }
        userDictSnapshot()
        return userCodesCache ?? []
    }

    /// 所有用户词库写路径（含删/插/批量重建/库重开）必须调用
    func invalidateUserDictCache() {
        userDictRowsCache = nil
        userCodesCache = nil
        // 词库变化后候选总数随之变化，页码缓存一并失效
        clearCandidatesCountCache()
    }

    func getUserCandidates() -> [Candidate] {
        var stmt: OpaquePointer?
        // query 为空的行是纯整句加权词条（[权重] 词条），不参与普通候选查询
        let sql = "select query, text from wb_py_dict where type = '\(CandidateType.user.rawValue)' and query <> ''"
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            var candidates: [Candidate] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let code = String(cString: sqlite3_column_text(stmt, 0))
                let text = String(cString: sqlite3_column_text(stmt, 1))
                candidates.append(Candidate(code: code, text: text, type: .user))
            }
            sqlite3_finalize(stmt)
            stmt = nil
            return candidates
        }
        sqlite3_finalize(stmt)
        stmt = nil
        return []
    }

    func getUserDictContent() -> String {
        // 获取用户候选词(包括调整顺序的词)，格式：[权重] 编码 词条1 词条2 ……
        struct UserDictLine {
            let code: String
            var weight: Int // 0 = 未设置
            var texts: [String]
        }
        let candidates = getUserCandidatesWithWeight()
        fireLog("[DictManager.exportUserDictToFile] candidates: \(candidates)")
        var list: [UserDictLine] = []
        candidates.forEach { candidate in
            if candidate.code.isEmpty {
                // 纯加权词条：单独成行 `权重 词条`
                if let index = list.firstIndex(where: {
                    $0.code.isEmpty && $0.weight == candidate.weight
                        && $0.texts.contains(candidate.text)
                }) { return }
                list.append(UserDictLine(code: "", weight: candidate.weight,
                                         texts: [candidate.text]))
                return
            }
            let index = list.firstIndex { dictItem in
                dictItem.code == candidate.code
            }
            if index == nil {
                list.append(UserDictLine(code: candidate.code, weight: candidate.weight,
                                         texts: [candidate.text]))
            } else if !list[index!].texts.contains(candidate.text) {
                list[index!].texts.append(candidate.text)
                if candidate.weight > 0 && list[index!].weight == 0 {
                    list[index!].weight = candidate.weight
                }
            }
        }
        let content = list.map { dictItem -> String in
            var parts: [String] = []
            if dictItem.weight > 0 { parts.append("\(dictItem.weight)") }
            if !dictItem.code.isEmpty { parts.append(dictItem.code) }
            parts.append(contentsOf: dictItem.texts)
            return parts.joined(separator: " ")
        }
        .joined(separator: "\n")
        return content
    }

    /// 用户候选词（带权重）。weight 列为 NULL/缺列时返回 0（未设置）。
    private func getUserCandidatesWithWeight() -> [(code: String, text: String, weight: Int)] {
        guard let database = database else { return [] }
        let hasWeight = columnExists("weight")
        let sql = hasWeight
            ? "select query, text, coalesce(weight, 0) from wb_py_dict where type = '\(CandidateType.user.rawValue)' order by id asc"
            : "select query, text, 0 from wb_py_dict where type = '\(CandidateType.user.rawValue)' order by id asc"
        var stmt: OpaquePointer?
        var candidates: [(String, String, Int)] = []
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let code = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let text = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                candidates.append((code, text, Int(sqlite3_column_int(stmt, 2))))
            }
        }
        sqlite3_finalize(stmt)
        return candidates
    }
}
