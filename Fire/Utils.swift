//
//  checkShiftUp.swift
//  Fire
//
//  Created by 虚幻 on 2020/8/15.
//  Copyright © 2020 qwertyyb. All rights reserved.
//

import AppKit
import Defaults
import InputMethodKit
import SwiftUI

enum HandlerStatus {
    case next
    case stop
}

/// 轻量日志：仅在 Debug 构建输出。
/// 使用 @autoclosure 延迟字符串插值，Release 下既不拼串也不写日志，
/// 避免在每次按键的热路径上因 NSLog 的同步写入 + 字符串构造造成卡顿。
#if DEBUG
func fireLog(_ message: @autoclosure () -> String) {
    NSLog("%@", message())
}
#else
@inline(__always)
func fireLog(_ message: @autoclosure () -> String) {}
#endif

class Utils {
    var toggleInputModeKeyUpChecker = ModifierKeyUpChecker(Defaults[.toggleInputModeKey])

    var toast: ToastWindowProtocol?

    // 用于删除/组词等操作的小字文本提示，独立于中英文切换提示，不受 inputModeTipWindowType 影响
    // 低频操作，按需创建、隐藏后释放
    private var messageToast: ToastWindow?

    // 显示一段小字文本提示(居中)，提示消失后释放窗口
    func showMessage(_ text: String) {
        if messageToast == nil {
            messageToast = ToastWindow()
        }
        messageToast?.showToast(text) { [weak self] in
            self?.messageToast = nil
        }
    }

    private func initToastWindow() {
        toast = Defaults[.inputModeTipWindowType] == .centerScreen
            ? ToastWindow()
           : Defaults[.inputModeTipWindowType] == .followInput
               ? TipsWindow()
               : nil
    }
    init() {
        Defaults.observe(keys: .inputModeTipWindowType, .candidateCount) { () in
            self.initToastWindow()
        }.tieToLifetime(of: self)
        Defaults.observe(.toggleInputModeKey) { (val) in
            let modifier = val.newValue
            print("modifier: ", modifier)
            self.toggleInputModeKeyUpChecker = ModifierKeyUpChecker(modifier)
        }.tieToLifetime(of: self)
    }
    func processHandlers<T>(
        handlers: [(NSEvent) -> T?]
    ) -> ((NSEvent) -> T?) {
        func handleFn(event: NSEvent) -> T? {
            for handler in handlers {
                if let result = handler(event) {
                    return result
                }
            }
            return nil
        }
        return handleFn
    }

    func getScreenFromPoint(_ point: NSPoint) -> NSScreen? {
        // find current screen
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                return screen
            }
        }
        return NSScreen.main
    }
    
    // 中英文衔接判断用到的正则，编译一次后复用。
    // 此前每次调用都会 new 出 4 个 NSRegularExpression，而该方法在按键/上屏热路径上被频繁调用。
    private static let endsWithEnReg = try? NSRegularExpression(pattern: "[a-zA-Z0-9]$")
    private static let startsWithCnReg = try? NSRegularExpression(pattern: "^[\\u4e00-\\u9fa5]")
    private static let endsWithCnReg = try? NSRegularExpression(pattern: "[\\u4e00-\\u9fa5]$")
    private static let startsWithEnReg = try? NSRegularExpression(pattern: "^[a-zA-Z0-9]")

    // 根据上次输入的字符，判断插入的新字符是否要前加空格
    func shouldConcatWithWhitespace(_ lastText: String, _ nextText: String) -> Bool {
        fireLog("[Utils] shouldConcatWithWhitespace, lastText: \(lastText), nextText: \(nextText)")
        if lastText.count <= 0 || nextText.count <= 0 {
            return false
        }
        guard let firstEnReg = Utils.endsWithEnReg,
              let nextCnReg = Utils.startsWithCnReg,
              let firstCnReg = Utils.endsWithCnReg,
              let nextEnReg = Utils.startsWithEnReg else {
            return false
        }
        let lastRange = NSMakeRange(0, lastText.utf16.count)
        let nextRange = NSMakeRange(0, nextText.utf16.count)
        if firstEnReg.numberOfMatches(in: lastText, range: lastRange) > 0
            && nextCnReg.numberOfMatches(in: nextText, range: nextRange) > 0 {
            return true
        }
        return firstCnReg.numberOfMatches(in: lastText, range: lastRange) > 0
            && nextEnReg.numberOfMatches(in: nextText, range: nextRange) > 0
    }

    static let shared = Utils()
}
