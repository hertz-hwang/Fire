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
    /// 纯位移滑动跟随时长
    private static let glideDuration: CFTimeInterval = 0.12
    /// 尺寸变化动画时长（旧内容幽灵层同步淡出）
    private static let resizeDuration: CFTimeInterval = 0.15
    /// 渐入/渐出时长
    private static let fadeInDuration: CFTimeInterval = 0.15
    private static let fadeOutDuration: CFTimeInterval = 0.12

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
    // （fileprivate：--preview-window-anim 自检需采样）
    fileprivate var isAnimatingFrame = false
    // 在飞窗框动画（滑动/尺寸）令牌：新动画开始时递增，旧动画的完成回调因此失效，
    // 不会把 isAnimatingFrame 提前复位
    private var frameToken = 0
    // 透明度动画令牌与渐出状态：渐入/渐出相互替换时旧完成回调失效
    private var alphaToken = 0
    private var isFadingOut = false
    // 尺寸动画期间的旧内容快照层（幽灵）：钉在窗框不动角，随窗框收缩被裁掉并淡出
    private var ghostImageView: NSImageView?

    /// 候选窗跟手滑动：easeOut 短平移，连续按键时新动画从当前视觉位置接续，丝滑跟随光标
    private func glideFrame(to newFrame: NSRect) {
        animateFrame(to: newFrame, duration: Self.glideDuration)
    }

    /// 窗框动画（位移与尺寸共用）：animator 动画可被下一个动画从当前视觉值
    /// 无缝接续，快速连击时不断替换目标也不会跳变
    private func animateFrame(to newFrame: NSRect, duration: CFTimeInterval) {
        isAnimatingFrame = true
        frameToken += 1
        let token = frameToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.animator().setFrame(newFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.frameToken == token else { return }
            self.isAnimatingFrame = false
        })
    }

    /// 尺寸变化动画：窗框从当前视觉尺寸滑向新尺寸，同时把换内容前的旧内容快照
    /// （幽灵层）钉在窗框不动的那一角淡出——扩张时新内容从固定角逐渐显出，
    /// 收缩时旧内容被收拢的窗框裁掉并淡出，两个方向的边缘都在平滑移动而非瞬跳。
    /// 内容本体以 contentAlignment 钉在同一角，中间帧文字不滑动不折行
    private func resizeFrame(to newFrame: NSRect, ghost: NSImage, anchor: Alignment) {
        animateFrame(to: newFrame, duration: Self.resizeDuration)
        showGhost(ghost, anchor: anchor, duration: Self.resizeDuration)
    }

    /// 当前内容的位图快照（不含幽灵层）：必须在 rootView 换新之前调用，否则抓到
    /// 的是新内容。按窗口 backing scale 自建位图，Retina 下不模糊
    private func snapshotContent() -> NSImage? {
        let bounds = hostingView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = isVisible ? backingScaleFactor : (NSScreen.main?.backingScaleFactor ?? 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((bounds.width * scale).rounded()),
            pixelsHigh: Int((bounds.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        hostingView.cacheDisplay(in: bounds, to: rep)
        guard let cgImage = rep.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: bounds.size)
    }

    /// 叠加旧内容快照并淡出移除；窗框收缩时超出的部分被窗口裁掉，
    /// 形成"边缘收拢 + 底下新内容显出"的交叉过渡
    private func showGhost(_ image: NSImage, anchor: Alignment, duration: CFTimeInterval) {
        clearGhost()
        guard let contentView = contentView else { return }
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: image.size.width),
            imageView.heightAnchor.constraint(equalToConstant: image.size.height),
        ])
        switch anchor.horizontal {
        case .trailing:
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor).isActive = true
        default:
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor).isActive = true
        }
        switch anchor.vertical {
        case .bottom:
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor).isActive = true
        default:
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor).isActive = true
        }
        ghostImageView = imageView
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            imageView.animator().alphaValue = 0
        }, completionHandler: {
            // 无论是否已被新幽灵替换都移除自身，避免残留
            imageView.removeFromSuperview()
        })
    }

    private func clearGhost() {
        ghostImageView?.removeFromSuperview()
        ghostImageView = nil
    }

    /// 尺寸变化时窗框哪一角保持不动（贴近光标/屏幕锚点的一角）：
    /// 比较新旧窗框四条边，每根轴上取位置不变的那一侧
    private func resizeAnchor(from oldFrame: NSRect, to newFrame: NSRect) -> Alignment {
        let epsilon: CGFloat = 0.5
        let horizontal: HorizontalAlignment
        if abs(oldFrame.minX - newFrame.minX) > epsilon
            && abs(oldFrame.maxX - newFrame.maxX) <= epsilon {
            horizontal = .trailing
        } else {
            horizontal = .leading
        }
        let vertical: VerticalAlignment
        if abs(oldFrame.maxY - newFrame.maxY) > epsilon
            && abs(oldFrame.minY - newFrame.minY) <= epsilon {
            vertical = .bottom
        } else {
            vertical = .top
        }
        return Alignment(horizontal: horizontal, vertical: vertical)
    }

    /// 不做动画直接落位。落位前先停掉在飞的滑动/尺寸动画：普通 setFrame 不会
    /// 取消 animator() 动画，键间隔小于动画时长时旧动画会继续把窗框拉回旧目标
    /// （旧位置+旧尺寸），造成候选词被窗口边缘截断；0 时长 animator 调用即替换
    /// 掉在飞动画
    private func placeWithoutAnimation(_ newFrame: NSRect) {
        frameToken += 1
        isAnimatingFrame = false
        clearGhost()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            self.animator().setFrame(self.frame, display: false)
        }
        self.setFrame(newFrame, display: false)
    }

    /// 渐入：orderFront 后透明度 0→1，替代首次显示的硬切
    private func fadeIn() {
        alphaToken += 1
        let token = alphaToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self, self.alphaToken == token else { return }
            self.alphaValue = 1
        })
    }

    /// 渐出途中来了新输入：取消渐出并恢复不透明，窗口按可见流程继续钉位
    private func cancelFadeOutIfNeeded() {
        guard isFadingOut else { return }
        alphaToken += 1
        isFadingOut = false
        alphaValue = 1
    }

    func setCandidates(
        _ candidatesData: CandidatesData,
        originalString: String,
        caretRect: NSRect,
        highlightIndex: Int = 0
    ) {
        // 渐出途中来了新输入：取消渐出、恢复不透明，按可见窗口继续钉位
        cancelFadeOutIfNeeded()
        fireLog("caret rect: \(caretRect)")
        fireLog("candidates: \(candidatesData)")
        // 先用新内容构造临时视图，在独立离屏 hosting 上同步测量目标尺寸（新建
        // 视图的 fittingSize 与根视图当前状态严格一致；直接读 hostingView.fittingSize
        // 在内容刚变更时可能拿到上一次布局的旧值，旧尺寸会让窗框小于内容，
        // 文字被裁、被换行），之后再一次性换上真实内容
        var upcoming = hostingView.rootView
        upcoming.candidates = candidatesData.list
        upcoming.origin = originalString
        upcoming.hasNext = candidatesData.hasNext
        upcoming.hasPrev = candidatesData.hasPrev
        upcoming.page = candidatesData.page
        upcoming.pageCount = candidatesData.pageCount
        upcoming.highlightIndex = highlightIndex
        let newSize = NSHostingView(rootView: upcoming).fittingSize
        // 按内容尺寸算出落点后一次性换算 frame（光标下 4pt，放不下放上方）
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
        let needsPlace = lastPin == nil
            || lastPin!.topLeft != topLeft
            || lastPin!.frame != self.frame
            || newSize != self.frame.size
        // 尺寸变化动画的旧内容快照必须在真实内容换新之前抓取
        let willResize = needsPlace && isVisible && newSize != self.frame.size
        let ghost = willResize ? snapshotContent() : nil
        if willResize {
            upcoming.contentAlignment = resizeAnchor(from: self.frame, to: newFrame)
        }
        hostingView.rootView = upcoming

        if needsPlace {
            let wasVisible = isVisible
            lastPin = (topLeft, newFrame)
            if !wasVisible {
                // 首次显示：内容已按最终尺寸布局，直接落位（不做尺寸动画），
                // 出现过程交给渐入动画
                placeWithoutAnimation(newFrame)
                alphaValue = 0
            } else if newSize == self.frame.size {
                // 纯位移（光标前进/上下翻转）：滑动跟随；位移不改变内容提案尺寸，
                // 动画全程内容布局不变，丝滑且不会出现换行/裁剪
                glideFrame(to: newFrame)
            } else if let ghost {
                // 尺寸变化（候选词字数/选项数增减）：窗框滑向新尺寸 + 旧内容
                // 幽灵淡出交叉过渡
                resizeFrame(to: newFrame, ghost: ghost, anchor: upcoming.contentAlignment)
            } else {
                // 快照抓取失败：退化为直接落位，保证窗框与内容严格一致
                placeWithoutAnimation(newFrame)
            }
        }
        // 已可见则跳过 orderFront，避免每键重入窗口排序；首次显示配渐入
        if !self.isVisible {
            self.orderFront(nil)
            fadeIn()
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

    /// 关闭即渐出：透明度渐隐到 0 再移出屏幕；期间新输入经
    /// cancelFadeOutIfNeeded 取消渐出，窗口无缝回到可见状态
    override func close() {
        lastPin = nil
        // 停掉在飞的窗框动画与幽灵层，渐出期间窗框不再变动
        frameToken += 1
        isAnimatingFrame = false
        clearGhost()
        guard isVisible, !isFadingOut else { return }
        isFadingOut = true
        alphaToken += 1
        let token = alphaToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaToken == token else { return }
            self.isFadingOut = false
            self.orderOut(nil)
            self.alphaValue = 1
        })
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
        // 尺寸动画中间帧内容可能大于窗框，裁到窗口边界，避免溢出画到窗口外
        contentView?.wantsLayer = true
        contentView?.layer?.masksToBounds = true
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
    // --theme <path>：用指定主题 JSON 渲染预览（主题作者调试用；缺省内置默认主题）
    private static let customTheme: ThemeConfig? = {
        guard let index = CommandLine.arguments.firstIndex(of: "--theme"),
              CommandLine.arguments.count > index + 1 else { return nil }
        guard let json = try? String(contentsOfFile: CommandLine.arguments[index + 1],
                                     encoding: .utf8) else {
            NSLog("[CandidatesPreviewRenderer] theme file read failed")
            return nil
        }
        guard let config = loadThemeConfig(jsonData: json) else {
            NSLog("[CandidatesPreviewRenderer] theme parse failed")
            return nil
        }
        return config
    }()

    private static var previewTheme: ApperanceThemeConfig {
        customTheme?.light ?? defaultThemeConfig.light
    }
    private static var darkTheme: ApperanceThemeConfig {
        customTheme?.dark ?? defaultThemeConfig.dark ?? previewTheme
    }

    private static var previews: [(name: String, make: () -> CandidatesView, dark: Bool)] {
        let wubiCandidates: [Candidate] = [
            Candidate(code: "a", text: "工", type: .wb),
            Candidate(code: "aa", text: "戈", type: .wb),
            Candidate(code: "aaaa", text: "工厂", type: .wb),
            Candidate(code: "ag", text: "啊", type: .py),
            Candidate(code: "ad", text: "的", type: .user)
        ]
        let sentenceCandidates: [Candidate] = [
            Candidate(code: "wj wdc", text: "我叫王大锤", type: .sentence,
                      scoreText: "通用ngram:-23.40 组句项:-0.94"),
            Candidate(code: "wj wxc", text: "我叫王小锤", type: .sentence,
                      scoreText: "通用ngram:-25.12 用户ngram:+0.35 组句项:-0.94"),
            Candidate(code: "wj wdc sd", text: "我叫王大锤的", type: .sentence,
                      scoreText: "通用ngram:-28.71 会话缓存:+0.42 组句项:-1.25")
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
                    themeOverride: darkTheme,
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
            ("sentence-dark", {
                CandidatesView(
                    candidates: sentenceCandidates, origin: "wjwdc",
                    highlightIndex: 1,
                    themeOverride: darkTheme,
                    directionOverride: .vertical,
                    showCodeInWindowOverride: true,
                    wubiCodeTipOverride: true)
            }, true),
            ("sentence-horizontal-light", {
                CandidatesView(
                    candidates: sentenceCandidates, origin: "wjwdc",
                    highlightIndex: 1,
                    themeOverride: previewTheme,
                    directionOverride: .horizontal,
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

// MARK: - 候选窗动画自检（调试）
// 用法：Fire --preview-window-anim
// 驱动真实窗口走完 渐入→尺寸扩张→尺寸收缩→渐出→渐出中断恢复 全流程，
// 按时间采样 frame/alpha/幽灵层数量并断言；不写任何 UserDefaults
enum WindowAnimationSelfCheck {
    private static func log(_ text: String) {
        NSLog("[WindowAnimationSelfCheck] %@", text)
    }

    private static func expect(_ condition: Bool, _ what: String) {
        log("\(condition ? "PASS" : "FAIL") \(what)")
    }

    private static func frameClose(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    private static func sample(_ tag: String, _ window: CandidatesWindow) {
        log("\(tag): alpha=\(window.alphaValue) frame=\(window.frame) "
            + "subviews=\(window.contentView?.subviews.count ?? -1) "
            + "animating=\(window.isAnimatingFrame ? 1 : 0)")
    }

    static func run() {
        let window = CandidatesWindow.shared
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 光标放在屏幕上部居中：落点走"光标下方 4pt"的常规分支，不触边不翻转
        let caret = NSRect(x: visible.midX, y: visible.maxY - 220, width: 1, height: 20)
        let small = CandidatesData(
            list: [Candidate(code: "a", text: "工", type: .wb)],
            hasPrev: false, hasNext: false, page: 1, pageCount: 0)
        let big = CandidatesData(
            list: (1...9).map {
                Candidate(code: "aaaaaaaaaa\($0)", text: "工厂那边一直\($0)在忙", type: .wb)
            },
            hasPrev: true, hasNext: true, page: 2, pageCount: 3)

        // 1. 首次显示：渐入
        window.setCandidates(small, originalString: "a", caretRect: caret)
        let firstFrame = window.frame
        expect(window.isVisible, "首次显示后窗口可见")
        expect(window.alphaValue < 1, "渐入起点 alpha<1（实际 \(window.alphaValue)）")
        sample("fade-in start", window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            sample("fade-in mid", window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                expect(window.alphaValue == 1, "渐入结束 alpha=1")
                sample("fade-in end", window)

                // 2. 尺寸扩张动画（选项数 1→9、候选词变长）
                // 注意：animator 窗框动画逐帧步进，setCandidates 刚返回时 frame
                // 仍处于起点，目标尺寸只能等动画到位后采样
                window.setCandidates(big, originalString: "aaaaaaaaaa", caretRect: caret)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    sample("grow mid", window)
                    expect(window.contentView?.subviews.count == 2,
                           "扩张中存在幽灵快照层")
                    expect(!frameClose(window.frame, firstFrame),
                           "扩张进行中窗框已离开首帧")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let grownFrame = window.frame
                        expect(grownFrame.height > firstFrame.height,
                               "扩张后高于首帧 \(grownFrame.size) vs \(firstFrame.size)")
                        expect(window.contentView?.subviews.count == 1, "幽灵已移除")
                        sample("grow end", window)

                        // 3. 尺寸收缩动画（候选词变短、选项数变少）
                        window.setCandidates(small, originalString: "a", caretRect: caret)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            sample("shrink mid", window)
                            expect(!frameClose(window.frame, grownFrame),
                                   "收缩进行中窗框已离开扩张后尺寸")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                expect(frameClose(window.frame, firstFrame),
                                       "收缩动画回到首帧尺寸")
                                sample("shrink end", window)

                                // 4. 渐出 + 渐出途中新输入打断
                                window.close()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    sample("fade-out mid", window)
                                    expect(window.alphaValue < 1, "渐出进行中 alpha<1")
                                    // 渐出未完成时来了新输入：应取消渐出、恢复不透明
                                    window.setCandidates(big, originalString: "aaaaaaaaaa",
                                                         caretRect: caret)
                                    expect(window.isVisible && window.alphaValue == 1,
                                           "渐出被新输入打断后恢复可见不透明")
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        sample("interrupted resume", window)
                                        expect(window.isVisible && window.alphaValue == 1,
                                               "打断后窗口保持可见")
                                        // 5. 正常关闭收尾
                                        window.close()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                            expect(!window.isVisible, "渐出完成后窗口不可见")
                                            expect(window.alphaValue == 1,
                                                   "关闭后 alpha 复位为 1")
                                            sample("closed", window)
                                            NSApp.terminate(nil)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
