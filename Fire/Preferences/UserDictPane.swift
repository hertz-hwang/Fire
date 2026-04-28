//
//  UserDictPane.swift
//  Fire
//
//  Created by 虚幻 on 2022/7/1.
//  Copyright © 2022 qwertyyb. All rights reserved.
//

import SwiftUI
import Settings
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

struct UserDictPane: View {
    @StateObject private var userDictTextModel = UserDictTextModel()
    @State private var saved = false

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
        Settings.Container(contentWidth: 450) {
            Settings.Section(title: "") {
                Text("用户词库")
                if #available(macOS 11.0, *) {
                    TextEditor(text: $userDictTextModel.text)
                        .font(Font.custom("Monaco", size: 14))
                        .frame(height: 400)
                        .lineSpacing(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                    Text("1. 编码需在行首")
                        .font(Font.system(size: 12))
                    Text("2. 编码和候选项之间需用空格分隔")
                        .font(Font.system(size: 12))
                    Text("3. 可以有多个候选项，每个候选项使用空格分隔")
                        .font(Font.system(size: 12))
                    Text("4. 候选项可使用{yyyy}/{MM}/{dd}/{HH}/{mm}/{ss}代替当前年/月/日/时/分/秒")
                        .font(Font.system(size: 12))
                    HStack {
                        Button("导入") {
                            importDict()
                        }
                        Button("导出") {
                            exportDict()
                        }
                        Spacer()
                        if #available(macOS 12.0, *) {
                            Button("保存") {
                                DictManager.shared.updateUserDict(userDictTextModel.text)
                                saved = true
                            }
                            .alert("保存成功", isPresented: $saved) {
                            }
                        } else {
                            Button("保存") {
                                DictManager.shared.updateUserDict(userDictTextModel.text)
                                print("saved")
                            }
                        }
                    }
                } else {
                    // Fallback on earlier versions
                    Text("暂不支持，请升级系统至11.0及以上")
                }
            }
        }
    }
}

struct UserDictPane_Previews: PreviewProvider {
    static var previews: some View {
        UserDictPane()
    }
}
