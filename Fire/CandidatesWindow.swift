//
//  FireCandidatesWindow.swift
//  Fire
//
//  Created by 虚幻 on 2019/9/16.
//  Copyright © 2019 qwertyyb. All rights reserved.
//

import SwiftUI
import InputMethodKit
import Defaults

typealias CandidatesData = (list: [Candidate], hasPrev: Bool, hasNext: Bool, page: Int, pageCount: Int)

class CandidatesWindow: NSWindow, NSWindowDelegate {
    let hostingView = NSHostingView(rootView: CandidatesView(candidates: [], origin: ""))
    var inputController: FireInputController?

    /// 候选窗口与光标行之间的间隙
    private static let caretGap: CGFloat = 4
    /// 应用给不出光标矩形时，拿鼠标位置当光标，按这个高度算一行
    private static let fallbackLineHeight: CGFloat = 16

    func windowDidMove(_ notification: Notification) {
        /* windowDidMove会先于windowDidResize调用，所以需要
         * 在DispatchQueue.main.async中调用，以便能拿到最新的窗口大小
         **/
        DispatchQueue.main.async {
            guard !self.isAnimatingFrame else { return }
            self.limitFrameInScreen()
        }
    }

    func windowDidResize(_ notification: Notification) {
        /* 窗口大小变化时，确保不会超出当前屏幕范围，
         * 但是输入第一个字符时，也即窗口初次显示时, 不会触发此事件, 所以需要配合windowDidMove方法一起使用
         */
        guard !isAnimatingFrame else { return }
        limitFrameInScreen()
    }

    // 上一次"钉位"时的 (topLeft, frame)：整句编码下按键高频刷窗，重复的
    // setFrame 会反复触发约束系统全树布局
    // （live sample 里每键 1~3ms）。
    private var lastPin: (topLeft: NSPoint, frame: NSRect)?

    // 窗口平移动画进行中：期间 windowDidMove/Resize 的安全钳制会让动画顿挫，先抑制
    private var isAnimatingFrame = false
    private var glideToken = 0

    /// 候选窗跟手滑动：easeOut 短平移，连续按键时新动画从当前视觉位置接续，丝滑跟随光标
    private func glideFrame(to newFrame: NSRect) {
        isAnimatingFrame = true
        glideToken += 1
        let token = glideToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.animator().setFrame(newFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.glideToken == token else { return }
            self.isAnimatingFrame = false
        })
    }

    /// 候选内容所需的窗口尺寸：用一块独立的离屏 hosting 视图同步测量。
    /// 直接读 hostingView.fittingSize 在内容刚变更时可能拿到上一次布局的旧值，
    /// 旧尺寸会让窗框小于内容（文字被裁、被换行）；新建视图的 fittingSize 与
    /// 根视图当前状态严格一致。
    private var contentSize: NSSize {
        NSHostingView(rootView: hostingView.rootView).fittingSize
    }

    func setCandidates(
        _ candidatesData: CandidatesData,
        originalString: String,
        caretRect: NSRect,
        highlightIndex: Int = 0
    ) {
        hostingView.rootView.candidates = candidatesData.list
        hostingView.rootView.origin = originalString
        hostingView.rootView.hasNext = candidatesData.hasNext
        hostingView.rootView.hasPrev = candidatesData.hasPrev
        hostingView.rootView.page = candidatesData.page
        hostingView.rootView.pageCount = candidatesData.pageCount
        hostingView.rootView.highlightIndex = highlightIndex
        fireLog("caret rect: \(caretRect)")
        fireLog("candidates: \(candidatesData)")
        // 按内容尺寸算出落点后一次性 setFrame（光标下 4pt，放不下放上方）
        let newSize = contentSize
        let topLeft = Self.placeTopLeft(caretRect: caretRect, windowSize: newSize)
        let newFrame = NSRect(
            x: topLeft.x,
            y: topLeft.y - newSize.height,
            width: newSize.width,
            height: newSize.height
        )
        // 位置与尺寸都未变才跳过钉位；内容尺寸变化必须落位，否则快速连击时
        // 客户端 caretRect 滞后（attributes 拿到上一次布局的矩形）会让 topLeft
        // 与上一键相同，resize 被吞掉，窗框停留在旧尺寸裁掉文字
        if lastPin == nil || lastPin!.topLeft != topLeft
            || lastPin!.frame != self.frame || newSize != self.frame.size {
            let wasVisible = isVisible
            lastPin = (topLeft, newFrame)
            if wasVisible && newFrame.size == self.frame.size {
                // 纯位移（光标前进/上下翻转）：滑动跟随；位移不改变内容提案尺寸，
                // 动画全程内容布局不变，丝滑且不会出现换行/裁剪
                glideFrame(to: newFrame)
            } else {
                // 首次显示或尺寸变化：直接落位——窗框尺寸动画期间内容已按新尺寸布局，
                // 临时提案宽度变窄会让文字被折行/裁剪，不做尺寸动画。
                // 落位前必须先停掉在飞的 glide：普通 setFrame 不会取消 animator() 动画，
                // 键间隔小于动画时长时旧动画会继续把窗框拉回旧目标（旧位置+旧尺寸），
                // 造成候选词被窗口边缘截断；0 时长 animator 调用即替换掉在飞动画
                glideToken += 1
                isAnimatingFrame = false
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    self.animator().setFrame(self.frame, display: false)
                }
                self.setFrame(newFrame, display: false)
            }
        }
        // 已可见则跳过 orderFront，避免每键重入窗口排序
        if !self.isVisible {
            self.orderFront(nil)
        }
//        NSApp.setActivationPolicy(.prohibited)
    }

    /// 窗口贴在光标行下方 4pt；下方放不下放上方；上下都放不下
    /// 贴屏幕底边（宁可盖住光标也别出屏）；x 钳制在光标所在屏幕内。
    /// 光标矩形是零或不落在任何屏幕（应用不支持）时以鼠标位置为准。
    /// 返回值为窗口左上角坐标（setCandidates 以左上角换算 frame）。
    static func placeTopLeft(caretRect: NSRect, windowSize: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let mouseAnchor = NSRect(
            x: mouse.x, y: mouse.y, width: 0, height: fallbackLineHeight)
        let anchor: NSRect
        let visible: NSRect
        if let screenVisible = Utils.shared.getScreenFromPoint(caretRect.origin)?.visibleFrame,
           !caretRect.equalTo(NSRect.zero) {
            anchor = caretRect
            visible = screenVisible
        } else {
            anchor = mouseAnchor
            visible = Utils.shared.getScreenFromPoint(mouse)?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? mouseAnchor
        }
        let min_x = visible.minX
        let max_x = max(min_x, visible.maxX - windowSize.width)
        let x = min(max(anchor.minX, min_x), max_x)
        // 按窗口底边算落点：下方放得下贴光标行下 4pt，否则翻到光标行上方，
        // 上下都放不下（屏幕很矮或窗口很高）贴屏幕底边
        let belowBottom = anchor.minY - caretGap - windowSize.height
        let aboveBottom = anchor.maxY + caretGap
        let bottom: CGFloat
        if belowBottom >= visible.minY {
            bottom = belowBottom
        } else if aboveBottom + windowSize.height <= visible.maxY {
            bottom = aboveBottom
        } else {
            bottom = visible.minY
        }
        // 无论怎么算，最后都要落在这块屏幕里：出屏等于不显示
        let max_bottom = max(visible.minY, visible.maxY - windowSize.height)
        let clampedBottom = min(max(bottom, visible.minY), max_bottom)
        return NSPoint(x: x, y: clampedBottom + windowSize.height)
    }

    override func close() {
        lastPin = nil
        super.close()
    }

    func bindEvents() {
        let events: [NotificationObserver] = [
            (CandidatesView.candidateSelected, { notification in
                if let candidate = notification.userInfo?["candidate"] as? Candidate {
                    // 鼠标点选不是按键，无提交键，只计已敲入的编码键数
                    self.inputController?.insertCandidate(
                        candidate,
                        committedKeys: self.inputController?.currentRawKeyCount ?? 0)
                }
            }),
            (CandidatesView.prevPageBtnTapped, { _ in self.inputController?.prevPage() }),
            (CandidatesView.nextPageBtnTapped, { _ in self.inputController?.nextPage() }),
            (Fire.inputModeChanged, { notification in
                if notification.userInfo?["val"] as? InputMode == InputMode.enUS {
                    self.inputController?.insertOriginText()
                }
            })
        ]
        events.forEach { (observer) in NotificationCenter.default.addObserver(
          forName: observer.name, object: nil, queue: nil, using: observer.callback
        )}
        // 由于使用IMKInputController recognizedEvents在一些场景下不能监听到flagChanged事件，比如保存文件和lanchPad场景
        // 所以这里需要使用NSEvent.addGlobalMonitorForEvents监听shift键被按下
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { (event) in
            fireLog("[CandidatesWindow] globalMonitorForEvents flagsChanged: \(event)")
            if !InputSource.shared.isSelected() {
                return
            }
            _ = self.inputController?.flagChangedHandler(event: event)
        }
        // 深浅主题模式变化时即时刷新候选窗口外观
        Defaults.observe(keys: .themeAppearanceMode) { [weak self] () in
            self?.updateAppearance()
        }.tieToLifetime(of: self)
    }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        level = NSWindow.Level(rawValue: NSWindow.Level.RawValue(CGShieldingWindowLevel()))
        styleMask = .init(arrayLiteral: .fullSizeContentView, .borderless)
        isReleasedWhenClosed = false
        backgroundColor = NSColor.clear
        delegate = self
        setSizePolicy()
        bindEvents()
        updateAppearance()
    }

    private func limitFrameInScreen() {
       let origin = self.transformTopLeft(originalTopLeft: NSPoint(x: self.frame.minX, y: self.frame.maxY))
       self.setFrameTopLeftPoint(origin)
    }

    /// 深浅主题手动切换：固定浅/深色时给窗口设定对应外观，SwiftUI 的
    /// colorScheme 环境值随之解析到主题对应套色；跟随系统时清除覆盖
    private func updateAppearance() {
        switch Defaults[.themeAppearanceMode] {
        case .followSystem: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func setSizePolicy() {
        // 窗口大小可根据内容变化
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        guard self.contentView != nil else {
            return
        }
        self.contentView?.addSubview(hostingView)
        self.contentView?.leftAnchor.constraint(equalTo: hostingView.leftAnchor).isActive = true
        self.contentView?.rightAnchor.constraint(equalTo: hostingView.rightAnchor).isActive = true
        self.contentView?.topAnchor.constraint(equalTo: hostingView.topAnchor).isActive = true
        self.contentView?.bottomAnchor.constraint(equalTo: hostingView.bottomAnchor).isActive = true
    }

    private func transformTopLeft(originalTopLeft: NSPoint) -> NSPoint {
        fireLog("[FireCandidatesWindow] transformTopLeft: \(frame)")

        let screenPadding: CGFloat = 6

        var left = originalTopLeft.x
        var top = originalTopLeft.y
        if let curScreen = Utils.shared.getScreenFromPoint(originalTopLeft) {
            let screen = curScreen.frame

            if originalTopLeft.x + frame.width > screen.maxX - screenPadding {
                left = screen.maxX - frame.width - screenPadding
            }
            if originalTopLeft.y - frame.height < screen.minY + screenPadding {
                top = screen.minY + frame.height + screenPadding
            }
        }
        return NSPoint(x: left, y: top)
    }

    static let shared = CandidatesWindow()
}

// MARK: - 候选框渲染预览（调试）
// 用法：Fire --preview-candidates
// 渲染状态全部通过视图的 *Override 注入参数指定，不读写任何 UserDefaults
// （UserDefaults 走 cfprefsd 按 true 用户主目录落盘，HOME 环境变量隔离不了它）。
enum CandidatesPreviewRenderer {
    private static let previewTheme = defaultThemeConfig.light

    private static var previews: [(name: String, make: () -> CandidatesView, dark: Bool)] {
        let wubiCandidates: [Candidate] = [
            Candidate(code: "a", text: "工", type: .wb),
            Candidate(code: "aa", text: "戈", type: .wb),
            Candidate(code: "aaaa", text: "工厂", type: .wb),
            Candidate(code: "ag", text: "啊", type: .py),
            Candidate(code: "ad", text: "的", type: .user)
        ]
        let sentenceCandidates: [Candidate] = [
            Candidate(code: "wj wdc", text: "我叫王大锤", type: .sentence),
            Candidate(code: "wj wxc", text: "我叫王小锤", type: .sentence),
            Candidate(code: "wj wdc sd", text: "我叫王大锤的", type: .sentence)
        ]
        return [
            ("vertical-light", {
                CandidatesView(
                    candidates: wubiCandidates, origin: "a",
                    hasPrev: true, hasNext: true, page: 2, pageCount: 3,
                    themeOverride: previewTheme,
                    directionOverride: .vertical,
                    showCodeInWindowOverride: true,
                    wubiCodeTipOverride: true)
            }, false),
            ("vertical-dark", {
                CandidatesView(
                    candidates: wubiCandidates, origin: "a",
                    hasPrev: true, hasNext: true, page: 2, pageCount: 3,
                    themeOverride: previewTheme,
                    directionOverride: .vertical,
                    showCodeInWindowOverride: true,
                    wubiCodeTipOverride: true)
            }, true),
            ("sentence-diff-light", {
                CandidatesView(
                    candidates: sentenceCandidates, origin: "wjwdc",
                    highlightIndex: 1,
                    themeOverride: previewTheme,
                    directionOverride: .vertical,
                    showCodeInWindowOverride: true,
                    wubiCodeTipOverride: true)
            }, false),
            ("horizontal-light", {
                CandidatesView(
                    candidates: wubiCandidates, origin: "a",
                    hasPrev: true, hasNext: true, page: 1, pageCount: 3,
                    highlightIndex: 1,
                    themeOverride: previewTheme,
                    directionOverride: .horizontal,
                    showCodeInWindowOverride: true,
                    wubiCodeTipOverride: true)
            }, false)
        ]
    }

    static func run() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            renderAll()
            verifyPlacement()
            NSApp.terminate(nil)
        }
    }

    /// 定位算法数值自检：光标在上→窗口顶贴光标行下 4pt；光标贴屏幕底→整窗翻到光标上方
    private static func verifyPlacement() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: 200, height: 190)
        let caretTop = NSRect(x: 100, y: visible.maxY - 50, width: 1, height: 20)
        let topLeftTop = CandidatesWindow.placeTopLeft(caretRect: caretTop, windowSize: size)
        NSLog("[placement] caret-top: windowTop=%.1f caretBottom=%.1f gap=%.1f",
              topLeftTop.y, caretTop.minY, caretTop.minY - topLeftTop.y)
        let caretBottom = NSRect(x: 100, y: visible.minY + 10, width: 1, height: 20)
        let topLeftBottom = CandidatesWindow.placeTopLeft(caretRect: caretBottom, windowSize: size)
        let windowBottom = topLeftBottom.y - size.height
        NSLog("[placement] caret-bottom: windowBottom=%.1f caretTop=%.1f gap=%.1f flipped=%d",
              windowBottom, caretBottom.maxY, windowBottom - caretBottom.maxY,
              windowBottom >= caretBottom.maxY ? 1 : 0)
    }

    private static func renderAll() {
        for (name, make, dark) in previews {
            let view = NSHostingView(rootView: make())
            if dark {
                view.appearance = NSAppearance(named: .darkAqua)
            }
            let size = view.fittingSize
            view.frame = NSRect(origin: .zero, size: size)
            view.wantsLayer = true
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let layer = view.layer, size.width > 0, size.height > 0 else {
                NSLog("[CandidatesPreviewRenderer] empty layer for \(name)")
                continue
            }
            let scale: CGFloat = 2
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            let ctx = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current = ctx
            layer.contentsScale = scale
            // 位图上下文原点在左下、layer 原点在左上，翻转一次避免快照上下颠倒
            let cgContext = ctx!.cgContext
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: size.height)
            cgContext.scaleBy(x: 1, y: -1)
            layer.render(in: cgContext)
            cgContext.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: "/tmp/fire-candidates-\(name).png")
                try? png.write(to: url)
                NSLog("[CandidatesPreviewRenderer] wrote \(url.path) \(size)")
            }
        }
    }
}
