//
//  PunctuationPane.swift
//  Fire
//
//  Created by 虚幻 on 2022/6/27.
//  Copyright © 2022 qwertyyb. All rights reserved.
//

import SwiftUI
import Defaults

/// 标点符号面板：迁移至原生 Form(.grouped)，与侧边栏风格首选项配套
struct PunctuationPane: View {
    @Default(.punctuationMode) private var punctuationMode
    @Default(.customPunctuationSettings) private var customPunctuationSettings
    @Default(.enableDotAfterNumber) private var enableDotAfterNumber
    @Default(.enableColonAfterNumber) private var enableColonAfterNumber
    @Default(.enablePunctuationTopScreen) private var enablePunctuationTopScreen

    var body: some View {
        Form {
            Section {
                PreferencePickerRow(title: "标点符号方案") {
                    Picker("", selection: $punctuationMode) {
                        Text("半角").tag(PunctuationMode.enUs)
                        Text("全角").tag(PunctuationMode.zhhans)
                        Text("自定义").tag(PunctuationMode.custom)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                PreferenceToggleRow(title: "数字/字母后标点自动转英文", caption: "连按两次转回中文", isOn: $enableDotAfterNumber)
                PreferenceToggleRow(title: "数字后全角冒号转半角", caption: "适用于 12:45 时间场景", isOn: $enableColonAfterNumber)
                PreferenceToggleRow(title: "标点顶屏", isOn: $enablePunctuationTopScreen)
            } header: {
                Text("标点方案")
            }
            Section {
                HStack {
                    Text("按键")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("输出")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                ForEach(
                    customPunctuationSettings.sorted(by: <),
                    id: \.key) { (key, value) in
                    HStack(spacing: 0) {
                        Text(key)
                            .frame(maxWidth: .infinity, alignment: .center)
                        Picker("", selection: Binding<String>(
                            get: { value },
                            set: {
                                customPunctuationSettings[key] = $0
                            }
                        )) {
                            Text(key)
                                .tag(key)
                            Text(punctuation[key] ?? key)
                                .tag(punctuation[key] ?? key)
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("自定义符号")
            }
            .disabled(punctuationMode != .custom)
        }
        .formStyle(.grouped)
    }
}

struct PunctuationPane_Previews: PreviewProvider {
    static var previews: some View {
        PunctuationPane()
    }
}
