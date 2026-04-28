//
//  HotkeyPane.swift
//  Fire
//
//  Created by Codex on 2026/3/12.
//

import SwiftUI
import Settings
import Defaults

struct HotkeyPane: View {
    @Default(.openPreferencesShortcutModifier) private var shortcutModifier
    @Default(.openPreferencesShortcutKey) private var shortcutKey
    @Default(.undoCommitShortcutModifier) private var undoShortcutModifier
    @Default(.undoCommitShortcutKey) private var undoShortcutKey

    private func normalizedKey(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else {
            return fallback
        }
        return String(first).lowercased()
    }

    var body: some View {
        Settings.Container(contentWidth: 450) {
            Settings.Section(title: "") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("打开首选项")
                    HStack(spacing: 12) {
                        Picker("修饰键", selection: $shortcutModifier) {
                            Text("control").tag(ModifierKey.control)
                            Text("shift").tag(ModifierKey.shift)
                            Text("option").tag(ModifierKey.option)
                            Text("command").tag(ModifierKey.command)
                            Text("fn").tag(ModifierKey.function)
                        }
                        .frame(width: 160)
                        Text("+")
                        TextField("按键", text: Binding<String>(
                            get: { shortcutKey },
                            set: { shortcutKey = normalizedKey($0, fallback: shortcutKey) }
                        ))
                        .frame(width: 80)
                    }
                    Text("仅支持一个修饰键 + 单个按键")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("撤消上屏")
                    HStack(spacing: 12) {
                        Picker("修饰键", selection: $undoShortcutModifier) {
                            Text("control").tag(ModifierKey.control)
                            Text("shift").tag(ModifierKey.shift)
                            Text("option").tag(ModifierKey.option)
                            Text("command").tag(ModifierKey.command)
                            Text("fn").tag(ModifierKey.function)
                        }
                        .frame(width: 160)
                        Text("+")
                        TextField("按键", text: Binding<String>(
                            get: { undoShortcutKey },
                            set: { undoShortcutKey = normalizedKey($0, fallback: undoShortcutKey) }
                        ))
                        .frame(width: 80)
                    }
                    Text("仅支持一个修饰键 + 单个按键")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

struct HotkeyPane_Previews: PreviewProvider {
    static var previews: some View {
        HotkeyPane()
    }
}
