//
//  HoverTrackingView.swift
//  Fire
//
//  Created by Kiro on 2026/7/24.
//  Copyright © 2026 qwertyyb. All rights reserved.
//

import AppKit
import SwiftUI

// 候选词窗口悬浮在其他 App 之上时，Fire 自身不是 active app，
// SwiftUI 的 .onHover/.help 依赖的 NSTrackingArea 默认 .activeInActiveApp 选项不会触发，
// 这里用 .activeAlways 手动实现，使悬浮检测在非激活状态下依然生效
private class HoverTrackingNSView: NSView {
    var onHover: ((Bool, NSPoint) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true, NSEvent.mouseLocation)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false, NSEvent.mouseLocation)
    }
}

struct HoverTracking: NSViewRepresentable {
    var onHover: (Bool, NSPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = HoverTrackingNSView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HoverTrackingNSView)?.onHover = onHover
    }
}
