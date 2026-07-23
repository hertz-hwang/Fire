//
//  StatisticsPane.swift
//  Fire
//
//  Created by 虚幻 on 2022/5/22.
//  Copyright © 2022 qwertyyb. All rights reserved.
//
//  统计设置面板：输入统计 / 输入日历 / 今日时段分布 / 输入详情
//

import SwiftUI
import Settings
import Defaults
import Combine
import UniformTypeIdentifiers

struct StatisticsPane: View {
    @Default(.enableStatistics) private var enableStatistics
    @State private var selectedTab: StatsTab = .summary

    @StateObject private var summaryModel = InputStatsModel()
    @StateObject private var calendarModel = InputCalendarModel()
    @StateObject private var hourModel = TodayHourDistributionModel()
    @StateObject private var detailModel = InputDetailsModel()
    @StateObject private var wordFrequencyModel = WordFrequencyModel()

    var body: some View {
        Settings.Container(contentWidth: 520) {
            Settings.Section(title: "") {
                VStack(alignment: .leading, spacing: 12) {
                    headerBar
                    tabBar
                    Divider()
                    Group {
                        switch selectedTab {
                        case .summary:
                            InputStatsView(model: summaryModel)
                        case .calendar:
                            InputCalendarView(model: calendarModel)
                        case .hourDistribution:
                            TodayHourDistributionView(model: hourModel) { hour in
                                selectedTab = .details
                                detailModel.setHourFilter(hour)
                            }
                        case .details:
                            InputDetailsView(model: detailModel)
                        case .wordFrequency:
                            WordFrequencyView(model: wordFrequencyModel)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 480)
            }
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("启用统计", isOn: $enableStatistics)
                .toggleStyle(.switch)
            Spacer()
            menuButtons
        }
    }

    private var menuButtons: some View {
        HStack(spacing: 6) {
            Button {
                backup()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("备份数据")
            Button {
                restore()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("恢复数据")
            Button {
                confirmClear()
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .help("清除数据")
        }
        .buttonStyle(.borderless)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(StatsTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.05))
        )
    }

    private func tabButton(_ tab: StatsTab) -> some View {
        let isActive = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: tab.iconName)
                    .font(.caption)
                Text(tab.title)
                    .font(.caption.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color.white : Color.clear)
                    .shadow(color: isActive ? Color.black.opacity(0.08) : .clear, radius: 1, y: 1)
            )
            .foregroundColor(isActive ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 备份 / 恢复 / 清除

    private func backup() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["json"]
        panel.nameFieldStringValue = "Fire统计备份.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Statistics.shared.backup(to: url)
        } catch {
            NSLog("[StatisticsPane] backup failed: \(error)")
        }
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["json"]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "选择恢复方式"
        alert.informativeText = "合并：保留现有数据并追加备份数据\n替换：清除现有数据后导入备份数据"
        alert.addButton(withTitle: "合并")
        alert.addButton(withTitle: "替换")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        do {
            try Statistics.shared.restore(from: url, merge: response == .alertFirstButtonReturn)
            NotificationCenter.default.post(name: Statistics.updated, object: nil)
        } catch {
            NSLog("[StatisticsPane] restore failed: \(error)")
        }
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "清除统计"
        alert.informativeText = "此操作不可恢复，将删除所有历史输入记录。"
        alert.addButton(withTitle: "确认清除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            Statistics.shared.clear()
            NotificationCenter.default.post(name: Statistics.updated, object: nil)
        }
    }
}

/// 统计 Tab 枚举
enum StatsTab: String, CaseIterable, Identifiable {
    case summary = "summary"
    case calendar = "calendar"
    case hourDistribution = "hour"
    case details = "details"
    case wordFrequency = "wordFrequency"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: return "输入统计"
        case .calendar: return "输入日历"
        case .hourDistribution: return "今日时段"
        case .details: return "输入详情"
        case .wordFrequency: return "用户词频"
        }
    }

    var iconName: String {
        switch self {
        case .summary: return "chart.bar.xaxis"
        case .calendar: return "calendar"
        case .hourDistribution: return "clock"
        case .details: return "list.bullet.rectangle"
        case .wordFrequency: return "text.book.closed"
        }
    }
}

struct StatisticsPane_Previews: PreviewProvider {
    static var previews: some View {
        StatisticsPane()
    }
}