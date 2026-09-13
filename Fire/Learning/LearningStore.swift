//
//  LearningStore.swift
//  Fire
//
//  学习系统持久化：user-learning.db（SQLCipher 加密，密钥独立于统计库，
//  同样落在 Keychain）。WAL 模式 + 防抖批量事务，写盘全部在后台队列。
//
//  表设计：n-gram 键直接存 pack2/pack3 的 UInt64 整数（< 2^63，SQLite
//  INTEGER 直存，免去字符串编解码）；纠错对键是 (ctx, code, word) 文本。
//  全局衰减日存在 meta，跨次启动衰减链不断。
//

import Foundation
import KeychainSwift
import NanoID

final class LearningStore {
    private var database: OpaquePointer?
    private let keychain = KeychainSwift(keyPrefix: Bundle.main.bundleIdentifier!)
    static let databaseName = "user-learning.db"

    private(set) var opened = false
    private(set) var databaseFilePath: String = ""

    // MARK: - 打开与建表

    init() {
        openDatabase()
    }

    deinit {
        if let database = database {
            sqlite3_close(database)
        }
    }

    private func supportDirectory() -> String {
        let dirPath = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first! + "/" + (Bundle.main.bundleIdentifier ?? "Fire")
        try? FileManager.default.createDirectory(
            atPath: dirPath, withIntermediateDirectories: true, attributes: nil)
        return dirPath
    }

    private func openDatabase() {
        databaseFilePath = supportDirectory() + "/" + Self.databaseName
        var key = keychain.get("learning-dbkey")
        if key == nil {
            key = ID(alphabet: .urlSafe, size: 16).generate()
            if !keychain.set(key!, forKey: "learning-dbkey") {
                NSLog("[Learning] write learning-dbkey failed: \(keychain.lastResultCode)")
                return
            }
        }
        guard sqlite3_open_v2(databaseFilePath, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            NSLog("[Learning] open db error: \(String(cString: sqlite3_errmsg(database)))")
            return
        }
        sqlite3_key(database, key!, Int32(key!.count))
        sqlite3_exec(database, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA synchronous=NORMAL", nil, nil, nil)
        let schema = """
        CREATE TABLE IF NOT EXISTS char_unigram(
            target INTEGER PRIMARY KEY, count REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS char_bigram(
            key INTEGER PRIMARY KEY, count REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS char_bigram_total(
            ctx INTEGER PRIMARY KEY, count REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS char_trigram(
            key INTEGER PRIMARY KEY, count REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS char_trigram_total(
            ctx INTEGER PRIMARY KEY, count REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS correction(
            ctx TEXT NOT NULL, code TEXT NOT NULL, word TEXT NOT NULL,
            wins REAL NOT NULL, losses REAL NOT NULL,
            PRIMARY KEY(ctx, code, word));
        CREATE TABLE IF NOT EXISTS meta(
            key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """
        if sqlite3_exec(database, schema, nil, nil, nil) != SQLITE_OK {
            NSLog("[Learning] schema error: \(String(cString: sqlite3_errmsg(database)))")
            return
        }
        opened = true
    }

    // MARK: - meta

    func metaValue(_ key: String) -> String? {
        guard opened, let database = database else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM meta WHERE key = ?",
                                 -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    func setMetaValue(_ value: String, forKey key: String) {
        guard opened, let database = database else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database,
                "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: - 加载

    /// 启动时把库里的计数读回内存（衰减已在落库前应用；跨启动的天差
    /// 由 store 的 lastDecayDay 接续处理）
    func load(ngramStore: UserCharNgramStore, correctionStore: CorrectionStore) {
        guard opened, let database = database else { return }
        let storedDay = (metaValue("lastDecayDay").flatMap { Int($0) }) ?? learningDayNumber()
        var uni: [UInt32: Double] = [:]
        var bi: [UInt64: Double] = [:]
        var biTotal: [UInt32: Double] = [:]
        var tri: [UInt64: Double] = [:]
        var triTotal: [UInt64: Double] = [:]
        var uniTotal = 0.0
        loadCounts("SELECT target, count FROM char_unigram", into: &uni) { $0[UInt32($1) ?? 0] = $2 }
        loadCounts("SELECT key, count FROM char_bigram", into: &bi) { $0[UInt64($1) ?? 0] = $2 }
        loadCounts("SELECT ctx, count FROM char_bigram_total", into: &biTotal) { $0[UInt32($1) ?? 0] = $2 }
        loadCounts("SELECT key, count FROM char_trigram", into: &tri) { $0[UInt64($1) ?? 0] = $2 }
        loadCounts("SELECT ctx, count FROM char_trigram_total", into: &triTotal) { $0[UInt64($1) ?? 0] = $2 }
        if let totalText = metaValue("unigramTotal"), let total = Double(totalText) {
            uniTotal = total
        }
        ngramStore.importCounts(unigrams: uni, bigrams: bi, bigramTotals: biTotal,
                                trigrams: tri, trigramTotals: triTotal,
                                unigramTotal: uniTotal, lastDecayDay: storedDay)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database,
                "SELECT ctx, code, word, wins, losses FROM correction", -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ctx = String(cString: sqlite3_column_text(stmt, 0))
            let code = String(cString: sqlite3_column_text(stmt, 1))
            let word = String(cString: sqlite3_column_text(stmt, 2))
            let wins = sqlite3_column_double(stmt, 3)
            let losses = sqlite3_column_double(stmt, 4)
            correctionStore.importEntry(ctx: ctx, code: code, word: word,
                                        wins: wins, losses: losses)
        }
        correctionStore.importLastDecayDay(storedDay)
    }

    private func loadCounts<T>(_ sql: String, into table: inout T,
                               apply: (inout T, String, Double) -> Void) {
        guard let database = database else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let count = sqlite3_column_double(stmt, 1)
            apply(&table, key, count)
        }
    }

    // MARK: - 落库

    /// 把两个 store 的脏簿记批量写入（单事务）。在后台队列调用。
    func flush(ngramStore: UserCharNgramStore, correctionStore: CorrectionStore) {
        guard opened, let database = database else { return }
        let today = learningDayNumber()
        sqlite3_exec(database, "BEGIN TRANSACTION", nil, nil, nil)

        // n-gram upserts
        for key in ngramStore.dirtyUnigrams {
            if let count = ngramStore.unigrams[key] {
                upsert("INSERT INTO char_unigram(target, count) VALUES(?, ?) "
                    + "ON CONFLICT(target) DO UPDATE SET count = excluded.count",
                       Int64(key), count)
            }
        }
        for key in ngramStore.dirtyBigrams {
            if let count = ngramStore.bigrams[key] {
                upsert("INSERT INTO char_bigram(key, count) VALUES(?, ?) "
                    + "ON CONFLICT(key) DO UPDATE SET count = excluded.count",
                       Int64(bitPattern: key), count)
            }
        }
        for key in ngramStore.dirtyBigramTotals {
            if let count = ngramStore.bigramTotals[key] {
                upsert("INSERT INTO char_bigram_total(ctx, count) VALUES(?, ?) "
                    + "ON CONFLICT(ctx) DO UPDATE SET count = excluded.count",
                       Int64(key), count)
            }
        }
        for key in ngramStore.dirtyTrigrams {
            if let count = ngramStore.trigrams[key] {
                upsert("INSERT INTO char_trigram(key, count) VALUES(?, ?) "
                    + "ON CONFLICT(key) DO UPDATE SET count = excluded.count",
                       Int64(bitPattern: key), count)
            }
        }
        for key in ngramStore.dirtyTrigramTotals {
            if let count = ngramStore.trigramTotals[key] {
                upsert("INSERT INTO char_trigram_total(ctx, count) VALUES(?, ?) "
                    + "ON CONFLICT(ctx) DO UPDATE SET count = excluded.count",
                       Int64(bitPattern: key), count)
            }
        }
        if ngramStore.unigramTotalDirty {
            setMetaValue(String(ngramStore.unigramTotal), forKey: "unigramTotal")
        }
        let deletes = ngramStore.pendingDeletes
        deleteKeys("DELETE FROM char_unigram WHERE target = ?", deletes.unigrams)
        deleteKeys("DELETE FROM char_bigram WHERE key = ?", deletes.bigrams)
        deleteKeys("DELETE FROM char_bigram_total WHERE ctx = ?", deletes.bigramTotals)
        deleteKeys("DELETE FROM char_trigram WHERE key = ?", deletes.trigrams)
        deleteKeys("DELETE FROM char_trigram_total WHERE ctx = ?", deletes.trigramTotals)

        // corrections upserts / deletes
        for key in correctionStore.dirtyKeys {
            let parts = key.components(separatedBy: "\u{1F}")
            guard parts.count == 3,
                  let entry = correctionStore.entries[parts[0]]?[parts[1]]?[parts[2]] else { continue }
            upsertCorrection(ctx: parts[0], code: parts[1], word: parts[2],
                             wins: entry.wins, losses: entry.losses)
        }
        for key in correctionStore.deletedKeys {
            let parts = key.components(separatedBy: "\u{1F}")
            guard parts.count == 3 else { continue }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(database,
                    "DELETE FROM correction WHERE ctx = ? AND code = ? AND word = ?",
                    -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, parts[0], -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, parts[1], -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, parts[2], -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        setMetaValue(String(today), forKey: "lastDecayDay")
        sqlite3_exec(database, "COMMIT", nil, nil, nil)

        // 落库完成后清空簿记
        ngramStore.dirtyUnigrams.removeAll(keepingCapacity: true)
        ngramStore.dirtyBigrams.removeAll(keepingCapacity: true)
        ngramStore.dirtyBigramTotals.removeAll(keepingCapacity: true)
        ngramStore.dirtyTrigrams.removeAll(keepingCapacity: true)
        ngramStore.dirtyTrigramTotals.removeAll(keepingCapacity: true)
        ngramStore.unigramTotalDirty = false
        ngramStore.pendingDeletes = .init()
        correctionStore.dirtyKeys.removeAll(keepingCapacity: true)
        correctionStore.deletedKeys.removeAll(keepingCapacity: true)
    }

    private func upsert(_ sql: String, _ key: Int64, _ count: Double) {
        guard let database = database else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, key)
            sqlite3_bind_double(stmt, 2, count)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func upsertCorrection(ctx: String, code: String, word: String,
                                  wins: Double, losses: Double) {
        guard let database = database else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(database,
                "INSERT INTO correction(ctx, code, word, wins, losses) VALUES(?, ?, ?, ?, ?) "
                + "ON CONFLICT(ctx, code, word) DO UPDATE SET wins = excluded.wins, losses = excluded.losses",
                -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, ctx, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, code, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, word, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 4, wins)
            sqlite3_bind_double(stmt, 5, losses)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func deleteKeys(_ sql: String, _ keys: Set<String>) {
        guard !keys.isEmpty, let database = database else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for key in keys {
            // pack3 键可达 2^63，必须走 Int64 解析（Double 会丢精度）
            guard let value = Int64(key) else { continue }
            sqlite3_bind_int64(stmt, 1, value)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
    }

    // MARK: - 清除

    /// 全量清除学习数据（设置面板一键清除）
    func clearAll() {
        guard opened, let database = database else { return }
        sqlite3_exec(database, """
            BEGIN TRANSACTION;
            DELETE FROM char_unigram;
            DELETE FROM char_bigram;
            DELETE FROM char_bigram_total;
            DELETE FROM char_trigram;
            DELETE FROM char_trigram_total;
            DELETE FROM correction;
            DELETE FROM meta;
            COMMIT;
            """, nil, nil, nil)
    }

    // MARK: - 统计库连接（历史回填 / 回放评估共用）

    /// 以 statistics.db 的 Keychain 密钥另开一条读写连接
    /// （回填需要写 learned 标记列；纯读取场景同样可用）。
    /// 返回连接，调用方负责 sqlite3_close。
    static func openStatisticsDatabase() -> OpaquePointer? {
        let dirPath = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first! + "/" + (Bundle.main.bundleIdentifier ?? "Fire")
        let path = dirPath + "/statistics.db"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let keychain = KeychainSwift(keyPrefix: Bundle.main.bundleIdentifier!)
        guard let key = keychain.get("dbkey") else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database = database else {
            sqlite3_close(database)
            return nil
        }
        sqlite3_key(database, key, Int32(key.count))
        // 校验密钥正确（错误密钥在首次读表时才报错）
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(database, "SELECT count(*) FROM sqlite_master", -1, &stmt, nil) != SQLITE_OK {
            sqlite3_finalize(stmt)
            sqlite3_close(database)
            return nil
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return database
    }
}
