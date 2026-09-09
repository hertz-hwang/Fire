//
//  SentenceLexicon.swift
//  Fire
//
//  整句词图边表（移植虎整句 build_lexicon_index 的精简版）。
//  从现有 wb_py_dict 建内存索引，自动跟随「高级」面板换词库与用户词库。
//

import Foundation
import Defaults

final class SentenceLexicon {
    static let shared = SentenceLexicon()
    /// 词图构建完成（会话需重置，lattice 与新词表不能再混用）
    static let updated = Notification.Name("SentenceLexicon.updated")

    /// 精确码边表：code -> 边（按 rank 升序）
    private(set) var codes: [String: [SentenceEdge]] = [:]
    /// 去重升序的码长集合
    private(set) var lengths: [Int] = []
    /// 所有码的真前缀（空码上屏判断要用）
    private(set) var properPrefixes: Set<String> = []
    private(set) var maxCodeLength: Int = 1

    private(set) var built: Bool = false
    /// 后台重建进行中
    private(set) var building: Bool = false
    /// 词库/用户词/编码模式变化后置脏，下次 rebuildIfNeeded 强制重建
    private var dirty: Bool = true
    private(set) var entryCount: Int = 0
    private(set) var codeCount: Int = 0
    private(set) var builtCodeMode: CodeMode?
    /// 词表代数：每次成功构建 +1；会话的 lattice 跨代数必须重置
    private(set) var generation: Int = 0

    private let queue = DispatchQueue(label: "fire.sentence.lexicon", qos: .userInitiated)
    private let rebuildGate = DispatchQueue(label: "fire.sentence.lexicon.gate")
    /// 构建进行中收到新请求时记下目标模式，当前构建完成后补一次
    private var pendingMode: CodeMode?

    private init() {}

    var usable: Bool {
        built && !building && !dirty && !codes.isEmpty
    }

    /// 词库内容变了（用户加词/删词/换词库/重建索引）
    func markDirty() {
        rebuildGate.sync {
            self.dirty = true
            if self.building {
                // 构建中又变脏：本轮读到的可能是旧快照，排队补建
                self.pendingMode = Defaults[.codeMode]
            }
        }
    }

    /// 后台重建（幂等；重复调用合并为一次）。完成前 usable 为 false，
    /// 调用方应回落到普通词候选，不阻塞主线程。
    func rebuildIfNeeded(codeMode: CodeMode? = nil) {
        let mode = codeMode ?? Defaults[.codeMode]
        let shouldBuild: Bool = rebuildGate.sync {
            if self.building {
                // 构建中收到新请求：记下模式，本轮结束后补一次
                if self.dirty || self.builtCodeMode != mode {
                    self.pendingMode = mode
                }
                return false
            }
            if self.built && !self.dirty && self.builtCodeMode == mode { return false }
            self.building = true
            self.pendingMode = nil
            return true
        }
        guard shouldBuild else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let snapshot = self.build(mode: mode)
            DispatchQueue.main.async {
                if let snapshot = snapshot {
                    self.codes = snapshot.codes
                    self.lengths = snapshot.lengths
                    self.properPrefixes = snapshot.properPrefixes
                    self.maxCodeLength = snapshot.maxCodeLength
                    self.entryCount = snapshot.entryCount
                    self.codeCount = snapshot.codes.count
                    self.built = true
                    self.builtCodeMode = mode
                    self.generation += 1
                    NotificationCenter.default.post(name: SentenceLexicon.updated, object: nil)
                    NSLog("[SentenceLexicon] built mode=%@ entries=%d codes=%d lengths=%@",
                        "\(mode)", snapshot.entryCount, snapshot.codes.count,
                        "\(snapshot.lengths)")
                }
                let followUp: CodeMode? = self.rebuildGate.sync {
                    self.building = false
                    self.dirty = false
                    return self.pendingMode
                }
                if let followUp = followUp {
                    // 构建期间又来新请求：按最新模式（重读 Defaults）补建
                    self.rebuildIfNeeded()
                }
            }
        }
    }

    /// 同步重建（供 Debug 一致性测试使用）
    func rebuildSync(codeMode: CodeMode? = nil) {
        let mode = codeMode ?? Defaults[.codeMode]
        guard let snapshot = build(mode: mode) else { return }
        codes = snapshot.codes
        lengths = snapshot.lengths
        properPrefixes = snapshot.properPrefixes
        maxCodeLength = snapshot.maxCodeLength
        entryCount = snapshot.entryCount
        codeCount = snapshot.codes.count
        built = true
        builtCodeMode = mode
        rebuildGate.sync {
            self.dirty = false
            self.building = false
            self.pendingMode = nil
        }
    }

    // MARK: - 构建

    struct Snapshot {
        var codes: [String: [SentenceEdge]]
        var lengths: [Int]
        var properPrefixes: Set<String>
        var maxCodeLength: Int
        var entryCount: Int
    }

    /// 打开一个只读连接（DictManager 的连接在主线程，这里独立开）。
    /// id 升序 = rank；用户调序/新增的词 id 为负数，天然排最前。
    private func build(mode: CodeMode) -> Snapshot? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(getDatabaseURL().path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            NSLog("[SentenceLexicon] open database failed")
            sqlite3_close_v2(database)
            return nil
        }
        var statement: OpaquePointer?
        defer {
            if let statement = statement { sqlite3_finalize(statement) }
            sqlite3_close_v2(database)
        }

        let types: String
        switch mode {
        case .wubi, .wubiPinyin:
            types = "('wb', 'user')"
        case .pinyin:
            types = "('py', 'user')"
        }
        let lengthCap = mode == .pinyin
            ? SentenceConfig.pinyinMaxCodeLength
            : SentenceConfig.wubiMaxCodeLength

        let sql = """
            select query, text, type from wb_py_dict
            where type in \(types) and query glob '[a-z]*'
            order by id asc
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("[SentenceLexicon] prepare failed: %@",
                  String(cString: sqlite3_errmsg(database)))
            return nil
        }

        var codes: [String: [SentenceEdge]] = [:]
        var lengthValues = Set<Int>()
        var entryCount = 0
        // 单字最短码：optimal_single 标记（同字多码取最短，先到先得即最小 rank）
        var optimalSingleCode: [String: String] = [:]

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let queryText = sqlite3_column_text(statement, 0),
                  let hintText = sqlite3_column_text(statement, 1) else { continue }
            let code = String(cString: queryText)
            let text = String(cString: hintText)
            // 只收 ASCII 小写字母码；含空格/数字/符号的自定义条目跳过
            guard isSimpleCode(code) else { continue }
            let len = code.count
            guard len >= 1, len <= lengthCap else { continue }

            var edges = codes[code] ?? []
            // 同 (code,text) 去重：rank 用"该 code 下第 n 条"（与虎整句一致）
            if edges.contains(where: { $0.text == text }) {
                continue
            }
            let rank = edges.count + 1
            edges.append(SentenceEdge(text: text, rank: rank))
            codes[code] = edges
            lengthValues.insert(len)
            entryCount += 1

            if text.count == 1 {
                if let existing = optimalSingleCode[text] {
                    if len < existing.count {
                        optimalSingleCode[text] = code
                    }
                } else {
                    optimalSingleCode[text] = code
                }
            }
        }

        guard !codes.isEmpty else { return nil }

        // 回填 optimalSingle
        for (code, edges) in codes {
            if code.count >= 2 {
                codes[code] = edges.map { edge in
                    var e = edge
                    e.optimalSingle = (e.text.count == 1 && optimalSingleCode[e.text] == code)
                    return e
                }
            }
        }

        // 所有码的真前缀（长度 1..count-1），空码上屏判断要用
        var prefixes = Set<String>()
        for code in codes.keys {
            let chars = Array(code)
            if chars.count < 2 { continue }
            var prefix = ""
            for ch in chars[0..<(chars.count - 1)] {
                prefix.append(ch)
                prefixes.insert(prefix)
            }
        }

        let lengths = lengthValues.sorted()
        let maxLength = lengths.last ?? 1
        return Snapshot(codes: codes, lengths: lengths, properPrefixes: prefixes,
                        maxCodeLength: maxLength, entryCount: entryCount)
    }

    @inline(__always)
    private func isSimpleCode(_ code: String) -> Bool {
        for scalar in code.unicodeScalars {
            if scalar.value < 97 || scalar.value > 122 {
                return false
            }
        }
        return !code.isEmpty
    }

    /// 把语句的 statement 暴露给 defer 用（Swift 限制：defer 捕获 var）
    private var statement: OpaquePointer? { nil }

    // MARK: - 查询

    @inline(__always)
    func edges(for code: String) -> [SentenceEdge]? {
        codes[code]
    }

    @inline(__always)
    func isProperPrefix(_ code: String) -> Bool {
        properPrefixes.contains(code)
    }
}
