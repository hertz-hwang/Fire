//
//  CharDivTipWindow.swift
//  Fire
//
//  Created by Kiro on 2026/7/24.
//  Copyright © 2026 qwertyyb. All rights reserved.
//

import AppKit
import SwiftUI
import Defaults

// 候选词悬浮拆分提示的独立窗口
// 输入法窗口悬浮在其他 App 之上时，Fire 自身永远不是 active app，
// 依赖系统 tooltip(.help)/NSTrackingArea 默认的 .activeInActiveApp 均不会触发，
// 所以这里用独立窗口 + .activeAlways 的 tracking area 手动实现悬浮提示
class CharDivTipWindow {
    static let shared = CharDivTipWindow()

    private struct InfoBlock: View {
        var info: CharDivInfo
        @Default(.charDivRootFontName) private var charDivRootFontName

        private var rootFont: Font {
            guard !charDivRootFontName.isEmpty,
                  let nsFont = NSFont(name: charDivRootFontName, size: 12) else {
                return .system(size: 12)
            }
            return Font(nsFont)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text("汉字：\(info.char)")
                Text("拆分：\(info.roots),\(info.radicalCode)")
                    .font(rootFont)
                Text("拼音：\(info.pinyin.joined(separator: " "))")
                Text("Unicode: \(info.unicodeArea)")
                Text("全码：\(info.fullCode)")
            }
        }
    }

    private struct TipView: View {
        var infos: [CharDivInfo]
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(infos.enumerated()), id: \.offset) { _, info in
                    InfoBlock(info: info)
                }
            }
            .font(.system(size: 12))
            .foregroundColor(.white)
            .fixedSize()
            .padding(8)
            .background(Color.black.opacity(0.85))
            .cornerRadius(6)
        }
    }

    private lazy var window: NSWindow = {
        let win = NSWindow()
        win.styleMask = .init(arrayLiteral: .borderless, .fullSizeContentView)
        win.isReleasedWhenClosed = false
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.RawValue(CGShieldingWindowLevel() + 1))
        return win
    }()

    private var autoHideTimer: Timer?

    func show(_ infos: [CharDivInfo], at screenPoint: NSPoint) {
        guard !infos.isEmpty else {
            hide()
            return
        }
        let hostingView = NSHostingView(rootView: TipView(infos: infos))
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        window.setContentSize(hostingView.fittingSize)

        var origin = NSPoint(x: screenPoint.x + 12, y: screenPoint.y - window.frame.height - 12)
        if let screen = Utils.shared.getScreenFromPoint(screenPoint) {
            let screenFrame = screen.frame
            if origin.x + window.frame.width > screenFrame.maxX {
                origin.x = screenFrame.maxX - window.frame.width
            }
            if origin.y < screenFrame.minY {
                origin.y = screenPoint.y + 12
            }
        }
        window.setFrameOrigin(origin)
        window.orderFront(nil)

        autoHideTimer?.invalidate()
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        window.orderOut(nil)
    }
}
