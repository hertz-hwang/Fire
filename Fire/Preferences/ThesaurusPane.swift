//
//  ThesaurusPane.swift
//  Fire
//
//  Created by 虚幻 on 2020/10/25.
//  Copyright © 2020 qwertyyb. All rights reserved.
//

import SwiftUI
import AppKit
import Settings
import Defaults

struct ThesaurusPane: View {
    @Default(.wbTablePath) private var wbTablePath
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

    var body: some View {
        Settings.Container(contentWidth: 450.0) {
            Settings.Section(title: "") {
                VStack(alignment: .leading) {
                    GroupBox(label: Text("词库设置")) {
                        VStack(spacing: 6) {
                            HStack {
                                Group {
                                    Text("形码词库: ")
                                    Text(wbTablePath)
                                        .lineLimit(1)
                                        .padding(.horizontal, 6)
                                        .truncationMode(.middle)
                                        .font(.system(size: 10))
                                      .foregroundColor(.white)
                                        .background(Color(.displayP3, red: 0.5, green: 0.5, blue: 0.5, opacity: 1))
                                        .cornerRadius(4)
                                        .onTapGesture {
                                            if let path = selectFile() {
                                                Defaults[.wbTablePath] = path
                                            }
                                        }
                                }
                                Spacer()
                            }
                            HStack {
                                Group {
                                    Text("拼音词库: ")
                                    Text(pyTablePath)
                                        .lineLimit(1)
                                        .padding(.horizontal, 6)
                                        .truncationMode(.middle)
                                        .font(.system(size: 10))
                                        .foregroundColor(.white)
                                        .background(Color(.displayP3, red: 0.5, green: 0.5, blue: 0.5, opacity: 1))
                                        .cornerRadius(4)
                                        .onTapGesture {
                                            if let path = selectFile() {
                                                Defaults[.pyTablePath] = path
                                            }
                                        }
                                }
                                Spacer()
                            }
                            HStack {
                                Group {
                                    Text("拆分表: ")
                                    Text(charDivTablePath.isEmpty ? "未设置（候选词悬浮拆分提示）" : charDivTablePath)
                                        .lineLimit(1)
                                        .padding(.horizontal, 6)
                                        .truncationMode(.middle)
                                        .font(.system(size: 10))
                                        .foregroundColor(.white)
                                        .background(Color(.displayP3, red: 0.5, green: 0.5, blue: 0.5, opacity: 1))
                                        .cornerRadius(4)
                                        .onTapGesture {
                                            if let path = selectFile() {
                                                Defaults[.charDivTablePath] = path
                                                CharDivTable.shared.reload()
                                            }
                                        }
                                }
                                Spacer()
                            }
                            HStack {
                                Text("拆分字根字体: ")
                                Picker("", selection: $charDivRootFontName) {
                                    Text("系统默认").tag("")
                                    ForEach(availableFontFamilies, id: \.self) { family in
                                        Text(family).tag(family)
                                    }
                                }
                                .frame(width: 200)
                                Spacer()
                            }
                            HStack {
                                Group {
                                    Text("整句模型: ")
                                    Text(modelStatus)
                                        .lineLimit(2)
                                        .padding(.horizontal, 6)
                                        .truncationMode(.middle)
                                        .font(.system(size: 10))
                                        .foregroundColor(.white)
                                        .background(modelLoaded
                                                    ? Color(.displayP3, red: 0.5, green: 0.5, blue: 0.5, opacity: 1)
                                                    : Color(.displayP3, red: 0.7, green: 0.3, blue: 0.3, opacity: 1))
                                        .cornerRadius(4)
                                }
                                Spacer()
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
                        }
                    }
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
                .onAppear {
                    refreshModelStatus()
                }
            }
        }
    }
}

struct ThesaurusPane_Previews: PreviewProvider {
    static var previews: some View {
        ThesaurusPane()
    }
}
