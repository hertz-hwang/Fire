//
//  PreferencesView.swift
//  Fire
//
//  Created by 虚幻 on 2020/10/18.
//  Copyright © 2020 qwertyyb. All rights reserved.
//

import SwiftUI
import Settings
import Defaults

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
    @Default(.toggleInputModeKey) private var toggleInputModeKey
    @Default(.disableEnMode) private var disableEnMode
    @Default(.disableTempEnMode) private var disableTempEnMode
    @Default(.showInputModeStatus) private var showInputModeStatus
    @Default(.enableWhitespaceBetweenZhEn) private var enableWhitespaceBetweenZhEn

    private func chineseNumber(_ n: Int) -> String {
        let map: [Int: String] = [3: "三", 4: "四", 5: "五", 6: "六", 7: "七", 8: "八", 9: "九", 10: "十"]
        return map[n] ?? "\(n)"
    }

    var body: some View {
        Settings.Container(contentWidth: 450.0) {
            Settings.Section(title: "") {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox(label: Text("编码")) {
                        VStack(spacing: 12) {
                            HStack {
                                Picker("编码方案", selection: $code) {
                                    Text("码表").tag(CodeMode.wubi)
                                    Text("拼音").tag(CodeMode.pinyin)
                                    Text("码表拼音混合").tag(CodeMode.wubiPinyin)
                                }
                                .frame(width: 180)
                                Spacer(minLength: 50)
                            }
                            HStack {
                                Picker("最大码长", selection: $maxCodeLength) {
                                    ForEach(3...9, id: \.self) { n in
                                        Text("\(n)").tag(n)
                                    }
                                }
                                Spacer(minLength: 20)
                                Picker("上屏模式", selection: $commitMode) {
                                    Text("空格上屏").tag(CommitMode.spaceCommit)
                                    Text("\(chineseNumber(maxCodeLength))码唯一上屏").tag(CommitMode.uniqueAtN)
                                    Text("统一第\(chineseNumber(maxCodeLength + 1))码顶").tag(CommitMode.commitAtM)
                                    Text("空码顶字上屏").tag(CommitMode.emptyCodePush)
                                    Text("空码直接上屏").tag(CommitMode.emptyCodeDirect)
                                    Text("\(chineseNumber(maxCodeLength + 1))二顶").tag(CommitMode.commitAtM2)
                                    Text("\(chineseNumber(maxCodeLength + 1))三顶").tag(CommitMode.commitAtM3)
                                }
                                Spacer(minLength: 50)
                            }
                            if commitMode == .emptyCodeDirect {
                                HStack {
                                    Text("上屏延迟")
                                    Slider(value: $emptyCodeDirectDelay, in: 0.1...1.0, step: 0.1) {
                                        EmptyView()
                                    }
                                    Text(String(format: "%.1f 秒", emptyCodeDirectDelay))
                                        .frame(width: 45, alignment: .trailing)
                                    Spacer(minLength: 50)
                                }
                            }
                            HStack {
                                Toggle("提示编码", isOn: $wubiCodeTip)
                                Spacer(minLength: 50)
                            }
                            HStack {
                                Toggle("z键查询", isOn: $zKeyQuery)
                                Spacer(minLength: 50)
                            }
                        }
                    }
                    GroupBox(label: Text("候选词")) {
                        VStack(spacing: 12) {
                            HStack {
                                Picker("候选词排列", selection: $candidatesDirection) {
                                    Text("横向").tag(CandidatesDirection.horizontal)
                                    Text("竖向").tag(CandidatesDirection.vertical)
                                }
                                Spacer(minLength: 50)
                                Picker("候选词数量", selection: $candidateCount) {
                                    Text("3").tag(3)
                                    Text("4").tag(4)
                                    Text("5").tag(5)
                                    Text("6").tag(6)
                                    Text("7").tag(7)
                                    Text("8").tag(8)
                                    Text("9").tag(9)
                                }
                            }
                            HStack {
                                Toggle("候选框显示输入码", isOn: $showCodeInWindow)
                                Spacer(minLength: 20)
                            }
                            if !showCodeInWindow {
                                HStack {
                                    Picker("", selection: $codeInWindowMode) {
                                        Text("显示输入码（默认）").tag(CodeInWindowMode.inputCode)
                                        Text("显示首选项").tag(CodeInWindowMode.firstCandidate)
                                    }
                                    .frame(width: 200, alignment: .leading)
                                    Spacer()
                                }
                            }
                            HStack {
                                Toggle("启用;键次选/引号三选", isOn: $enablePunctuationCandidateSelect)
                                Spacer(minLength: 20)
                            }
                            HStack {
                                Picker("二三候选词额外选择键", selection: $extraCandidateSelectKeys) {
                                    Text("禁用").tag(ExtraCandidateSelectKeys.disabled)
                                    Text(";'").tag(ExtraCandidateSelectKeys.semicolonQuote)
                                    Text(",.").tag(ExtraCandidateSelectKeys.commaPeriod)
                                }
                                Spacer(minLength: 20)
                            }
                            HStack {
                                Picker("简全模式", selection: $jianQuanMode) {
                                    Text("默认").tag(JianQuanMode.normal)
                                    Text("出简让全").tag(JianQuanMode.quanAfterJian)
                                    Text("出简无全").tag(JianQuanMode.noQuanIfJian)
                                }
                                .frame(width: 200, alignment: .leading)
                                Spacer()
                            }
                        }
                    }
                    GroupBox(label: Text("中英文切换")) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Toggle("禁止切换英文", isOn: $disableEnMode)
                                Spacer()
                                Toggle("状态栏显示", isOn: $showInputModeStatus)
                            }
                            HStack {
                                Toggle("中文与英文/数字之间插入空格", isOn: $enableWhitespaceBetweenZhEn)
                                Spacer()
                                Toggle("禁用;键临时英文模式", isOn: $disableTempEnMode)
                            }
                            HStack {
                                Picker("快捷键", selection: $toggleInputModeKey) {
                                    Text("control").tag(ModifierKey.control)
                                    Text("shift").tag(ModifierKey.shift)
                                    Text("左shift").tag(ModifierKey.leftShift)
                                    Text("右shift").tag(ModifierKey.rightShift)
                                    Text("option").tag(ModifierKey.option)
                                    Text("command").tag(ModifierKey.command)
                                    Text("fn").tag(ModifierKey.function)
                                }
                                .disabled(disableEnMode)
                                Spacer(minLength: 50)
                                Picker(
                                    "提示框位置",
                                    selection: $inputModeTipWindowType
                                ) {
                                    Text("屏幕中间")
                                    .tag(InputModeTipWindowType.centerScreen)
                                    Text("跟随输入框")
                                    .tag(InputModeTipWindowType.followInput)
                                    Text("不显示")
                                    .tag(InputModeTipWindowType.none)
                                }
                                .disabled(disableEnMode)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct GeneralPane_Previews: PreviewProvider {
    static var previews: some View {
        GeneralPane()
    }
}
