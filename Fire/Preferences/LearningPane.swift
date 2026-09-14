//
//  LearningPane.swift
//  Fire
//
//  学习系统设置面板：通道开关、强度、历史回填与数据清除。
//  学习数据全部保存在本地加密库（user-learning.db），不上传。
//

import SwiftUI
import AppKit
import Defaults
import UniformTypeIdentifiers

struct LearningPane: View {
    @Default(.enableLearning) private var enableLearning
    @Default(.enableLearningUserNgram) private var enableLearningUserNgram
    @Default(.enableLearningSessionCache) private var enableLearningSessionCache
    @Default(.enableLearningCorrection) private var enableLearningCorrection
    @Default(.learningStrength) private var learningStrength

    @State private var statusText: String = "读取中…"
    @State private var backfillRunning: Bool = false
    @State private var showClearConfirm: Bool = false

    private func refreshStatus() {
        LearnerCenter.shared.statusSummary { summary in
            DispatchQueue.main.async { statusText = summary }
        }
    }

    private func runBackfill() {
        guard !backfillRunning else { return }
        let confirm = NSAlert()
        confirm.messageText = "从历史重建字符 n-gram？"
        confirm.informativeText = "将清空现有字符 n-gram 计数，从统计历史全量重学一遍（纠错对不受影响）。"
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: "重建")
        confirm.addButton(withTitle: "取消")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        backfillRunning = true
        statusText = "历史重建中…"
        LearnerCenter.shared.rebuildFromHistory { processed, finished in
            DispatchQueue.main.async {
                if finished {
                    backfillRunning = false
                    refreshStatus()
                } else {
                    statusText = "历史重建中… 已处理 \(processed) 条"
                }
            }
        }
    }

    private func clearData() {
        let alert = NSAlert()
        alert.messageText = "清除全部学习数据？"
        alert.informativeText = "字符 n-gram、纠错对与会话缓存都会清空，此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            LearnerCenter.shared.clearAllData()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshStatus() }
        }
    }

    // MARK: 导入导出（TCSKNM02 格式，通道 B 字符 n-gram）

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    private func exportLearning() {
        let panel = NSSavePanel()
        panel.title = "导出学习数据"
        panel.message = "TCSKNM02 分页格式（与整句 n-gram 模型同构），可在其他设备导入。"
        panel.nameFieldStringValue = "fire-learning-ngram.bin"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        LearnerCenter.shared.exportNgramData { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    do {
                        try data.write(to: url)
                        self.showAlert(title: "导出成功",
                                       message: "已写入 \(data.count / 1024) KB → \(url.lastPathComponent)")
                    } catch {
                        self.showAlert(title: "导出失败", message: error.localizedDescription)
                    }
                case .failure(let error):
                    self.showAlert(title: "导出失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func importLearning() {
        let panel = NSOpenPanel()
        panel.title = "导入学习数据"
        panel.message = "选择 TCSKNM02 格式的学习数据文件（由本面板导出）。"
        panel.allowedContentTypes = [.data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let confirm = NSAlert()
        confirm.messageText = "导入学习数据？"
        confirm.informativeText = "将替换当前的字符 n-gram 学习数据（纠错对不受影响），导入后立即生效。"
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "导入")
        confirm.addButton(withTitle: "取消")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            showAlert(title: "导入失败", message: "读取文件失败：\(error.localizedDescription)")
            return
        }
        LearnerCenter.shared.importNgramData(data) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let entries):
                    self.showAlert(title: "导入成功", message: "已载入 \(entries) 条学习数据")
                    self.refreshStatus()
                case .failure(let error):
                    self.showAlert(title: "导入失败", message: error.localizedDescription)
                }
            }
        }
    }

    var body: some View {
        Form {
            Section {
                PreferenceToggleRow(title: "启用学习系统", caption: "辅助整句 n-gram 模型", isOn: $enableLearning)
                if enableLearning {
                    PreferenceToggleRow(title: "字符级用户 n-gram", caption: "长期用词习惯，带时间衰减", isOn: $enableLearningUserNgram)
                    PreferenceToggleRow(title: "会话缓存", caption: "最近输入的内容优先（切换输入框自动清空）", isOn: $enableLearningSessionCache)
                    PreferenceToggleRow(title: "纠错对", caption: "记住同码下被你否决的首选", isOn: $enableLearningCorrection)
                    HStack(spacing: 8) {
                        Text("学习强度")
                        Slider(value: $learningStrength, in: 0.2...2.0)
                        Text(String(format: "%.1f", learningStrength))
                            .font(.system(size: 12).monospacedDigit())
                            .frame(width: 32)
                    }
                }
            } header: {
                Text("用词习惯学习")
            }
            if enableLearning {
                Section {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button("立即落库") {
                            LearnerCenter.shared.flushImmediately()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refreshStatus() }
                        }
                        Button(backfillRunning ? "重建中…" : "回填历史数据") {
                            runBackfill()
                        }
                        .disabled(backfillRunning)
                        Button("清除学习数据") {
                            clearData()
                        }
                    }
                    HStack {
                        Button("导出学习数据 (TCSKNM02)") {
                            exportLearning()
                        }
                        Button("导入学习数据 (TCSKNM02)") {
                            importLearning()
                        }
                    }
                    Text("学习数据只保存在本机加密数据库，不会上传；撤销上屏（默认 Ctrl+U）会同步回退学习计数。导入导出覆盖字符 n-gram（TCSKNM02 分页格式），纠错对保留在本地库。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("学习数据")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshStatus)
    }
}
