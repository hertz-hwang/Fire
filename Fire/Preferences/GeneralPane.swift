//
//  PreferencesView.swift
//  Fire
//
//  Created by 虚幻 on 2020/10/18.
//  Copyright © 2020 qwertyyb. All rights reserved.
//

import SwiftUI
import Defaults
import AppKit
import UniformTypeIdentifiers

// MARK: - 偏好设置面板（迁移自 Settings 库）
//
// 原使用 Settings.Container/Section 包装，现改用原生 Form + .formStyle(.grouped)，
// 与侧边栏风格的首选项窗口（NativePreferencesView）配套。
// 布局选项与功能保持不变。

struct GeneralPane: View {

    @Default(.codeMode) private var code
    @Default(.candidateCount) private var candidateCount
    @Default(.wubiCodeTip) private var wubiCodeTip
    @Default(.showCodeInWindow) private var showCodeInWindow
    @Default(.codeInWindowMode) private var codeInWindowMode
    @Default(.candidatesDirection) private var candidatesDirection
    @Default(.maxCodeLength) private var maxCodeLength
    @Default(.commitMode) private var commitMode
    @Default(.emptyCodeDirectDelay) private var emptyCodeDirectDelay
    @Default(.enablePunctuationCandidateSelect) private var enablePunctuationCandidateSelect
    @Default(.jianQuanMode) private var jianQuanMode
    @Default(.extraCandidateSelectKeys) private var extraCandidateSelectKeys
    @Default(.inputModeTipWindowType) private var inputModeTipWindowType
    @Default(.zKeyQuery) private var zKeyQuery
    @Default(.zKeyRepeat) private var zKeyRepeat
    @Default(.enableSentenceMode) private var enableSentenceMode
    @Default(.enableSentenceScore) private var enableSentenceScore
    @Default(.enableSentenceAutoCommit) private var enableSentenceAutoCommit
    @Default(.enableSentenceAllowDuplicateSingle) private var enableSentenceAllowDuplicateSingle
    @Default(.sentenceContextDepth) private var sentenceContextDepth
    @Default(.enableCharDivTip) private var enableCharDivTip
    @Default(.toggleInputModeKey) private var toggleInputModeKey
    @Default(.leftShiftToEnRightShiftToZh) private var leftShiftToEnRightShiftToZh
    @Default(.disableEnMode) private var disableEnMode
    @Default(.disableTempEnMode) private var disableTempEnMode
    @Default(.showInputModeStatus) private var showInputModeStatus
    @Default(.enableWhitespaceBetweenZhEn) private var enableWhitespaceBetweenZhEn
    @Default(.wbTablePath) private var wbTablePath

    /// 「自定义码表」哨兵值：选中它即弹文件选择面板
    private let customTableTag = ""

    /// 当前选中值：#visible=1 的内置码表用其路径；
    /// #visible=0 的内置码表（全拼、整句方案码表，由编码方案/整句
    /// 开关自动支持）与本地自定义路径一律落到「自定义码表」
    private var currentTableSelection: String {
        SchemaCatalog.isSelectableBuiltin(path: wbTablePath) ? wbTablePath : customTableTag
    }

    private var builtinTables: [SchemaTableInfo] { SchemaCatalog.builtinTables() }

    private func selectFile() -> String? {
        let openPanel = NSOpenPanel()
        let schemasDir = SchemaCatalog.schemasDirectory
        openPanel.directoryURL = FileManager.default.fileExists(atPath: schemasDir)
            ? URL(fileURLWithPath: schemasDir)
            : Bundle.main.resourceURL
        openPanel.prompt = "选择码表文件"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        var types: [UTType] = []
        for ext in SchemaCatalog.supportedExtensions {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        openPanel.allowedContentTypes = types
        let result = openPanel.runModal()
        if result == NSApplication.ModalResponse.OK {
            return openPanel.url!.path
        }
        return nil
    }

    /// 码表下拉选中值：内置表用其路径，其余一律落到「自定义码表」
    private var tableSelectionBinding: Binding<String> {
        Binding(
            get: { currentTableSelection },
            set: { newValue in
                if newValue == customTableTag {
                    // 行为同旧版点击「形码词库」：弹面板选本地码表；取消则保持原选择
                    guard let path = selectFile() else { return }
                    applyTableSelection(path)
                } else {
                    applyTableSelection(newValue)
                }
            }
        )
    }

    /// 当前码表能否走整句（仅虎/琉璃/琉璃-友版有配套整句码表）。
    /// 仅码表方案参与判定：五笔86/98 等切过去后「整句」不可勾选。
    private var sentenceAvailableForTable: Bool {
        code != .wubi || SchemaCatalog.supportsSentence(selectedTablePath: wbTablePath)
    }

    /// 切换码表：持久化路径并后台重建索引（与高级面板「建立索引」同义）。
    /// wbTablePath 变化会由 SentenceEngine 监听自动打脏整句词图。
    private func applyTableSelection(_ path: String) {
        let changed = path != wbTablePath
        wbTablePath = path
        // 无配套整句码表的方案（五笔86/98 等）：整句强制关闭
        if code == .wubi, !SchemaCatalog.supportsSentence(selectedTablePath: path), enableSentenceMode {
            enableSentenceMode = false
        }
        guard changed else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            DictManager.shared.close()
            buildDict()
            DictManager.shared.reinit()
            // 整句词图跟随词库重建
            SentenceLexicon.shared.markDirty()
        }
    }

    private func chineseNumber(_ n: Int) -> String {
        let map: [Int: String] = [3: "三", 4: "四", 5: "五", 6: "六", 7: "七", 8: "八", 9: "九", 10: "十"]
        return map[n] ?? "\(n)"
    }

    /// 拼音方案锁定整套编码行为：整句+空格上屏，其余互斥项一律固定（置灰不可改）
    private var isPinyin: Bool { code == .pinyin }

    private func enforcePinyinDefaults() {
        guard isPinyin else { return }
        enableSentenceMode = true
        enableSentenceAutoCommit = false
        commitMode = .spaceCommit
        enableSentenceAllowDuplicateSingle = true
        wubiCodeTip = false
        zKeyQuery = false
        zKeyRepeat = false
    }

    var body: some View {
        Form {
            Section {
                PreferencePickerRow(title: "编码方案") {
                    Picker("", selection: $code) {
                        Text("码表").tag(CodeMode.wubi)
                        Text("拼音").tag(CodeMode.pinyin)
                        Text("码表拼音混合").tag(CodeMode.wubiPinyin)
                    }
                    .labelsHidden()
                    .onChange(of: code) { _ in
                        enforcePinyinDefaults()
                    }
                }
                // 仅码表方案提供内置码表选择（选项来自 Resources/schemas）
                if code == .wubi {
                    PreferencePickerRow(title: "码表") {
                        Picker("", selection: tableSelectionBinding) {
                            ForEach(builtinTables) { info in
                                Text(info.name)
                                    .help(info.tooltip)
                                    .tag(info.path)
                            }
                            Text("自定义码表").tag(customTableTag)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if !SchemaCatalog.isSelectableBuiltin(path: wbTablePath), !wbTablePath.isEmpty {
                        Text(wbTablePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                PreferenceToggleRow(title: "整句", isOn: $enableSentenceMode)
                    // 拼音方案强制整句：勾选锁定不可改；
                    // 所选码表无配套整句码表（五笔86/98 等）：不可勾选
                    .disabled(isPinyin || !sentenceAvailableForTable)
                if enableSentenceMode {
                    PreferenceToggleRow(title: "显示打分", caption: "整句候选末尾显示加权得分", isOn: $enableSentenceScore)
                        .help("在各整句候选末尾显示各维度加权得分（通用ngram、用户ngram等），颜色/字号/加粗可在主题 JSON 中配置")
                    PreferenceToggleRow(title: "自动上屏", isOn: $enableSentenceAutoCommit)
                        // 拼音方案统一空格上屏：不可启用自动上屏
                        .disabled(isPinyin)
                    PreferenceToggleRow(title: "单字重码组句", isOn: $enableSentenceAllowDuplicateSingle)
                        // 拼音方案固定启用（词表侧已按 rank 截断防爆）
                        .disabled(isPinyin)
                    HStack(spacing: 8) {
                        Text("N-gram留存信息数")
                        Slider(value: Binding(
                            get: { Double(sentenceContextDepth) },
                            set: { sentenceContextDepth = Int($0) }
                        ), in: 0...2, step: 1) {
                            EmptyView()
                        }
                        Text("\(sentenceContextDepth)")
                            .frame(width: 20, alignment: .trailing)
                    }
                    Text("0：不留存；1：保留前一次上屏文本的信息；2：保留前两次上屏文本的信息，用于后续组句的语境")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PreferencePickerRow(title: "最大码长") {
                    Picker("", selection: $maxCodeLength) {
                        ForEach(3...9, id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(isPinyin || enableSentenceMode)
                PreferencePickerRow(title: "上屏模式") {
                    Picker("", selection: $commitMode) {
                        Text("空格上屏").tag(CommitMode.spaceCommit)
                        Text("\(chineseNumber(maxCodeLength))码唯一上屏").tag(CommitMode.uniqueAtN)
                        Text("统一第\(chineseNumber(maxCodeLength + 1))码顶").tag(CommitMode.commitAtM)
                        Text("空码顶字上屏").tag(CommitMode.emptyCodePush)
                        Text("空码直接上屏").tag(CommitMode.emptyCodeDirect)
                        Text("\(chineseNumber(maxCodeLength + 1))二顶").tag(CommitMode.commitAtM2)
                        Text("\(chineseNumber(maxCodeLength + 1))三顶").tag(CommitMode.commitAtM3)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(isPinyin || enableSentenceMode)
                if commitMode == .emptyCodeDirect && !enableSentenceMode {
                    HStack(spacing: 8) {
                        Text("上屏延迟")
                        Slider(value: $emptyCodeDirectDelay, in: 0.1...1.0, step: 0.1) {
                            EmptyView()
                        }
                        Text(String(format: "%.1f 秒", emptyCodeDirectDelay))
                            .frame(width: 45, alignment: .trailing)
                    }
                }
                PreferenceToggleRow(title: "提示编码", isOn: $wubiCodeTip)
                    // 拼音方案整句走精确码边，固定关闭
                    .disabled(isPinyin)
                PreferenceToggleRow(title: "Z键查询", caption: "万能键", isOn: $zKeyQuery)
                    // 整句走精确码边，没有 xxx* 通配查询的余地
                    .disabled(isPinyin || enableSentenceMode)
                PreferenceToggleRow(title: "Z键重复上屏", isOn: $zKeyRepeat)
                    // 拼音方案固定关闭
                    .disabled(isPinyin)
            } header: {
                Text("编码")
            }
            Section {
                PreferencePickerRow(title: "排列方式") {
                    Picker("", selection: $candidatesDirection) {
                        Text("横向").tag(CandidatesDirection.horizontal)
                        Text("竖向").tag(CandidatesDirection.vertical)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                PreferencePickerRow(title: "候选词数量") {
                    Picker("", selection: $candidateCount) {
                        Text("3").tag(3)
                        Text("4").tag(4)
                        Text("5").tag(5)
                        Text("6").tag(6)
                        Text("7").tag(7)
                        Text("8").tag(8)
                        Text("9").tag(9)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                PreferenceToggleRow(title: "候选框显示输入码", caption: "不内嵌文本框", isOn: $showCodeInWindow)
                if !showCodeInWindow {
                    PreferencePickerRow(title: "输入码显示方式") {
                        Picker("", selection: $codeInWindowMode) {
                            Text("显示输入码（默认）").tag(CodeInWindowMode.inputCode)
                            Text("显示首选项").tag(CodeInWindowMode.firstCandidate)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                PreferenceToggleRow(title: "拆分信息悬浮提示", isOn: $enableCharDivTip)
                PreferenceToggleRow(title: "启用;键次选/引号三选", isOn: $enablePunctuationCandidateSelect)
                PreferencePickerRow(title: "二三候选额外选择键") {
                    Picker("", selection: $extraCandidateSelectKeys) {
                        Text("禁用").tag(ExtraCandidateSelectKeys.disabled)
                        Text(";'").tag(ExtraCandidateSelectKeys.semicolonQuote)
                        Text(",.").tag(ExtraCandidateSelectKeys.commaPeriod)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                PreferencePickerRow(title: "简全模式") {
                    Picker("", selection: $jianQuanMode) {
                        Text("默认").tag(JianQuanMode.normal)
                        Text("出简让全").tag(JianQuanMode.quanAfterJian)
                        Text("出简无全").tag(JianQuanMode.noQuanIfJian)
                    }
                    .labelsHidden()
                    .fixedSize()
                    // 整句用精确码边，简全让位在整句下没有作用对象
                    .disabled(enableSentenceMode)
                }
            } header: {
                Text("候选词")
            }
            Section {
                PreferenceToggleRow(title: "禁止切换英文", isOn: $disableEnMode)
                PreferenceToggleRow(title: "状态栏显示中英文状态", isOn: $showInputModeStatus)
                    .disabled(disableEnMode)
                PreferenceToggleRow(title: "中文与英文/数字之间插入空格", isOn: $enableWhitespaceBetweenZhEn)
                PreferenceToggleRow(title: "禁用;键临时英文模式", isOn: $disableTempEnMode)
                PreferenceToggleRow(
                    title: "左Shift切英文，右Shift切中文",
                    caption: "开启后左右Shift不再互相轮换",
                    isOn: $leftShiftToEnRightShiftToZh
                )
                .disabled(disableEnMode)
                PreferencePickerRow(title: "中英文切换快捷键") {
                    Picker("", selection: $toggleInputModeKey) {
                        Text("control").tag(ModifierKey.control)
                        Text("shift").tag(ModifierKey.shift)
                        Text("左shift").tag(ModifierKey.leftShift)
                        Text("右shift").tag(ModifierKey.rightShift)
                        Text("option").tag(ModifierKey.option)
                        Text("command").tag(ModifierKey.command)
                        Text("fn").tag(ModifierKey.function)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(disableEnMode)
                }
                PreferencePickerRow(title: "提示框位置") {
                    Picker("", selection: $inputModeTipWindowType) {
                        Text("屏幕中间").tag(InputModeTipWindowType.centerScreen)
                        Text("跟随输入框").tag(InputModeTipWindowType.followInput)
                        Text("不显示").tag(InputModeTipWindowType.none)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(disableEnMode)
                }
            } header: {
                Text("中英文切换")
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralPane_Previews: PreviewProvider {
    static var previews: some View {
        GeneralPane()
    }
}
