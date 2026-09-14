//
//  ThemePane.swift
//  Fire
//
//  Created by 虚幻 on 2022/3/19.
//  Copyright © 2022 qwertyyb. All rights reserved.
//

import SwiftUI
import Defaults

struct ThemeConfigView: View {
    let themeConfig: ThemeConfig
    let isUsing: Bool
    let use: () -> Void
    var onEdit: (() -> Void)?
    var onExport: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(themeConfig.name)
                        .font(.system(size: 13, weight: .medium))
                    if isUsing {
                        Text("使用中")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
                Text("ID: \(themeConfig.id) · \(themeConfig.author)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                if let onEdit = onEdit {
                    Button("编辑", action: onEdit).controlSize(.small)
                }
                if let onExport = onExport {
                    Button("导出", action: onExport).controlSize(.small)
                }
                if let onDelete = onDelete {
                    Button("删除", action: onDelete).controlSize(.small)
                }
                Button(isUsing ? "正使用" : "使用") { use() }
                    .disabled(isUsing)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                // 当前使用 → 彩色粗边框；未使用 → 灰色细边框
                .stroke(
                    isUsing ? Color.accentColor : Color.gray.opacity(0.3),
                    lineWidth: isUsing ? 2 : 1
                )
        )
    }
}

/// 主题面板：迁移至原生 Form(.grouped)；「创建主题」抛弃网页窗口
/// （theme.html），改用原生 ThemeEditorView + 候选栏实时预览浮窗。
struct ThemePane: View {
    @Default(.themeConfig) var themeConfig
    @Default(.importedThemeConfig) var importedThemeConfig
    @Default(.hideCandidatesWindow) var hideCandidatesWindow
    @Default(.themeAppearanceMode) var themeAppearanceMode

    /// 正在编辑的主题；nil = 新建
    @State private var editingTheme: ThemeConfig?
    @State private var confirmDeleteTheme: ThemeConfig?
    @State private var importedMessage = ""
    @State private var showAlert = false
    /// 编辑器窗口静态持有：编辑器内部需要据此定位预览浮窗
    static var editorWindow: NSWindow?
    static let editorDelegate = EditorCloseHandler()
    class EditorCloseHandler: NSObject, NSWindowDelegate {
        func windowWillClose(_: Notification) { ThemeEditorView.closePreview() }
    }

    /// 关闭编辑器窗口并清理静态引用
    static func closeEditor() {
        editorWindow?.close()
        editorWindow = nil
    }

    private func openEditor() {
        ThemeEditorView.closePreview()
        ThemePane.editorWindow?.close()
        let host = NSHostingView(rootView: ThemeEditorView(existing: editingTheme))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = editingTheme == nil ? "创建主题" : "编辑主题 · \(editingTheme?.name ?? "")"
        win.contentView = host
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = Self.editorDelegate
        // 先持有窗口再显示：编辑器 onAppear 构建预览浮窗时即可按此定位
        ThemePane.editorWindow = win
        win.makeKeyAndOrderFront(nil)
    }

    private func importTheme() {
        let openPanel = NSOpenPanel()
        openPanel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        openPanel.prompt = "选择主题文件"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [.json]
        let result = openPanel.runModal()
        if result != NSApplication.ModalResponse.OK { return }
        guard let url = openPanel.url,
              let jsonData = try? String(contentsOf: url, encoding: .utf8) else {
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
        Form {
            Section {
                PreferencePickerRow(title: "深浅模式") {
                    Picker("", selection: $themeAppearanceMode) {
                        Text("深色主题").tag(ThemeAppearanceMode.dark)
                        Text("浅色主题").tag(ThemeAppearanceMode.light)
                        Text("跟随系统").tag(ThemeAppearanceMode.followSystem)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                PreferenceToggleRow(title: "隐藏候选区", isOn: $hideCandidatesWindow)
            } header: {
                Text("外观")
            }
            Section {
                HStack {
                    Button("创建主题") {
                        editingTheme = nil
                        openEditor()
                    }
                    Spacer()
                    Button("导入", action: importTheme)
                        .alert(importedMessage, isPresented: $showAlert) {
                            Button("确认", role: .cancel) {}
                        }
                }
            } header: {
                Text("主题管理")
            }
            Section {
                ThemeConfigView(
                    themeConfig: defaultThemeConfig,
                    isUsing: themeConfig.id == defaultThemeConfig.id,
                    use: { useThemeConfig(themeConfig: defaultThemeConfig) },
                    onEdit: {
                        editingTheme = defaultThemeConfig
                        openEditor()
                    }
                )
                if let importedThemeConfig = importedThemeConfig {
                    Divider()
                    ThemeConfigView(
                        themeConfig: importedThemeConfig,
                        isUsing: importedThemeConfig.id == themeConfig.id,
                        use: {
                            useThemeConfig(themeConfig: importedThemeConfig)
                        },
                        onEdit: {
                            editingTheme = importedThemeConfig
                            openEditor()
                        },
                        onExport: { exportTheme(importedThemeConfig) },
                        onDelete: { deleteImportedTheme() }
                    )
                }
            } header: {
                Text("主题列表")
            }
        }
        .formStyle(.grouped)
    }
}

struct ThemePane_Previews: PreviewProvider {
    static var previews: some View {
        ThemePane()
    }
}
