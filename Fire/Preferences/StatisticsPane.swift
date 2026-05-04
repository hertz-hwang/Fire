//
//  StatisticsPane.swift
//  Fire
//
//  Created by 虚幻 on 2022/5/22.
//  Copyright © 2022 qwertyyb. All rights reserved.
//

import SwiftUI
import Settings
import Defaults
import Combine
import UniformTypeIdentifiers

func formatCount(_ count: Int64) -> String {
    return NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
}

struct CountCircle: View {
    let data: DateCount

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .stroke(
                    style: StrokeStyle(
                        lineWidth: 4,
                        lineCap: .round,
                        lineJoin: .round,
                        miterLimit: 80,
                        dash: [],
                        dashPhase: 0
                    )
                )
                .frame(width: 10, height: 10, alignment: .center)
                .foregroundColor(Color(red: 251/255, green: 82/255, blue: 0))
                .background(Color.white)
                .cornerRadius(5)
                .scaleEffect(hovered ? 1.3 : 1)
                .onHover { state in
                    hovered = state
                }
                .popover(isPresented: $hovered) {
                    Text("\(data.date)输入: \(formatCount(data.count))字")
                        .padding(6)
                }
        }
    }
}

class DateCountData: ObservableObject {
    @Published var startDate = Date().addingTimeInterval(-5 * 24 * 60 * 60)
    @Published var endDate = Date()
    @Published var data: [DateCount] = []
    @Published var total: Int64 = 0

    var cancellables = Set<AnyCancellable>()

    init() {
        refresh()
        NotificationCenter.default
            .publisher(for: Statistics.updated)
            .sink { _ in
                self.refresh()
            }
            .store(in: &cancellables)
        $startDate.sink { date in
            self.refreshData(startDate: date, endDate: nil)
        }
            .store(in: &cancellables)
        $endDate.sink { date in
            self.refreshData(startDate: nil, endDate: date)
        }
            .store(in: &cancellables)
    }

    deinit {
        cancellables.forEach { cancellable in
            cancellable.cancel()
        }
        cancellables = []
    }

    @objc func refresh() {
        NSLog("[DateCountData] refresh start: \(startDate)")
        if !FirePreferencesController.shared.isVisible {
            NSLog("[DateCountData] refresh cancel: not visible")
            return
        }
        total = Statistics.shared.queryTotalCount()
        self.refreshData(startDate: nil, endDate: nil)
    }

    func refreshData(startDate: Date?, endDate: Date?) {
        data = Statistics.shared
            .queryCountByDate(
                startDate: startDate ?? self.startDate,
                endDate: endDate ?? self.endDate
            )
    }

    func clear() {
        Statistics.shared.clear()
    }
}

class WordFrequencyData: ObservableObject {
    @Published var data: [WordFrequency] = []

    var cancellables = Set<AnyCancellable>()

    init() {
        refresh()
        NotificationCenter.default
            .publisher(for: Statistics.updated)
            .sink { _ in
                self.refresh()
            }
            .store(in: &cancellables)
    }

    deinit {
        cancellables.forEach { $0.cancel() }
        cancellables = []
    }

    @objc func refresh() {
        if !FirePreferencesController.shared.isVisible { return }
        data = Statistics.shared.queryWordFrequency(limit: 50)
    }
}

struct StatisticsPane: View {
    @StateObject var dateCountData = DateCountData()
    @StateObject var wordFrequencyData = WordFrequencyData()
    @Default(.enableStatistics) private var enableStatistics
    @State private var showAlert = false
    @State private var showExportError = false

    func getPath(geo: GeometryProxy) -> Path {
        return Path { path in
            let data = dateCountData.data
            let maxVal = data.reduce(0) { (res, dateCount) -> Int64 in
                return max(res, dateCount.count)
            }
            let scale = geo.size.height / CGFloat(maxVal)
            let gap = data.count > 1
                ? (geo.size.width - 16) / CGFloat(data.count - 1)
                : 0

            path.move(to: CGPoint(x: 8, y: geo.size.height - CGFloat((data[0].count)) * scale))

            data.enumerated().forEach { element in
                path.addLine(
                    to: CGPoint(
                        x: 8 + CGFloat(element.offset) * gap,
                        y: geo.size.height - CGFloat(element.element.count) * scale
                    )
                )
            }

            path.addLine(to: CGPoint(x: 8 + CGFloat(data.count - 1) * gap, y: geo.size.height))
            path.addLine(to: CGPoint(x: 8, y: geo.size.height))
            path.closeSubpath()
        }
    }

    func drawLogPoints(data: [DateCount]) -> some View {
        return GeometryReader { geo in
            let maxNum = data.reduce(0) { (res, item) -> Int64 in
                return max(res, item.count)
            }

            let scale = geo.size.height / CGFloat(maxNum)
            let gap = data.count > 1
                ? (geo.size.width - 16) / CGFloat(data.count - 1)
                : 0

            ForEach(Array(data.enumerated()), id: \.element) { (offset, element) in
                CountCircle(data: element)
                    .offset(
                        x: 8 + gap * CGFloat(offset) - 5,
                        y: (geo.size.height - (CGFloat(element.count) * scale)) - 5
                    )
            }
        }
    }

    func drawBackground(data: [DateCount]) -> some View {
        return GeometryReader { geo in
            Path { path in
                let data = dateCountData.data
                let gap = data.count > 1
                    ? (geo.size.width - 16) / CGFloat(data.count - 1)
                    : 0

                (0..<data.count).forEach { element in
                    path.move(to: CGPoint(x: 8 + CGFloat(element) * gap, y: geo.size.height))
                    path.addLine(to: CGPoint(x: 8 + CGFloat(element) * gap, y: 0))
                }
            }
            .stroke(
                style: StrokeStyle(
                    lineWidth: 1,
                    lineCap: .round,
                    lineJoin: .round,
                    miterLimit: 80,
                    dash: [],
                    dashPhase: 0
                )
            )
            .foregroundColor(Color.black.opacity(0.5))
        }
    }

    func drawData(data: [DateCount]) -> some View {
        return VStack {
            GeometryReader { geo in
                getPath(geo: geo)
                    .fill(Color.red.opacity(0.2))
            }
            .frame(height: 320)
            .overlay(drawBackground(data: data))
            .overlay(GeometryReader(content: { geo in
                getPath(geo: geo)
                    .stroke(
                        style: StrokeStyle(
                            lineWidth: 2,
                            lineCap: .round,
                            lineJoin: .round,
                            miterLimit: 80,
                            dash: [],
                            dashPhase: 0
                        )
                    )
                    .foregroundColor(Color(red: 251/255, green: 82/255, blue: 0).opacity(0.6))
            }))
            .overlay(drawLogPoints(data: data))
            .background(Color.yellow.opacity(0.1))
            HStack {
                ForEach(Array(data.enumerated()), id: \.element) { (offset, element) in
                    Text(element.date)
                    if offset < data.count - 1 {
                        Spacer()
                    }
                }
            }
            Spacer(minLength: 20)
        }
    }

    var body: some View {
        Settings.Container(contentWidth: 450) {
            Settings.Section(title: "") {
                VStack(alignment: .leading) {
                    HStack(alignment: .center) {
                        Toggle("启用统计", isOn: $enableStatistics)
                        Spacer()
                        Button("备份数据") {
                            let panel = NSSavePanel()
                            panel.allowedFileTypes = ["json"]
                            panel.nameFieldStringValue = "统计数据备份.json"
                            guard panel.runModal() == .OK, let url = panel.url else { return }
                            do {
                                try Statistics.shared.backup(to: url)
                                let alert = NSAlert()
                                alert.messageText = "备份成功"
                                alert.runModal()
                            } catch {
                                let alert = NSAlert()
                                alert.messageText = "备份失败"
                                alert.informativeText = error.localizedDescription
                                alert.runModal()
                            }
                        }
                        Button("恢复数据") {
                            let panel = NSOpenPanel()
                            panel.allowedFileTypes = ["json"]
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            guard panel.runModal() == .OK, let url = panel.url else { return }
                            let confirm = NSAlert()
                            confirm.messageText = "选择恢复方式"
                            confirm.informativeText = "合并：保留现有数据并追加备份数据\n替换：清除现有数据后导入备份数据"
                            confirm.addButton(withTitle: "合并")
                            confirm.addButton(withTitle: "替换")
                            confirm.addButton(withTitle: "取消")
                            let response = confirm.runModal()
                            guard response != .alertThirdButtonReturn else { return }
                            do {
                                try Statistics.shared.restore(from: url, merge: response == .alertFirstButtonReturn)
                                let alert = NSAlert()
                                alert.messageText = "恢复成功"
                                alert.runModal()
                            } catch {
                                let alert = NSAlert()
                                alert.messageText = "恢复失败"
                                alert.informativeText = error.localizedDescription
                                alert.runModal()
                            }
                        }
                        if #available(macOS 12.0, *) {
                            Button {
                                dateCountData.clear()
                                showAlert = true
                            } label: {
                                Text("清除数据")
                            }
                            .alert("清除成功", isPresented: $showAlert, actions: {})
                        } else {
                            Button {
                                dateCountData.clear()
                            } label: {
                                Text("清除数据")
                            }
                        }
                    }
                    GroupBox(label: Text("累计输入")) {
                        HStack {
                            Text("\(formatCount(dateCountData.total))字")
                            Spacer()
                        }
                        .frame(width: 420)
                    }

                    GroupBox(label: Text("输入统计")) {
                        HStack {
                            DatePicker("开始日期", selection: $dateCountData.startDate, displayedComponents: [.date])
                                .datePickerStyle(.field)
                            DatePicker("结束日期", selection: $dateCountData.endDate, displayedComponents: [.date])
                                .datePickerStyle(.field)
                        }
                        Spacer(minLength: 20)
                        if dateCountData.data.count <= 0 {
                            HStack {
                                Spacer()
                                Text("暂无数据")
                                Spacer()
                            }
                            .frame(width: 420, height: 320)
                        } else {
                            drawData(data: dateCountData.data)
                        }
                    }

                    GroupBox(label: Text("字词频率")) {
                        HStack {
                            Text("Top 50 上屏词频")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            if #available(macOS 12.0, *) {
                                Button("导出 CSV") {
                                    let panel = NSSavePanel()
                                    panel.allowedContentTypes = [UTType.commaSeparatedText]
                                    panel.nameFieldStringValue = "字词频率.csv"
                                    if panel.runModal() == .OK, let url = panel.url {
                                        do {
                                            try Statistics.shared.exportWordFrequencyCSV(to: url)
                                        } catch {
                                            showExportError = true
                                        }
                                    }
                                }
                                .alert("导出失败", isPresented: $showExportError, actions: {})
                            } else {
                                Button("导出 CSV") {
                                    let panel = NSSavePanel()
                                    panel.allowedFileTypes = ["csv"]
                                    panel.nameFieldStringValue = "字词频率.csv"
                                    if panel.runModal() == .OK, let url = panel.url {
                                        try? Statistics.shared.exportWordFrequencyCSV(to: url)
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 8)
                        if wordFrequencyData.data.isEmpty {
                            HStack {
                                Spacer()
                                Text("暂无数据")
                                Spacer()
                            }
                            .frame(width: 420, height: 120)
                        } else {
                            VStack(spacing: 0) {
                                // 表头
                                HStack {
                                    Text("排名")
                                        .frame(width: 40, alignment: .center)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("词/字")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("次数")
                                        .frame(width: 60, alignment: .trailing)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.05))

                                ScrollView {
                                    LazyVStack(spacing: 0) {
                                        ForEach(Array(wordFrequencyData.data.enumerated()), id: \.element.id) { (index, item) in
                                            HStack {
                                                Text("\(index + 1)")
                                                    .frame(width: 40, alignment: .center)
                                                    .foregroundColor(index < 3 ? Color(red: 251/255, green: 82/255, blue: 0) : .primary)
                                                    .font(index < 3 ? .body.bold() : .body)
                                                Text(item.text)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                Text(formatCount(item.count))
                                                    .frame(width: 60, alignment: .trailing)
                                                    .foregroundColor(.secondary)
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(index % 2 == 0 ? Color.clear : Color.black.opacity(0.03))
                                        }
                                    }
                                }
                                .frame(width: 420, height: 200)
                            }
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.black.opacity(0.1), lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
    }
}

struct StatisticsPane_Previews: PreviewProvider {
    static var previews: some View {
        StatisticsPane()
    }
}
