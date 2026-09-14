//
//  HotkeyPane.swift
//  Fire
//
//  Created by Codex on 2026/3/12.
//

import SwiftUI
import Defaults

/// 快捷键设置面板：迁移至原生 Form(.grouped)，与侧边栏风格首选项配套
struct HotkeyPane: View {
    @Default(.openPreferencesShortcutModifier) private var shortcutModifier
    @Default(.openPreferencesShortcutKey) private var shortcutKey
    @Default(.undoCommitShortcutModifier) private var undoShortcutModifier
    @Default(.undoCommitShortcutKey) private var undoShortcutKey
    @Default(.clearCodeShortcutModifier) private var clearCodeShortcutModifier
    @Default(.clearCodeShortcutKey) private var clearCodeShortcutKey

    private func normalizedKey(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else {
            return fallback
        }
        return String(first).lowercased()
    }

    /// 一行「修饰键 + 按键」快捷键编辑器
    @ViewBuilder
    private func shortcutRow(_ title: String, modifier: Binding<ModifierKey>, key: Binding<String>, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                Picker("", selection: modifier) {
                    Text("control").tag(ModifierKey.control)
                    Text("shift").tag(ModifierKey.shift)
                    Text("option").tag(ModifierKey.option)
                    Text("command").tag(ModifierKey.command)
                    Text("fn").tag(ModifierKey.function)
                }
                .labelsHidden()
                .fixedSize()
                Text("+")
                    .foregroundStyle(.secondary)
                TextField("按键", text: Binding<String>(
                    get: { key.wrappedValue },
                    set: { key.wrappedValue = normalizedKey($0, fallback: key.wrappedValue) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    var body: some View {
        Form {
            Section {
                shortcutRow("打开首选项", modifier: $shortcutModifier, key: $shortcutKey,
                           caption: "仅支持一个修饰键 + 单个按键")
                shortcutRow("撤消上屏", modifier: $undoShortcutModifier, key: $undoShortcutKey,
                           caption: "仅支持一个修饰键 + 单个按键")
                shortcutRow("清空编码串", modifier: $clearCodeShortcutModifier, key: $clearCodeShortcutKey,
                           caption: "直接丢弃当前未上屏的编码（非ESC）；无编码时该快捷键交回应用处理")
            } header: {
                Text("全局快捷键")
            }
        }
        .formStyle(.grouped)
    }
}

struct HotkeyPane_Previews: PreviewProvider {
    static var previews: some View {
        HotkeyPane()
    }
}
