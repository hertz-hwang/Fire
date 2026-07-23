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
import AppKit

struct DateCount: Hashable {
    let count: Int64
    let date: String
}

struct WordFrequency: Hashable, Identifiable {
    let text: String
    let count: Int64
    var id: String { text }
}

/// 用户词频条目（统计页 - 用户词频）
///  - text: 字词
///  - code: 输入法编码
///  - count: 该 (字词, 编码, 应用) 组合的累计上屏次数
///  - appBundleId: 应用 bundle identifier
///  - appName: 本地化应用名；解析失败时回退到 bundle id
struct WordFrequencyEntry: Hashable, Identifiable {
    let text: String
    let code: String
    let count: Int64
    let appBundleId: String
    let appName: String
    var id: String { "\(text)\t\(code)\t\(appBundleId)" }
}

// MARK: - 扩展统计模型

/// 输入统计摘要（统计页 - 输入统计）
struct StatsSummary {
    /// 今日输入字符数
    var todayChars: Int64 = 0
    /// 今日上屏次数
    var todayCommits: Int64 = 0
    /// 今日平均码长（候选上屏）
    var todayAvgCodeLen: Double = 0
    /// 近 7 日总字符数
    var weekChars: Int64 = 0
    /// 近 30 日总字符数
    var monthChars: Int64 = 0
    /// 累计字符数
    var totalChars: Int64 = 0
    /// 累计天数（有数据的不同日期数）
    var activeDays: Int64 = 0
    /// 连续输入天数（截止今天，含今天）
    var streak: Int = 0
    /// 历史最长连续天数
    var maxStreak: Int = 0
    /// 今日最快速度（字/分钟）
    var todayMaxSpeed: Int = 0
    /// 今日平均速度（字/分钟）
    var todayAvgSpeed: Int = 0
    /// 首次使用日期
    var firstDay: String = ""
}

/// 时段分布单元（统计页 - 今日时段分布）
struct HourCount: Hashable, Identifiable {
    let hour: Int      // 0..23
    let count: Int64   // 字符数
    let commits: Int64 // 上屏次数
    var id: Int { hour }
}

/// 输入详情（统计页 - 输入详情）
struct InputDetail: Hashable, Identifiable {
    let id: Int64
    let text: String
    let code: String
    let type: String
    let createdAt: String  // "yyyy-MM-dd'T'HH:mm:ss.SSS"
    let appBundleId: String
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

    /// 用户词频查询（统计页 - 用户词频）
    ///  - 按 (text, code, appBundleId) 聚合上屏次数
    ///  - type / appBundleId / searchText 为 nil 表示不筛选
    ///  - searchText 仅匹配 text 字段（LIKE 包含）
    func queryWordFrequencyEntries(
        type: String? = nil,
        appBundleId: String? = nil,
        searchText: String? = nil,
        limit: Int = 10000
    ) -> [WordFrequencyEntry] {
        var conditions: [String] = []
        var binds: [String] = []
        if let type = type {
            switch type {
            case "wb", "py", "user", "placeholder":
                conditions.append("type = ?")
                binds.append(type)
            default:
                break
            }
        }
        if let app = appBundleId, !app.isEmpty {
            conditions.append("appBundleId = ?")
            binds.append(app)
        }
        let trimmedSearch = searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedSearch.isEmpty {
            conditions.append("text LIKE ? ESCAPE '\\'")
            let escaped = trimmedSearch
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            binds.append("%\(escaped)%")
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let safeLimit = max(1, limit)
        let sql = """
            SELECT text, code, appBundleId, COUNT(*) as count
            FROM data
            \(whereClause)
            GROUP BY text, code, appBundleId
            ORDER BY count DESC, text ASC
            LIMIT \(safeLimit)
        """
        var stmt: OpaquePointer?
        var entries: [WordFrequencyEntry] = []
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            var idx: Int32 = 1
            for value in binds {
                sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
                idx += 1
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let text = String(cString: sqlite3_column_text(stmt, 0))
                let code: String = {
                    if let p = sqlite3_column_text(stmt, 1) { return String(cString: p) }
                    return ""
                }()
                let appBundleId: String = {
                    if let p = sqlite3_column_text(stmt, 2) { return String(cString: p) }
                    return ""
                }()
                let count = sqlite3_column_int64(stmt, 3)
                let appName = Statistics.appDisplayName(for: appBundleId)
                entries.append(WordFrequencyEntry(
                    text: text,
                    code: code,
                    count: count,
                    appBundleId: appBundleId,
                    appName: appName
                ))
            }
        }
        sqlite3_finalize(stmt)
        return entries
    }

    /// 应用 bundle identifier → 本地化显示名（解析失败时回退到 bundle id）
    static func appDisplayName(for bundleId: String) -> String {
        guard !bundleId.isEmpty else { return "" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleId
    }

    /// 用户词频对应的所有应用 bundle id（用于 UI 应用筛选下拉）
    func queryWordFrequencyApps() -> [String] {
        let sql = """
            SELECT appBundleId, COUNT(*) as total
            FROM data
            GROUP BY appBundleId
            ORDER BY total DESC
        """
        var stmt: OpaquePointer?
        var ids: [String] = []
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id: String = {
                    if let p = sqlite3_column_text(stmt, 0) { return String(cString: p) }
                    return ""
                }()
                if !id.isEmpty { ids.append(id) }
            }
        }
        sqlite3_finalize(stmt)
        return ids
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

    // MARK: - 统计页扩展查询

    /// 查询综合统计摘要（输入统计页使用）
    func queryStatsSummary() -> StatsSummary {
        var summary = StatsSummary()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())
        summary.todayChars = queryTotalCount(today: today)
        summary.weekChars = queryTotalCount(daysBack: 7)
        summary.monthChars = queryTotalCount(daysBack: 30)
        summary.totalChars = queryTotalCount()

        // 今日上屏次数与平均码长
        let (commits, avgCode) = queryTodayMetrics()
        summary.todayCommits = commits
        summary.todayAvgCodeLen = avgCode

        // 时段速度（今日最快/平均 字/分钟）
        let (maxSpeed, avgSpeed) = queryTodaySpeed()
        summary.todayMaxSpeed = maxSpeed
        summary.todayAvgSpeed = avgSpeed

        // 连续天数 / 首次日 / 最长连续
        let (streak, maxStreak, firstDay, activeDays) = queryStreakInfo()
        summary.streak = streak
        summary.maxStreak = maxStreak
        summary.firstDay = firstDay
        summary.activeDays = activeDays

        return summary
    }

    /// 给定日期（yyyy-MM-dd），当日总字符数
    func queryTotalCount(today: String) -> Int64 {
        let sql = "SELECT COALESCE(SUM(LENGTH(text)), 0) FROM data WHERE date(createdAt) = ?"
        return singleInt64(sql: sql, bind: today)
    }

    /// 近 N 天（含今天）总字符数
    func queryTotalCount(daysBack: Int) -> Int64 {
        guard daysBack > 0 else { return queryTotalCount() }
        let sql = """
            SELECT COALESCE(SUM(LENGTH(text)), 0) FROM data
            WHERE date(createdAt) >= date('now', ?)
        """
        return singleInt64(sql: sql, bind: "-\(daysBack - 1) day")
    }

    /// 今日上屏次数与平均码长（code 非空视为候选上屏）
    private func queryTodayMetrics() -> (Int64, Double) {
        let commitSQL = "SELECT COUNT(*) FROM data WHERE date(createdAt) = date('now')"
        let avgSQL = """
            SELECT COALESCE(AVG(LENGTH(code)), 0) FROM data
            WHERE date(createdAt) = date('now') AND code != ''
        """
        let commits = singleInt64(sql: commitSQL)
        let avg = singleDouble(sql: avgSQL)
        return (commits, avg)
    }

    /// 今日每小时字符数（用于今日时段分布）
    func queryTodayHourDistribution() -> [HourCount] {
        let sql = """
            SELECT
                CAST(strftime('%H', createdAt) AS INTEGER) AS hour,
                COALESCE(SUM(LENGTH(text)), 0) AS chars,
                COUNT(*) AS commits
            FROM data
            WHERE date(createdAt) = date('now')
            GROUP BY hour
            ORDER BY hour ASC
        """
        var stmt: OpaquePointer?
        var map: [Int: (Int64, Int64)] = [:]
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let hour = Int(sqlite3_column_int(stmt, 0))
                let chars = sqlite3_column_int64(stmt, 1)
                let commits = sqlite3_column_int64(stmt, 2)
                map[hour] = (chars, commits)
            }
        }
        sqlite3_finalize(stmt)
        return (0..<24).map { h in
            let pair = map[h] ?? (0, 0)
            return HourCount(hour: h, count: pair.0, commits: pair.1)
        }
    }

    /// 输入详情（按 id 倒序，分页）
    func queryInputDetails(limit: Int = 50, offset: Int = 0) -> [InputDetail] {
        return queryInputDetails(type: "all", limit: limit, offset: offset)
    }

    /// 输入详情（按类型筛选和小时筛选，分页）
    func queryInputDetails(type: String, hour: Int? = nil, limit: Int = 50, offset: Int = 0) -> [InputDetail] {
        var conditions: [String] = []
        let bindType: Bool
        switch type {
        case "all":
            bindType = false
        case "wb", "py", "user", "placeholder":
            conditions.append("type = ?")
            bindType = true
        default:
            bindType = false
        }
        if hour != nil {
            conditions.append("CAST(strftime('%H', createdAt) AS INTEGER) = ?")
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT id, text, code, type, createdAt, appBundleId
            FROM data
            \(whereClause)
            ORDER BY id DESC
            LIMIT ? OFFSET ?
        """
        var stmt: OpaquePointer?
        var results: [InputDetail] = []
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            var paramIdx: Int32 = 1
            if bindType {
                sqlite3_bind_text(stmt, paramIdx, type, -1, SQLITE_TRANSIENT)
                paramIdx += 1
            }
            if let h = hour {
                sqlite3_bind_int(stmt, paramIdx, Int32(h))
                paramIdx += 1
            }
            sqlite3_bind_int(stmt, paramIdx, Int32(limit))
            paramIdx += 1
            sqlite3_bind_int(stmt, paramIdx, Int32(offset))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let text = String(cString: sqlite3_column_text(stmt, 1))
                let code = String(cString: sqlite3_column_text(stmt, 2))
                let type = String(cString: sqlite3_column_text(stmt, 3))
                let createdAt = String(cString: sqlite3_column_text(stmt, 4))
                let appBundleId: String = {
                    if let p = sqlite3_column_text(stmt, 5) { return String(cString: p) }
                    return ""
                }()
                results.append(InputDetail(
                    id: id, text: text, code: code, type: type,
                    createdAt: createdAt, appBundleId: appBundleId
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    /// 输入详情记录总数（用于分页，按类型筛选和小时筛选）
    func queryInputDetailCount(type: String, hour: Int? = nil) -> Int64 {
        var conditions: [String] = []
        let bindType: Bool
        switch type {
        case "all":
            bindType = false
        case "wb", "py", "user", "placeholder":
            conditions.append("type = ?")
            bindType = true
        default:
            bindType = false
        }
        if hour != nil {
            conditions.append("CAST(strftime('%H', createdAt) AS INTEGER) = ?")
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = "SELECT COUNT(*) FROM data \(whereClause)"
        var stmt: OpaquePointer?
        var value: Int64 = 0
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            var paramIdx: Int32 = 1
            if bindType {
                sqlite3_bind_text(stmt, paramIdx, type, -1, SQLITE_TRANSIENT)
                paramIdx += 1
            }
            if let h = hour {
                sqlite3_bind_int(stmt, paramIdx, Int32(h))
                paramIdx += 1
            }
            if sqlite3_step(stmt) == SQLITE_ROW {
                value = sqlite3_column_int64(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)
        return value
    }

    /// 连续输入天数信息：(当前连续, 最长连续, 首次日期, 累计有数据天数)
    private func queryStreakInfo() -> (Int, Int, String, Int64) {
        let sql = """
            SELECT date(createdAt) AS d, SUM(LENGTH(text)) AS chars
            FROM data
            GROUP BY d
            ORDER BY d ASC
        """
        var stmt: OpaquePointer?
        var dates: [String] = []
        var firstDay = ""
        var activeDays: Int64 = 0
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let d = String(cString: sqlite3_column_text(stmt, 0))
                let chars = sqlite3_column_int64(stmt, 1)
                if chars > 0 {
                    dates.append(d)
                    activeDays += 1
                    if firstDay.isEmpty { firstDay = d }
                }
            }
        }
        sqlite3_finalize(stmt)

        guard !dates.isEmpty else { return (0, 0, "", 0) }

        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")

        // 计算最长连续
        var maxStreak = 1
        var runMax = 1
        for i in 1..<dates.count {
            guard let prev = parser.date(from: dates[i - 1]),
                  let cur = parser.date(from: dates[i]) else { continue }
            let diff = Calendar(identifier: .gregorian).dateComponents([.day], from: prev, to: cur).day ?? 0
            if diff == 1 {
                runMax += 1
            } else {
                runMax = 1
            }
            if runMax > maxStreak { maxStreak = runMax }
        }

        // 当前连续（从今天往前数）
        var streak = 0
        let todayStr = parser.string(from: Date())
        var index = dates.count - 1
        // 允许今天还没有数据，从昨天算起
        var cursorStr = todayStr
        if index >= 0 && dates[index] == todayStr {
            streak += 1
            index -= 1
            // 前一天
            if let today = parser.date(from: todayStr),
               let yest = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: today) {
                cursorStr = parser.string(from: yest)
            }
        } else {
            // 今天没数据，从昨天开始看
            if let today = parser.date(from: todayStr),
               let yest = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: today) {
                cursorStr = parser.string(from: yest)
            }
        }
        while index >= 0 && dates[index] == cursorStr {
            streak += 1
            index -= 1
            if let cur = parser.date(from: cursorStr),
               let prev = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: cur) {
                cursorStr = parser.string(from: prev)
            } else {
                break
            }
        }
        // 若今天没数据但有昨天的连续，从昨天起算 streak
        if streak == 0 {
            streak = 0
            // 重新尝试：仅当今天没数据时，从昨天开始算
            if let today = parser.date(from: todayStr),
               let yest = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: today) {
                var cursor = yest
                var idx = dates.count - 1
                var count = 0
                while idx >= 0,
                      let d = parser.date(from: dates[idx]),
                      Calendar(identifier: .gregorian).isDate(d, inSameDayAs: cursor) {
                    count += 1
                    idx -= 1
                    guard let p = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: cursor) else {
                        break
                    }
                    cursor = p
                }
                streak = count
            }
        }

        return (streak, maxStreak, firstDay, activeDays)
    }

    /// 今日速度统计：返回 (最快字/分钟, 平均字/分钟)
    /// 算法（按用户要求）：
    /// 1. 把今日上屏按"同一应用 + 间隔 ≤ 5s"切成连续的 burst 段
    /// 2. 只累计"字数 ≥ 10"的 burst（去除试词、改字、跨窗切换等零碎输入）
    /// 3. 最快：在所有符合 burst 拼成的时序上做 1 分钟滑动窗口最大值
    /// 4. 平均：所有符合 burst 的总字数 / 这些 burst 的总持续时间
    ///    数学上仍然保证 max ≥ avg（滑动窗口可以跨 burst 内部或者 burst 边界衔接）
    private func queryTodaySpeed() -> (Int, Int) {
        let sql = """
            SELECT createdAt, LENGTH(text), appBundleId FROM data
            WHERE date(createdAt) = date('now')
            ORDER BY createdAt ASC
        """
        var stmt: OpaquePointer?
        var rows: [(Date, Int64, String)] = []
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        parser.timeZone = TimeZone.current
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = String(cString: sqlite3_column_text(stmt, 0))
                let len = sqlite3_column_int64(stmt, 1)
                let app: String = {
                    if let p = sqlite3_column_text(stmt, 2) { return String(cString: p) }
                    return ""
                }()
                if let d = parser.date(from: ts) {
                    rows.append((d, len, app))
                }
            }
        }
        sqlite3_finalize(stmt)

        guard !rows.isEmpty else { return (0, 0) }

        // ---- 1. 切 burst：同应用 + 相邻上屏间隔 ≤ 5 秒视为连续输入 ----
        let burstGap: Double = 5
        var bursts: [[(Date, Int64)]] = []
        var cur: [(Date, Int64)] = []
        var curApp = ""
        for (ts, len, app) in rows {
            if cur.isEmpty {
                cur = [(ts, len)]
                curApp = app
                continue
            }
            let gap = ts.timeIntervalSince(cur.last!.0)
            if app == curApp && gap <= burstGap {
                cur.append((ts, len))
            } else {
                bursts.append(cur)
                cur = [(ts, len)]
                curApp = app
            }
        }
        if !cur.isEmpty { bursts.append(cur) }

        // ---- 2. 只留字数 ≥ 10 的 burst（同一窗口连续输入超过 10 字）----
        let qualifying = bursts.filter { b in
            b.reduce(0 as Int64) { $0 + $1.1 } >= 10
        }
        guard !qualifying.isEmpty else { return (0, 0) }

        // ---- 3. 最快：在所有符合 burst 拼接的时序上滑动 1 分钟窗口 ----
        var seq: [(Date, Int64)] = []
        for b in qualifying { seq.append(contentsOf: b) }

        let windowSecs: Double = 60
        var maxSpeed = 0
        for i in 0..<seq.count {
            var sum: Int64 = 0
            let anchor = seq[i].0
            for j in i..<seq.count {
                if seq[j].0.timeIntervalSince(anchor) <= windowSecs {
                    sum += seq[j].1
                } else {
                    break
                }
            }
            if Int(sum) > maxSpeed { maxSpeed = Int(sum) }
        }

        // ---- 4. 平均：总字数 / 这些 burst 的总持续分钟数 ----
        //      用每个 burst 首尾时间差作为"打字时长"，跨 burst 间的空闲不计
        var totalChars: Int64 = 0
        var totalBurstSeconds: Double = 0
        for b in qualifying {
            let chars = b.reduce(0 as Int64) { $0 + $1.1 }
            totalChars += chars
            if let first = b.first?.0, let last = b.last?.0 {
                // 至少计 1 秒，避免单点 burst 除以 0 出现虚高
                totalBurstSeconds += max(1.0, last.timeIntervalSince(first))
            }
        }
        let avgSpeed = totalBurstSeconds > 0
            ? Int((Double(totalChars) / (totalBurstSeconds / 60.0)).rounded())
            : 0

        return (maxSpeed, avgSpeed)
    }

    /// 单条 Int64 聚合查询辅助
    /// 修复说明：`sqlite3_bind_parameter_index(stmt, "?")` 对匿名 `?` 占位符永远返回 0
    /// （SQLite 文档明确说明非 `?NNN` / `:AAA` / `@AAA` / `$AAA` 形式的名称返回 0），
    /// 结果参数根本未绑定，WHERE 条件匹配 0 行，所以今日/本周/本月输入一直是 0。
    /// 改为位置绑定，与 queryInputDetails / queryRecentDailyCounts 保持一致。
    private func singleInt64(sql: String, bind: String? = nil) -> Int64 {
        var stmt: OpaquePointer?
        var value: Int64 = 0
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            if let b = bind {
                sqlite3_bind_text(stmt, 1, b, -1, SQLITE_TRANSIENT)
            }
            if sqlite3_step(stmt) == SQLITE_ROW {
                value = sqlite3_column_int64(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)
        return value
    }

    /// 单条 Double 聚合查询辅助
    private func singleDouble(sql: String) -> Double {
        var stmt: OpaquePointer?
        var value: Double = 0
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                value = sqlite3_column_double(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)
        return value
    }

    /// 输入详情按天聚合（用于输入详情页按天筛选）
    func queryDailyCommits(date: String) -> Int64 {
        let sql = "SELECT COUNT(*) FROM data WHERE date(createdAt) = ?"
        return singleInt64(sql: sql, bind: date)
    }

    /// 输入详情按天聚合字符数
    func queryDailyChars(date: String) -> Int64 {
        let sql = "SELECT COALESCE(SUM(LENGTH(text)), 0) FROM data WHERE date(createdAt) = ?"
        return singleInt64(sql: sql, bind: date)
    }

    /// 近 N 天每日字符数（输入日历用，含无数据天补零）
    func queryRecentDailyCounts(days: Int) -> [DateCount] {
        guard days > 0 else { return [] }
        let sql = """
            SELECT date(createdAt) AS d, SUM(LENGTH(text)) AS chars
            FROM data
            WHERE date(createdAt) >= date('now', ?)
            GROUP BY d
        """
        var stmt: OpaquePointer?
        var map: [String: Int64] = [:]
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, "-\(days - 1) day", -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let d = String(cString: sqlite3_column_text(stmt, 0))
                let chars = sqlite3_column_int64(stmt, 1)
                map[d] = chars
            }
        }
        sqlite3_finalize(stmt)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        var results: [DateCount] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = fmt.string(from: d)
            results.append(DateCount(count: map[key] ?? 0, date: key))
        }
        return results
    }

    /// 删除早于某日期之前的数据（用于清理过期数据）
    func pruneBefore(_ date: Date) -> Int64 {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dateStr = fmt.string(from: date)
        let sql = "DELETE FROM data WHERE date(createdAt) < ?"
        var stmt: OpaquePointer?
        var changes: Int64 = 0
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, dateStr, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            changes = Int64(sqlite3_changes(database))
        }
        sqlite3_finalize(stmt)
        return changes
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
        try exportWordFrequencyCSV(
            to: url,
            type: nil,
            appBundleId: nil,
            searchText: nil,
            limit: 50000
        )
    }

    /// 导出用户词频为 CSV（列：字词,编码,次数,应用名称）
    /// 筛选条件与 queryWordFrequencyEntries 一致。
    func exportWordFrequencyCSV(
        to url: URL,
        type: String? = nil,
        appBundleId: String? = nil,
        searchText: String? = nil,
        limit: Int = 50000
    ) throws {
        let entries = queryWordFrequencyEntries(
            type: type,
            appBundleId: appBundleId,
            searchText: searchText,
            limit: limit
        )
        var csv = "字词,编码,次数,应用名称\n"
        for entry in entries {
            let displayApp = entry.appName.isEmpty ? entry.appBundleId : entry.appName
            let row = [
                Statistics.csvEscape(entry.text),
                Statistics.csvEscape(entry.code),
                String(entry.count),
                Statistics.csvEscape(displayApp)
            ].joined(separator: ",")
            csv += row + "\n"
        }
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }

    /// CSV 字段转义：包含分隔符或引号时整体用双引号包裹，内部引号成对转义
    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return s
    }

    /// 导出输入详情为 CSV
    func exportInputDetailsCSV(to url: URL, typeFilter: String = "all", hourFilter: Int? = nil) throws {
        var conditions: [String] = []
        switch typeFilter {
        case "wb", "py", "user", "placeholder":
            conditions.append("type = '\(typeFilter)'")
        default:
            break
        }
        if let hour = hourFilter {
            conditions.append("CAST(strftime('%H', createdAt) AS INTEGER) = \(hour)")
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT id, text, code, type, createdAt, appBundleId
            FROM data
            \(whereClause)
            ORDER BY id DESC
            LIMIT 50000
        """
        var stmt: OpaquePointer?
        var csv = "ID,文本,编码,类型,时间,应用\n"
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let text = String(cString: sqlite3_column_text(stmt, 1))
                let code = String(cString: sqlite3_column_text(stmt, 2))
                let type = String(cString: sqlite3_column_text(stmt, 3))
                let createdAt = String(cString: sqlite3_column_text(stmt, 4))
                let appBundleId: String = {
                    if let p = sqlite3_column_text(stmt, 5) { return String(cString: p) }
                    return ""
                }()
                let escText = text.replacingOccurrences(of: "\"", with: "\"\"")
                let escCode = code.replacingOccurrences(of: "\"", with: "\"\"")
                let escApp = appBundleId.replacingOccurrences(of: "\"", with: "\"\"")
                csv += "\(id),\"\(escText)\",\"\(escCode)\",\(type),\(createdAt),\"\(escApp)\"\n"
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
