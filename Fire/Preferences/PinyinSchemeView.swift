//
//  PinyinSchemeView.swift
//  Fire
//
//  偏好设置「基本」页里的拼音方案区：拼音输入方式（全拼 / 小鹤 / 自然码 / 自定义双拼）、
//  模糊音、敲错纠正。只在编码方案=拼音时出现。
//
//  这里只写设置 + 通知引擎重载配置；真正的键位编辑在 `ShuangpinEditorWindow`
//  （模拟键盘 + 拖动声/韵元素）。
//

import SwiftUI
import Defaults

struct PinyinSchemeSection: View {
    @Default(.pinyinLayout) private var layout
    @Default(.pinyinCustomTable) private var customTable
    @Default(.pinyinTypoCorrection) private var typoCorrection
    @State private var fuzzy = PinyinFuzzyRules.none
    @State private var showEditor = false

    /// 当前自定义表（解析失败按小鹤跑，并在面板上说明）
    private var table: ShuangpinKeyTable {
        PinyinLayout.customKeyTable(from: customTable)
    }

    var body: some View {
        PreferencePickerRow(title: "拼音输入方式") {
            Picker("", selection: $layout) {
                ForEach(PinyinLayout.allCases, id: \.self) { item in
                    Text(item.label).tag(item)
                }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: layout) { _ in apply() }
        }
        .help("双拼两键一个音节：第一键声母、第二键韵母，零声母另有约定。切分/查词/组句与全拼同一套管线")

        if layout.isShuangpin {
            ShuangpinOverview(table: table, editable: layout == .custom) {
                showEditor = true
            }
        }

        PreferenceToggleRow(title: "敲错纠正", isOn: $typoCorrection)
            .help("相邻两键敲反（mignt → ming t…）、少敲/多敲一个字母时按噪声信道纠正；纠正后的读法要在语境里明显更通顺才会顶掉原样")
            .onChange(of: typoCorrection) { _ in apply() }

        DisclosureGroup(isExpanded: $fuzzyExpanded) {
            ForEach(Array(PinyinSettings.fuzzyItems.enumerated()), id: \.offset) { _, item in
                Toggle(isOn: Binding(
                    get: { item.get(fuzzy) },
                    set: { on in
                        var next = fuzzy
                        item.set(&next, on)
                        fuzzy = next
                        PinyinSettings.save(fuzzyRules: next)
                        apply()
                    }
                )) {
                    HStack(spacing: 6) {
                        Text(item.title)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("全开") {
                    fuzzy = PinyinFuzzyRules.all
                    PinyinSettings.save(fuzzyRules: fuzzy)
                    apply()
                }
                Button("全关") {
                    fuzzy = PinyinFuzzyRules.none
                    PinyinSettings.save(fuzzyRules: fuzzy)
                    apply()
                }
            }
            .controlSize(.small)
            Text("只对「按原样读不出来」或读出来不通顺的输入让路：模糊音写法命中要扣一次分（词频减半），原样读得通时不会被它顶掉。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            // 两段 Text 拼一起（`Text + Text` 会让尾部的 foregroundStyle 解析到 macOS 14 才有的重载）
            HStack(spacing: 6) {
                Text("模糊音")
                Text(fuzzy.any ? "（已开 \(fuzzy.enabledCount) 条）" : "（未开启）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if layout == .custom && !customTable.isEmpty && !PinyinLayout.customTableIsValid {
            Text("自定义键位表读取失败，已按小鹤双拼运行。打开键位编辑器重新保存即可。")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @State private var fuzzyExpanded = false

    private func apply() {
        PinyinEngineCenter.shared.applySettings()
    }

    private static func loadFuzzy() -> PinyinFuzzyRules {
        PinyinSettings.fuzzyRules()
    }
}

/// 当前双拼方案的键位概览：一行一个小结（声母键 / 韵母键数 / 零声母写法数），
/// 自定义时给「编辑键位」入口。不做全键盘渲染——键盘在编辑器窗口里。
private struct ShuangpinOverview: View {
    let table: ShuangpinKeyTable
    let editable: Bool
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("声母键 \(table.initials.count) 个 · 韵母键 \(table.finals.count) 个 · 零声母 \(table.zeroInitials.count) 个")
                    .font(.callout)
                if table.semicolon {
                    Text("占用 ; 键")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
                if editable {
                    Button("编辑键位…", action: onEdit)
                }
            }
            // 韵母键位摘要：按键排序，一眼能看出这套方案把哪些韵放在哪个键上
            Text(table.finals.map { "\($0.key)=\($0.finals.joined(separator: "/"))" }
                .joined(separator: "  "))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
