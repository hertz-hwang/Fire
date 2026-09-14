//
//  UserDictPane.swift
//  Fire
//
//  Created by 虚幻 on 2022/7/1.
//  Copyright © 2022 qwertyyb. All rights reserved.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

class UserDictTextModel: ObservableObject {
    @Published var text = ""
    private var cancellable = Set<AnyCancellable>()

    init() {
        refresh()
        NotificationCenter.default.publisher(for: DictManager.userDictUpdated).sink { _ in
            self.refresh()
        }
        .store(in: &cancellable)
    }

    func refresh() {
        NSLog("[UserDictTextModel.refresh]")
        self.text = DictManager.shared.getUserDictContent()
    }
}

/// 用户词库面板：迁移至原生 Form(.grouped)，与侧边栏风格首选项配套
struct UserDictPane: View {
    @StateObject private var userDictTextModel = UserDictTextModel()

    private func exportDict() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "user-dict.txt"
        panel.title = "导出用户词库"
        if panel.runModal() == .OK, let url = panel.url {
            try? userDictTextModel.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func importDict() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.title = "导入用户词库"
        panel.message = "选择用户词库文件（将替换当前词库）"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                userDictTextModel.text = content
                DictManager.shared.updateUserDict(content)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $userDictTextModel.text)
                    .font(Font.custom("Monaco", size: 14))
                    .frame(minHeight: 260)
                    .lineSpacing(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. 编码需在行首")
                    Text("2. 编码和候选项之间需用空格分隔")
                    Text("3. 可以有多个候选项，每个候选项使用空格分隔")
                    Text("4. 候选项可使用{yyyy}/{MM}/{dd}/{HH}/{mm}/{ss}代替当前年/月/日/时/分/秒")
                    Text("5. 行首可加权重：「[权重] 编码 词条1 词条2 ……」（权重省略时默认1000）。整句模式下，带权重词条按权重提升组句得分，用于新词/流行词/个人常用词；「权重 词条」（无编码）只参与整句加权，不出普通候选")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Button("导入") {
                        importDict()
                    }
                    Button("导出") {
                        exportDict()
                    }
                    Spacer()
                    Button("保存") {
                        DictManager.shared.updateUserDict(userDictTextModel.text)
                    }
                    .keyboardShortcut("s", modifiers: .command)
                }
            } header: {
                Text("用户词库")
            }
        }
        .formStyle(.grouped)
    }
}

struct UserDictPane_Previews: PreviewProvider {
    static var previews: some View {
        UserDictPane()
    }
}
