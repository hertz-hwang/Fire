//
//  ReplayTuner.swift
//  Fire
//
//  离线回放评估（通道 D 的基础）：把 statistics.db 里的历史整句上屏
//  （编码 → 所选文字）按会话重放给解码器，度量 top-1 命中率。
//
//  用法（CLI）：
//    Fire.app/Contents/MacOS/Fire --replay-eval [--split 0.7] [--limit N] [--mode both]
//
//  - mode baseline：关闭学习通道，纯通用模型基线
//  - mode learned ：前 split 比例的历史喂通道 B 训练（模拟在线学习），
//                   后 1−split 比例做评估
//  - mode both    ：两轮各测一遍并对比（默认），验证学习是否真的提升命中率
//
//  会话切分：appBundleId 变化或与上一条间隔超过 120s 视为新会话，
//  解码上下文与会话语义一致（留存最近 1~2 段上屏文本）。
//  评估目标函数是 top-1 命中率而非困惑度——调参服务于实际选字体验。
//

import Foundation
import Defaults

enum ReplayTuner {
    struct Record {
        let id: Int64
        let text: String
        let code: String
        let type: String
        let createdAt: String
        let appBundleId: String
    }

    struct Session {
        var appBundleId: String
        var records: [Record] = []
    }

    struct Metrics {
        var total = 0
        var hits = 0
        var noDecode = 0
        /// 与基线轮 top-1 不同的条数（only both 模式统计）
        var flipped = 0
        /// 首选分数与基线不同但排序未变的条数（诊断插值是否生效）
        var scoreChanged = 0

        var hitRate: Double { total > 0 ? Double(hits) / Double(total) : 0 }
    }

    static let sessionGapSeconds: TimeInterval = 120

    // MARK: - CLI 入口

    @discardableResult
    static func run(arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> Int32 {
        var split = 0.7
        var limit = 0
        var mode = "both"
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--split": index += 1; split = Double(arguments[index]) ?? 0.7
            case "--limit": index += 1; limit = Int(arguments[index]) ?? 0
            case "--mode": index += 1; mode = arguments[index]
            default: break
            }
            index += 1
        }

        print("[ReplayTuner] loading n-gram model…")
        NgramModel.shared.ensureLoaded()
        guard NgramModel.shared.loaded else {
            print("[ReplayTuner] n-gram model load failed: \(NgramModel.shared.loadError ?? "?")")
            return 1
        }
        print("[ReplayTuner] model: \(NgramModel.shared.statusText())")
        SentenceLexicon.shared.rebuildSync()
        guard SentenceLexicon.shared.usable else {
            print("[ReplayTuner] sentence lexicon build failed")
            return 1
        }
        print("[ReplayTuner] lexicon entries=\(SentenceLexicon.shared.entryCount) codes=\(SentenceLexicon.shared.codeCount)")

        guard let db = LearningStore.openStatisticsDatabase() else {
            print("[ReplayTuner] cannot open statistics.db (不存在或密钥不可用)")
            return 1
        }
        defer { sqlite3_close(db) }
        let records = loadRecords(db: db, limit: limit)
        print("[ReplayTuner] history records: \(records.count) (all types)")
        let sessions = buildSessions(records: records)
        let evalRecords = sessions.flatMap { $0.records }
            .filter { $0.type == CandidateType.sentence.rawValue }
        print("[ReplayTuner] sentence commits: \(evalRecords.count) in \(sessions.count) sessions")
        guard !evalRecords.isEmpty else {
            print("[ReplayTuner] 没有可回放的整句历史（需在整句模式下输入产生记录）")
            return 0
        }

        let trainCount = Int(Double(evalRecords.count) * split)
        let trainTexts = evalRecords.prefix(trainCount).map { $0.text }
        // 严格留出法：只对切分点之后的记录计分（上下文仍从全量历史延续），
        // 两轮对比的才是诚实的泛化效果
        let evalFromId = trainCount < evalRecords.count ? evalRecords[trainCount].id : Int64.max

        var results: [(label: String, metrics: Metrics)] = []
        var baselineTopTexts: [Int64: (text: String, score: Double)] = [:]
        if mode == "baseline" || mode == "both" {
            let (metrics, topTexts) = evaluate(records: evalRecords, evalFromId: evalFromId,
                                               trainTexts: nil)
            results.append(("baseline", metrics))
            baselineTopTexts = topTexts
        }
        if mode == "learned" || mode == "both" {
            let (metrics, topTexts) = evaluate(records: evalRecords, evalFromId: evalFromId,
                                               trainTexts: trainTexts)
            if !baselineTopTexts.isEmpty {
                var flippedCount = 0
                var scoreChangedCount = 0
                for (id, baseline) in baselineTopTexts {
                    guard let learned = topTexts[id] else { continue }
                    if learned.text != baseline.text {
                        flippedCount += 1
                    } else if abs(learned.score - baseline.score) > 1e-9 {
                        scoreChangedCount += 1
                    }
                }
                print("[ReplayTuner] 诊断：插值生效（分数变化）\(scoreChangedCount) 条 · top-1 翻案 \(flippedCount) 条")
            }
            results.append(("learned", metrics))
        }

        print("")
        print("========== ReplayTuner 结果 ==========")
        for (label, metrics) in results {
            print(String(format: "[%@] 评估 %d 条 · top-1 命中 %d · 命中率 %.2f%% · 无法解码 %d",
                         label, metrics.total, metrics.hits, metrics.hitRate * 100, metrics.noDecode))
        }
        if results.count == 2 {
            let delta = results[1].metrics.hitRate - results[0].metrics.hitRate
            print(String(format: "学习带来的命中率变化：%+.2f pp", delta * 100))
        }
        print("======================================")
        return 0
    }

    // MARK: - 数据加载

    private static func loadRecords(db: OpaquePointer?, limit: Int) -> [Record] {
        var records: [Record] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, text, code, type, createdAt, appBundleId FROM data ORDER BY id"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let record = Record(
                id: sqlite3_column_int64(stmt, 0),
                text: String(cString: sqlite3_column_text(stmt, 1)),
                code: String(cString: sqlite3_column_text(stmt, 2)),
                type: String(cString: sqlite3_column_text(stmt, 3)),
                createdAt: String(cString: sqlite3_column_text(stmt, 4)),
                appBundleId: String(cString: sqlite3_column_text(stmt, 5)))
            records.append(record)
            if limit > 0, records.count >= limit { break }
        }
        return records
    }

    private static func buildSessions(records: [Record]) -> [Session] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        formatter.timeZone = .current
        var sessions: [Session] = []
        var current: Session?
        for record in records {
            var newSession = false
            if let existing = current {
                if existing.appBundleId != record.appBundleId {
                    newSession = true
                } else if let previous = existing.records.last,
                          let previousDate = formatter.date(from: previous.createdAt),
                          let currentDate = formatter.date(from: record.createdAt),
                          currentDate.timeIntervalSince(previousDate) > sessionGapSeconds {
                    newSession = true
                }
            } else {
                newSession = true
            }
            if newSession {
                current = Session(appBundleId: record.appBundleId, records: [record])
                sessions.append(current!)
            } else {
                current?.records.append(record)
            }
        }
        return sessions
    }

    // MARK: - 评估

    /// 一次评估轮：trainTexts 非 nil 时先喂通道 B（模拟已学习状态），
    /// 再逐会话回放。上下文沿全量历史延续；仅 id ≥ evalFromId 的记录计入
    /// 指标（留出评估）。同时返回每条计分记录的 (首选文字, 分数) 供两轮对比。
    private static func evaluate(records: [Record], evalFromId: Int64, trainTexts: [String]?)
        -> (Metrics, [Int64: (text: String, score: Double)]) {
        var metrics = Metrics()
        let tuning = LearningTuning.fromDefaults()
        let originalLearningEnabled = Defaults[.enableLearning]
        defer { Defaults[.enableLearning] = originalLearningEnabled }

        // 训练：历史记录没有 rank 信息，只喂通道 B（生成式），纠错对不参与
        var replaySnapshot: LearningSnapshot?
        if let trainTexts = trainTexts {
            let store = UserCharNgramStore()
            for text in trainTexts {
                store.record(text)
            }
            print("[ReplayTuner] train: texts=\(trainTexts.count) uni=\(store.unigrams.count) bi=\(store.bigrams.count) biTotal=\(store.bigramTotals.count) uniTotal=\(store.unigramTotal)")
            if let data = store.snapshotData(tuning: tuning), data.hasData {
                replaySnapshot = LearningSnapshot(generation: 1, ngram: data)
                print("[ReplayTuner] replay snapshot active: ngramData.hasData=\(data.hasData)")
            } else {
                print("[ReplayTuner] replay snapshot EMPTY")
            }
        } else {
            // 基线轮：关闭学习通道，确保测的是纯通用模型
            //（用户已积累的学习数据不得混入基线）
            Defaults[.enableLearning] = false
        }

        // 会话切分与上下文复现
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        formatter.timeZone = .current
        let contextDepth = Swift.max(0, Swift.min(2, Defaults[.sentenceContextDepth]))

        var decoder = SentenceDecoder()
        var contextSegments: [String] = []
        var lastDate: Date?
        var lastApp = ""
        var topTexts: [Int64: (text: String, score: Double)] = [:]

        for record in records {
            let currentDate = formatter.date(from: record.createdAt)
            if record.appBundleId != lastApp
                || (currentDate != nil && lastDate != nil
                    && currentDate!.timeIntervalSince(lastDate!) > sessionGapSeconds) {
                // 新会话：换解码器（清 lattice），清上下文
                decoder = SentenceDecoder()
                contextSegments = []
            }
            lastDate = currentDate
            lastApp = record.appBundleId

            let context = contextSegments.suffix(contextDepth).joined()
            defer {
                contextSegments.append(record.text)
                if contextSegments.count > 2 {
                    contextSegments.removeFirst(contextSegments.count - 2)
                }
            }

            guard record.type == CandidateType.sentence.rawValue,
                  !record.code.isEmpty, !record.text.isEmpty else { continue }
            guard SentenceDecoder.normalize(record.code) != nil else { continue }
            // 留出法：切分点之前的记录只喂上下文不计分
            let isEvalRecord = record.id >= evalFromId

            if replaySnapshot != nil {
                decoder.configureReplayLearning(snapshot: replaySnapshot,
                                                corrections: nil, tuning: tuning)
            } else {
                decoder.clearReplayLearning()
            }

            let result = decoder.decode(record.code, includeEarlyCommit: false, context: context)
            guard isEvalRecord else { continue }
            metrics.total += 1
            guard let top = result.candidates.first else {
                metrics.noDecode += 1
                continue
            }
            topTexts[record.id] = (top.text, top.score)
            if top.text == record.text {
                metrics.hits += 1
            }
        }
        return (metrics, topTexts)
    }
}

// MARK: - 整句解码探针（CLI）

/// `Fire --decode-probe <编码>...`：加载真实模型与词图，逐条解码并打印
/// 候选文字、总分与各维度打分拆解。用于验证「显示打分」的数据口径，
/// 以及调参时的分数归因（各维度加分是否如预期生效）。
enum SentenceDecodeProbe {
    @discardableResult
    static func run(codes: [String]) -> Int32 {
        guard !codes.isEmpty else {
            print("usage: --decode-probe <编码>...")
            return 1
        }
        print("[DecodeProbe] loading n-gram model…")
        NgramModel.shared.ensureLoaded()
        guard NgramModel.shared.loaded else {
            print("[DecodeProbe] n-gram model load failed: \(NgramModel.shared.loadError ?? "?")")
            return 1
        }
        SentenceLexicon.shared.rebuildSync()
        guard SentenceLexicon.shared.usable else {
            print("[DecodeProbe] sentence lexicon build failed")
            return 1
        }
        let decoder = SentenceDecoder()
        var exitCode: Int32 = 0
        for code in codes {
            let result = decoder.decode(code, includeEarlyCommit: false)
            print("==== \(code) ====")
            if result.candidates.isEmpty {
                print("  (无可解候选)")
                exitCode = 1
                continue
            }
            for (index, candidate) in result.candidates.enumerated() {
                print(String(format: "%d. %@  score=%.4f  %@",
                             index + 1, candidate.text, candidate.score,
                             candidate.dimensions.displayText()))
            }
        }
        return exitCode
    }
}
