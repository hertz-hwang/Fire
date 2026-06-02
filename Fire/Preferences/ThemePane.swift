//
//  ThemePane.swift
//  Fire
//
//  Created by 虚幻 on 2022/3/19.
//  Copyright © 2022 qwertyyb. All rights reserved.
//

import SwiftUI
import Settings
import Defaults

struct ThemeConfigView: View {
    let themeConfig: ThemeConfig
    let isUsing: Bool
    let use: () -> Void
    var onExport: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .trailing) {
            HStack {
                Text("\(themeConfig.name)(\(themeConfig.id))")
                Spacer()
                Text(themeConfig.author)
            }
            HStack {
                Spacer()
                if let onExport = onExport {
                    Button("导出", action: onExport)
                }
                if let onDelete = onDelete {
                    Button("删除", action: onDelete)
                }
                Button(isUsing ? "正使用" : "使用") {
                    use()
                }
                .disabled(isUsing)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }
}

struct ThemePane: View {
    @Default(.themeConfig) var themeConfig
    @Default(.importedThemeConfig) var importedThemeConfig

    @State private var importedMessage = ""
    @State private var showAlert = false

    private func importTheme() {
        let openPanel = NSOpenPanel()
        openPanel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        openPanel.prompt = "选择应用"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [.json]
        let result = openPanel.runModal()
        if result != NSApplication.ModalResponse.OK { return }
        let selectedPath = openPanel.url!.path
        guard let jsonData = try? String(contentsOfFile: selectedPath) else {
            importedMessage = "导入失败，请检查文件内容"
            showAlert = true
            return
        }
        switch parseThemeConfig(jsonData: jsonData) {
        case .success(let themeConfig):
            applyImportedTheme(themeConfig)
        case .failure(let error):
            importedMessage = error.localizedDescription
            showAlert = true
        }
    }

    func useThemeConfig(themeConfig: ThemeConfig) {
        Defaults[.themeConfig] = themeConfig
    }

    private func exportTheme(_ themeConfig: ThemeConfig) {
        guard let json = jsonThemeConfig(config: themeConfig) else {
            importedMessage = "导出失败"
            showAlert = true
            return
        }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "\(themeConfig.name)-\(themeConfig.id)-\(themeConfig.author).json"
        savePanel.canCreateDirectories = true
        if savePanel.runModal() != .OK { return }
        guard let url = savePanel.url else { return }
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            importedMessage = "导出失败：\(error.localizedDescription)"
            showAlert = true
        }
    }

    private func deleteImportedTheme() {
        guard let imported = Defaults[.importedThemeConfig] else { return }
        let alert = NSAlert()
        alert.messageText = "确认删除主题 \(imported.name)(\(imported.id))？"
        alert.informativeText = "删除后无法恢复，若当前正在使用该主题，将回退到默认主题。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() != .alertFirstButtonReturn { return }

        if Defaults[.themeConfig].id == imported.id {
            Defaults[.themeConfig] = defaultThemeConfig
        }
        Defaults[.importedThemeConfig] = nil
    }

    var body: some View {
        Settings.Container(contentWidth: 450.0) {
            Settings.Section(title: "") {
                HStack {
                    Button("创建主题") {
                        if let url = URL(string: "https://qwertyyb.github.io/Fire/theme.html") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer()
                    if #available(macOS 12.0, *) {
                        Button("导入", action: importTheme)
                            .alert(importedMessage, isPresented: $showAlert) {
                                Button("确认", role: .cancel) {}
                            }
                    } else {
                        Button("导入", action: importTheme)
                    }
                }
                GroupBox(label: Text("默认主题")) {
                    ThemeConfigView(
                        themeConfig: defaultThemeConfig,
                        isUsing: themeConfig.id == defaultThemeConfig.id,
                        use: { useThemeConfig(themeConfig: defaultThemeConfig)}
                    )
                }
                if let importedThemeConfig = importedThemeConfig {
                    GroupBox(label: Text("导入的主题")) {
                        ThemeConfigView(
                            themeConfig: importedThemeConfig,
                            isUsing: importedThemeConfig.id == themeConfig.id,
                            use: {
                                useThemeConfig(themeConfig: importedThemeConfig)
                            },
                            onExport: { exportTheme(importedThemeConfig) },
                            onDelete: { deleteImportedTheme() }
                        )
                    }
                }
            }
        }
    }
}

struct ThemePane_Previews: PreviewProvider {
    static var previews: some View {
        ThemePane()
    }
}
