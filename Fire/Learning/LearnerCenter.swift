//
//  LearnerCenter.swift
//  Fire
//
//  学习系统中心：订阅上屏/撤销通知 → 串行队列记账（通道 B/C）→
//  防抖落库 → 发布只读快照（generation 换代驱动解码端 lattice 失效）。
//
//  线程模型：
//  - 通知回调只做解析，记账/落库全部在 fire.learning 串行队列；
//  - 解码端（主线程）读快照与纠错条目，经 NSLock 保护的引用/查询，
//    均为指针级或单键级操作，热路径无竞争；
//  - 快照换代只在防抖 flush 后发生（默认 60s），不会频繁打断增量解码。
//
//  通道 A（会话缓存）不经过这里：它挂在 per-controller 的 SentenceDecoder
//  上，由 insertText/撤销直接喂入，生命周期与会话一致。
//

import Foundation
import Defaults

final class LearnerCenter {
    static let shared = LearnerCenter()

    // MARK: - 状态

    private let queue = DispatchQueue(label: "fire.learning", qos: .utility)
    private let stateLock = NSLock()
    private var _snapshot: LearningSnapshot = .empty
    private var _ngramGeneration = 0

    /// 学习数据存储（队列独占访问；快照发布经 stateLock 换引用）
    private var ngramStore = UserCharNgramStore()
    private var correctionStore = CorrectionStore()
    private let store = LearningStore()

    // 防抖落库
    private var flushPending = false
    private let flushInterval: TimeInterval = 60.0

    // 遥测计数（设置面板展示）
    private(set) var telemetry = Telemetry()

    struct Telemetry {
        var commitsRecorded: Int = 0
        var commitsUnrecorded: Int = 0
        var correctionsRecorded: Int = 0
        var correctionsUndone: Int = 0
        var lastFlushDate: Date?
        var backfilledRecords: Int = 0
        var backfillFinished: Bool = false
    }

    private var observationTokens: [NSObjectProtocol] = []

    // MARK: - 初始化

    private init() {
        store.load(ngramStore: ngramStore, correctionStore: correctionStore)
        rebuildSnapshotLocked()
        installObservers()
        maybeAutoBackfill()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observationTokens.append(center.addObserver(
            forName: Fire.candidateInserted, object: nil, queue: nil) { [weak self] notification in
                self?.handleCommit(notification: notification, undone: false)
        })
        observationTokens.append(center.addObserver(
            forName: Fire.commitUndone, object: nil, queue: nil) { [weak self] notification in
                self?.handleCommit(notification: notification, undone: true)
        })
    }

    // MARK: - 解码端接口

    /// 当前只读快照（含 generation）
    var snapshot: LearningSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _snapshot
    }

    /// n-gram 数据代数：解码端比对后决定是否作废增量 lattice
    var ngramGeneration: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _ngramGeneration
    }

    /// 纠错条目查询（emit 阶段每次解码一次）。学习关闭时恒 nil。
    func correctionEntries(ctx: String, code: String,
                           correctionEnabled: Bool) -> [String: CorrectionStore.Entry]? {
        guard correctionEnabled else { return nil }
        stateLock.lock()
        defer { stateLock.unlock() }
        return correctionStore.entriesFor(ctx: ctx, code: code)
    }

    // MARK: - 信号入口

    private func signal(from notification: Notification, undone: Bool) -> CommitSignal? {
        guard let userInfo = notification.userInfo else { return nil }
        guard let text = userInfo["text"] as? String ?? (userInfo["candidate"] as? Candidate)?.text,
              !text.isEmpty else { return nil }
        if undone {
            // 撤销信号：text 必带；纠错回退信息可选
            return CommitSignal(
                text: text,
                code: userInfo["code"] as? String ?? "",
                type: userInfo["type"] as? String ?? "",
                rank: userInfo["rank"] as? Int ?? 0,
                top1Text: userInfo["top1Text"] as? String ?? "",
                ctx: userInfo["ctx"] as? String ?? "",
                appBundleId: userInfo["appBundleId"] as? String ?? "",
                timestamp: Date(),
                undone: true)
        }
        guard let candidate = userInfo["candidate"] as? Candidate else { return nil }
        guard candidate.type != .placeholder else { return nil }
        return CommitSignal(
            text: candidate.text,
            code: userInfo["rawCode"] as? String ?? candidate.code,
            type: candidate.type.rawValue,
            rank: userInfo["rank"] as? Int ?? 0,
            top1Text: userInfo["top1Text"] as? String ?? "",
            ctx: userInfo["ctx"] as? String ?? "",
            appBundleId: userInfo["appBundleId"] as? String ?? "",
            timestamp: Date(),
            undone: false)
    }

    private func handleCommit(notification: Notification, undone: Bool) {
        guard Defaults[.enableLearning] else { return }
        guard let signal = signal(from: notification, undone: undone) else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            if signal.undone {
                self.applyUndo(signal)
            } else {
                self.applyCommit(signal)
            }
            self.scheduleFlush()
        }
    }

    /// 上屏记账（通道 B 字符 n-gram + 通道 C 纠错对）
    private func applyCommit(_ signal: CommitSignal) {
        if signal.hasLearnableChars {
            ngramStore.record(signal.text)
            telemetry.commitsRecorded += 1
        }
        // 纠错对：只在用户显式选了非首选（rank ≥ 1）时记
        // （整句模式限定——学习系统当前只辅助整句解码）
        if signal.rank >= 1, signal.type == CandidateType.sentence.rawValue,
           !signal.top1Text.isEmpty, !signal.code.isEmpty {
            let code = SentenceDecoder.normalize(signal.code)
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            if !code.isEmpty {
                correctionStore.record(ctx: String(signal.ctx.suffix(2)), code: code,
                                       chosenText: signal.text, rejectedTopText: signal.top1Text)
                telemetry.correctionsRecorded += 1
            }
        }
    }

    /// 撤销记账：通道 B 计数回退 + 纠错对回退
    private func applyUndo(_ signal: CommitSignal) {
        if signal.hasLearnableChars {
            ngramStore.unrecord(signal.text)
            telemetry.commitsUnrecorded += 1
        }
        if signal.rank >= 1, !signal.top1Text.isEmpty, !signal.code.isEmpty {
            let code = SentenceDecoder.normalize(signal.code)
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            if !code.isEmpty {
                correctionStore.unrecord(ctx: String(signal.ctx.suffix(2)), code: code,
                                         chosenText: signal.text, rejectedTopText: signal.top1Text)
                telemetry.correctionsUndone += 1
            }
        }
    }

    // MARK: - 落库与快照

    private func scheduleFlush() {
        guard !flushPending else { return }
        flushPending = true
        queue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            guard let self = self else { return }
            self.flushPending = false
            self.flushNow()
        }
    }

    /// 立即落库（防抖触发或设置面板手动触发）。须在 queue 上调用。
    private func flushNow() {
        ngramStore.sweep(tuning: LearningTuning.fromDefaults())
        correctionStore.sweep(tuning: LearningTuning.fromDefaults())
        store.flush(ngramStore: ngramStore, correctionStore: correctionStore)
        rebuildSnapshotLocked()
        telemetry.lastFlushDate = Date()
    }

    /// 快照换代（generation +1）
    private func rebuildSnapshotLocked() {
        let data = ngramStore.snapshotData(tuning: LearningTuning.fromDefaults())
        stateLock.lock()
        _ngramGeneration += 1
        _snapshot = LearningSnapshot(generation: _ngramGeneration, ngram: data)
        stateLock.unlock()
    }

    // MARK: - 历史回填（通道 B 冷启动 / 增量补学）

    /// 启动时补学「未被实时学习过」的历史记录（statistics.learned = 0）：
    /// 首次迁移后为全量；正常情况下为空集（学习关闭期间产生的记录会在这里补上）。
    private func maybeAutoBackfill() {
        guard Defaults[.enableLearning] else { return }
        backfill(progress: nil)
    }

    /// 回放 statistics.db 中 learned = 0 的历史记录进通道 B。
    ///
    /// 数据源不重叠的保证：statistics 行插入时按当时的学习开关写入 learned
    /// 标记（实时学过的行 = 1），本方法只取 learned = 0 的行，计数落库后
    /// 统一标记为 1。崩溃窗口的取舍：先落库计数再标记——宁可极端情况下
    /// 重学一小段（计数翻倍），绝不静默漏学。
    ///
    /// 分块读取（每块一条独立语句），避免长读事务阻塞统计写入。
    /// 在 queue 上执行；进度回调在主线程。
    func backfill(progress: ((Int, Bool) -> Void)?) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard Defaults[.enableLearning] else {
                progress?(0, true)
                return
            }
            guard let db = LearningStore.openStatisticsDatabase() else {
                progress?(0, true)
                return
            }
            defer { sqlite3_close(db) }
            // CLI 路径下 Statistics.shared 未初始化，确保 learned 列已迁移
            _ = Statistics.migrate(db)

            var processed = 0
            var lastId: Int64 = 0
            var consumedIds: [Int64] = []
            var reported = 0
            while true {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db,
                        "SELECT id, text FROM data "
                      + "WHERE learned = 0 AND type != 'placeholder' AND id > ? "
                      + "ORDER BY id LIMIT 5000",
                        -1, &stmt, nil) == SQLITE_OK else { break }
                sqlite3_bind_int64(stmt, 1, lastId)
                var chunk: [(id: Int64, text: String)] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = sqlite3_column_int64(stmt, 0)
                    let text = String(cString: sqlite3_column_text(stmt, 1))
                    chunk.append((id, text))
                }
                sqlite3_finalize(stmt)
                if chunk.isEmpty { break }
                for row in chunk {
                    lastId = row.id
                    consumedIds.append(row.id)
                    guard row.text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else {
                        continue
                    }
                    self.ngramStore.record(row.text)
                    processed += 1
                }
                if processed - reported >= 2000 {
                    reported = processed
                    progress?(processed, false)
                }
            }

            guard !consumedIds.isEmpty else {
                progress?(processed, true)
                return
            }
            // 先落库计数，再把消费过的行标记为已学习
            self.ngramStore.sweep(tuning: LearningTuning.fromDefaults())
            self.store.flush(ngramStore: self.ngramStore, correctionStore: self.correctionStore)
            var update: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE data SET learned = 1 WHERE id = ?",
                                  -1, &update, nil) == SQLITE_OK {
                sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
                for id in consumedIds {
                    sqlite3_bind_int64(update, 1, id)
                    sqlite3_step(update)
                    sqlite3_reset(update)
                }
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
            }
            sqlite3_finalize(update)

            self.telemetry.backfilledRecords += processed
            self.telemetry.backfillFinished = true
            self.rebuildSnapshotLocked()
            self.notifyDataReplaced()
            NSLog("[Learning] backfilled %d records (%ld rows consumed)", processed, consumedIds.count)
            progress?(processed, true)
        }
    }

    /// 手动全量重建：清空通道 B 计数、把全部历史行重置为未学习，再从头回填。
    /// 与增量补学的区别：会覆盖现有计数（关闭统计期间实时学到的上屏不在
    /// 历史中，重建后会丢失——面板确认文案里已说明）。
    func rebuildFromHistory(progress: ((Int, Bool) -> Void)?) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard Defaults[.enableLearning] else {
                DispatchQueue.main.async { progress?(0, true) }
                return
            }
            self.ngramStore = UserCharNgramStore()
            if let db = LearningStore.openStatisticsDatabase() {
                sqlite3_exec(db, "UPDATE data SET learned = 0", nil, nil, nil)
                sqlite3_close(db)
            }
            // 先广播「已清空」：窗口开着时能立刻看到存量归零，
            // 回填收尾时 backfill 会再广播一次最终结果
            self.notifyDataReplaced()
            self.backfill(progress: progress)
        }
    }

    // MARK: - 导入导出（TCSKNM02 学习数据交换，通道 B）

    // 回调约定：以下接口的 completion/progress 可能在后台线程交付，
    // 需要 UI 的调用方自行派发主线程（CLI 调用方则直接使用）。

    /// 导出字符 n-gram 学习数据（含防抖窗口内尚未落库的计数）。
    /// 格式与 sentence-ngram-mobile.bin 同构（TCSKNM02 分页），
    /// 字段语义为计数/上下文总量（见 LearningSerialization.swift 头注）。
    func exportNgramData(completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let data = UserNgramBinary.export(self.ngramStore)
            completion(.success(data))
        }
    }

    /// 导入并替换字符 n-gram 学习数据（纠错对与会话缓存不受影响）。
    /// 成功回调带导入的条目数；清库后全量重写，快照立即换代生效。
    func importNgramData(_ data: Data, completion: @escaping (Result<Int, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let imported = try UserNgramBinary.importStore(from: data)
                self.store.clearAll()
                self.ngramStore = imported
                self.ngramStore.markAllDirtyForPersist()
                self.store.flush(ngramStore: self.ngramStore,
                                 correctionStore: self.correctionStore)
                self.rebuildSnapshotLocked()
                self.notifyDataReplaced()
                NSLog("[Learning] imported n-gram data: %d entries", imported.entryCount)
                completion(.success(imported.entryCount))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: - 清除（设置面板）

    func clearAllData() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.store.clearAll()
            self.ngramStore = UserCharNgramStore()
            self.correctionStore = CorrectionStore()
            self.telemetry = Telemetry()
            self.rebuildSnapshotLocked()
            self.notifyDataReplaced()
            // 注意：statistics.learned 标记有意保留——清除 = 真正的干净状态，
            // 历史不会在下一次启动时被自动回填回来；需要历史基线时用
            // 「回填历史数据」（全量重建）显式恢复
            NSLog("[Learning] cleared all learning data")
        }
    }

    /// 手动触发落库（设置面板）
    func flushImmediately() {
        queue.async { [weak self] in
            self?.flushNow()
        }
    }

    // MARK: - 结构性变化通知

    /// 学习数据被整体替换后通知 UI 重新取数（主线程发布）。
    ///
    /// 只在「存量整批变了」的场合发布：清除、全量重建、导入、回填收尾。
    /// 日常记账刻意不发布——上屏频率太高，会把「查看学习数据」窗口
    /// 拖成常驻的全表扫描。
    private func notifyDataReplaced() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .learningDataReplaced, object: nil)
        }
    }

    // MARK: - 面板展示

    /// 状态摘要（面板展示用，后台线程取数，回调可能来自后台线程）
    func statusSummary(completion: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            var lines: [String] = []
            lines.append("字符 n-gram 条目：\(self.ngramStore.entryCount)")
            lines.append("纠错对条目：\(self.correctionStore.entryCount)")
            if let flush = self.telemetry.lastFlushDate {
                let formatter = DateFormatter()
                formatter.dateFormat = "MM-dd HH:mm"
                lines.append("上次落库：\(formatter.string(from: flush))")
            }
            lines.append("累计记账 \(self.telemetry.commitsRecorded) 次 · 纠错 \(self.telemetry.correctionsRecorded) 条 · 撤销 \(self.telemetry.commitsUnrecorded) 次")
            if self.telemetry.backfilledRecords > 0 {
                lines.append("历史回填 \(self.telemetry.backfilledRecords) 条")
            }
            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - 数据明细（设置面板「查看学习数据」）

    /// 取学习数据明细供界面浏览。
    ///
    /// 在 fire.learning 串行队列上读：与记账/落库天然互斥，读到的是含防抖
    /// 窗口内尚未落库计数的实时状态；纯读——不动计数、不触发衰减、不换代快照。
    /// 全表扫描 + 排序的量级是条目数（上限 20 万），故放在后台队列，
    /// completion 可能在后台线程交付，UI 侧自行派发主线程。
    ///
    /// - Parameters:
    ///   - query: 关键词过滤，对行的显示文本做包含匹配；空 = 不过滤
    ///   - limit: 每张表按计数降序保留的行数（`*Total` 仍是截断前的匹配总数）
    func inspectData(query: String?, limit: Int,
                     completion: @escaping (LearningDataReport) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(LearningDataReport())
                return
            }
            completion(Self.buildReport(ngram: self.ngramStore,
                                        correction: self.correctionStore,
                                        query: query, limit: limit))
        }
    }

    /// 明细装配（无副作用，须在 queue 上调用）
    private static func buildReport(ngram: UserCharNgramStore,
                                    correction: CorrectionStore,
                                    query: String?, limit: Int) -> LearningDataReport {
        var report = LearningDataReport()
        let keyword = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let limit = Swift.max(1, limit)
        let tuning = LearningTuning.fromDefaults()
        // 无关键词时恒真：走全量浏览路径
        func matches(_ text: String) -> Bool { keyword.isEmpty || text.contains(keyword) }

        report.unigramMass = ngram.unigramTotal
        report.charEntries = ngram.unigrams.count
        report.bigramEntries = ngram.bigrams.count
        report.trigramEntries = ngram.trigrams.count
        report.correctionEntries = correction.entryCount

        // MARK: 通道 B 一元
        var charRows: [LearningDataReport.CharRow] = []
        for (key, count) in ngram.unigrams {
            let text = LearningDataReport.text(for: key)
            guard matches(text) else { continue }
            charRows.append(.init(char: text, count: count))
        }
        report.charTotal = charRows.count
        report.chars = topRows(charRows, by: \.count, limit: limit)

        // MARK: 通道 B 二元
        var bigramRows: [LearningDataReport.BigramRow] = []
        for (key, count) in ngram.bigrams {
            let (prev, next) = LearningDataReport.unpackBigram(key)
            let prevText = LearningDataReport.text(for: prev)
            let nextText = LearningDataReport.text(for: next)
            guard matches(prevText) || matches(nextText) else { continue }
            bigramRows.append(.init(prev: prevText, next: nextText, count: count,
                                    total: ngram.bigramTotals[prev] ?? 0))
        }
        report.bigramTotal = bigramRows.count
        report.bigrams = topRows(bigramRows, by: \.count, limit: limit)

        // MARK: 通道 B 三元
        var trigramRows: [LearningDataReport.TrigramRow] = []
        for (key, count) in ngram.trigrams {
            let (prev2, prev1, next) = LearningDataReport.unpackTrigram(key)
            let ctx = LearningDataReport.contextText(prev2: prev2, prev1: prev1)
            let nextText = LearningDataReport.text(for: next)
            guard matches(ctx) || matches(nextText) else { continue }
            let total = ngram.trigramTotals[NgramModel.pack2(UInt64(prev2), UInt64(prev1))] ?? 0
            trigramRows.append(.init(ctx: ctx, next: nextText, count: count, total: total))
        }
        report.trigramTotal = trigramRows.count
        report.trigrams = topRows(trigramRows, by: \.count, limit: limit)

        // MARK: 通道 C1 纠错对：按胜+负的总证据量排序
        var correctionRows: [LearningDataReport.CorrectionRow] = []
        for (ctx, codes) in correction.entries {
            for (code, words) in codes {
                for (word, entry) in words {
                    guard matches(ctx) || matches(code) || matches(word) else { continue }
                    correctionRows.append(.init(
                        ctx: ctx, code: code, word: word,
                        wins: entry.wins, losses: entry.losses,
                        bonus: CorrectionStore.bonus(wins: entry.wins,
                                                     losses: entry.losses,
                                                     tuning: tuning)))
                }
            }
        }
        report.correctionTotal = correctionRows.count
        report.corrections = Array(correctionRows
            .sorted { $0.wins + $0.losses > $1.wins + $1.losses }
            .prefix(limit))
        return report
    }

    /// 按计数降序截断到 limit
    private static func topRows<Row>(_ rows: [Row], by value: KeyPath<Row, Double>,
                                     limit: Int) -> [Row] {
        Array(rows.sorted { $0[keyPath: value] > $1[keyPath: value] }.prefix(limit))
    }
}

// MARK: - 通知

extension Notification.Name {
    /// 学习数据被整体替换：清除 / 全量重建 / 导入 / 回填收尾。
    /// 「查看学习数据」窗口订阅它自动重新取数，免得在设置页操作完
    /// 还要回窗口手动点刷新。
    static let learningDataReplaced = Notification.Name("LearnerCenter.learningDataReplaced")
}
