//
//  FireCandidatesView.swift
//  Fire
//
//  Created by 虚幻 on 2019/9/16.
//  Copyright © 2019 qwertyyb. All rights reserved.
// 

import SwiftUI
import Defaults

func getShownCode(candidate: Candidate, origin: String) -> String {
    if candidate.type == CandidateType.py || !candidate.code.hasPrefix(origin) {
        return "(\(candidate.code))"
    }
    if candidate.code.hasPrefix(origin) {
        return candidate.code.count > origin.count
            ? "~\(String(candidate.code.suffix(candidate.code.count - origin.count)))"
            : ""
    }
    return ""
}

func getCharDivInfos(text: String) -> [CharDivInfo] {
    text.map { String($0) }.compactMap { CharDivTable.shared.lookup($0) }
}

struct CandidateView: View {
    var candidate: Candidate
    var index: Int
    var origin: String
    var selected: Bool = false
    var indexVisible = true
    /// 整句模式：与首选文字的差异着色基准（首选自身与常规候选为 nil）
    var diffBase: String? = nil

    @Default(.themeConfig) private var themeConfig
    @Default(.wubiCodeTip) private var wubiCodeTip
    @Default(.enableCharDivTip) private var enableCharDivTip
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        // @Default(.themeConfig) 每次读取都会走 UserDefaults + JSON 解码；
        // 候选栏每键刷新会访问几十次，这里按键求值只解码一次。
        let theme = themeConfig[colorScheme]
        let indexColor = selected
            ? theme.selectedIndexColor
            : theme.candidateIndexColor
        let textColor = selected
            ? theme.selectedTextColor
            : theme.candidateTextColor
        let codeColor = selected
            ? theme.selectedCodeColor
            : theme.candidateCodeColor

        return HStack(alignment: .center, spacing: 2) {
            if indexVisible {
                Text("\(index + 1).")
                    .foregroundColor(Color(indexColor))
            }
            candidateText(baseColor: Color(textColor))
            if wubiCodeTip || origin.first == "`" {
                Text(getShownCode(candidate: candidate, origin: origin))
                    .foregroundColor(Color(codeColor))
            }
        }
        .onTapGesture {
            NotificationCenter.default.post(
                name: CandidatesView.candidateSelected,
                object: nil,
                userInfo: [
                    "candidate": candidate,
                    "index": index
                ]
            )
        }
        .background(
            Group {
                if enableCharDivTip {
                    HoverTracking { hovering, screenPoint in
                        if hovering {
                            let infos = getCharDivInfos(text: candidate.text)
                            CharDivTipWindow.shared.show(infos, at: screenPoint)
                        } else {
                            CharDivTipWindow.shared.hide()
                        }
                    }
                } else {
                    // 关闭开关时主动收掉可能还开着的提示窗
                    Color.clear.onAppear {
                        CharDivTipWindow.shared.hide()
                    }
                }
            }
        )
    }

    /// 整句候选与首选的差异着色（git diff 风格：等长替换橙、净删除红、净增绿），
    /// 无基准或全同时退化为单色 Text。Text 拼接保持整词为一个排版单元
    private func candidateText(baseColor: Color) -> Text {
        guard let base = diffBase, !base.isEmpty, base != candidate.label else {
            return Text(candidate.label).foregroundColor(baseColor)
        }
        let segments = sentenceDiff(base: base, candidate: candidate.label)
        let runs = segments.map { segment -> Text in
            Text(segment.text).foregroundColor(
                segment.kind == .equal
                    ? baseColor
                    : segment.kind.color(colorScheme: colorScheme)
            )
        }
        guard runs.count > 1, let first = runs.first else {
            return Text(candidate.label).foregroundColor(baseColor)
        }
        return runs.dropFirst().reduce(first) { $0 + $1 }
    }
}

struct CandidatesView: View {
    static let candidateSelected = Notification.Name("CandidatesView.candidateSelected")
    static let nextPageBtnTapped = Notification.Name("CandidatesView.nextPageBtnTapped")
    static let prevPageBtnTapped = Notification.Name("CandidatesView.prevPageBtnTapped")

    var candidates: [Candidate]
    var origin: String
    var hasPrev: Bool = false
    var hasNext: Bool = false
    /// 高亮候选下标（整句模式 Tab/方向键循环选词），默认 0
    var highlightIndex: Int = 0

    @Default(.candidatesDirection) private var direction
    @Default(.themeConfig) private var themeConfig
    @Default(.showCodeInWindow) private var showCodeInWindow
    @Environment(\.colorScheme) var colorScheme

    var _candidatesView: some View {
        // 整句模式（列表中出现整句候选即视为）非首选候选以首位文字为差异基准
        let diffBase = candidates.contains { $0.type == .sentence }
            ? candidates.first?.label
            : nil
        return ForEach(Array(candidates.enumerated()), id: \.offset) { (index, candidate) -> CandidateView in
            CandidateView(
                candidate: candidate,
                index: index,
                origin: origin,
                selected: index == highlightIndex,
                indexVisible: candidates.count > 1,
                diffBase: index > 0 ? diffBase : nil
            )
        }
    }

    func getIndicatorIcon(
        imageName: String,
        direction: CandidatesDirection,
        disabled: Bool,
        eventName: Notification.Name
    ) -> some View {
        let theme = themeConfig[colorScheme]
        let size = CGFloat(theme.fontSize) * 0.5
        return Image(imageName)
            .renderingMode(.template)
            .resizable()
            .frame(width: size, height: size, alignment: .center)
            .rotationEffect(Angle(degrees: direction == CandidatesDirection.horizontal ? 0 : -90), anchor: .center)
            .onTapGesture {
                if disabled { return }
                NotificationCenter.default.post(
                    name: eventName,
                    object: nil
                )
            }
            .foregroundColor(Color(disabled
                                   ? theme.pageIndicatorDisabledColor
                                   : theme.pageIndicatorColor
                                  ))
    }

    var _indicator: some View {
        if candidates.count <= 1 {
            return AnyView(EmptyView())
        }
        let arrowUp = getIndicatorIcon(
            imageName: "arrowUp",
            direction: direction,
            disabled: !hasPrev,
            eventName: CandidatesView.prevPageBtnTapped
        )
        let arrowDown = getIndicatorIcon(
            imageName: "arrowDown",
            direction: direction,
            disabled: !hasNext,
            eventName: CandidatesView.nextPageBtnTapped
        )
        if direction == CandidatesDirection.horizontal {
            return AnyView(VStack(spacing: 0) { arrowUp; arrowDown })
        } else {
            return AnyView(HStack(spacing: 4) { arrowUp; arrowDown })
        }
    }

    var body: some View {
        // 同 CandidateView：body 求值一次解码，后续全部复用
        let theme = themeConfig[colorScheme]
        return VStack(alignment: .leading, spacing: CGFloat(theme.originCandidatesSpace), content: {
            if showCodeInWindow {
                Text(origin)
                    .foregroundColor(Color(theme.originCodeColor))
                    .fixedSize()
            }
            if direction == CandidatesDirection.horizontal {
                HStack(alignment: .center, spacing: CGFloat(theme.candidateSpace)) {
                    _candidatesView
                    _indicator
                }
                .fixedSize()
            } else {
                VStack(alignment: .leading, spacing: CGFloat(theme.candidateSpace)) {
                    _candidatesView
                    _indicator
                }
                .fixedSize()
            }
        })
            .padding(.top, CGFloat(theme.windowPaddingTop))
            .padding(.bottom, CGFloat(theme.windowPaddingBottom))
            .padding(.leading, CGFloat(theme.windowPaddingLeft))
            .padding(.trailing, CGFloat(theme.windowPaddingRight))
            .fixedSize()
            .font(.system(size: CGFloat(theme.fontSize)))
            .background(Color(theme.windowBackgroundColor))
            .cornerRadius(CGFloat(theme.windowBorderRadius), antialiased: true)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        CandidatesView(candidates: [
            Candidate(code: "a", text: "工", type: CandidateType.wb),
            Candidate(code: "ab", text: "戈", type: CandidateType.wb),
            Candidate(code: "abc", text: "啊", type: CandidateType.wb),
            Candidate(code: "abcg", text: "阿", type: CandidateType.wb),
            Candidate(code: "addd", text: "吖", type: CandidateType.wb)
        ], origin: "a")
    }
}
