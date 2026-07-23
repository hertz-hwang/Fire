//
//  StatsViewComponents.swift
//  Fire
//
//  Created by 虚幻 on 2026/7/23.
//  Copyright © 2026 qwertyyb. All rights reserved.
//
//  统计页子视图组件：输入统计 / 输入日历 / 今日时段分布 / 输入详情
//

import SwiftUI
import Defaults
import Combine
import AppKit
import UniformTypeIdentifiers

// MARK: - 工具函数与基础样式

/// 数字千分位格式化
func formatStatCount(_ count: Int64) -> String {
    return NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
}

/// 数字千分位格式化（Int）
func formatStatCount(_ count: Int) -> String {
    return formatStatCount(Int64(count))
}

/// 颜色：Fire 输入法主色调
let statPrimaryColor = Color(red: 251.0 / 255.0, green: 82.0 / 255.0, blue: 0)

/// 统计卡片标题与数值
struct StatCardTitle: View {
    let title: String
    let value: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title2.bold())
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let sub = subtitle {
                Text(sub)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.03))
        )
    }
}

// MARK: - 1. 输入统计（摘要卡片）

struct InputStatsView: View {
    @ObservedObject var model: InputStatsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summaryGrid
                Divider()
                speedSection
                Divider()
                streakSection
            }
            .padding(.vertical, 8)
        }
    }

    private var summaryGrid: some View {
        let summary = model.summary
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            StatCardTitle(
                title: "今日输入",
                value: formatStatCount(summary.todayChars),
                subtitle: "\(formatStatCount(summary.todayCommits)) 次上屏"
            )
            StatCardTitle(
                title: "本周输入",
                value: formatStatCount(summary.weekChars)
            )
            StatCardTitle(
                title: "本月输入",
                value: formatStatCount(summary.monthChars)
            )
            StatCardTitle(
                title: "累计输入",
                value: formatStatCount(summary.totalChars),
                subtitle: "活跃 \(formatStatCount(summary.activeDays)) 天"
            )
            StatCardTitle(
                title: "今日平均码长",
                value: String(format: "%.2f", summary.todayAvgCodeLen),
                subtitle: "按候选上屏计"
            )
            StatCardTitle(
                title: "今日最快速度",
                value: "\(formatStatCount(summary.todayMaxSpeed)) 字/分"
            )
            StatCardTitle(
                title: "今日平均速度",
                value: "\(formatStatCount(summary.todayAvgSpeed)) 字/分"
            )
            StatCardTitle(
                title: "最长连续",
                value: "\(formatStatCount(summary.maxStreak)) 天",
                subtitle: summary.firstDay.isEmpty ? nil : "首次: \(summary.firstDay)"
            )
        }
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("速度与连续天数")
                .font(.subheadline.bold())
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                statItem(label: "当前连续", value: "\(formatStatCount(model.summary.streak)) 天")
                statItem(label: "最长连续", value: "\(formatStatCount(model.summary.maxStreak)) 天")
                statItem(label: "累计天数", value: "\(formatStatCount(model.summary.activeDays)) 天")
            }
        }
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3.bold())
                .foregroundColor(.primary)
        }
    }

    private var streakSection: some View {
        HStack {
            Image(systemName: "flame.fill")
                .foregroundColor(statPrimaryColor)
            Text(model.summary.streak > 0
                 ? "已连续输入 \(model.summary.streak) 天，继续保持！"
                 : "今日还未开始记录，去敲几个字试试看吧～")
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.08))
        )
    }
}

/// 输入统计 ViewModel
final class InputStatsModel: ObservableObject {
    @Published var summary: StatsSummary = StatsSummary()

    private var cancellables = Set<AnyCancellable>()

    init() {
        refresh()
        NotificationCenter.default
            .publisher(for: Statistics.updated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    func refresh() {
        guard FirePreferencesController.shared.isVisible else { return }
        summary = Statistics.shared.queryStatsSummary()
    }
}

// MARK: - 2. 输入日历（热力图）

struct InputCalendarView: View {
    @ObservedObject var model: InputCalendarModel

    private let cellSize: CGFloat = 12
    private let cellSpacing: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("范围", selection: $model.monthsBack) {
                    Text("近 3 个月").tag(1)
                    Text("近 6 个月").tag(2)
                    Text("近 12 个月").tag(3)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Spacer()
                Text("总计 \(formatStatCount(model.totalInRange)) 字")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            heatmap
            legend
            if let selected = model.selectedDay {
                selectedInfoView(selected)
            }
        }
    }

    private var heatmap: some View {
        let weeks = model.weeks
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                // 月份标签行
                HStack(spacing: 0) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { (idx, week) in
                        Text(monthLabel(for: week))
                            .font(.caption2)
                            .foregroundColor(idx == 0 ? .clear : .secondary)
                            .frame(width: cellSize + cellSpacing, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: cellSpacing) {
                    // 星期标签
                    VStack(spacing: cellSpacing) {
                        ForEach(0..<7, id: \.self) { dow in
                            Text(weekdayShort(dow))
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .frame(width: 18, height: cellSize, alignment: .trailing)
                                .opacity(dow % 2 == 1 ? 0 : 1)
                        }
                    }
                    ForEach(Array(weeks.enumerated()), id: \.offset) { (_, week) in
                        VStack(spacing: cellSpacing) {
                            ForEach(0..<7, id: \.self) { dow in
                                if let day = week.first(where: { $0.dayOfWeek == dow }) {
                                    dayCell(day)
                                } else {
                                    Color.clear.frame(width: cellSize, height: cellSize)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func dayCell(_ day: CalendarDay) -> some View {
        let color = model.colorLevel(for: day.count)
        return RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: cellSize, height: cellSize)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.black.opacity(model.selectedDay?.date == day.date ? 0.4 : 0.05), lineWidth: 1)
            )
            .onTapGesture {
                if model.selectedDay?.date == day.date {
                    model.selectedDay = nil
                } else {
                    model.selectedDay = day
                }
            }
            .help("\(day.date): \(formatStatCount(day.count)) 字")
    }

    private func selectedInfoView(_ day: CalendarDay) -> some View {
        HStack {
            Text("📅 \(day.date)")
                .font(.subheadline.bold())
            Text("输入 \(formatStatCount(day.count)) 字")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("关闭") {
                model.selectedDay = nil
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.04))
        )
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Text("少")
                .font(.caption2)
                .foregroundColor(.secondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(InputCalendarModel.color(forLevel: level))
                    .frame(width: cellSize, height: cellSize)
            }
            Text("多")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func weekdayShort(_ dow: Int) -> String {
        ["日", "一", "二", "三", "四", "五", "六"][dow]
    }

    private func monthLabel(for week: [CalendarDay]) -> String {
        // 由调用方取首日属于的月份
        let first = week.first { _ in true }?.date ?? ""
        return monthText(for: first)
    }

    private func monthText(for date: String) -> String {
        guard date.count >= 7 else { return "" }
        return String(date.prefix(7))
    }
}

/// 日历中的某一天
struct CalendarDay: Hashable, Identifiable {
    let date: String
    let count: Int64
    let dayOfWeek: Int  // 0..6, 0=周日
    var id: String { date }
}

/// 输入日历 ViewModel
final class InputCalendarModel: ObservableObject {
    @Published var monthsBack: Int = 1 {
        didSet { refresh() }
    }
    @Published var weeks: [[CalendarDay]] = []
    @Published var totalInRange: Int64 = 0
    @Published var selectedDay: CalendarDay? = nil
    @Published var maxCount: Int64 = 1

    private var cancellables = Set<AnyCancellable>()

    init() {
        refresh()
        NotificationCenter.default
            .publisher(for: Statistics.updated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    func refresh() {
        guard FirePreferencesController.shared.isVisible else { return }
        let days = monthsBack == 1 ? 90 : (monthsBack == 2 ? 180 : 365)
        let raw = Statistics.shared.queryRecentDailyCounts(days: days)
        let map: [String: Int64] = Dictionary(uniqueKeysWithValues: raw.map { ($0.date, $0.count) })

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = Date()
        let cal = Calendar(identifier: .gregorian)

        // 计算网格起点：从今天所在周的周日（向前推 dayOfWeek 天）开始
        let weekday = cal.component(.weekday, from: today) - 1 // 0=周日
        let totalDays = days
        let startOffset = weekday + (totalDays - 1 - weekday) // 从最远的周日
        guard let startDate = cal.date(byAdding: .day, value: -startOffset, to: today) else {
            weeks = []
            return
        }

        var weeksTemp: [[CalendarDay]] = []
        var current: [CalendarDay] = []
        var currentDate = startDate
        var totalInRangeLocal: Int64 = 0
        var maxLocal: Int64 = 1

        for i in 0..<totalDays {
            let dateStr = fmt.string(from: currentDate)
            let dow = cal.component(.weekday, from: currentDate) - 1
            let count = map[dateStr] ?? 0
            if i > 0 && dow == 0 {
                weeksTemp.append(current)
                current = []
            }
            current.append(CalendarDay(date: dateStr, count: count, dayOfWeek: dow))
            totalInRangeLocal += count
            if count > maxLocal { maxLocal = count }
            currentDate = cal.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }
        if !current.isEmpty { weeksTemp.append(current) }

        weeks = weeksTemp
        totalInRange = totalInRangeLocal
        maxCount = max(1, maxLocal)
        if let sel = selectedDay, !weeks.flatMap({ $0 }).contains(where: { $0.date == sel.date }) {
            selectedDay = nil
        }
    }

    func colorLevel(for count: Int64) -> Color {
        let level: Int
        if count == 0 {
            level = 0
        } else if maxCount <= 1 {
            level = 1
        } else {
            let pct = Double(count) / Double(maxCount)
            if pct >= 0.75 { level = 4 }
            else if pct >= 0.5 { level = 3 }
            else if pct >= 0.25 { level = 2 }
            else { level = 1 }
        }
        return InputCalendarModel.color(forLevel: level)
    }

    static func color(forLevel level: Int) -> Color {
        switch level {
        case 0: return Color.gray.opacity(0.15)
        case 1: return statPrimaryColor.opacity(0.25)
        case 2: return statPrimaryColor.opacity(0.45)
        case 3: return statPrimaryColor.opacity(0.7)
        case 4: return statPrimaryColor
        default: return Color.gray.opacity(0.15)
        }
    }
}

// MARK: - 3. 今日时段分布

struct TodayHourDistributionView: View {
    @ObservedObject var model: TodayHourDistributionModel
    /// 点击某小时时回调，参数为小时数（0..23）
    var onBarTap: (Int) -> Void = { _ in }

    @State private var hoveredHour: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今日 24 小时输入分布")
                    .font(.subheadline.bold())
                Spacer()
                Text("共 \(formatStatCount(model.totalChars)) 字 / \(formatStatCount(model.totalCommits)) 次")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .help("提示：点击下方时段条形可查看该时段的输入详情")
            hourChart
            HStack(spacing: 16) {
                metric("峰值小时", value: model.peakHour >= 0 ? "\(model.peakHour)时" : "—")
                metric("峰值字数", value: "\(formatStatCount(model.peakChars)) 字")
                metric("活跃小时", value: "\(formatStatCount(model.activeHours)) 个")
            }
        }
    }

    private var hourChart: some View {
        GeometryReader { geo in
            let data = model.hours
            let maxChars = max(1, data.map { $0.count }.max() ?? 1)
            let chartHeight = geo.size.height - 24
            let barWidth = (geo.size.width - 8 * CGFloat(data.count - 1)) / CGFloat(data.count)
            let chartWidth = geo.size.width

            ZStack(alignment: .bottomLeading) {
                // 横向网格
                Path { p in
                    for i in 0...4 {
                        let y = chartHeight * CGFloat(i) / 4
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: chartWidth, y: y))
                    }
                }
                .stroke(Color.gray.opacity(0.2), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(data) { hour in
                        hourColumn(hour: hour, barWidth: barWidth, chartHeight: chartHeight, maxChars: maxChars)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                handleHover(hour: hour.hour, hovering: hovering)
                            }
                            .onTapGesture {
                                onBarTap(hour.hour)
                            }
                    }
                }
                .frame(height: chartHeight + 18, alignment: .bottom)
            }
        }
        .frame(height: 200)
    }

    /// 单个时段列（条 + 标签）+ 点击交互
    private func hourColumn(hour: HourCount, barWidth: CGFloat, chartHeight: CGFloat, maxChars: Int64) -> some View {
        let isHovered = hoveredHour == hour.hour
        let h = chartHeight * CGFloat(hour.count) / CGFloat(maxChars)
        return VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: barWidth, height: chartHeight)
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(for: hour.hour, count: hour.count, max: maxChars))
                    .frame(width: barWidth, height: h)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(isHovered ? statPrimaryColor : .clear, lineWidth: 1.5)
                    )
                    .help(hour.count > 0
                          ? "\(hour.hour):00 - \(hour.hour + 1):00\n字符: \(formatStatCount(hour.count))\n上屏: \(formatStatCount(hour.commits))\n点击查看该时段输入详情"
                          : "\(hour.hour):00 - \(hour.hour + 1):00\n暂无输入\n点击查看该时段输入详情")
            }
            Text("\(hour.hour)")
                .font(.system(size: 9))
                .fontWeight(isHovered ? .bold : .regular)
                .foregroundColor(isHovered ? statPrimaryColor : .secondary)
        }
    }

    /// 维护 hover 状态与鼠标指针
    private func handleHover(hour: Int, hovering: Bool) {
        if hovering {
            if hoveredHour != hour {
                if hoveredHour != nil {
                    NSCursor.pop()
                }
                hoveredHour = hour
                NSCursor.pointingHand.push()
            }
        } else if hoveredHour == hour {
            hoveredHour = nil
            NSCursor.pop()
        }
    }

    private func barColor(for hour: Int, count: Int64, max: Int64) -> Color {
        if count == 0 { return Color.gray.opacity(0.1) }
        let intensity = min(1.0, Double(count) / Double(max))
        return statPrimaryColor.opacity(0.35 + intensity * 0.6)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.03))
        )
    }
}

/// 今日时段分布 ViewModel
final class TodayHourDistributionModel: ObservableObject {
    @Published var hours: [HourCount] = []
    @Published var totalChars: Int64 = 0
    @Published var totalCommits: Int64 = 0
    @Published var peakHour: Int = -1
    @Published var peakChars: Int64 = 0
    @Published var activeHours: Int = 0

    private var cancellables = Set<AnyCancellable>()
    private var timer: AnyCancellable?

    init() {
        refresh()
        NotificationCenter.default
            .publisher(for: Statistics.updated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
        // 每分钟自动刷新一次，确保跨小时后数据及时更新
        timer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    func refresh() {
        guard FirePreferencesController.shared.isVisible else { return }
        let data = Statistics.shared.queryTodayHourDistribution()
        hours = data
        totalChars = data.reduce(0) { $0 + $1.count }
        totalCommits = data.reduce(0) { $0 + $1.commits }
        if let peak = data.max(by: { $0.count < $1.count }) {
            peakHour = peak.count > 0 ? peak.hour : -1
            peakChars = peak.count
        } else {
            peakHour = -1
            peakChars = 0
        }
        activeHours = data.filter { $0.count > 0 }.count
    }
}

// MARK: - 4. 输入详情

struct InputDetailsView: View {
    @ObservedObject var model: InputDetailsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("输入详情")
                    .font(.subheadline.bold())
                Spacer()
                Text("共 \(formatStatCount(model.total)) 条")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack {
                Picker("类型", selection: $model.typeFilter) {
                    Text("全部").tag("all")
                    Text("五笔").tag("wb")
                    Text("拼音").tag("py")
                    Text("用户词").tag("user")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                if let hour = model.hourFilter {
                    hourFilterChip(hour: hour)
                }
                Spacer()
                if #available(macOS 12.0, *) {
                    Button {
                        exportCSV()
                    } label: {
                        Label("导出 CSV", systemImage: "square.and.arrow.down")
                    }
                    .controlSize(.small)
                } else {
                    Button("导出 CSV") {
                        exportCSV()
                    }
                }
            }

            if model.records.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.title)
                            .foregroundColor(.secondary.opacity(0.4))
                        Text("暂无数据")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .frame(height: 200)
            } else {
                detailTable
                paginationBar
            }
        }
    }

    private var detailTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("时间").frame(width: 150, alignment: .leading)
                Text("类型").frame(width: 60, alignment: .center)
                Text("编码").frame(width: 80, alignment: .leading)
                Text("文本").frame(maxWidth: .infinity, alignment: .leading)
                Text("应用").frame(width: 130, alignment: .trailing)
            }
            .font(.caption.bold())
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.05))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.records) { record in
                        detailRow(record)
                            .background(model.records.firstIndex(of: record).map { $0 % 2 == 0 ? Color.clear : Color.black.opacity(0.025) } ?? Color.clear)
                    }
                }
            }
            .frame(height: 280)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.black.opacity(0.1), lineWidth: 1)
            )
        }
    }

    private func detailRow(_ r: InputDetail) -> some View {
        HStack {
            Text(formatTime(r.createdAt))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(typeLabel(r.type))
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(typeColor(r.type).opacity(0.15))
                .foregroundColor(typeColor(r.type))
                .cornerRadius(4)
                .frame(width: 60, alignment: .center)
            Text(r.code.isEmpty ? "—" : r.code)
                .font(.caption.monospacedDigit())
                .foregroundColor(.primary)
                .frame(width: 80, alignment: .leading)
            Text(r.text)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(r.appBundleId.isEmpty ? "—" : r.appBundleId)
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var paginationBar: some View {
        HStack {
            Button("上一页") {
                model.prevPage()
            }
            .disabled(model.page <= 0)
            .buttonStyle(.borderless)

            Spacer()
            Text("第 \(model.page + 1) / \(max(1, model.totalPages)) 页")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()

            Button("下一页") {
                model.nextPage()
            }
            .disabled(model.page >= model.totalPages - 1)
            .buttonStyle(.borderless)
        }
        .padding(.top, 6)
    }

    private func formatTime(_ s: String) -> String {
        // createdAt: "yyyy-MM-dd'T'HH:mm:ss.SSS" → 显示 HH:mm:ss.SSS
        if let range = s.range(of: "T") {
            return String(s[range.upperBound...])
        }
        return s
    }

    private func typeLabel(_ t: String) -> String {
        switch t {
        case "wb": return "五笔"
        case "py": return "拼音"
        case "user": return "用户"
        case "placeholder": return "占位"
        default: return t
        }
    }

    private func typeColor(_ t: String) -> Color {
        switch t {
        case "wb": return .blue
        case "py": return .purple
        case "user": return statPrimaryColor
        default: return .gray
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [UTType.commaSeparatedText]
        } else {
            panel.allowedFileTypes = ["csv"]
        }
        panel.nameFieldStringValue = "输入详情.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Statistics.shared.exportInputDetailsCSV(
            to: url,
            typeFilter: model.typeFilter,
            hourFilter: model.hourFilter
        )
    }

    /// 时段筛选 chip：可一键清除
    private func hourFilterChip(hour: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.caption2)
            Text("\(hour):00 - \(hour + 1):00")
                .font(.caption)
            Button {
                model.setHourFilter(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help("清除时段筛选")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(statPrimaryColor.opacity(0.12))
        )
        .foregroundColor(statPrimaryColor)
        .transition(.opacity.combined(with: .scale))
    }
}

/// 输入详情 ViewModel
final class InputDetailsModel: ObservableObject {
    @Published var typeFilter: String = "all" {
        didSet { reload() }
    }
    /// 时段筛选：nil 表示全部时段；0..23 表示对应小时（按 createdAt 本地小时）
    @Published var hourFilter: Int? = nil
    @Published var page: Int = 0
    private let pageSize: Int = 100

    @Published var records: [InputDetail] = []
    @Published var total: Int64 = 0
    @Published var totalPages: Int = 1

    private var cancellables = Set<AnyCancellable>()

    init() {
        reload()
        NotificationCenter.default
            .publisher(for: Statistics.updated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reload()
            }
            .store(in: &cancellables)
    }

    func reload() {
        guard FirePreferencesController.shared.isVisible else { return }
        total = Statistics.shared.queryInputDetailCount(type: typeFilter, hour: hourFilter)
        totalPages = max(1, Int((total + Int64(pageSize) - 1) / Int64(pageSize)))
        if page >= totalPages { page = 0 }
        records = Statistics.shared.queryInputDetails(
            type: typeFilter, hour: hourFilter, limit: pageSize, offset: page * pageSize
        )
    }

    /// 设置时段筛选（nil 清除），并复位到第一页
    func setHourFilter(_ hour: Int?) {
        guard hourFilter != hour else { return }
        hourFilter = hour
        page = 0
        reload()
    }

    func prevPage() {
        if page > 0 { page -= 1; reload() }
    }

    func nextPage() {
        if page < totalPages - 1 { page += 1; reload() }
    }
}

// MARK: - 5. 用户词频

/// 应用筛选下拉项
struct WordFrequencyAppOption: Hashable, Identifiable {
    let bundleId: String
    let displayName: String
    var id: String { bundleId }

    /// 显示文本：本地化名（解析失败时回退到 bundle id），方便用户认图
    var label: String {
        displayName.isEmpty ? bundleId : "\(displayName) (\(bundleId))"
    }
}

struct WordFrequencyView: View {
    @ObservedObject var model: WordFrequencyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            filterBar
            if model.entries.isEmpty {
                emptyState
            } else {
                tableView
                paginationBar
            }
        }
    }

    // MARK: 顶部状态行

    private var header: some View {
        HStack {
            Text("用户词频")
                .font(.subheadline.bold())
            Spacer()
            Text("共 \(formatStatCount(model.total)) 条")
                .font(.caption)
                .foregroundColor(.secondary)
            if #available(macOS 12.0, *) {
                Button {
                    exportCSV()
                } label: {
                    Label("导出 CSV", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
            } else {
                Button("导出 CSV") {
                    exportCSV()
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: 筛选条

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("搜索字词", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(minWidth: 120)
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                        model.reload()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.05))
            )

            Picker("类型", selection: $model.typeFilter) {
                Text("全部").tag("all")
                Text("五笔").tag("wb")
                Text("拼音").tag("py")
                Text("用户词").tag("user")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .onChange(of: model.typeFilter) { _ in
                model.reload()
            }

            if !model.availableApps.isEmpty {
                Picker("应用", selection: Binding<String>(
                    get: { model.appFilter ?? "__all__" },
                    set: { newValue in
                        model.appFilter = (newValue == "__all__") ? nil : newValue
                        model.reload()
                    }
                )) {
                    Text("全部应用").tag("__all__")
                    ForEach(model.availableApps) { opt in
                        Text(opt.label).tag(opt.bundleId)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
            }

            Spacer()
        }
    }

    // MARK: 表格

    private var tableView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("字词").frame(width: 90, alignment: .leading)
                Text("编码").frame(width: 100, alignment: .leading)
                Text("次数").frame(width: 80, alignment: .trailing)
                Text("应用").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.bold())
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.05))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { (idx, entry) in
                        row(entry, zebra: idx % 2 == 1)
                    }
                }
            }
            .frame(height: 280)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.black.opacity(0.1), lineWidth: 1)
            )
        }
    }

    private func row(_ entry: WordFrequencyEntry, zebra: Bool) -> some View {
        HStack {
            Text(entry.text)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 90, alignment: .leading)
            Text(entry.code.isEmpty ? "—" : entry.code)
                .font(.caption.monospacedDigit())
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)
            Text(formatStatCount(entry.count))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(entry.appName.isEmpty
                 ? (entry.appBundleId.isEmpty ? "—" : entry.appBundleId)
                 : entry.appName)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(entry.appBundleId)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(zebra ? Color.black.opacity(0.025) : Color.clear)
    }

    // MARK: 空态

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.title)
                    .foregroundColor(.secondary.opacity(0.4))
                Text("暂无匹配数据")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            Spacer()
        }
        .frame(height: 200)
    }

    // MARK: 分页

    private var paginationBar: some View {
        HStack {
            Button("上一页") {
                model.prevPage()
            }
            .disabled(model.page <= 0)
            .buttonStyle(.borderless)

            Spacer()
            Text("第 \(model.page + 1) / \(max(1, model.totalPages)) 页")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()

            Button("下一页") {
                model.nextPage()
            }
            .disabled(model.page >= model.totalPages - 1)
            .buttonStyle(.borderless)
        }
        .padding(.top, 6)
    }

    // MARK: 导出

    private func exportCSV() {
        let panel = NSSavePanel()
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [UTType.commaSeparatedText]
        } else {
            panel.allowedFileTypes = ["csv"]
        }
        panel.nameFieldStringValue = "用户词频.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let type: String? = model.typeFilter == "all" ? nil : model.typeFilter
        let search: String? = model.searchText.isEmpty ? nil : model.searchText
        try? Statistics.shared.exportWordFrequencyCSV(
            to: url,
            type: type,
            appBundleId: model.appFilter,
            searchText: search,
            limit: 50000
        )
    }
}

/// 用户词频 ViewModel
final class WordFrequencyModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var typeFilter: String = "all"
    @Published var appFilter: String? = nil
    @Published var entries: [WordFrequencyEntry] = []
    @Published var availableApps: [WordFrequencyAppOption] = []
    @Published var total: Int64 = 0
    @Published var totalPages: Int = 1

    @Published var page: Int = 0
    private let pageSize: Int = 100
    /// 触发完整重新加载（不分页，内存中分页）
    private var fullResultCache: [WordFrequencyEntry] = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        reload()
        NotificationCenter.default
            .publisher(for: Statistics.updated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reload()
            }
            .store(in: &cancellables)

        // 搜索防抖：300ms 后触发刷新
        $searchText
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.page = 0
                self?.reload()
            }
            .store(in: &cancellables)
    }

    func reload() {
        guard FirePreferencesController.shared.isVisible else { return }
        let type: String? = typeFilter == "all" ? nil : typeFilter
        let search: String? = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : searchText
        let raw = Statistics.shared.queryWordFrequencyEntries(
            type: type,
            appBundleId: appFilter,
            searchText: search,
            limit: 10000
        )
        fullResultCache = raw
        total = Int64(raw.count)
        totalPages = max(1, (raw.count + pageSize - 1) / pageSize)
        if page >= totalPages { page = 0 }
        applyPage()
        // 重新拉取应用列表（应用列表变化不频繁，全量重查）
        let ids = Statistics.shared.queryWordFrequencyApps()
        availableApps = ids.map { id in
            WordFrequencyAppOption(
                bundleId: id,
                displayName: Statistics.appDisplayName(for: id)
            )
        }
    }

    private func applyPage() {
        guard !fullResultCache.isEmpty else {
            entries = []
            return
        }
        let start = page * pageSize
        let end = min(start + pageSize, fullResultCache.count)
        guard start < end else {
            entries = []
            return
        }
        entries = Array(fullResultCache[start..<end])
    }

    func prevPage() {
        if page > 0 { page -= 1; applyPage() }
    }

    func nextPage() {
        if page < totalPages - 1 { page += 1; applyPage() }
    }
}