//
//  FireCandidatesView.swift
//  Fire
//
//  Created by 虚幻 on 2019/9/16.
//  Copyright © 2019 qwertyyb. All rights reserved.
//

import SwiftUI
import Defaults
import AppKit

// MARK: - 自定义毛玻璃背景（替代内置 .glassEffect()，实现圆角完全可控）

struct GlassEffectView: NSViewRepresentable {
    let cornerRadius: CGFloat
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = blendingMode
        view.material = .popover
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
    }
}

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

private enum CandidateRenderConst {
    /// preedit 光标宽度 CARET_WIDTH
    static let caretWidth: CGFloat = 1.5
    /// 横排时序号与候选词之间的间距 INDEX_GAP
    static let indexGap: CGFloat = 3.0
    /// 横排时高亮底色在候选两侧多出的宽度 HIGHLIGHT_INSET
    static let highlightInset: CGFloat = 5.0
}

private func measure(_ text: String, _ font: NSFont) -> NSSize {
    NSAttributedString(string: text, attributes: [.font: font]).size()
}

private func themeFont(_ theme: ApperanceThemeConfig, size: CGFloat) -> NSFont {
    if theme.fontName != "system", let font = NSFont(name: theme.fontName, size: size) {
        return font
    }
    return NSFont.systemFont(ofSize: size)
}

/// SwiftUI Text 用的 Font（与 themeFont 同一字体族/字号）
private func swiftFont(_ theme: ApperanceThemeConfig, size: CGFloat) -> Font {
    if theme.fontName != "system" {
        return Font.custom(theme.fontName, size: size)
    }
    return Font.system(size: size)
}

/// 打分显示的 NSFont（默认加粗，测量列宽用；自定义字体取同族 Bold 变体）
private func themeScoreFont(_ theme: ApperanceThemeConfig, size: CGFloat) -> NSFont {
    let base = themeFont(theme, size: size)
    guard theme.scoreBold else { return base }
    return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
}

/// 打分显示的 SwiftUI Font
private func swiftScoreFont(_ theme: ApperanceThemeConfig, size: CGFloat) -> Font {
    let base = swiftFont(theme, size: size)
    return theme.scoreBold ? base.weight(.bold) : base
}

/// 竖排的列宽与行高
private struct CandidateColumns {
    var indexWidth: CGFloat = 0
    var textWidth: CGFloat = 0
    var codeWidth: CGFloat = 0
    var scoreWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
}

struct CandidateView: View {
    var candidate: Candidate
    var index: Int
    var origin: String
    var selected: Bool = false
    /// 占位提示（删除确认/组词预览）不显示序号；
    var indexVisible = true
    /// 整句模式：与首选文字的差异着色基准（首选自身与常规候选为 nil）
    var diffBase: String? = nil
    // 列布局参数：竖排固定列宽（横排为 nil 取自然宽），列间距由排布方向决定
    var indexWidth: CGFloat? = nil
    var textWidth: CGFloat? = nil
    var codeText: String = ""
    var codeWidth: CGFloat? = nil
    /// 整句打分显示串（「显示打分」开启时整句候选才有）
    var scoreText: String = ""
    var scoreWidth: CGFloat? = nil
    /// 序号与候选词间距：竖排 = column_gap，横排 = INDEX_GAP
    var indexGap: CGFloat = 8
    /// 候选词与编码提示间距：竖排 = column_gap
    var columnGap: CGFloat = 8
    /// 预览注入（离屏渲染用）：非 nil 时优先于用户配置，避免为渲染改写真实配置
    var themeOverride: ApperanceThemeConfig? = nil

    @Default(.themeConfig) private var themeConfig
    @Default(.enableCharDivTip) private var enableCharDivTip
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        // @Default(.themeConfig) 每次读取都会走 UserDefaults + JSON 解码；
        // 候选栏每键刷新会访问几十次，这里按键求值只解码一次。
        let theme = themeOverride ?? themeConfig[colorScheme]
        let indexColor = Color(selected
            ? theme.selectedIndexColor
            : theme.candidateIndexColor)
        let textColor = Color(selected
            ? theme.selectedTextColor
            : theme.candidateTextColor)
        let codeColor = Color(selected
            ? theme.selectedCodeColor
            : theme.candidateCodeColor)
        let textFont = swiftFont(theme, size: CGFloat(theme.fontSize))
        let indexFont = swiftFont(theme, size: CGFloat(theme.indexFontSize))
        let codeFont = swiftFont(theme, size: CGFloat(theme.codeFontSize))

        // 行内各元素底对齐（小字下挪 small_offset 贴候选词底边）
        return HStack(alignment: .bottom, spacing: 0) {
            if indexVisible {
                Text("\(index + 1)")
                    .font(indexFont)
                    .foregroundColor(indexColor)
                    .fixedSize()
                    .frame(width: indexWidth, alignment: .leading)
            }
            candidateText(baseColor: textColor)
                .font(textFont)
                .fixedSize()
                .padding(.leading, indexVisible ? indexGap : 0)
                .frame(width: textWidth.map { $0 + (indexVisible ? indexGap : 0) },
                       alignment: .leading)
            if !codeText.isEmpty {
                Text(codeText)
                    .font(codeFont)
                    .foregroundColor(codeColor)
                    .fixedSize()
                    .padding(.leading, columnGap)
                    .frame(width: codeWidth.map { $0 + columnGap }, alignment: .leading)
            }
            if !scoreText.isEmpty {
                Text(scoreText)
                    .font(swiftScoreFont(theme, size: CGFloat(theme.scoreFontSize)))
                    .foregroundColor(Color(theme.scoreColor))
                    .fixedSize()
                    .padding(.leading, columnGap)
                    .frame(width: scoreWidth.map { $0 + columnGap }, alignment: .leading)
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
        // 与首选无任何公共字符时 diff 只剩单个变更块，也要按 diff 色整体着色；
        // 仅当没有非 equal 片段（候选文字全部命中首选）时才退化为单色
        guard segments.contains(where: { $0.kind != .equal }) else {
            return Text(candidate.label).foregroundColor(baseColor)
        }
        let runs = segments.map { segment -> Text in
            Text(segment.text).foregroundColor(
                segment.kind == .equal
                    ? baseColor
                    : segment.kind.color(colorScheme: colorScheme)
            )
        }
        guard let first = runs.first else {
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
    /// 当前页码（页码指示 "n/m" 用）
    var page: Int = 1
    /// 总页数；<= 1 时不显示页码指示
    var pageCount: Int = 0
    /// 高亮候选下标（整句模式 Tab/方向键循环选词），默认 0
    var highlightIndex: Int = 0
    // 预览注入（离屏渲染用）：非 nil 时优先于用户配置，避免为渲染改写真实配置
    var themeOverride: ApperanceThemeConfig? = nil
    var directionOverride: CandidatesDirection? = nil
    var showCodeInWindowOverride: Bool? = nil
    var wubiCodeTipOverride: Bool? = nil
    /// 尺寸动画中间帧的对齐角：窗框从旧尺寸滑向新尺寸时内容钉在不动的那一角，
    /// 文字不随中间帧滑动/折行；常态下窗口与内容同尺寸，该参数无效果
    var contentAlignment: Alignment = .topLeading

    @Default(.candidatesDirection) private var directionDefault
    @Default(.themeConfig) private var themeConfig
    @Default(.showCodeInWindow) private var showCodeInWindowDefault
    @Default(.wubiCodeTip) private var wubiCodeTipDefault
    @Environment(\.colorScheme) var colorScheme

    private var direction: CandidatesDirection { directionOverride ?? directionDefault }
    private var resolvedTheme: ApperanceThemeConfig { themeOverride ?? themeConfig[colorScheme] }
    private var showCodeInWindow: Bool { showCodeInWindowOverride ?? showCodeInWindowDefault }
    private var showWubiCodeTip: Bool { wubiCodeTipOverride ?? wubiCodeTipDefault }

    /// 整句模式（列表中出现整句候选即视为）非首选候选以首位文字为差异基准
    private var diffBase: String? {
        candidates.contains { $0.type == .sentence }
            ? candidates.first?.label
            : nil
    }

    private func measureColumns(
        textFont: NSFont, indexFont: NSFont, codeFont: NSFont, scoreFont: NSFont,
        rowPad: CGFloat, showHints: Bool
    ) -> CandidateColumns {
        var columns = CandidateColumns()
        for (index, candidate) in candidates.enumerated() {
            if candidate.type != .placeholder {
                let indexSize = measure("\((index + 1))", indexFont)
                columns.indexWidth = max(columns.indexWidth, indexSize.width)
            }
            let textSize = measure(candidate.label, textFont)
            columns.textWidth = max(columns.textWidth, textSize.width)
            columns.rowHeight = max(columns.rowHeight, textSize.height + rowPad * 2)
            if showHints {
                let codeSize = measure(getShownCode(candidate: candidate, origin: origin), codeFont)
                columns.codeWidth = max(columns.codeWidth, codeSize.width)
            }
            if let scoreText = candidate.scoreText {
                let scoreSize = measure(scoreText, scoreFont)
                columns.scoreWidth = max(columns.scoreWidth, scoreSize.width)
                let scoreRowHeight = measure(scoreText, scoreFont).height + rowPad * 2
                columns.rowHeight = max(columns.rowHeight, scoreRowHeight)
            }
        }
        return columns
    }

    /// 顶部编码行：提示字号文字 + 1.5pt 光标（手动绘制，不依赖应用画插入点），
    /// 行高 = 提示字号行高 + 2 * row_padding
    private func preeditLine(
        theme: ApperanceThemeConfig, codeFont: NSFont, rowPad: CGFloat
    ) -> some View {
        let lineHeight = measure("x", codeFont).height
        return HStack(spacing: 0) {
            Text(origin)
                .font(swiftFont(theme, size: CGFloat(theme.codeFontSize)))
                .foregroundColor(Color(theme.originCodeColor))
                .fixedSize()
            Rectangle()
                .fill(Color(theme.candidateTextColor))
                .frame(width: CandidateRenderConst.caretWidth, height: lineHeight)
        }
        .padding(.top, rowPad)
        .frame(height: lineHeight + rowPad * 2, alignment: .top)
    }

    /// 高亮底色条：圆角 = 窗口圆角一半
    private func highlightPill(theme: ApperanceThemeConfig, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius / 2, style: .continuous)
            .fill(Color(theme.selectedBackground))
    }

    /// 页码指示（"n/m"，仅多页时显示）。
    /// 左右半区可点分别翻上一页/下一页，保留原候选框的鼠标翻页能力
    private func pageFooter(theme: ApperanceThemeConfig) -> some View {
        Text("\(page)/\(pageCount)")
            .font(swiftFont(theme, size: CGFloat(theme.indexFontSize)))
            .foregroundColor(Color(theme.pageIndicatorColor))
            .fixedSize()
            .overlay(
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            NotificationCenter.default.post(
                                name: CandidatesView.prevPageBtnTapped, object: nil)
                        }
                        .help("上一页")
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            NotificationCenter.default.post(
                                name: CandidatesView.nextPageBtnTapped, object: nil)
                        }
                        .help("下一页")
                }
            )
    }

    /// 竖排（draw_vertical）：一行一个候选，序号/候选词/编码提示三列
    private func verticalBody(
        theme: ApperanceThemeConfig,
        textFont: NSFont, indexFont: NSFont, codeFont: NSFont, scoreFont: NSFont,
        rowPad: CGFloat, gap: CGFloat, radius: CGFloat,
        padLeft: CGFloat, padRight: CGFloat, showHints: Bool
    ) -> some View {
        let columns = measureColumns(
            textFont: textFont, indexFont: indexFont, codeFont: codeFont, scoreFont: scoreFont,
            rowPad: rowPad, showHints: showHints)
        // 有序号列（indexWidth > 0）时内容宽含序号列与列间距；纯占位提示（如删除确认）只有文字列
        let contentWidth = (columns.indexWidth > 0
            ? columns.indexWidth + gap + columns.textWidth
            : columns.textWidth)
            + (columns.codeWidth > 0 ? gap + columns.codeWidth : 0)
            + (columns.scoreWidth > 0 ? gap + columns.scoreWidth : 0)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { (index, candidate) in
                let selected = index == highlightIndex
                CandidateView(
                    candidate: candidate,
                    index: index,
                    origin: origin,
                    selected: selected,
                    indexVisible: candidate.type != .placeholder,
                    diffBase: index > 0 ? diffBase : nil,
                    indexWidth: columns.indexWidth,
                    textWidth: columns.textWidth,
                    codeText: showHints
                        ? getShownCode(candidate: candidate, origin: origin) : "",
                    codeWidth: columns.codeWidth > 0 ? columns.codeWidth : nil,
                    scoreText: candidate.scoreText ?? "",
                    scoreWidth: columns.scoreWidth > 0 ? columns.scoreWidth : nil,
                    indexGap: gap,
                    columnGap: gap,
                    themeOverride: theme
                )
                .frame(height: columns.rowHeight)
                .background(
                    GeometryReader { geo in
                        if selected {
                            // 高亮条两端各越出内容半个窗口内边距（x = padding/2，宽 = 窗宽 - padding）
                            highlightPill(theme: theme, radius: radius)
                                .frame(width: geo.size.width + (padLeft + padRight) / 2,
                                       height: geo.size.height)
                                .offset(x: -padLeft / 2)
                        }
                    }
                )
            }
            if pageCount > 1 {
                pageFooter(theme: theme)
                    .frame(width: contentWidth, alignment: .trailing)
                    .padding(.top, rowPad)
            }
        }
    }

    /// 横排（draw_horizontal）：候选排成一行（序号+词），高亮底色向两侧各加宽
    /// HIGHLIGHT_INSET；页码在行尾；高亮项的编码提示独占下一行
    private func horizontalBody(
        theme: ApperanceThemeConfig,
        textFont: NSFont, indexFont: NSFont, codeFont: NSFont,
        rowPad: CGFloat, gap: CGFloat, radius: CGFloat, showHints: Bool
    ) -> some View {
        var rowHeight: CGFloat = 0
        for candidate in candidates {
            rowHeight = max(rowHeight, measure(candidate.label, textFont).height + rowPad * 2)
        }
        let highlighted = candidates.indices.contains(highlightIndex)
            ? candidates[highlightIndex] : nil
        let highlightedCode = (showHints && highlighted != nil)
            ? getShownCode(candidate: highlighted!, origin: origin) : ""
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(candidates.enumerated()), id: \.offset) { (index, candidate) in
                    CandidateView(
                        candidate: candidate,
                        index: index,
                        origin: origin,
                        selected: index == highlightIndex,
                        indexVisible: candidate.type != .placeholder,
                        diffBase: index > 0 ? diffBase : nil,
                        indexWidth: nil,
                        textWidth: nil,
                        codeText: "",
                        scoreText: candidate.scoreText ?? "",
                        indexGap: CandidateRenderConst.indexGap,
                        themeOverride: theme
                    )
                    .background(
                        Group {
                            if index == highlightIndex {
                                // 高亮底色以候选为中心，两侧各加宽 HIGHLIGHT_INSET、上下铺满行高
                                highlightPill(theme: theme, radius: radius)
                                    .frame(height: rowHeight)
                                    .padding(.horizontal, -CandidateRenderConst.highlightInset)
                            }
                        }
                    )
                }
                if pageCount > 1 {
                    pageFooter(theme: theme)
                }
            }
            .padding(.horizontal, CandidateRenderConst.highlightInset)
            .padding(.vertical, rowPad)
            if !highlightedCode.isEmpty {
                Text(highlightedCode)
                    .font(swiftFont(theme, size: CGFloat(theme.codeFontSize)))
                    .foregroundColor(Color(theme.candidateCodeColor))
                    .fixedSize()
                    .padding(.leading, CandidateRenderConst.highlightInset)
                    .padding(.top, rowPad / 2)
            }
        }
    }

    var body: some View {
        // 同 CandidateView：body 求值一次解码，后续全部复用
        let theme = resolvedTheme
        let textFont = themeFont(theme, size: CGFloat(theme.fontSize))
        let indexFont = themeFont(theme, size: CGFloat(theme.indexFontSize))
        let codeFont = themeFont(theme, size: CGFloat(theme.codeFontSize))
        let scoreFont = themeScoreFont(theme, size: CGFloat(theme.scoreFontSize))
        let rowPad = CGFloat(theme.rowPadding)
        let gap = CGFloat(theme.candidateSpace)
        let radius = CGFloat(theme.windowBorderRadius)
        let padLeft = CGFloat(theme.windowPaddingLeft)
        let padRight = CGFloat(theme.windowPaddingRight)
        let showHints = showWubiCodeTip || origin.first == "`"
        return VStack(alignment: .leading, spacing: 0, content: {
            if showCodeInWindow && !origin.isEmpty {
                preeditLine(theme: theme, codeFont: codeFont, rowPad: rowPad)
            }
            if !candidates.isEmpty {
                if direction == CandidatesDirection.vertical {
                    verticalBody(
                        theme: theme,
                        textFont: textFont, indexFont: indexFont, codeFont: codeFont,
                        scoreFont: scoreFont,
                        rowPad: rowPad, gap: gap, radius: radius,
                        padLeft: padLeft, padRight: padRight, showHints: showHints)
                } else {
                    horizontalBody(
                        theme: theme,
                        textFont: textFont, indexFont: indexFont, codeFont: codeFont,
                        rowPad: rowPad, gap: gap, radius: radius, showHints: showHints)
                }
            }
        })
            .padding(.top, CGFloat(theme.windowPaddingTop))
            .padding(.bottom, CGFloat(theme.windowPaddingBottom))
            .padding(.leading, padLeft)
            .padding(.trailing, padRight)
            .fixedSize()
            .background(Color(theme.windowBackgroundColor))
            .cornerRadius(radius, antialiased: true)
            // 主题描边：strokeBorder 画在内容边界内侧，不会被窗口裁掉
            .overlay(
                Group {
                    if theme.borderLineWidth > 0 {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color(theme.windowBorderColorValue),
                                          lineWidth: CGFloat(theme.borderLineWidth))
                    }
                }
            )
            // 窗口比内容大/小（尺寸动画中间帧）时把内容钉到固定角；无具体提案
            // （fittingSize 测量）时 infinity 不生效，尺寸仍是内容的理想尺寸
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
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
        ], origin: "a", page: 1, pageCount: 3)
    }
}
