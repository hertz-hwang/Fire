//
//  ThemeEditorView.swift
//  Fire
//
//  参考上游 qwertyyb/Fire 的原生主题编辑器重构：抛弃网页窗口
//  （theme.html），改为原生 SwiftUI 编辑器 + 候选栏实时预览浮窗。
//  参数覆盖本项目 ApperanceThemeConfig 的全部选项（含描边、打分、
//  页码指示等本地扩展字段）。
//
//  Copyright © 2026 qwertyyb. All rights reserved.
//

import SwiftUI
import AppKit

/// 编辑器内的可编辑主题草稿：字段与 ApperanceThemeConfig 一一对应，
/// 全部为 var 以支持 @State 子路径绑定；保存时转回不可变的 ApperanceThemeConfig。
struct ThemeAppearanceDraft: Equatable {
    var windowBackgroundColor: ColorData
    var windowPaddingTop: Float
    var windowPaddingLeft: Float
    var windowPaddingRight: Float
    var windowPaddingBottom: Float
    var windowBorderRadius: Float
    var windowBorderWidth: Float
    var windowBorderColor: ColorData

    var originCodeColor: ColorData
    var originCandidatesSpace: Float
    var candidateSpace: Float

    var candidateIndexColor: ColorData
    var candidateTextColor: ColorData
    var candidateCodeColor: ColorData

    var selectedIndexColor: ColorData
    var selectedTextColor: ColorData
    var selectedCodeColor: ColorData
    var selectedBackgroundColor: ColorData

    var pageIndicatorColor: ColorData
    var pageIndicatorDisabledColor: ColorData

    var candidateScoreColor: ColorData
    var candidateScoreFontSize: Float
    var candidateScoreBold: Bool

    var fontName: String
    var fontSize: Float
    var candidateIndexFontSize: Float
    var candidateCodeFontSize: Float
    var candidateRowPadding: Float

    /// 从已渲染配置构建草稿：可选字段取实际生效值（缺省回落主题扩展的默认）
    init(_ c: ApperanceThemeConfig) {
        windowBackgroundColor = c.windowBackgroundColor
        windowPaddingTop = c.windowPaddingTop
        windowPaddingLeft = c.windowPaddingLeft
        windowPaddingRight = c.windowPaddingRight
        windowPaddingBottom = c.windowPaddingBottom
        windowBorderRadius = c.windowBorderRadius
        windowBorderWidth = c.borderLineWidth
        windowBorderColor = c.windowBorderColorValue
        originCodeColor = c.originCodeColor
        originCandidatesSpace = c.originCandidatesSpace
        candidateSpace = c.candidateSpace
        candidateIndexColor = c.candidateIndexColor
        candidateTextColor = c.candidateTextColor
        candidateCodeColor = c.candidateCodeColor
        selectedIndexColor = c.selectedIndexColor
        selectedTextColor = c.selectedTextColor
        selectedCodeColor = c.selectedCodeColor
        selectedBackgroundColor = c.selectedBackground
        pageIndicatorColor = c.pageIndicatorColor
        pageIndicatorDisabledColor = c.pageIndicatorDisabledColor
        candidateScoreColor = c.scoreColor
        candidateScoreFontSize = c.scoreFontSize
        candidateScoreBold = c.scoreBold
        fontName = c.fontName
        fontSize = c.fontSize
        candidateIndexFontSize = c.indexFontSize
        candidateCodeFontSize = c.codeFontSize
        candidateRowPadding = c.rowPadding
    }

    func toConfig() -> ApperanceThemeConfig {
        ApperanceThemeConfig(
            windowBackgroundColor: windowBackgroundColor,
            windowPaddingTop: windowPaddingTop, windowPaddingLeft: windowPaddingLeft,
            windowPaddingRight: windowPaddingRight, windowPaddingBottom: windowPaddingBottom,
            windowBorderRadius: windowBorderRadius,
            windowBorderWidth: windowBorderWidth,
            windowBorderColor: windowBorderColor,
            originCodeColor: originCodeColor,
            originCandidatesSpace: originCandidatesSpace, candidateSpace: candidateSpace,
            candidateIndexColor: candidateIndexColor, candidateTextColor: candidateTextColor,
            candidateCodeColor: candidateCodeColor,
            selectedIndexColor: selectedIndexColor, selectedTextColor: selectedTextColor,
            selectedCodeColor: selectedCodeColor,
            selectedBackgroundColor: selectedBackgroundColor,
            pageIndicatorColor: pageIndicatorColor,
            pageIndicatorDisabledColor: pageIndicatorDisabledColor,
            candidateScoreColor: candidateScoreColor,
            candidateScoreFontSize: candidateScoreFontSize,
            candidateScoreBold: candidateScoreBold,
            fontName: fontName, fontSize: fontSize,
            candidateIndexFontSize: candidateIndexFontSize,
            candidateCodeFontSize: candidateCodeFontSize,
            candidateRowPadding: candidateRowPadding
        )
    }
}

/// 主题 JSON 的 schema 版本（与 defaultThemeConfig 保持一致）
let themeSchemaVersion = 2

// MARK: - 主题编辑器

struct ThemeEditorView: View {
    /// 编辑既有主题时为 true（ID 保留）；创建新主题为 false（随机 ID）
    private let isEditingExisting: Bool

    @State private var editingDark = false
    @State private var showVerticalPreview = false
    @State private var showCodeInPreview = true
    @State private var showTipInPreview = true
    @State private var darkSameLight = true
    @State private var name = ""
    @State private var schemaVersionDisplay = String(themeSchemaVersion)
    @State private var id = ""
    @State private var author = NSFullUserName()
    @State private var light: ThemeAppearanceDraft
    @State private var dark: ThemeAppearanceDraft
    @State private var availableFontFamilies = NSFontManager.shared.availableFontFamilies

    private static var previewWindow: NSWindow?

    init(existing: ThemeConfig? = nil) {
        isEditingExisting = existing != nil
        if let e = existing {
            _name = State(initialValue: e.name)
            _id = State(initialValue: e.id)
            _author = State(initialValue: e.author)
            let lightDraft = ThemeAppearanceDraft(e.light)
            _light = State(initialValue: lightDraft)
            _dark = State(initialValue: ThemeAppearanceDraft(e.dark ?? e.light))
            _darkSameLight = State(initialValue: e.dark == nil || e.dark == e.light)
        } else {
            let base = ThemeAppearanceDraft(defaultThemeConfig.light)
            _light = State(initialValue: base)
            _dark = State(initialValue: ThemeAppearanceDraft(defaultThemeConfig.dark ?? defaultThemeConfig.light))
            _id = State(initialValue: String(UUID().uuidString.prefix(8).lowercased()))
        }
    }

    // MARK: - 预览浮窗

    /// 关闭旧预览窗后重建：CandidatesView 尺寸由内容决定（fixedSize），
    /// 每次改动按 fittingSize 重新开窗，避免替换 contentView 的 AppKit 状态问题。
    private func updatePreviewWindow() {
        Self.closePreview()
        let config = (darkSameLight || !editingDark) ? light.toConfig() : dark.toConfig()
        let demo: [Candidate] = [
            Candidate(code: "a", text: "工", type: .wb),
            Candidate(code: "a", text: "戈", type: .wb),
            Candidate(code: "aa", text: "啊", type: .wb),
            Candidate(code: "aa", text: "阿", type: .user),
            Candidate(code: "aaaa", text: "工工整整", type: .sentence, scoreText: "92.5"),
        ]
        let preview = CandidatesView(
            candidates: demo,
            origin: "aa",
            hasPrev: true,
            hasNext: true,
            page: 1,
            pageCount: 3,
            themeOverride: config,
            directionOverride: showVerticalPreview ? .vertical : .horizontal,
            showCodeInWindowOverride: showCodeInPreview,
            wubiCodeTipOverride: showTipInPreview
        )
        let host = NSHostingView(rootView: preview)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.contentView = host
        win.title = "候选栏预览"
        // 定位在编辑器窗口右侧；编辑器尚未可见时居中
        if let editorWin = ThemePane.editorWindow {
            let editorFrame = editorWin.frame
            win.setFrameTopLeftPoint(
                NSPoint(x: editorFrame.maxX + 20, y: editorFrame.maxY)
            )
        } else {
            win.center()
        }
        win.orderFront(nil)
        Self.previewWindow = win
    }

    /// 隐藏预览浮窗（不释放窗口对象，仅移出屏幕并释放内部视图）
    static func closePreview() {
        previewWindow?.orderOut(nil)
        previewWindow?.contentView = nil
    }

    // MARK: - 绑定

    private var activeTheme: Binding<ThemeAppearanceDraft> {
        if darkSameLight || !editingDark { $light } else { $dark }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    basicInfoSection
                    windowSection
                    originCodeSection
                    candidateSection
                    selectedCandidateSection
                    scoreSection
                    pageIndicatorSection
                    Spacer(minLength: 12)
                }
                .padding(20)
            }

            Divider()
            HStack {
                Text("预览为实时渲染的候选栏，拖动可移动")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消") {
                    ThemePane.closeEditor()
                }
                .controlSize(.large)
                Button("保存并应用") { saveTheme() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 640, minHeight: 620)
        .onAppear { updatePreviewWindow() }
        .onDisappear {
            Self.closePreview()
            ThemePane.editorWindow = nil
        }
        // 任一配色/布局改动都即时重建预览
        .onChange(of: light) { _ in updatePreviewWindow() }
        .onChange(of: dark) { _ in updatePreviewWindow() }
        .onChange(of: editingDark) { _ in updatePreviewWindow() }
        .onChange(of: darkSameLight) { same in
            if same {
                editingDark = false
            }
            updatePreviewWindow()
        }
        .onChange(of: showVerticalPreview) { _ in updatePreviewWindow() }
        .onChange(of: showCodeInPreview) { _ in updatePreviewWindow() }
        .onChange(of: showTipInPreview) { _ in updatePreviewWindow() }
    }

    // MARK: - 基础信息

    @ViewBuilder
    private var basicInfoSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    formRow(label: "ID") {
                        TextField("", text: $id)
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                    }
                    formRow(label: "主题版本") {
                        TextField("", text: $schemaVersionDisplay)
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                    }
                }
                HStack {
                    formRow(label: "名称") {
                        TextField("", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    formRow(label: "作者") {
                        TextField("", text: $author)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                formRow(label: "预览") {
                    HStack(spacing: 6) {
                        if !darkSameLight {
                            previewModeButton(icon: "sun.max.fill", label: "浅色",
                                             isActive: !editingDark) { editingDark = false }
                            previewModeButton(icon: "moon.fill", label: "深色",
                                             isActive: editingDark) { editingDark = true }
                            Divider().frame(height: 36)
                        }
                        previewModeButton(icon: "text.justify", label: "横向",
                                         isActive: !showVerticalPreview) { showVerticalPreview = false }
                        previewModeButton(icon: "text.justify", label: "竖向",
                                         isActive: showVerticalPreview, rotation: 90) { showVerticalPreview = true }
                        Divider().frame(height: 36)
                        previewModeButton(icon: "keyboard", label: "输入码",
                                         isActive: showCodeInPreview) { showCodeInPreview.toggle() }
                        previewModeButton(icon: "questionmark.bubble", label: "提示码",
                                         isActive: showTipInPreview) { showTipInPreview.toggle() }
                    }
                }
                formRow(label: "深色配色") {
                    Toggle("深色模式与浅色模式使用同一套配色", isOn: $darkSameLight)
                        .controlSize(.small)
                }
            }
            .padding(16)
        } label: {
            Label("基础信息", systemImage: "info.circle")
        }
    }

    // MARK: - 窗口

    @ViewBuilder
    private var windowSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ColorPickerRow(label: "背景", color: activeTheme.windowBackgroundColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    numberRow(label: "圆角", value: activeTheme.windowBorderRadius, range: 0...24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    ColorPickerRow(label: "描边", color: activeTheme.windowBorderColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    numberRow(label: "线宽", value: activeTheme.windowBorderWidth, range: 0...4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                }
                HStack(spacing: 10) {
                    numberRow(label: "上", value: activeTheme.windowPaddingTop, range: 0...20)
                    numberRow(label: "下", value: activeTheme.windowPaddingBottom, range: 0...20)
                    numberRow(label: "左", value: activeTheme.windowPaddingLeft, range: 0...30)
                    numberRow(label: "右", value: activeTheme.windowPaddingRight, range: 0...30)
                }
            }
            .padding(16)
        } label: {
            Label("窗口", systemImage: "macwindow")
        }
    }

    // MARK: - 原码（顶部编码行）

    @ViewBuilder
    private var originCodeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ColorPickerRow(label: "颜色", color: activeTheme.originCodeColor)
                    Spacer()
                    numberRow(label: "与候选间距", value: activeTheme.originCandidatesSpace, range: 0...20)
                }
                HStack(spacing: 10) {
                    numberRow(label: "字号", value: activeTheme.candidateCodeFontSize, range: 8...28)
                    Spacer()
                }
            }
            .padding(16)
        } label: {
            Label("编码行", systemImage: "character.cursor.ibeam")
        }
    }

    // MARK: - 候选项

    @ViewBuilder
    private var candidateSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ColorPickerRow(label: "序号", color: activeTheme.candidateIndexColor)
                    ColorPickerRow(label: "候选词", color: activeTheme.candidateTextColor)
                    ColorPickerRow(label: "提示码", color: activeTheme.candidateCodeColor)
                }
                HStack(spacing: 10) {
                    numberRow(label: "序号字号", value: activeTheme.candidateIndexFontSize, range: 8...28)
                    numberRow(label: "字号", value: activeTheme.fontSize, range: 10...28)
                    numberRow(label: "提示码字号", value: activeTheme.candidateCodeFontSize, range: 8...28)
                }
                HStack(spacing: 10) {
                    numberRow(label: "候选间距", value: activeTheme.candidateSpace, range: 0...20)
                    numberRow(label: "行留白", value: activeTheme.candidateRowPadding, range: 0...12)
                }
                HStack(spacing: 10) {
                    Text("字体")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Picker("", selection: activeTheme.fontName) {
                        Text("系统默认").tag("system")
                        ForEach(availableFontFamilies, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
            }
            .padding(16)
        } label: {
            Label("候选项", systemImage: "list.bullet")
        }
    }

    // MARK: - 候选项选中态

    @ViewBuilder
    private var selectedCandidateSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ColorPickerRow(label: "序号", color: activeTheme.selectedIndexColor)
                    ColorPickerRow(label: "候选词", color: activeTheme.selectedTextColor)
                    ColorPickerRow(label: "提示码", color: activeTheme.selectedCodeColor)
                }
                HStack(spacing: 10) {
                    ColorPickerRow(label: "高亮背景", color: activeTheme.selectedBackgroundColor)
                    Spacer()
                }
            }
            .padding(16)
        } label: {
            Label("选中态", systemImage: "checkmark.circle")
        }
    }

    // MARK: - 整句打分

    @ViewBuilder
    private var scoreSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ColorPickerRow(label: "颜色", color: activeTheme.candidateScoreColor)
                    numberRow(label: "字号", value: activeTheme.candidateScoreFontSize, range: 8...28)
                    Toggle("加粗", isOn: activeTheme.candidateScoreBold)
                        .controlSize(.small)
                        .toggleStyle(.switch)
                    Spacer()
                }
                Text("整句候选末尾的加权得分显示样式（需开启「基本→整句→显示打分」）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        } label: {
            Label("整句打分", systemImage: "number")
        }
    }

    // MARK: - 页面指示器

    @ViewBuilder
    private var pageIndicatorSection: some View {
        GroupBox {
            HStack(spacing: 10) {
                ColorPickerRow(label: "可用", color: activeTheme.pageIndicatorColor)
                ColorPickerRow(label: "禁用", color: activeTheme.pageIndicatorDisabledColor)
            }
            .padding(16)
        } label: {
            Label("翻页指示", systemImage: "arrow.up.arrow.down")
        }
    }

    // MARK: - 表单辅助

    private func formRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(alignment: .leading)
                .lineLimit(1)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func numberRow(label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        let intRange = Int(range.lowerBound)...Int(range.upperBound)
        formRow(label: label) {
            TextField("", value: Binding(
                get: { Int(value.wrappedValue.rounded()) },
                set: { newValue in
                    let clamped = min(max(newValue, intRange.lowerBound), intRange.upperBound)
                    value.wrappedValue = Float(clamped)
                }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.body)
            .frame(width: 52)
        }
    }

    private func previewModeButton(
        icon: String,
        label: String,
        isActive: Bool,
        rotation: Double = 0,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .rotationEffect(.degrees(rotation))
            Text(label).font(.caption2)
        }
        .foregroundStyle(isActive ? Color.accentColor : Color.gray.opacity(0.35))
        .frame(width: 56, height: 52)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
    }

    // MARK: - 保存

    private func saveTheme() {
        // 深浅同套配色时 dark 置 nil，JSON 更精简、行为不变
        let finalDark = darkSameLight ? nil : dark.toConfig()
        let theme = ThemeConfig(
            schemaVersion: themeSchemaVersion,
            id: id,
            name: name.isEmpty ? "未命名" : name,
            author: author.isEmpty ? "匿名" : author,
            light: light.toConfig(),
            dark: finalDark
        )
        applyImportedTheme(theme)
        Self.closePreview()
        ThemePane.closeEditor()
    }
}

// MARK: - 颜色选择器

struct ColorPickerRow: View {
    let label: String
    @Binding var color: ColorData

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(alignment: .trailing)
                .lineLimit(1)

            HStack(spacing: 4) {
                ColorPicker("", selection: Binding(
                    get: { Color(color) },
                    set: {
                        if let c = $0.cgColor?.components, c.count >= 3 {
                            color = ColorData(red: c[0], green: c[1], blue: c[2],
                                             opacity: c.count > 3 ? c[3] : 1)
                        }
                    }
                ))
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 24)

                TextField("Hex", text: Binding(
                    get: { color.hexString },
                    set: { if let d = ColorData(hex: $0) { color = d } }
                ))
                .frame(width: 90)
                .font(.system(size: 10, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
    }
}

#Preview {
    ThemeEditorView()
        .frame(width: 640, height: 620)
}
