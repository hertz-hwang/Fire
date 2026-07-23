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
    }
    deinit {
        close()
    }
    func reinit() {
        close()
        prepareStatement()
    }
    func close() {
        sqlite3_finalize(queryStatement)
        queryStatement = nil
        sqlite3_finalize(reverseLookupStatement)
        reverseLookupStatement = nil
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
        if database == nil {
            sqlite3_open_v2(getDatabaseURL().path, &database, SQLITE_OPEN_READWRITE, nil)
            sqlite3_exec(database, "PRAGMA case_sensitive_like=ON;", nil, nil, nil)
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
        NSLog("[Fire.getMinIdFromDictTable] errmsg: \(String(cString: sqlite3_errmsg(queryStmt)))")
        sqlite3_finalize(queryStmt)
        queryStmt = nil
        return 0
    }

    private func replaceTextWithVars(_ text: String) -> String {
        let date = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy MM dd HH mm ss"
        let arr = formatter.string(from: date).split(separator: " ")
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
        print("[replaceTextWithVars] \(text), \(newText)")
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
        NSLog("[DictManager] getCandidates origin: \(query)")
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
        NSLog("[DictManager] getCandidates query: \(query) , duration: \(duration)")
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

    func setCandidateToFirst(query: String, candidate: Candidate) {
        let newCandidate = Candidate(code: query, text: candidate.text, type: CandidateType.user)
        _ = prependCandidate(candidate: newCandidate)
        NotificationQueue.default.enqueue(Notification(name: DictManager.userDictUpdated), postingStyle: .whenIdle)
    }

    func prependCandidate(candidate: Candidate) -> Bool {
        let sql = """
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
            "(\(minId - candidates.count + n), '\(candidate.code)', '\(candidate.text)', '\(candidate.type)', '\(candidate.code)')"
        }.joined(separator: ",")
        let sql = """
            insert into wb_py_dict(id, wbcode, text, type, query)
            values \(values)
        """
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    func updateUserDict(_ dictContent: String) {
        // 1. 先删除之前的用户词库
        sqlite3_exec(database, "delete from wb_py_dict where type = '\(CandidateType.user.rawValue)'", nil, nil, nil)
        // 2. 添加用户词库
        let lines = dictContent.split(whereSeparator: \.isNewline)
        NSLog("[DictManager] updateUserDict: \(lines)");
        let candidates = lines.map { (line) -> [Candidate] in
            let strs = line.split(whereSeparator: \.isWhitespace)
            NSLog("[DictManager] line: \(line), strs: \(strs)")
            if strs.count <= 1 {
                return []
            }
            let code = String(strs.first!)
            let candidateTexts = strs[1...]
            return candidateTexts.map { text in
                Candidate(code: code, text: String(text), type: CandidateType.user)
            }
        }.reduce([] as [Candidate]) { partialResult, cur in
            partialResult + cur
        }
        prependCandidates(candidates: candidates)
        NotificationQueue.default.enqueue(Notification(name: DictManager.userDictUpdated), postingStyle: .whenIdle)
    }

    func getUserCandidates() -> [Candidate] {
        var stmt: OpaquePointer?
        let sql = "select query, text from wb_py_dict where type = '\(CandidateType.user.rawValue)'"
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
        // 获取用户候选词(包括调整顺序的词)
        struct UserDictLine {
            let code: String
            var texts: [String]
        }
        let candidates = getUserCandidates()
        NSLog("[DictManager.exportUserDictToFile] candidates: \(candidates)")
        var list: [UserDictLine] = []
        candidates.forEach { candidate in
            let index = list.firstIndex { dictItem in
                dictItem.code == candidate.code
            }
            if index == nil {
                list.append(UserDictLine(code: candidate.code, texts: [candidate.text]))
            } else if !list[index!].texts.contains(candidate.text) {
                list[index!].texts.append(candidate.text)
            }
        }
        let content = list.map { dictItem in
            ([dictItem.code] + dictItem.texts).joined(separator: " ")
        }
        .joined(separator: "\n")
        return content
    }
}
