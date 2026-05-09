//
//  Statistics.swift
//  Fire
//
//  Created by 虚幻 on 2022/5/22.
//  Copyright © 2022 qwertyyb. All rights reserved.
//

import Foundation
import Defaults
import KeychainSwift
import NanoID

struct DateCount: Hashable {
    let count: Int64
    let date: String
}

struct WordFrequency: Hashable, Identifiable {
    let text: String
    let count: Int64
    var id: String { text }
}

class Statistics {
    static let shared = Statistics()

    static let updated = Notification.Name("Statistics.updated")

    init() {
        NSLog("[Statistics] init")
        NotificationCenter.default
            .addObserver(self, selector: #selector(listener), name: Fire.candidateInserted, object: nil)
        initDB()
    }

    @objc func listener(notification: Notification) {
        NSLog("[Statistics] listener: \(notification)")
        guard let candidate = notification.userInfo?["candidate"] as? Candidate else {
            return
        }
        if !Defaults[.enableStatistics] {
            return
        }
        if candidate.type == CandidateType.placeholder { return }
        let appBundleId = notification.userInfo?["appBundleId"] as? String ?? ""
        let sql = "insert into data(text, type, code, createdAt, appBundleId) values (:text, :type, :code, :createdAt, :appBundleId)"
        var insertStatement: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &insertStatement, nil) == SQLITE_OK {
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
            sqlite3_bind_text(insertStatement,
                              sqlite3_bind_parameter_index(insertStatement, ":text"),
                              candidate.text, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insertStatement,
                              sqlite3_bind_parameter_index(insertStatement, ":type"),
                              candidate.type.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insertStatement,
                              sqlite3_bind_parameter_index(insertStatement, ":code"),
                              candidate.code, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insertStatement,
                              sqlite3_bind_parameter_index(insertStatement, ":createdAt"),
                              format.string(from: Date()), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insertStatement,
                              sqlite3_bind_parameter_index(insertStatement, ":appBundleId"),
                              appBundleId, -1, SQLITE_TRANSIENT)

            if sqlite3_step(insertStatement) == SQLITE_DONE {
                sqlite3_finalize(insertStatement)
                insertStatement = nil
            } else {
                sqlite3_finalize(insertStatement)
                insertStatement = nil
                print("errmsg: \(String(cString: sqlite3_errmsg(database)!))")
            }
        } else {
            sqlite3_finalize(insertStatement)
            insertStatement = nil
            print("prepare_errmsg: \(String(cString: sqlite3_errmsg(database)!))")
        }
        NotificationCenter.default.post(name: Statistics.updated, object: nil)
    }

    func queryCountByDate(startDate: Date, endDate: Date, appBundleId: String? = nil) -> [DateCount] {
        var queryStatement: OpaquePointer?
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.string(from: startDate)
        let end = formatter.string(from: endDate)
        let appFilter = appBundleId.map { "AND appBundleId = \"\($0)\"" } ?? ""
        let sql = """
            select date, count from
                (select
                    date(createdAt) as date,
                    sum(length(text)) as count
                from data
                where date(createdAt) >= "\(start)" and date(createdAt) <= "\(end)" \(appFilter)
                group by date(createdAt))
            order by date desc;
            PRAGMA key = 'testkey'
        """
        if sqlite3_prepare_v2(database, sql, -1, &queryStatement, nil) == SQLITE_OK {
            var results: [DateCount] = []
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                let date = String(cString: sqlite3_column_text(queryStatement, 0))
                let count = sqlite3_column_int64(queryStatement, 1)
                let dateCount = DateCount(count: count, date: date)
                results.append(dateCount)
            }
            sqlite3_finalize(queryStatement)
            return results.sorted { prev, next in
                return next.date > prev.date
            }
        } else {
            return []
        }
    }

    func queryTotalCount(appBundleId: String? = nil) -> Int64 {
        let appFilter = appBundleId.map { "WHERE appBundleId = \"\($0)\"" } ?? ""
        let sql = "select sum(length(text)) as total from data \(appFilter)"
        var queryStatement: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &queryStatement, nil) == SQLITE_OK
            && sqlite3_step(queryStatement) == SQLITE_ROW {
            let count = sqlite3_column_int64(queryStatement, 0)
            sqlite3_finalize(queryStatement)
            return count
        }
        return 0
    }

    func queryWordFrequency(limit: Int = 50, appBundleId: String? = nil) -> [WordFrequency] {
        let appFilter = appBundleId.map { "WHERE appBundleId = \"\($0)\"" } ?? ""
        let sql = """
            SELECT text, COUNT(*) as count
            FROM data
            \(appFilter)
            GROUP BY text
            ORDER BY count DESC
            LIMIT \(limit)
        """
        var queryStatement: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &queryStatement, nil) == SQLITE_OK {
            var results: [WordFrequency] = []
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                let text = String(cString: sqlite3_column_text(queryStatement, 0))
                let count = sqlite3_column_int64(queryStatement, 1)
                results.append(WordFrequency(text: text, count: count))
            }
            sqlite3_finalize(queryStatement)
            return results
        } else {
            sqlite3_finalize(queryStatement)
            return []
        }
    }

    struct AppCount: Hashable, Identifiable {
        let appBundleId: String
        let count: Int64
        var id: String { appBundleId }
    }

    func queryCountByApp(startDate: Date? = nil, endDate: Date? = nil) -> [AppCount] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var conditions: [String] = []
        if let start = startDate { conditions.append("date(createdAt) >= \"\(formatter.string(from: start))\"") }
        if let end = endDate { conditions.append("date(createdAt) <= \"\(formatter.string(from: end))\"") }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT appBundleId, sum(length(text)) as count
            FROM data
            \(whereClause)
            GROUP BY appBundleId
            ORDER BY count DESC
        """
        var queryStatement: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &queryStatement, nil) == SQLITE_OK {
            var results: [AppCount] = []
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                let appBundleId = String(cString: sqlite3_column_text(queryStatement, 0))
                let count = sqlite3_column_int64(queryStatement, 1)
                results.append(AppCount(appBundleId: appBundleId, count: count))
            }
            sqlite3_finalize(queryStatement)
            return results
        } else {
            sqlite3_finalize(queryStatement)
            return []
        }
    }

    struct Record: Codable {
        let text: String
        let type: String
        let code: String
        let createdAt: String
        let appBundleId: String?
    }

    struct Backup: Codable {
        let version: Int
        let exportedAt: String
        let data: [Record]
    }

    func backup(to url: URL) throws {
        let sql = "SELECT text, type, code, createdAt, appBundleId FROM data ORDER BY id ASC"
        var stmt: OpaquePointer?
        var records: [Record] = []
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                records.append(Record(
                    text: String(cString: sqlite3_column_text(stmt, 0)),
                    type: String(cString: sqlite3_column_text(stmt, 1)),
                    code: String(cString: sqlite3_column_text(stmt, 2)),
                    createdAt: String(cString: sqlite3_column_text(stmt, 3)),
                    appBundleId: sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                ))
            }
        }
        sqlite3_finalize(stmt)
        let payload = Backup(version: 1, exportedAt: ISO8601DateFormatter().string(from: Date()), data: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(payload).write(to: url)
    }

    func restore(from url: URL, merge: Bool) throws {
        let payload = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
        if !merge {
            sqlite3_exec(database, "DELETE FROM data", nil, nil, nil)
        }
        let sql = "INSERT INTO data(text, type, code, createdAt, appBundleId) VALUES (:text, :type, :code, :createdAt, :appBundleId)"
        sqlite3_exec(database, "BEGIN TRANSACTION", nil, nil, nil)
        for record in payload.data {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, sqlite3_bind_parameter_index(stmt, ":text"), record.text, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, sqlite3_bind_parameter_index(stmt, ":type"), record.type, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, sqlite3_bind_parameter_index(stmt, ":code"), record.code, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, sqlite3_bind_parameter_index(stmt, ":createdAt"), record.createdAt, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, sqlite3_bind_parameter_index(stmt, ":appBundleId"), record.appBundleId ?? "", -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        sqlite3_exec(database, "COMMIT", nil, nil, nil)
        NotificationCenter.default.post(name: Statistics.updated, object: nil)
    }

    func exportWordFrequencyCSV(to url: URL) throws {
        let sql = """
            SELECT text, appBundleId, COUNT(*) as count
            FROM data
            GROUP BY text, appBundleId
            ORDER BY count DESC
            LIMIT 10000
        """
        var stmt: OpaquePointer?
        var csv = "词/字,应用ID,次数\n"
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let text = String(cString: sqlite3_column_text(stmt, 0))
                let appBundleId = String(cString: sqlite3_column_text(stmt, 1))
                let count = sqlite3_column_int64(stmt, 2)
                let escapedText = text.replacingOccurrences(of: "\"", with: "\"\"")
                csv += "\"\(escapedText)\",\(appBundleId),\(count)\n"
            }
        }
        sqlite3_finalize(stmt)
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }

    func clear() {
        let sql = "delete from data"
        sqlite3_exec(database, sql, nil, nil, nil)
        NotificationCenter.default.post(name: Statistics.updated, object: nil)
    }

    private var database: OpaquePointer?
    private let keychain = KeychainSwift(keyPrefix: Bundle.main.bundleIdentifier!)
    private let upgrade = [
        """
        CREATE TABLE IF NOT EXISTS "data" (
            "id" INTEGER PRIMARY KEY NOT NULL,
            "text" TEXT NOT NULL,
            "type" TEXT NOT NULL,
            "code" TEXT NOT NULL,
            "createdAt" TEXT NOT NULL DEFAULT (datetime('now'))
        )
        """,
        "ALTER TABLE data ADD COLUMN appBundleId TEXT NOT NULL DEFAULT ''"
    ]

    private func getVersion() -> Int32 {
        let sql = "PRAGMA user_version"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            let version = sqlite3_column_int(stmt, 0)
            sqlite3_finalize(stmt)
            return version
        }
        sqlite3_finalize(stmt)
        return 0
    }

    private func setVersion(_ version: Int32) -> Bool {
        let sql = "PRAGMA user_version = \(version)"
        if sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK {
            return true
        }
        return false
    }

    private func migrate() -> Bool {
        let curVersion = getVersion()
        NSLog("[Statistics] migrate curVersion: \(curVersion)")
        if curVersion >= upgrade.count {
            return true
        }
        for i in Int(curVersion)..<upgrade.count {
            sqlite3_exec(database, upgrade[i], nil, nil, nil)
        }
        NSLog("[Statistics] migrate setVersion: \(upgrade.count)")
        return setVersion(Int32(upgrade.count))
    }

    private func initDB() {
        let dirPath = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first! + "/" + Bundle.main.bundleIdentifier!

        // create parent directory iff it doesn’t exist
        try? FileManager.default.createDirectory(
            atPath: dirPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        NSLog("[Statistics] init DB, database path in \(dirPath)")
        var key = keychain.get("dbkey")
        if key == nil {
            key = ID(alphabet: .urlSafe, size: 16).generate()
            if !keychain.set(key!, forKey: "dbkey") {
                NSLog("[Statistics] write dbkey failed: \(keychain.lastResultCode)")
                return
            }
        }
        if sqlite3_open_v2(
            dirPath + "/statistics.db",
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK {
            sqlite3_key(database, key!, Int32(key!.count))
            _ = migrate()
        } else {
            NSLog("[Statistics] init DB, open error: \(String(cString: sqlite3_errmsg(database)))")
        }
    }
}
