//
//  FireInputController.swift
//  Fire
//
//  Created by 虚幻 on 2019/9/15.
//  Copyright © 2019 qwertyyb. All rights reserved.
//

import SwiftUI
import InputMethodKit
import Sparkle
import Defaults

typealias NotificationObserver = (name: Notification.Name, callback: (_ notification: Notification) -> Void)

class FireInputController: IMKInputController {
    private var _candidates: [Candidate] = []
    private var _hasNext: Bool = false
    private var _lastInputIsAlphanumeric = false
    private var _lastPunctuationKeyCode: UInt16? = nil
    private var _lastInputText = ""
    private var _lastCommittedText = ""
    private var _lastCommittedRange: NSRange?
    internal var inputMode: InputMode {
        get { Fire.shared.inputMode }
        set(value) { Fire.shared.inputMode = value }
    }

    internal var temp: (
        observerList: [NSObjectProtocol],
        monitorList: [Any?]
    ) = (
        observerList: [],
        monitorList: []
    )

    deinit {
        NSLog("[FireInputController] deinit")
        clean()
    }

    private var _originalString = "" {
        didSet {
            if self.curPage != 1 {
                // code被重新设置时，还原页码为1
                self.curPage = 1
                self.markText()
                return
            }
            NSLog("[FireInputController] original changed: \(self._originalString), refresh window")

            // 建议mark originalString, 否则在某些APP中会有问题
            self.markText()

            self._originalString.count > 0 ? self.refreshCandidatesWindow() : CandidatesWindow.shared.close()
        }
    }
    private var curPage: Int = 1 {
        didSet(old) {
            guard old == self.curPage else {
                NSLog("[FireInputHandler] page changed")
                self.refreshCandidatesWindow()
                return
            }
        }
    }
    func prevPage() {
        self.curPage = self.curPage > 1 ? self.curPage - 1 : 1
    }
    func nextPage() {
        self.curPage = self._hasNext ? self.curPage + 1 : self.curPage
    }

    private func markText() {
        let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: NSNotFound, length: 0))
        if let attributes = attrs as? [NSAttributedString.Key: Any] {
            var selected = self._originalString
            if Defaults[.showCodeInWindow] {
                selected = self._originalString.count > 0 ? " " : ""
            }
            let text = NSAttributedString(string: selected, attributes: attributes)
            client()?.setMarkedText(text, selectionRange: selectionRange(), replacementRange: replacementRange())
        }
    }
    
    private func getPreviousText(_ count: Int = 1) -> String {
        // 中文输入模式下，markedRange 会跟随输入字符变化
        // 不同APP下，对selectedRange的location处理不同，有的把location放在组字区后，比如备忘录APP，有的把location放在组字区前，比如Chrome浏览器，此处根据大小判断一下
        let selectedRange = client().selectedRange()
        var markedRange = client().markedRange()
        // 默认认为 location 在组字区后
        if (markedRange.location > 1000000) {
            markedRange = NSRange(location: 0, length: 0)
        }
        var previousLocation = selectedRange.location - markedRange.length - count
        // 某些场景下，markedRange的location和length不正常，此处按大小判断一下
        if selectedRange.location < markedRange.location + markedRange.length {
            // selectedRange的location在组字区前
            previousLocation = selectedRange.location - 1
        }
        if previousLocation < 0 {
            return ""
        }
        return client().attributedSubstring(from: NSMakeRange(previousLocation, count))?.string ?? ""
    }

    private func getPreviousTextIgnoringMarked(_ count: Int = 1) -> String {
        let selectedRange = client().selectedRange()
        let previousLocation = selectedRange.location - count
        if previousLocation < 0 {
            return ""
        }
        return client().attributedSubstring(from: NSMakeRange(previousLocation, count))?.string ?? ""
    }

    // ---- handlers begin -----

    private func hotkeyHandler(event: NSEvent) -> Bool? {
        NSLog("[FireInputController] hotkeyHandler")
        if event.type == .flagsChanged {
            return nil
        }
        if let handled = undoCommitHotkeyHandler(event: event) {
            return handled
        }
        guard let charsIgnoring = event.charactersIgnoringModifiers else {
            return nil
        }
        guard let num = Int(charsIgnoring) else { return nil }
        if event.modifierFlags == .control &&
            num > 0 && num <= _candidates.count {
            NSLog("hotkey: control + \(num)")
            DictManager.shared.setCandidateToFirst(query: _originalString, candidate: _candidates[num-1])
            self.curPage = 1
            self.refreshCandidatesWindow()
            return true
        }
        return nil
    }

    private func undoCommitHotkeyHandler(event: NSEvent) -> Bool? {
        let required = FireInputController.modifierFlag(for: Defaults[.undoCommitShortcutModifier])
        guard FireInputController.modifiersMatch(event.modifierFlags, required: required) else { return nil }
        let key = Defaults[.undoCommitShortcutKey].lowercased()
        guard let keyCode = FireInputController.keyCode(for: key) else { return nil }
        if event.keyCode == keyCode {
            return undoLastCommit()
        }
        return nil
    }

    private static let shortcutModifierMask: NSEvent.ModifierFlags = [
        .shift, .control, .option, .command, .function
    ]

    private static func modifiersMatch(_ flags: NSEvent.ModifierFlags,
                                       required: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection(shortcutModifierMask)
        return relevant == required
    }

    private static func modifierFlag(for key: ModifierKey) -> NSEvent.ModifierFlags {
        switch key {
        case .shift, .leftShift, .rightShift:
            return .shift
        case .control:
            return .control
        case .option:
            return .option
        case .command:
            return .command
        case .function:
            return .function
        }
    }

    private static func keyCode(for key: String) -> UInt16? {
        if key.count != 1 { return nil }
        let k = key.lowercased()
        let table: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "`": kVK_ANSI_Grave,
            "-": kVK_ANSI_Minus,
            "=": kVK_ANSI_Equal,
            "[": kVK_ANSI_LeftBracket,
            "]": kVK_ANSI_RightBracket,
            "\\": kVK_ANSI_Backslash,
            ";": kVK_ANSI_Semicolon,
            "'": kVK_ANSI_Quote,
            ",": kVK_ANSI_Comma,
            ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash
        ]
        return table[k].map { UInt16($0) }
    }

     func flagChangedHandler(event: NSEvent) -> Bool? {
         NSLog("[FireInputController] flagChangedHandler")
        // 只有在shift keyup时，才切换中英文输入, 否则会导致shift+[a-z]大写的功能失效
        if !Defaults[.disableEnMode] && Utils.shared.toggleInputModeKeyUpChecker.check(event) {
            NSLog("[FireInputController]toggle mode: \(inputMode)")

            // 把当前未上屏的原始code上屏处理
            insertText(_originalString)

            Fire.shared.toggleInputMode()
            return true
        }
        // 监听.flagsChanged事件只为切换中英文，其它情况不处理需要返回 false 以避免快捷键不生效
        if event.type == .flagsChanged || (
            event.modifierFlags != .init(rawValue: 0)
            // 输入法需要处理方向键做翻页，所以需要排除方向键
            && event.modifierFlags != .init(arrayLiteral: .numericPad, .function)
        ) {
            let onlyShift = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
            // 标点顶屏: 有输入码时，shift+标点键需要继续传递给 punctuationKeyHandler 处理
            if onlyShift && _originalString.count > 0 && Defaults[.enablePunctuationTopScreen] {
                return nil
            }
            // 中文模式下，shift+标点键需要传递给 punctuationKeyHandler 处理，以输出中文标点
            if onlyShift && inputMode == .zhhans,
               let chars = event.characters, chars.count == 1,
               punctuation.keys.contains(chars) {
                return nil
            }
            // 中文模式下，shift+字母直接上屏，需检查是否在中文后插入空格
            if onlyShift && inputMode == .zhhans && _originalString.isEmpty,
               let chars = event.characters, chars.count == 1,
               Defaults[.enableWhitespaceBetweenZhEn] {
                var lastText = getPreviousText()
                if lastText.isEmpty {
                    lastText = getPreviousTextIgnoringMarked()
                }
                if Utils.shared.shouldConcatWithWhitespace(lastText, chars) {
                    insertText(" " + chars)
                    return true
                }
            }
            NSLog("[FireInputController] flagChangedHandler no need handle")
            return false
        }
        return nil
    }

    private func enModeHandler(event: NSEvent) -> Bool? {
        NSLog("[FireInputController] enModeHandler")
        // 英文输入模式, 不做任何处理
        if inputMode == .enUS {
            if Defaults[.enableWhitespaceBetweenZhEn],
               _originalString.isEmpty,
               let string = event.characters,
               (try? NSRegularExpression(pattern: "^[a-zA-Z0-9]+$"))?
                    .firstMatch(in: string, options: [], range: NSRange(location: 0, length: string.count)) != nil {
                var lastText = getPreviousText()
                if lastText.isEmpty {
                    lastText = getPreviousTextIgnoringMarked()
                }
                if Utils.shared.shouldConcatWithWhitespace(lastText, string) {
                    insertText(" " + string)
                    return true
                }
            }
            return false
        }
        return nil
    }

    private func predictorHandler(event: NSEvent) -> Bool? {
        // 在数字/字母后输入标点时，以英文标点输出；连续输入两次相同标点，则改为输出中文标点
        // 例：「3,」→「3,」；「3,,」→「3，」；「hello.」→「hello.」；「hello..」→「hello。」
        if Defaults[.enableDotAfterNumber] && _lastInputIsAlphanumeric && _originalString.isEmpty {
            let keyCode = event.keyCode
            // base: 无修饰键字符，用于查 punctuation 字典（字典 key 均为无修饰键字符）
            // enPunct: 实际应输出的英文标点（含 Shift，如 Shift+; → ":"）
            if let base = event.charactersIgnoringModifiers, base.count == 1,
               let chars = event.characters, chars.count == 1,
               punctuation.keys.contains(base) {
                let enPunct = chars  // 实际输出字符，如 ":" 而非 ";"
                if _lastPunctuationKeyCode == keyCode {
                    // 连续两次相同标点：撤销上次输出的英文标点，改输出中文标点
                    // 优先用 enPunct（含 Shift，如 ":"）查字典，找不到再用 base（如 ";"）
                    let zhPunct = PunctuationConversion.shared.conversion(enPunct)
                        ?? PunctuationConversion.shared.conversion(base)
                        ?? enPunct
                    // 删除上次插入的英文标点（1个字符）并替换为中文标点
                    client()?.insertText(
                        NSAttributedString(string: zhPunct),
                        replacementRange: NSRange(location: client().selectedRange().location - 1, length: 1)
                    )
                    _lastInputIsAlphanumeric = false
                    _lastPunctuationKeyCode = nil
                } else {
                    // 第一次：输出英文标点（含 Shift 效果，如 ":" 而非 ";"）
                    insertText(enPunct)
                    _lastInputIsAlphanumeric = true   // 保留，以便检测下一次是否重复
                    _lastPunctuationKeyCode = keyCode
                }
                return true
            }
        }
        _lastInputIsAlphanumeric = false
        _lastPunctuationKeyCode = nil

        _lastInputText = getPreviousText()
        NSLog("[FireInputController] predictorHandler range, selectionRange: \(selectionRange()), replacementRange: \(replacementRange()), client.selectedRange: \(client().selectedRange()), client.markedRange: \(client().markedRange())")
        NSLog("[FireInputController] predictorHandler previous text, \(_lastInputText)")

        return nil
    }

    private func pageKeyHandler(event: NSEvent) -> Bool? {
        // +/-/arrowdown/arrowup翻页
        let keyCode = event.keyCode
        if inputMode == .zhhans && _originalString.count > 0 {
            let needNextPage = keyCode == kVK_ANSI_Equal ||
                (keyCode == kVK_DownArrow && Defaults[.candidatesDirection] == .horizontal) ||
                (keyCode == kVK_RightArrow && Defaults[.candidatesDirection] == .vertical)
            if needNextPage {
                curPage = _hasNext ? curPage + 1 : curPage
                return true
            }

            let needPrevPage = keyCode == kVK_ANSI_Minus ||
                (keyCode == kVK_UpArrow && Defaults[.candidatesDirection] == .horizontal) ||
                (keyCode == kVK_LeftArrow && Defaults[.candidatesDirection] == .vertical)
            if needPrevPage {
                curPage = curPage > 1 ? curPage - 1 : 1
                return true
            }
        }
        return nil
    }

    private func deleteKeyHandler(event: NSEvent) -> Bool? {
        // 删除键删除字符
        if event.keyCode == kVK_Delete {
            if _originalString.count > 0 {
                _originalString = String(_originalString.dropLast())
                return true
            }
            return false
        }
        return nil
    }

    private func charKeyHandler(event: NSEvent) -> Bool? {
        // 获取输入的字符
        let string = event.characters!

        guard let reg = try? NSRegularExpression(pattern: "^[a-zA-Z]+$") else {
            return nil
        }
        let match = reg.firstMatch(
            in: string,
            options: [],
            range: NSRange(location: 0, length: string.count)
        )

        // 当前没有输入非字符并且之前没有输入字符,不做处理
        if  _originalString.count <= 0 && match == nil {
            NSLog("非字符,不做处理")
            return nil
        }
        // 当前输入的是英文字符,附加到之前
        if match != nil {
            _originalString += string

            return true
        }
        return nil
    }

    private func numberKeyHandlder(event: NSEvent) -> Bool? {
        // 获取输入的字符
        let string = event.characters!
        // 当前输入的是数字,选择当前候选列表中的第N个字符 v
        if let pos = Int(string) {
            if _originalString.count > 0 {
                let index = pos - 1
                if index >= 0 && index < _candidates.count {
                    insertCandidate(_candidates[index])
                } else {
                    _originalString += string
                }
                return true
            }
            if Defaults[.enableWhitespaceBetweenZhEn] && Utils.shared.shouldConcatWithWhitespace(_lastInputText, string) {
                // 中文后输入了数字，先插入一个空格
                insertText(" ")
            }
            _lastInputIsAlphanumeric = true
            _lastPunctuationKeyCode = nil
        }
        return nil
    }

    private func candidateSelectKeyHandler(event: NSEvent) -> Bool? {
        guard inputMode == .zhhans else { return nil }
        guard _originalString.count > 0 else { return nil }
        guard Defaults[.enablePunctuationCandidateSelect] else { return nil }
        // 标点顶屏时，shift+标点键应触发顶屏而非候选选择
        if Defaults[.enablePunctuationTopScreen] && event.modifierFlags.contains(.shift) { return nil }
        let keyCode = event.keyCode
        if keyCode == kVK_ANSI_Semicolon {
            if _candidates.count >= 2 {
                insertCandidate(_candidates[1])
                return true
            }
            return nil
        }
        if keyCode == kVK_ANSI_Quote {
            if _candidates.count >= 3 {
                insertCandidate(_candidates[2])
                return true
            }
            return nil
        }
        return nil
    }

    private func escKeyHandler(event: NSEvent) -> Bool? {
        // ESC键取消所有输入
        if event.keyCode == kVK_Escape, _originalString.count > 0 {
            clean()
            return true
        }
        return nil
    }

    private func enterKeyHandler(event: NSEvent) -> Bool? {
        if event.keyCode == kVK_Return && _originalString.count > 0 {
            if _originalString.first == "`" {
                clean()
            } else {
                insertText(_originalString)
            }
            return true
        }
        return nil
    }

    private func spaceKeyHandler(event: NSEvent) -> Bool? {
        // 空格键输入转换后的中文字符
        if event.keyCode == kVK_Space && _originalString.count > 0 {
            if let first = self._candidates.first {
                insertCandidate(first)
            }
            return true
        }
        return nil
    }

    private func reverseLookupKeyHandler(event: NSEvent) -> Bool? {
        guard inputMode == .zhhans else { return nil }
        guard Defaults[.codeMode] != .pinyin else { return nil }
        if event.keyCode == kVK_ANSI_Grave {
            if _originalString.isEmpty {
                _originalString = "`"
                return true
            }
            if _originalString.first == "`" {
                return true
            }
        }
        return nil
    }

    private func punctuationKeyHandler(event: NSEvent) -> Bool? {
        // 获取输入的字符
        let string = event.characters!
        var punctuationInput = string
        if let base = event.charactersIgnoringModifiers, base.count == 1 {
            if event.modifierFlags.contains(.shift) {
                if base == "1" || event.keyCode == kVK_ANSI_1 {
                    punctuationInput = "!"
                } else if base == "/" || event.keyCode == kVK_ANSI_Slash {
                    punctuationInput = "?"
                }
            } else {
                punctuationInput = base
            }
        }
        guard inputMode == .zhhans else { return nil }

        if !Defaults[.disableTempEnMode]
            && _originalString.count <= 0 && string == String(DictManager.shared.tempEnTriggerPunctuation)
                || string != String(DictManager.shared.tempEnTriggerPunctuation)
                    && _originalString.first == DictManager.shared.tempEnTriggerPunctuation {
            _originalString += string
            return true
        }

        if Defaults[.enablePunctuationTopScreen]
            && _originalString.count > 0
            && _originalString.first != DictManager.shared.tempEnTriggerPunctuation
            && PunctuationConversion.shared.conversion(punctuationInput) != nil {
            let converted = PunctuationConversion.shared.conversion(punctuationInput) ?? punctuationInput
            if let first = _candidates.first, first.type != .placeholder {
                insertText(first.text + converted)
            } else {
                insertText(_originalString + converted)
            }
            return true
        }

        // 如果输入的字符是标点符号，转换标点符号为中文符号
        if inputMode == .zhhans, let result = PunctuationConversion.shared.conversion(punctuationInput) {
            insertText(result)
            return true
        }
        return nil
    }

    // ---- handlers end -------

    override func recognizedEvents(_ sender: Any!) -> Int {
        // 当在当前应用下输入时　NSEvent.addGlobalMonitorForEvents 回调不会被调用，需要针对当前app, 使用原始的方式处理flagsChanged事件
        let isCurrentApp = client().bundleIdentifier() == Bundle.main.bundleIdentifier
        var events = NSEvent.EventTypeMask(arrayLiteral: .keyDown)
        if isCurrentApp {
            events = NSEvent.EventTypeMask(arrayLiteral: .keyDown, .flagsChanged)
        }
        return Int(events.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event else { return false }
        NSLog("[FireInputController] handle: \(event.debugDescription)")

        // 在activateServer中有把IMKInputController绑定给CandidatesWindow
        // 然而在实际运行中发现，在Safari地址栏输入部分原码后，再按shift切到英文输入模式下时，候选窗消失了，但原码没有上屏
        // 排查发现，因为shift切换中英文是通过CandidatesWindow调用绑定的inputController方法实现的，而在safari地址栏时，接受键盘输入的inputController
        // 和CandidatesWindow绑定的inputController并不是同一个，所以出现了此问题
        // 这里猜测之所以会出现不一致，是因为在Safari地址栏输入场景下，会有多个TextInputClient而创建多个inputController, activateServer也会多次执行
        // 但是activateServer的调用顺序并不能保证最后调用的就是接受输入事件的TextInputClient对应的inputController
        // 所以仅是在activateServer中绑定inputController是不行的，需要在此处再绑定一下
        CandidatesWindow.shared.inputController = self

        let handler = Utils.shared.processHandlers(handlers: [
            hotkeyHandler,
            flagChangedHandler,
            enModeHandler,
            predictorHandler,
            pageKeyHandler,
            deleteKeyHandler,
            charKeyHandler,
            numberKeyHandlder,
            candidateSelectKeyHandler,
            escKeyHandler,
            enterKeyHandler,
            spaceKeyHandler,
            reverseLookupKeyHandler,
            punctuationKeyHandler
        ])
        return handler(event) ?? false
    }

    func updateCandidates(_ sender: Any!) {
        if _originalString.first == "`" {
            let pyQuery = String(_originalString.dropFirst())
            if pyQuery.isEmpty {
                _candidates = []
                _hasNext = false
                return
            }
            let (candidates, hasNext) = DictManager.shared.getReverseLookupCandidates(query: pyQuery, page: curPage)
            _candidates = candidates
            _hasNext = hasNext
            return
        }

        let mode = Defaults[.commitMode]
        let count = _originalString.count

        // For M二顶/M三顶, build composite candidates when input length > prefixLength
        if mode == .commitAtM2 || mode == .commitAtM3,
           _originalString.first != DictManager.shared.tempEnTriggerPunctuation {
            let prefixLength = mode == .commitAtM2 ? 2 : 3
            if count > prefixLength {
                let prefix = String(_originalString.prefix(prefixLength))
                let suffix = String(_originalString.dropFirst(prefixLength))
                let (prefixCandidates, _) = Fire.shared.getCandidates(origin: prefix, page: 1)
                let (suffixCandidates, suffixHasNext) = Fire.shared.getCandidates(origin: suffix, page: curPage)
                // First candidate: top of full string
                let (fullCandidates, _) = Fire.shared.getCandidates(origin: _originalString, page: 1)
                var merged: [Candidate] = []
                if let full = fullCandidates.first, full.type != .placeholder {
                    merged.append(full)
                }
                // Composite: prefix top + suffix candidates
                if let prefixTop = prefixCandidates.first, prefixTop.type != .placeholder {
                    for sc in suffixCandidates where sc.type != .placeholder {
                        merged.append(Candidate(
                            code: prefix + sc.code,
                            text: prefixTop.text + sc.text,
                            type: sc.type
                        ))
                    }
                }
                _candidates = merged
                _hasNext = suffixHasNext
                return
            }
        }

        let (candidates, hasNext) = Fire.shared.getCandidates(origin: self._originalString, page: curPage)
        _candidates = candidates
        _hasNext = hasNext
    }

    // 更新候选窗口
    func refreshCandidatesWindow() {
        updateCandidates(client())
        if shouldAutoCommitCandidate() {
            return
        }
        if !Defaults[.showCodeInWindow] && _candidates.count <= 0 {
            // 不在候选框显示输入码时，如果候选词为空，则不显示候选框
            CandidatesWindow.shared.close()
            return
        }
        let candidatesData = (list: _candidates, hasPrev: curPage > 1, hasNext: _hasNext)
        CandidatesWindow.shared.setCandidates(
            candidatesData,
            originalString: _originalString,
            topLeft: getOriginPoint()
        )
    }

    override func selectionRange() -> NSRange {
        if Defaults[.showCodeInWindow] {
            return NSRange(location: 0, length: min(1, _originalString.count))
        }
        return NSRange(location: 0, length: _originalString.count)
    }

    func insertCandidate(_ candidate: Candidate) {
        insertText(candidate.text)
        let notification = Notification(
            name: Fire.candidateInserted,
            object: nil,
            userInfo: [ "candidate": candidate ]
        )
        // 异步派发事件，防止阻塞当前线程
        NotificationQueue.default.enqueue(notification, postingStyle: .whenIdle)
    }

    // 往输入框插入当前字符
    func insertText(_ text: String) {
        NSLog("insertText: %@", text)
        if text.count > 0 {
            var newText = text
            if Defaults[.enableWhitespaceBetweenZhEn] {
                var lastText = getPreviousText()
                if lastText.isEmpty {
                    lastText = _lastInputText
                }
                if lastText.isEmpty {
                    lastText = getPreviousTextIgnoringMarked()
                }
                if Utils.shared.shouldConcatWithWhitespace(lastText, text) {
                    newText = " " + newText
                    NSLog("[FireInputController] insertCandidate should append whitespace: \(newText)")
                }
            }
            let replaceRange = replacementRange()
            let selectedRange = client().selectedRange()
            var insertionLocation: Int?
            if replaceRange.location != NSNotFound {
                if replaceRange.length == 0 {
                    insertionLocation = replaceRange.location
                }
            } else if selectedRange.location != NSNotFound && selectedRange.location < 1_000_000 {
                insertionLocation = selectedRange.location
            }
            let value = NSAttributedString(string: newText)
            client()?.insertText(value, replacementRange: replacementRange())
            _lastInputIsAlphanumeric = newText.last.map { $0.isASCII && ($0.isNumber || $0.isLetter) } ?? false
            _lastPunctuationKeyCode = nil
            _lastCommittedText = newText
            if let insertionLocation = insertionLocation {
                _lastCommittedRange = NSRange(location: insertionLocation, length: newText.count)
            } else {
                _lastCommittedRange = nil
            }
        }
        clean()
    }

    // 往输入框中插入原始字符
    func insertOriginText() {
        if self._originalString.count > 0 {
            self.insertText(self._originalString)
        }
    }

    private func shouldAutoCommitCandidate() -> Bool {
        if _originalString.first == DictManager.shared.tempEnTriggerPunctuation { return false }
        if _originalString.first == "`" { return false }
        let mode = Defaults[.commitMode]
        let maxLen = Defaults[.maxCodeLength]
        let count = _originalString.count
        guard let first = _candidates.first else { return false }
        switch mode {
        case .spaceCommit:
            return false
        case .uniqueAtN:
            if count == maxLen {
                if first.type == .placeholder {
                    clean()
                    return true
                } else if _candidates.count == 1 {
                    insertCandidate(first)
                    return true
                }
            }
            return tryTopScreenByPrefix(prefixLength: maxLen, fullLength: maxLen + 1)
        case .commitAtM:
            return tryTopScreenByPrefix(prefixLength: maxLen, fullLength: maxLen + 1)
        case .emptyCodePush:
            if first.type == .placeholder {
                if count > 1 {
                    let lastChar = String(_originalString.suffix(1))
                    let prefix = String(_originalString.dropLast())
                    let (candidates, _) = Fire.shared.getCandidates(origin: prefix, page: 1)
                    if let candidate = candidates.first, candidate.type != .placeholder {
                        insertCandidate(candidate)
                        _originalString = lastChar
                        return true
                    }
                }
                insertOriginText()
                return true
            }
            return false
        case .emptyCodeDirect:
            if first.type == .placeholder {
                insertOriginText()
                return true
            }
            return false
        case .commitAtM2:
            return tryTopScreenByPrefix(prefixLength: 2, fullLength: maxLen + 1)
        case .commitAtM3:
            return tryTopScreenByPrefix(prefixLength: 3, fullLength: maxLen + 1)
        }
    }

    private func tryTopScreenByPrefix(prefixLength: Int, fullLength: Int) -> Bool {
        guard _originalString.count == fullLength else { return false }
        let prefix = String(_originalString.prefix(prefixLength))
        let remaining = String(_originalString.dropFirst(prefixLength))
        let (candidates, _) = Fire.shared.getCandidates(origin: prefix, page: 1)
        guard let candidate = candidates.first, candidate.type != .placeholder else { return false }
        insertCandidate(candidate)
        _originalString = remaining
        return true
    }

    // 获取当前输入的光标位置
    func getOriginPoint() -> NSPoint {
        let xd: CGFloat = 0
        let yd: CGFloat = 4
        var rect = NSRect()
        client()?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return NSPoint(x: rect.minX + xd, y: rect.minY - yd)
    }

    func clean() {
        NSLog("[FireInputController] clean")
        _originalString = ""
        curPage = 1
        CandidatesWindow.shared.close()
    }

    private func undoLastCommit() -> Bool {
        guard _originalString.isEmpty else { return false }
        guard !_lastCommittedText.isEmpty else { return false }
        let selectedRange = client().selectedRange()
        guard selectedRange.location != NSNotFound && selectedRange.location < 1_000_000 else { return false }
        guard let range = _lastCommittedRange else { return false }
        guard selectedRange.location == range.location + range.length else { return false }
        let previousText = client().attributedSubstring(from: range)?.string ?? ""
        guard previousText == _lastCommittedText else { return false }
        client()?.insertText(NSAttributedString(string: ""), replacementRange: range)
        _lastCommittedText = ""
        _lastCommittedRange = nil
        return true
    }
}
