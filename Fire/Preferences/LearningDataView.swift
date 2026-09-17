//
//  LearningDataView.swift
//  Fire
//
//  「查看学习数据」窗口：把「用词习惯学习」真正记下来的东西摊开看——
//  通道 B 的字符一元/二元/三元计数（含时间衰减后的当前值）与通道 C1 的
//  胜负纠错对。入口在学习设置页「学习数据」分组。
//
//  只读：数据由 LearnerCenter.inspectData 在后台串行队列取，本页不改任何
//  计数；关掉学习开关也能进来查看存量（与「清除学习数据」配套）。
//  清除 / 全量重建 / 导入 / 回填收尾会发 .learningDataReplaced，窗口开着时
//  自动重新取数，不用手动点刷新。
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - 标签页定义

/// 学习数据浏览的四个视图，对应学习系统的两张存储
enum LearningDataTab: String, CaseIterable, Identifiable {
    case chars
    case bigrams
    case trigrams
    case corrections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chars: return "字符频次"
        case .bigrams: return "二元关联"
        case .trigrams: return "三元关联"
        case .corrections: return "纠错对"
        }
    }

    var iconName: String {
        switch self {
        case .chars: return "character"
        case .bigrams: return "arrow.right.circle"
        case .trigrams: return "arrow.triangle.branch"
        case .corrections: return "checklist"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .chars: return "搜索单字"
        case .bigrams: return "搜索前字或后字"
        case .trigrams: return "搜索语境或后字"
        case .corrections: return "搜索语境、编码或词条"
        }
    }

    /// 列定义：标题 / 固定宽度 / 是否右对齐
    var columns: [LearningDataColumn] {
        switch self {
        case .chars:
            return [.init(title: "字", width: 48),
                    .init(title: "次数", width: 76, trailing: true),
                    .init(title: "占全部学到的字", width: 118, trailing: true)]
        case .bigrams:
            return [.init(title: "前字", width: 56),
                    .init(title: "后字", width: 56),
                    .init(title: "次数", width: 72, trailing: true),
                    .init(title: "前字总次数", width: 86, trailing: true),
                    .init(title: "P(后|前)", width: 86, trailing: true)]
        case .trigrams:
            return [.init(title: "语境", width: 72),
                    .init(title: "后字", width: 56),
                    .init(title: "次数", width: 72, trailing: true),
                    .init(title: "语境总次数", width: 86, trailing: true),
                    .init(title: "P(后|语境)", width: 92, trailing: true)]
        case .corrections:
            return [.init(title: "语境", width: 58),
                    .init(title: "编码", width: 118),
                    .init(title: "词条", width: 118),
                    .init(title: "胜", width: 44, trailing: true),
                    .init(title: "负", width: 44, trailing: true),
                    .init(title: "计分", width: 58, trailing: true)]
        }
    }

    /// 表格下方的一行语义说明
    var footnote: String {
        switch self {
        case .chars:
            return "「次数」是这个字被学到的权重，带 30 天半衰期，久不用会持续变小直到被清扫。"
        case .bigrams, .trigrams:
            return "「P(后|前)」是纯用户数据里的条件占比（未做平滑），次数与语境总次数都是衰减后的当前值。"
        case .corrections:
            return "「计分」是这条证据当前对整句候选的实际加减（正 = 加持所选词，负 = 降权被弃首选）。"
        }
    }

    var exportFileName: String {
        switch self {
        case .chars: return "学习数据-字符频次.csv"
        case .bigrams: return "学习数据-二元关联.csv"
        case .trigrams: return "学习数据-三元关联.csv"
        case .corrections: return "学习数据-纠错对.csv"
        }
    }
}

/// 表格列
struct LearningDataColumn {
    let title: String
    let width: CGFloat
    var trailing: Bool = false
}

/// 表格的一行：单元格文本已按当前标签页格式化好
struct LearningDataRow: Identifiable {
    let id: String
    let cells: [String]
}

// MARK: - 数值格式

/// 学习计数：带衰减所以是小数；够大后收起小数位，避免表格宽度抖动
private func formatLearningCount(_ value: Double) -> String {
    value >= 100 ? String(format: "%.0f", value) : String(format: "%.2f", value)
}

/// 占比
private func formatLearningShare(_ value: Double, of total: Double) -> String {
    guard total > 0, value > 0 else { return "—" }
    let share = value / total * 100
    if share < 0.01 { return "<0.01%" }
    return String(format: "%.2f%%", share)
}

// MARK: - ViewModel

/// 「查看学习数据」的数据装载：后台取数 → 内存分页 → 搜索防抖
final class LearningDataModel: ObservableObject {
    @Published var tab: LearningDataTab = .chars
    @Published var query: String = ""
    @Published private(set) var rows: [LearningDataRow] = []
    @Published private(set) var report = LearningDataReport()
    @Published private(set) var loading = false
    @Published var page: Int = 0
    @Published private(set) var totalPages: Int = 1

    private let pageSize = 100
    /// 单张表一次最多取回的行数：再多对浏览没意义，也别把二十万行灌进 UI
    private let reportLimit = 5000
    /// 当前标签页的全部行（已按计数降序，未分页）
    private var allRows: [LearningDataRow] = []
    /// 只认最后一次请求的结果，避免快速切页时旧数据覆盖新数据
    private var requestToken = 0
    private var cancellables = Set<AnyCancellable>()

    init() {
        // 搜索防抖：300ms 后重新取数（dropFirst 跳过订阅时的初值，避免重复加载）
        $query
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.page = 0
                self?.reload()
            }
            .store(in: &cancellables)
        // 存量被整体替换（清除 / 全量重建 / 导入 / 回填收尾）时自己刷新：
        // 这些操作都发生在设置页，窗口开着时不应该还是旧数据。
        // 250ms 防抖把「清空 + 重建」这类连发合成一次取数。
        NotificationCenter.default.publisher(for: .learningDataReplaced)
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reload()
            }
            .store(in: &cancellables)
        reload()
    }

    /// 当前标签页在过滤条件下的条目数（截断前）
    var sectionTotal: Int {
        switch tab {
        case .chars: return report.charTotal
        case .bigrams: return report.bigramTotal
        case .trigrams: return report.trigramTotal
        case .corrections: return report.correctionTotal
        }
    }

    /// 已装载进内存、可翻页/导出的行数（受 reportLimit 约束）
    var displayedCount: Int { allRows.count }

    /// 是否装载到了数据（决定「导出 CSV」是否可点）
    var canExport: Bool { !allRows.isEmpty }

    /// 库里是否还有任何学习数据（不受过滤影响）
    var hasAnyData: Bool {
        report.charEntries + report.bigramEntries
            + report.trigramEntries + report.correctionEntries > 0
    }

    func select(_ newTab: LearningDataTab) {
        guard newTab != tab else { return }
        tab = newTab
        page = 0
        reload()
    }

    func prevPage() {
        guard page > 0 else { return }
        page -= 1
        applyPage()
    }

    func nextPage() {
        guard page < totalPages - 1 else { return }
        page += 1
        applyPage()
    }

    /// 向 LearnerCenter 的串行队列要一份明细快照
    func reload() {
        loading = true
        requestToken += 1
        let token = requestToken
        let activeTab = tab
        LearnerCenter.shared.inspectData(query: query, limit: reportLimit) { result in
            DispatchQueue.main.async {
                guard token == self.requestToken else { return }
                self.report = result
                self.allRows = Self.materialize(result, tab: activeTab)
                self.totalPages = max(1, (self.allRows.count + self.pageSize - 1) / self.pageSize)
                if self.page >= self.totalPages { self.page = 0 }
                self.applyPage()
                self.loading = false
            }
        }
    }

    private func applyPage() {
        let start = page * pageSize
        guard start < allRows.count else {
            rows = []
            return
        }
        rows = Array(allRows[start..<min(start + pageSize, allRows.count)])
    }

    /// 行模型 → 单元格文本（派生列：占比、条件概率、计分）
    private static func materialize(_ report: LearningDataReport,
                                    tab: LearningDataTab) -> [LearningDataRow] {
        switch tab {
        case .chars:
            return report.chars.map {
                LearningDataRow(id: $0.id, cells: [$0.char,
                                                   formatLearningCount($0.count),
                                                   formatLearningShare($0.count, of: report.unigramMass)])
            }
        case .bigrams:
            return report.bigrams.map {
                LearningDataRow(id: $0.id, cells: [$0.prev, $0.next,
                                                   formatLearningCount($0.count),
                                                   formatLearningCount($0.total),
                                                   formatLearningShare($0.count, of: $0.total)])
            }
        case .trigrams:
            return report.trigrams.map {
                LearningDataRow(id: $0.id, cells: [$0.ctx, $0.next,
                                                   formatLearningCount($0.count),
                                                   formatLearningCount($0.total),
                                                   formatLearningShare($0.count, of: $0.total)])
            }
        case .corrections:
            return report.corrections.map {
                LearningDataRow(id: $0.id, cells: [$0.ctx.isEmpty ? "（句首）" : $0.ctx,
                                                   $0.code, $0.word,
                                                   formatLearningCount($0.wins),
                                                   formatLearningCount($0.losses),
                                                   String(format: "%+.2f", $0.bonus)])
            }
        }
    }

    // MARK: 导出 CSV

    func exportCSV() {
        let panel = NSSavePanel()
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [UTType.commaSeparatedText]
        } else {
            panel.allowedFileTypes = ["csv"]
        }
        panel.nameFieldStringValue = tab.exportFileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let titles = tab.columns.map { $0.title }
        var lines = [titles.map(Self.csvCell).joined(separator: ",")]
        for row in allRows {
            lines.append(row.cells.map(Self.csvCell).joined(separator: ","))
        }
        // 带 BOM：Excel 直接双击能认出 UTF-8
        var data = Data("\u{FEFF}".utf8)
        data.append(Data(lines.joined(separator: "\r\n").utf8))
        try? data.write(to: url)
    }

    private static func csvCell(_ text: String) -> String {
        guard text.contains(",") || text.contains("\"") || text.contains("\n") else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: - 视图

struct LearningDataView: View {
    @StateObject private var model = LearningDataModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar
            tabBar
            filterBar
            Divider()
            if model.rows.isEmpty {
                emptyState
            } else {
                tableView
                paginationBar
            }
            Text(model.tab.footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 顶部：汇总 + 刷新 + 导出

    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("学习数据明细")
                    .font(.subheadline.bold())
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.reload()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(model.loading)
            Button {
                model.exportCSV()
            } label: {
                Label("导出 CSV", systemImage: "square.and.arrow.down")
            }
            .controlSize(.small)
            .disabled(!model.canExport)
        }
    }

    /// 顶部汇总：库里存量（不受搜索影响）+ 累计字符转移量
    private var summaryLine: String {
        let report = model.report
        var parts = [
            "字 \(formatStatCount(report.charEntries))",
            "二元 \(formatStatCount(report.bigramEntries))",
            "三元 \(formatStatCount(report.trigramEntries))",
            "纠错 \(formatStatCount(report.correctionEntries))",
        ]
        if report.unigramMass > 0 {
            parts.append("累计 \(formatLearningCount(report.unigramMass)) 次字符转移")
        }
        return parts.joined(separator: " · ")
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(LearningDataTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.05))
        )
    }

    private func tabButton(_ tab: LearningDataTab) -> some View {
        let isActive = model.tab == tab
        return Button {
            model.select(tab)
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
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(model.tab.searchPlaceholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(minWidth: 60, maxWidth: .infinity)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            Spacer()
            if model.loading {
                ProgressView()
                    .controlSize(.small)
                Text("读取中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 表格

    private var columns: [LearningDataColumn] { model.tab.columns }

    private var tableView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    Text(column.title)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: column.width,
                               alignment: column.trailing ? .trailing : .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.05))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        tableRow(row, zebra: index % 2 == 1)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.black.opacity(0.1), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tableRow(_ row: LearningDataRow, zebra: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(zip(columns.indices, row.cells)), id: \.0) { index, cell in
                let column = columns[index]
                Text(cell)
                    .font(index == 0 && model.tab == .chars ? .system(size: 15) : .caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: column.width,
                           alignment: column.trailing ? .trailing : .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(zebra ? Color.black.opacity(0.025) : Color.clear)
    }

    private var paginationBar: some View {
        HStack {
            Button("上一页") { model.prevPage() }
                .disabled(model.page <= 0)
                .buttonStyle(.borderless)
            Spacer()
            Text(countLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("下一页") { model.nextPage() }
                .disabled(model.page >= model.totalPages - 1)
                .buttonStyle(.borderless)
        }
        .padding(.top, 2)
    }

    /// 匹配条数 + 页码；匹配数超出装载上限时提示收窄关键词
    private var countLine: String {
        let pages = "第 \(model.page + 1) / \(max(1, model.totalPages)) 页"
        let matched = "匹配 \(formatStatCount(model.sectionTotal)) 条"
        var text = "\(pages) · \(matched)"
        if model.sectionTotal > model.displayedCount {
            text += "（仅装载前 \(formatStatCount(model.displayedCount)) 条，可用关键词收窄）"
        }
        return text
    }

    // MARK: 空态

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: model.hasAnyData ? "magnifyingglass" : "brain")
                    .font(.title)
                    .foregroundStyle(.secondary.opacity(0.4))
                Text(emptyTitle)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Text(emptySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var emptyTitle: String {
        if model.loading { return "读取中…" }
        return model.hasAnyData ? "没有匹配的学习数据" : "还没有学到东西"
    }

    private var emptySubtitle: String {
        if model.loading { return "正在读取学习数据库" }
        if model.hasAnyData { return "换个关键词试试，或清空搜索框浏览全部数据" }
        return "正常打字一段时间后再回来看；也可以点「回填历史数据」从输入历史重建"
    }
}

// MARK: - 窗口

/// 「查看学习数据」窗口：静态持有，重复点击入口只置顶不新建
enum LearningDataWindow {
    fileprivate static var window: NSWindow?
    fileprivate static let closeHandler = CloseHandler()

    /// 关闭时清掉静态引用：下次入口点击会重建窗口（连带重建 ViewModel，
    /// 重新打开即是最新数据）
    final class CloseHandler: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            guard let win = notification.object as? NSWindow else { return }
            if win === LearningDataWindow.window {
                LearningDataWindow.window = nil
            }
        }
    }

    static func open() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "学习数据"
        win.contentView = NSHostingView(rootView: LearningDataView())
        win.contentMinSize = NSSize(width: 560, height: 360)
        win.isReleasedWhenClosed = false
        win.delegate = closeHandler
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
