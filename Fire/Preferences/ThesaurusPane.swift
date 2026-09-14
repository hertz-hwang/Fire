//
//  ThesaurusPane.swift
//  Fire
//
//  Created by 虚幻 on 2020/10/25.
//  Copyright © 2020 qwertyyb. All rights reserved.
//

import SwiftUI
import AppKit
import Defaults

/// 高级/词库面板：迁移至原生 Form(.grouped)，与侧边栏风格首选项配套
struct ThesaurusPane: View {
    @Default(.pyTablePath) private var pyTablePath
    @Default(.charDivTablePath) private var charDivTablePath
    @Default(.charDivRootFontName) private var charDivRootFontName

    @State private var modelLoaded: Bool = false
    @State private var modelStatus: String = "未加载"

    private let availableFontFamilies = NSFontManager.shared.availableFontFamilies

    private func selectFile() -> String? {
        let openPanel = NSOpenPanel()
        openPanel.directoryURL = Bundle.main.resourceURL
        openPanel.prompt = "选择词库文件"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [.text]
        let result = openPanel.runModal()
        if result == NSApplication.ModalResponse.OK {
            let selectedPath = openPanel.url!.path
            print(selectedPath)
            return selectedPath

        }
        return nil
    }

    private func refreshModelStatus() {
        // 懒加载语义下 loaded 初始恒为 false，面板打开时先如实显示，
        // 再在后台 ensureLoaded 一次并回填真实状态。
        if !NgramModel.shared.loaded && NgramModel.shared.loadError == nil {
            modelLoaded = false
            modelStatus = "就绪（首次整句输入时自动加载）"
        } else {
            modelLoaded = NgramModel.shared.loaded
            modelStatus = NgramModel.shared.statusText()
        }
        DispatchQueue.global(qos: .utility).async {
            NgramModel.shared.ensureLoaded()
            let loaded = NgramModel.shared.loaded
            let status = NgramModel.shared.statusText()
            DispatchQueue.main.async {
                modelLoaded = loaded
                modelStatus = status
            }
        }
    }

    /// 可点击切换路径的路径徽章
    @ViewBuilder
    private func pathBadge(_ path: String, onTap: @escaping () -> Void) -> some View {
        Text(path)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .truncationMode(.middle)
            .font(.system(size: 10))
            .foregroundColor(.white)
            .background(Color(.displayP3, red: 0.5, green: 0.5, blue: 0.5, opacity: 1))
            .cornerRadius(4)
            .onTapGesture(perform: onTap)
    }

    /// 状态徽章（按加载状态着色）
    @ViewBuilder
    private func statusBadge() -> some View {
        Text(modelStatus)
            .lineLimit(2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .truncationMode(.middle)
            .font(.system(size: 10))
            .foregroundColor(.white)
            .background(modelLoaded
                        ? Color(.displayP3, red: 0.5, green: 0.5, blue: 0.5, opacity: 1)
                        : Color(.displayP3, red: 0.7, green: 0.3, blue: 0.3, opacity: 1))
            .cornerRadius(4)
    }

    var body: some View {
        Form {
            Section {
                PreferencePickerRow(title: "拼音词库") {
                    pathBadge(pyTablePath) {
                        if let path = selectFile() {
                            Defaults[.pyTablePath] = path
                        }
                    }
                }
                PreferencePickerRow(title: "拆分表") {
                    pathBadge(charDivTablePath.isEmpty ? "未设置（候选词悬浮拆分提示）" : charDivTablePath) {
                        if let path = selectFile() {
                            Defaults[.charDivTablePath] = path
                            CharDivTable.shared.reload()
                        }
                    }
                }
                PreferencePickerRow(title: "拆分字根字体") {
                    Picker("", selection: $charDivRootFontName) {
                        Text("系统默认").tag("")
                        ForEach(availableFontFamilies, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack(spacing: 8) {
                    Text("整句模型")
                    Spacer()
                    statusBadge()
                    Button("重新载入") {
                        DispatchQueue.global(qos: .userInitiated).async {
                            NgramModel.shared.reload()
                            let loaded = NgramModel.shared.loaded
                            let status = NgramModel.shared.statusText()
                            DispatchQueue.main.async {
                                modelLoaded = loaded
                                modelStatus = status
                            }
                        }
                    }
                }
            } header: {
                Text("词库设置")
            }
            Section {
                Button(action: {
                    DictManager.shared.close()
                    buildDict()
                    DictManager.shared.reinit()
                    // 整句词图跟随词库重建
                    SentenceLexicon.shared.markDirty()
                }, label: {
                    Text("建立索引")
                })
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshModelStatus()
        }
    }
}

struct ThesaurusPane_Previews: PreviewProvider {
    static var previews: some View {
        ThesaurusPane()
    }
}
