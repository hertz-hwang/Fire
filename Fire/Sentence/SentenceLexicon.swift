//
//  SentenceLexicon.swift
//  Fire
//
//  整句词图边表（移植虎整句 build_lexicon_index 的精简版）。
//  内置方案：Resources/sentence-codes-liuli.txt（琉璃整句码表，明文
//  `文字 码`，文件序 = rank）；Application Support 同名文件可覆盖。
//  与虎整句一致：不使用用户词覆盖层，rank 完全由码表文件序决定。
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
    /// 实际加载的码表路径（诊断用）
    private(set) var loadedPath: String?

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
                    self.loadedPath = snapshot.loadedPath
                    self.built = true
                    self.builtCodeMode = mode
                    self.generation += 1
                    NotificationCenter.default.post(name: SentenceLexicon.updated, object: nil)
                    NSLog("[SentenceLexicon] built mode=%@ entries=%d codes=%d lengths=%@ path=%@",
                        "\(mode)", snapshot.entryCount, snapshot.codes.count,
                        "\(snapshot.lengths)", snapshot.loadedPath ?? "")
                }
                let followUp: CodeMode? = self.rebuildGate.sync {
                    self.building = false
                    self.dirty = false
                    return self.pendingMode
                }
                if followUp != nil {
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
        loadedPath = snapshot.loadedPath
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
        var loadedPath: String?
    }

    /// 内置整句码表文件名（明文 `文字 码`，琉璃整句）
    static let codesFileName = "sentence-codes-liuli.txt"

    private func candidateTablePaths() -> [String] {
        var paths: [String] = []
        if let resourceURL = Bundle.main.resourceURL {
            paths.append(resourceURL.appendingPathComponent(Self.codesFileName).path)
        }
        if let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            paths.append(supportDir
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Fire")
                .appendingPathComponent(Self.codesFileName).path)
        }
        return paths
    }

    /// 解析琉璃整句码表：每行 `文字 码`（文字在前！），文件序 = rank。
    /// 整句编码只用这张表（与虎整句 schema 的"运行时明文码表、无用户覆盖"一致）。
    private func build(mode: CodeMode) -> Snapshot? {
        var codes: [String: [SentenceEdge]] = [:]
        var lengthValues = Set<Int>()
        var entryCount = 0
        // 单字最短码：optimal_single 标记（同字多码取最短，先到先得即最小 rank）
        var optimalSingleCode: [String: String] = [:]
        var loadedPath: String?

        for path in candidateTablePaths() where FileManager.default.fileExists(atPath: path) {
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            let data = handle.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { continue }
            loadedPath = path
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // 分隔符兼容制表符与空格（琉璃表原格式为 tab，允许空格排版）
                guard let spaceIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
                let entryText = String(line[line.startIndex..<spaceIndex])
                let code = String(line[line.index(after: spaceIndex)...].trimmingCharacters(in: .whitespaces))
                guard !entryText.isEmpty, isSimpleCode(code) else { continue }
                let len = code.count
                guard len >= 1, len <= SentenceConfig.wubiMaxCodeLength else { continue }

                var edges = codes[code] ?? []
                // 同 (code,text) 去重：rank 用"该 code 下第 n 条"（与虎整句一致）
                if edges.contains(where: { $0.text == entryText }) {
                    continue
                }
                let rank = edges.count + 1
                edges.append(SentenceEdge(text: entryText, rank: rank))
                codes[code] = edges
                lengthValues.insert(len)
                entryCount += 1

                if entryText.count == 1 {
                    if let existing = optimalSingleCode[entryText] {
                        if len < existing.count {
                            optimalSingleCode[entryText] = code
                        }
                    } else {
                        optimalSingleCode[entryText] = code
                    }
                }
            }
            break // 第一个存在的表就是生效表
        }

        guard !codes.isEmpty else {
            NSLog("[SentenceLexicon] codes table not found in %@", candidateTablePaths().joined(separator: ", "))
            return nil
        }

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
                        maxCodeLength: maxLength, entryCount: entryCount,
                        loadedPath: loadedPath)
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
