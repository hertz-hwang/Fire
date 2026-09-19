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
    var _lastCommittedText = ""
    // 最近一次 activateServer 的客户端：身份变化才清撤销栈（跨输入框防护），
    // 同一输入框重复 activate 不清，避免上屏后误清撤销栈
    weak var activateServerClient: IMKTextInput?
    private var _lastInputIsNumber = false
    // 上屏撤销记录：每次真正插入输入框的文字（含自动插入的空格）记一条，
    // 撤销快捷键按栈顶逐条回退，支持多级撤销
    private var _committedRecords: [CommittedRecord] = []
    private static let maxUndoDepth = 10

    /// 上屏撤销记录：文字与其插入起始位置。
    /// location 为 nil 表示上屏时应用未报告位置，撤销时按光标定位并校验文字，
    /// 保证不会误删用户文字
    struct CommittedRecord {
        let text: String
        let location: Int?
        // NSRange 以 UTF-16 单元计，代理对(emoji等)会让 count 与实际长度不一致
        var utf16Length: Int { text.utf16.count }
        /// 学习系统的纠错回退信息（rank ≥ 1 的显式选择才有）
        let learning: CommitLearningInfo?
        /// 该条文字是否已实时写入通道 B（上屏时学习开启且含中文）。
        /// 撤销据此决定是否发 commitUndone，保证负样本与实时学习严格对账：
        /// 学习关闭期间上屏的记录撤销时不产生虚假的计数回退
        let wasLearned: Bool
    }

    /// 学习信号：显式选择非首选时记录的纠错上下文，
    /// 随 CommittedRecord 入撤销栈，撤销时一并回退学习计数
    struct CommitLearningInfo {
        let rank: Int
        let top1Text: String
        let code: String
        let ctx: String
    }

    /// 整句候选全量可见列表（学习信号取 rank/被弃首选用；_candidates 只装当前页）
    private var _sentenceAllCandidates: [Candidate] = []
    /// 待随下一次 insertText 入撤销栈的学习信息（insertCandidate 设置，insertText 消费）
    private var _pendingCommitLearning: CommitLearningInfo?
    private var _lastInputText = ""
    // 待二次确认删除的候选词，非 nil 时候选窗处于删除确认态
    private var _pendingDeleteCandidate: Candidate?
    // 组词模式下当前组合的字数，非 nil 时处于"快速加词"组词态
    private var _combineCount: Int?
    // 整句会话：per-controller（IMK 多 client 多 controller，_originalString 本身就是 per-controller）
    private let _sentenceSession = SentenceSession()
    // 整句候选是否激活（激活时数字键不再把数字追加进编码）
    private var _sentenceActive: Bool = false
    // 整句候选高亮位（Tab / Shift+Tab 循环定位）
    private var _sentenceHighlightIndex: Int = 0
    // 整句解码总候选数（分页用；_candidates 只装当前页）
    private var _sentenceTotalCount = 0
    // 拼音方案分支激活：候选与上屏消耗全部归 PinyinEngine（与整句分支互斥）
    private var _pinyinActive: Bool = false
    // 与 `_candidates` 一一对齐：这条候选上屏要吃掉几个已敲键。
    // 拼音不能按「全部清空」结算：双拼一键一音节、简拼一音节一键，
    // 选一个前缀词时剩下的键要留在组字区继续组句
    private var _pinyinConsumed: [Int] = []
    // 全量可见候选与其消耗键数（学习信号按它取 rank / 被弃首选，顺序与用户所见一致）
    private var _pinyinAll: [Candidate] = []
    private var _pinyinAllConsumed: [Int] = []
    // 组字区显示串（分段拼音，带 `'`）
    private var _pinyinMarked: String = ""

    /// 高亮驱动候选态（整句与拼音共用一套交互：空格上屏高亮项、Tab/方向键循环、-/= 翻页）
    private var highlightDrivenCandidates: Bool { _sentenceActive || _pinyinActive }
    // 候选总页数（页码指示 "n/m" 用；0/1 表示单页不显示）
    private var _pageCount = 0
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
        fireLog("[FireInputController] deinit")
        clean()
    }

    private var _autoCommitTimer: DispatchWorkItem?

    private func scheduleAutoCommit(candidate: Candidate) {
        _autoCommitTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // 定时上屏无提交键，消耗的键数即候选编码长度
            self.insertCandidate(candidate, committedKeys: candidate.code.count)
        }
        _autoCommitTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Defaults[.emptyCodeDirectDelay], execute: item)
    }

    private func cancelAutoCommit() {
        _autoCommitTimer?.cancel()
        _autoCommitTimer = nil
    }

    private var _originalString = "" {
        didSet(oldValue) {
            if oldValue.isEmpty && !_originalString.isEmpty {
                // 组字开始（自动上屏后保留尾码续组字也走这里：那次上屏的
                // clean() 刚把编码清空）：读一次光标前语境，整段组字期内复用
                refreshSentenceContext()
            }
            if oldValue != _originalString {
                // 编码变化即重置整句高亮位与页码
                _sentenceHighlightIndex = 0
                if highlightDrivenCandidates {
                    curPage = 1
                }
            }
            if self.curPage != 1 {
                // code被重新设置时，还原页码为1
                self.curPage = 1
                self.markText()
                return
            }
            fireLog("[FireInputController] original changed: \(self._originalString), refresh window")

            // 建议mark originalString, 否则在某些APP中会有问题
            self.markText()

            self._originalString.count > 0 ? self.refreshCandidatesWindow() : CandidatesWindow.shared.close()
        }
    }
    private var curPage: Int = 1 {
        didSet(old) {
            guard old == self.curPage else {
                fireLog("[FireInputHandler] page changed")
                self.refreshCandidatesWindow()
                return
            }
        }
    }
    func prevPage() {
        if _sentenceActive {
            sentencePage(step: -1)
            return
        }
        self.curPage = self.curPage > 1 ? self.curPage - 1 : 1
    }
    func nextPage() {
        if _sentenceActive {
            sentencePage(step: 1)
            return
        }
        self.curPage = self._hasNext ? self.curPage + 1 : self.curPage
    }

    private func markText() {
        let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: NSNotFound, length: 0))
        if let attributes = attrs as? [NSAttributedString.Key: Any] {
            var selected = self._originalString
            if Defaults[.showCodeInWindow] {
                selected = self._originalString.count > 0 ? " " : ""
            } else if Defaults[.codeInWindowMode] == .firstCandidate && !self._originalString.isEmpty {
                selected = sentenceFocusedCandidate()?.text ?? _candidates.first?.text ?? self._originalString
            } else if let segmented = pinyinPreedit() ?? sentenceSegmentedPreedit() {
                selected = segmented
            }
            let text = NSAttributedString(string: selected, attributes: attributes)
            client()?.setMarkedText(text, selectionRange: selectionRange(), replacementRange: replacementRange())
        }
    }

    /// 整句焦点候选（高亮项），非整句态返回 nil
    private func sentenceFocusedCandidate() -> Candidate? {
        guard highlightDrivenCandidates, _sentenceHighlightIndex < _candidates.count else { return nil }
        return _candidates[_sentenceHighlightIndex]
    }

    /// 整句模式下组字区按焦点候选的分段码显示（如 `sb ear lh mw ajt sba vbz gc`）。
    /// 仅当分段码恰好覆盖全部已敲键时启用——含选重符（`;`/`'`/数字）时
    /// 分段码已剥掉这些键，回退显示原码以免删键时显示与实际不一致。
    private func sentenceSegmentedPreedit() -> String? {
        guard !Defaults[.showCodeInWindow],
              Defaults[.codeInWindowMode] != .firstCandidate,
              !_originalString.isEmpty,
              let focused = sentenceFocusedCandidate(),
              focused.type == .sentence else { return nil }
        let code = focused.code
        guard code != _originalString,
              code.filter({ $0 != " " }) == _originalString.filter({ $0 != " " }) else { return nil }
        return code
    }

    /// 拼音方案的组字区：显示分段后的读音（`ni'hao`）而不是原键。
    /// 双拼下这一步尤其重要——用户敲的是 `nihc`，要看到的是一个拼音词串；
    /// 纠错生效时 `marked` 里已带着被改掉字母的位置（划删除线的信儿）。
    private func pinyinPreedit() -> String? {
        guard _pinyinActive, !_originalString.isEmpty else { return nil }
        return _pinyinMarked.isEmpty ? _originalString : _pinyinMarked
    }

    // 组词模式下用一个空格占位标记合成串，保持合成态，确保方向键等被输入法消费而不传给应用
    private func markCombineText() {
        let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: NSNotFound, length: 0))
        if let attributes = attrs as? [NSAttributedString.Key: Any] {
            let text = NSAttributedString(string: " ", attributes: attributes)
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

    /// 整句 n-gram 左上下文：从光标插入点向前取最多 `count` 个汉字。
    /// 非汉字（标点/空格/英文/数字）跳过不计，只向前回看一小扇窗口；
    /// 位置不可信或读不到文本（应用不实现 attributedSubstring、无权限）
    /// 返回空串，由 SentenceSession.contextText 回落到本会话上屏文字。
    private func leftContextHanText(_ count: Int) -> String {
        guard count > 0, let client = client() else { return "" }
        let selected = client.selectedRange()
        // 部分应用把 location 报成 NSNotFound / 天文数字，这类位置不可信
        guard selected.location != NSNotFound, selected.location >= 0,
              selected.location < 1_000_000 else { return "" }
        // 组字区不算语境：不同 App 的光标基准不一致（备忘录 location 在组字区后、
        // Chrome 在组字区前），与 getPreviousText 一样按合成区长度剥离
        var marked = client.markedRange()
        if marked.location > 1_000_000 { marked = NSRange(location: 0, length: 0) }
        var anchor = selected.location
        if anchor >= marked.location + marked.length {
            anchor -= marked.length
        }
        guard anchor > 0 else { return "" }   // 文档开头：光标前没有文字
        // 一次读回一扇窗口再向前筛，避免逐字多次 IPC
        let window = min(anchor, max(count * 6, 12))
        guard let text = client.attributedSubstring(
            from: NSRange(location: anchor - window, length: window))?.string,
            !text.isEmpty else { return "" }
        var picked: [Character] = []
        for ch in text.reversed() {
            guard ch.isChineseChar else { continue }
            picked.append(ch)
            if picked.count == count { break }
        }
        return String(picked.reversed())
    }

    /// 刷新整句左上下文：读一次光标前语境塞进会话。
    /// 只在组字开始与会话重置后调用——一次组字期内光标不动，逐键重读
    /// 既多一次 IPC，光标抖动还会让解码器的增量 lattice 反复整体作废。
    private func refreshSentenceContext() {
        guard Defaults[.enableSentenceMode] else {
            _sentenceSession.cursorContext = ""
            return
        }
        let depth = min(2, max(0, Defaults[.sentenceContextDepth]))
        _sentenceSession.cursorContext = depth > 0 ? leftContextHanText(depth) : ""
    }

    // ---- handlers begin -----

    private func hotkeyHandler(event: NSEvent) -> Bool? {
        fireLog("[FireInputController] hotkeyHandler")
        if event.type == .flagsChanged {
            return nil
        }
        if let handled = undoCommitHotkeyHandler(event: event) {
            return handled
        }
        if let handled = clearCodeHotkeyHandler(event: event) {
            return handled
        }
        // Ctrl+Shift+数字：从词库删除对应候选词
        // 按住 Shift 时数字键的 charactersIgnoringModifiers 会变成符号(如 Shift+1 -> !)，
        // 无法用 Int 解析，这里改用 keyCode 映射数字
        let digitByKeyCode: [UInt16: Int] = [
            UInt16(kVK_ANSI_1): 1, UInt16(kVK_ANSI_2): 2, UInt16(kVK_ANSI_3): 3,
            UInt16(kVK_ANSI_4): 4, UInt16(kVK_ANSI_5): 5, UInt16(kVK_ANSI_6): 6,
            UInt16(kVK_ANSI_7): 7, UInt16(kVK_ANSI_8): 8, UInt16(kVK_ANSI_9): 9
        ]
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.control, .shift],
           let deleteIndex = digitByKeyCode[event.keyCode],
           deleteIndex <= _candidates.count {
            let target = _candidates[deleteIndex - 1]
            if target.type != .placeholder {
                fireLog("hotkey: control + shift + \(deleteIndex), delete confirm: \(target.text)")
                if _pendingDeleteCandidate == target {
                    // 再按一次同一组合键 = 确认删除
                    confirmDelete(target)
                } else {
                    // 首次按下或切换删除目标，进入二次确认态
                    _pendingDeleteCandidate = target
                    showDeleteConfirm(target)
                }
            }
            return true
        }
        // Ctrl+= ：在无正在输入原码时进入"快速加词"组词模式
        if modifiers == .control, event.keyCode == UInt16(kVK_ANSI_Equal), _originalString.isEmpty {
            if Fire.shared.recentCommittedTexts.count >= 2 {
                _combineCount = 2
                markCombineText()
                showCombinePreview()
            } else {
                Utils.shared.showMessage("请先输入至少两个字，再按 Ctrl+= 组词")
            }
            return true
        }
        guard let charsIgnoring = event.charactersIgnoringModifiers else {
            return nil
        }
        guard let num = Int(charsIgnoring) else { return nil }
        if event.modifierFlags == .control &&
            num > 0 && num <= _candidates.count {
            fireLog("hotkey: control + \(num)")
            DictManager.shared.setCandidateToFirst(query: _originalString, candidate: _candidates[num-1])
            self.curPage = 1
            self.refreshCandidatesWindow()
            return true
        }
        return nil
    }

    private func undoCommitHotkeyHandler(event: NSEvent) -> Bool? {
        if shortcutMatches(event,
                           modifier: Defaults[.undoCommitShortcutModifier],
                           key: Defaults[.undoCommitShortcutKey]) {
            return undoLastCommit()
        }
        return nil
    }

    /// 清空编码串：直接丢弃当前未上屏的编码并清理合成态（不走 Esc 按键路径）。
    /// 无编码时不拦截，保留 Ctrl+C 的复制语义交给应用处理。
    private func clearCodeHotkeyHandler(event: NSEvent) -> Bool? {
        if shortcutMatches(event,
                           modifier: Defaults[.clearCodeShortcutModifier],
                           key: Defaults[.clearCodeShortcutKey]) {
            guard !self._originalString.isEmpty else { return nil }
            fireLog("hotkey: clear code: \(self._originalString)")
            self.clean()
            return true
        }
        return nil
    }

    /// 快捷键匹配：一个修饰键 + 单个按键（与首选项面板的约定一致）
    private func shortcutMatches(_ event: NSEvent,
                                 modifier: ModifierKey,
                                 key: String) -> Bool {
        let required = FireInputController.modifierFlag(for: modifier)
        guard FireInputController.modifiersMatch(event.modifierFlags, required: required) else { return false }
        guard let keyCode = FireInputController.keyCode(for: key.lowercased()) else { return false }
        return event.keyCode == keyCode
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

    // 在候选窗中以 placeholder 形式展示删除确认提示
    private func showDeleteConfirm(_ target: Candidate) {
        let tip = Candidate(
            code: _originalString,  // code 设为原码，避免 getShownCode 显示多余的"()"
            text: "",               // text 置空，防止鼠标点按候选时误插入文字
            type: .placeholder,
            label: "确认删除「\(target.text)」? Enter键确认， Esc键取消"
        )
        CandidatesWindow.shared.setCandidates(
            (list: [tip], hasPrev: false, hasNext: false, page: 1, pageCount: 0),
            originalString: _originalString,
            caretRect: getCaretRect()
        )
    }

    // 确认删除并恢复正常候选窗
    private func confirmDelete(_ target: Candidate) {
        fireLog("[FireInputController] confirmDelete: \(target.text)")
        DictManager.shared.deleteCandidate(target)
        Utils.shared.showMessage("已删除「\(target.text)」")
        _pendingDeleteCandidate = nil
        self.curPage = 1
        self.refreshCandidatesWindow()
    }

    // 删除确认态下的按键处理：回车确认、Esc 取消、组合键透传、其它键取消并照常处理
    private func deleteConfirmHandler(event: NSEvent) -> Bool? {
        guard let pending = _pendingDeleteCandidate else { return nil }
        // 放行 flagsChanged(如 shift 切中英文)，相关清理由 clean() 完成
        if event.type == .flagsChanged { return nil }
        // 回车确认删除
        if event.keyCode == kVK_Return {
            confirmDelete(pending)
            return true
        }
        // 组合键(Ctrl+Shift+数字)透传给 hotkeyHandler 处理：同号确认、换号切目标
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.control, .shift] {
            return nil
        }
        // 其余按键一律取消确认，恢复真实候选
        _pendingDeleteCandidate = nil
        self.refreshCandidatesWindow()
        // Esc 仅取消，不清空已输入的原码
        if event.keyCode == kVK_Escape {
            return true
        }
        // 其它键取消后继续走正常处理链
        return nil
    }

    // 组词模式当前合成的文本(最近 count 个上屏项按原顺序拼接)
    private func combineText(_ count: Int) -> String {
        return Fire.shared.recentCommittedTexts.suffix(count).joined()
    }

    // 在候选窗中以 placeholder 形式预览组词结果及其五笔码
    private func showCombinePreview() {
        guard let count = _combineCount else { return }
        let text = combineText(count)
        // 五笔码显示在候选窗原码区；code 与 origin 保持一致以避免出现多余的"()"
        let codeStr = DictManager.shared.makeWubiWordCode(for: text) ?? "无法取码"
        let tip = Candidate(
            code: codeStr,
            text: "",
            type: .placeholder,
            label: "【\(text)】，←键增字， →键减字，Enter键确认， Esc键取消"
        )
        CandidatesWindow.shared.setCandidates(
            (list: [tip], hasPrev: false, hasNext: false, page: 1, pageCount: 0),
            originalString: codeStr,
            caretRect: getCaretRect()
        )
    }

    // 确认组词：生成五笔码并写入用户词库
    private func confirmCombine() {
        guard let count = _combineCount else { return }
        let text = combineText(count)
        if let code = DictManager.shared.makeWubiWordCode(for: text) {
            _ = DictManager.shared.prependCandidate(
                candidate: Candidate(code: code, text: text, type: .user))
            NotificationQueue.default.enqueue(
                Notification(name: DictManager.userDictUpdated), postingStyle: .whenIdle)
            Utils.shared.showMessage("已添加新词【\(text)】\(code)")
        } else {
            Utils.shared.showMessage("无法为【\(text)】生成编码")
        }
        // clean() 会清空 _originalString 触发 markText 清除组词占位的合成串，并重置 _combineCount、关闭候选窗
        clean()
    }

    // 组词模式下的按键处理：Left 增、Right 减、Enter 确认、Esc 退出，其它键退出后照常处理
    private func combineHandler(event: NSEvent) -> Bool? {
        guard let count = _combineCount else { return nil }
        if event.type == .flagsChanged { return nil }
        let bufCount = Fire.shared.recentCommittedTexts.count
        switch Int(event.keyCode) {
        case kVK_LeftArrow:
            _combineCount = min(count + 1, bufCount)
            showCombinePreview()
            return true
        case kVK_RightArrow:
            _combineCount = max(count - 1, 2)
            showCombinePreview()
            return true
        case kVK_Return:
            confirmCombine()
            return true
        case kVK_Escape:
            clean()
            return true
        default:
            // 其它键退出组词模式后继续走正常处理链
            clean()
            return nil
        }
    }

     func flagChangedHandler(event: NSEvent) -> Bool? {
         fireLog("[FireInputController] flagChangedHandler")
        // 固定方向切换: 左Shift轻点切英文、右Shift轻点切中文
        // 开启后左右Shift均不再用于中/英互相轮换;
        // 若轮换快捷键配置为非Shift键(如control)，该键的轮换仍照常生效
        if !Defaults[.disableEnMode] && Defaults[.leftShiftToEnRightShiftToZh] {
            let targetMode: InputMode?
            if Utils.shared.leftShiftKeyUpChecker.check(event) {
                targetMode = .enUS
            } else if Utils.shared.rightShiftKeyUpChecker.check(event) {
                targetMode = .zhhans
            } else {
                targetMode = nil
            }
            if let targetMode = targetMode {
                fireLog("[FireInputController]shift fixed toggle: \(inputMode) -> \(targetMode)")
                // 把当前未上屏的原始code上屏处理
                insertText(_originalString)
                Fire.shared.toggleInputMode(targetMode)
                return true
            }
        }
        // 只有在shift keyup时，才切换中英文输入, 否则会导致shift+[a-z]大写的功能失效
        let toggleKey = Defaults[.toggleInputModeKey]
        let rotationUsesShift = toggleKey == .shift || toggleKey == .leftShift || toggleKey == .rightShift
        if !Defaults[.disableEnMode]
            && !(Defaults[.leftShiftToEnRightShiftToZh] && rotationUsesShift)
            && Utils.shared.toggleInputModeKeyUpChecker.check(event) {
            fireLog("[FireInputController]toggle mode: \(inputMode)")

            // 把当前未上屏的原始code上屏处理
            insertText(_originalString)

            Fire.shared.toggleInputMode()
            return true
        }
        // 监听.flagsChanged事件只为切换中英文，其它情况不处理需要返回 false 以避免快捷键不生效
        // 放行规则：先把 Shift / CapsLock 这类不属于"快捷键修饰键"的位剔除，再要求剩余位
        //   - 为空(无修饰键，如 a、,、.)，或
        //   - 恰好是 .numericPad|.function (方向键、用于翻页)
        // 其它情况（含 Cmd/Ctrl/Option/单独 .function 的 F 键、单独 .numericPad 的数字小键盘等）
        // 全部交给系统处理，避免无谓的 handler 链空跑(predictorHandler 会读 client 的 IPC 状态)。
        // Shift / CapsLock 必须放行的原因：
        //   - Shift+标点是常规中文标点输入路径(Shift+1=! 等)，需要继续走到 punctuationKeyHandler 完成全角转换
        //   - Shift+字母由 charKeyHandler 处理(commit 0b51393 起，大写字母会被附加到原码而不直接上屏)
        // .deviceIndependentFlagsMask 用来过滤低位"设备相关"标志，避免极少数键盘场景下的脏数据误判。
        // 关联 issue #149 #152，回归源 commit 2d66064。
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.shift, .capsLock])
        if event.type == .flagsChanged || (
            !modifiers.isEmpty
            && modifiers != .init(arrayLiteral: .numericPad, .function)
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
            fireLog("[FireInputController] flagChangedHandler no need handle")
            return false
        }
        return nil
    }

    private func enModeHandler(event: NSEvent) -> Bool? {
        fireLog("[FireInputController] enModeHandler")
        // 英文输入模式, 不做任何处理
        if inputMode == .enUS {
            if Defaults[.enableWhitespaceBetweenZhEn],
               _originalString.isEmpty,
               let string = event.characters,
               FireInputController.alphanumericReg?
                    .firstMatch(in: string, options: [], range: NSRange(location: 0, length: string.utf16.count)) != nil {
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
               punctuation.keys.contains(base),
               !(!Defaults[.disableTempEnMode] && inputMode == .zhhans && chars == String(DictManager.shared.tempEnTriggerPunctuation)) {
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

        // 在数字后输入“：”，自动转为英文半角冒号
        if Defaults[.enableColonAfterNumber] && event.keyCode == kVK_ANSI_Semicolon && _lastInputIsNumber {
            insertText(":")
            _lastInputIsNumber = false
            return true
        }
        _lastInputIsNumber = false

        _lastInputText = getPreviousText()
        fireLog("[FireInputController] predictorHandler range, selectionRange: \(selectionRange()), replacementRange: \(replacementRange()), client.selectedRange: \(client().selectedRange()), client.markedRange: \(client().markedRange())")

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
                if highlightDrivenCandidates {
                    if keyCode == kVK_ANSI_Equal {
                        sentencePage(step: 1)
                    } else {
                        cycleSentenceHighlight(step: 1)
                    }
                    return true
                }
                curPage = _hasNext ? curPage + 1 : curPage
                return true
            }

            let needPrevPage = keyCode == kVK_ANSI_Minus ||
                (keyCode == kVK_UpArrow && Defaults[.candidatesDirection] == .horizontal) ||
                (keyCode == kVK_LeftArrow && Defaults[.candidatesDirection] == .vertical)
            if needPrevPage {
                if highlightDrivenCandidates {
                    if keyCode == kVK_ANSI_Minus {
                        sentencePage(step: -1)
                    } else {
                        cycleSentenceHighlight(step: -1)
                    }
                    return true
                }
                curPage = curPage > 1 ? curPage - 1 : curPage
                return true
            }
        }
        return nil
    }

    /// 整句候选高亮循环（Tab/Shift+Tab、方向键共用），页内回绕
    private func cycleSentenceHighlight(step: Int) {
        if _sentenceActive {
            SentenceEngine.shared.suspendAutoCommit(_sentenceSession)
        }
        guard _candidates.count > 0 else { return }
        _sentenceHighlightIndex = (_sentenceHighlightIndex + step + _candidates.count) % _candidates.count
        refreshCandidatesWindow()
    }

    /// 整句候选翻页（-/= 与候选窗翻页按钮共用）；高亮落到新页首个候选。
    /// -/= 只翻页：已在边缘页时不做任何事（页内循环归 Tab/方向键管）。
    /// curPage 的 didSet 会触发 refreshCandidatesWindow，句柄分支按页重组候选。
    private func sentencePage(step: Int) {
        if _sentenceActive {
            SentenceEngine.shared.suspendAutoCommit(_sentenceSession)
        }
        let pageSize = max(1, Defaults[.candidateCount])
        let total = _pinyinActive ? _pinyinAll.count : _sentenceTotalCount
        let pageCount = max(1, (total + pageSize - 1) / pageSize)
        let target = curPage + step
        guard target >= 1, target <= pageCount, target != curPage else { return }
        _sentenceHighlightIndex = 0
        curPage = target
    }

    private func deleteKeyHandler(event: NSEvent) -> Bool? {
        // 删除键删除字符
        if event.keyCode == kVK_Delete {
            if _originalString.count > 0 {
                _originalString = String(_originalString.dropLast())
                // 整句：删键后证据作废（会话保留，继续敲可重新积累）；拼音不走那套证据
                if _sentenceActive || (Defaults[.enableSentenceMode] && Defaults[.codeMode] != .pinyin) {
                    SentenceEngine.shared.evidenceInvalidated(_sentenceSession)
                }
                return true
            }
            return false
        }
        return nil
    }

    // 每次按键都会走 charKeyHandler，正则编译一次后复用，避免热路径反复 new NSRegularExpression
    private static let alphaReg = try? NSRegularExpression(pattern: "^[a-zA-Z]+$")
    private static let alphanumericReg = try? NSRegularExpression(pattern: "^[a-zA-Z0-9]+$")

    private func charKeyHandler(event: NSEvent) -> Bool? {
        // 获取输入的字符
        let string = event.characters!

        guard let reg = FireInputController.alphaReg else {
            return nil
        }
        let match = reg.firstMatch(
            in: string,
            options: [],
            range: NSRange(location: 0, length: string.utf16.count)
        )

        // 当前没有输入非字符并且之前没有输入字符,不做处理
        if  _originalString.count <= 0 && match == nil {
            fireLog("非字符,不做处理")
            return nil
        }
        // 当前输入的是英文字符,附加到之前
        if match != nil {
            // 整句：组字区编码超过上限不再吸收新键（把键交回系统）
            if _sentenceActive && _originalString.count >= SentenceConfig.maxRawLength {
                return nil
            }
            // 拼音：同样设长度上限。引擎每键从头重解，开销随音节数涨，
            // 不封顶时长串能把主线程拖住（上限 40 键 ≈ 20 个音节，比参考实现的
            // 纠错上界宽一倍，正常句子远碰不到）
            if _pinyinActive && _originalString.count >= PinyinEngine.maxRawKeys {
                return nil
            }
            // 常规码表（非整句）：已达最大码长且候选为空时，下一码丢弃旧串，
            // 本码成为新一串的首位编码（如 `dkku` 无候选，再敲 `v` 组字区只剩 `v`）。
            // 空码顶字/空码直接上屏有自己的清屏规则，反查与临时英文不参与。
            if !Defaults[.enableSentenceMode],
               !_sentenceActive,
               _originalString.first != "`",
               _originalString.first != DictManager.shared.tempEnTriggerPunctuation,
               Defaults[.commitMode] != .emptyCodePush,
               Defaults[.commitMode] != .emptyCodeDirect,
               _originalString.count >= Defaults[.maxCodeLength],
               _candidates.isEmpty || _candidates.first?.type == .placeholder {
                _originalString = string
                return true
            }
            // 追加前 _sentenceActive / emptyCodePending 还是上一键留下的状态（didSet 未跑）。
            // 收窄门控：只有上一键整句仍有候选、或会话里仍留有挂起的空码捕获，
            // 才继续把键喂给自动上屏；整句分支已松手（回落普通词候选且无捕获）则不喂。
            let sentenceAliveBeforeKey = _sentenceActive || _sentenceSession.emptyCodePending != nil
            _originalString += string

            // 整句自动上屏：先空码型，再概率型。
            // 保护用户自定义短语：当前编码仍是某个用户码的前缀（如还没打完
            // `date`）时不自动上屏，等编码完整命中后置顶让用户选择。
            // 门控不能只看 _sentenceActive：本键使编码变为空码时，didSet 里先跑的
            // updateCandidates 会因整句解码为空回落普通词候选，把 _sentenceActive
            // 置 false（如琉璃 fl+o → flo），空码上屏会永远等不到这一键。
            // 但补判也不能宽成"引擎可用就喂"：死码段会白白累计键数/证据，
            // 出字时机也可能被不相干的键带偏；只保留"上一键还活着"的一键续喂窗口
            // （emptyCodePending 覆盖捕获后暂缓截断、跨键等待出字的链式场景）。
            if _sentenceActive || (sentenceBranchAllowed() && sentenceAliveBeforeKey) {
                let raw = _originalString
                if DictManager.shared.hasUserDictPrefix(matching: raw) {
                    SentenceEngine.shared.evidenceInvalidated(_sentenceSession)
                } else if let commit = SentenceEngine.shared.keyPressed(
                    session: _sentenceSession, raw: raw, appendedLetter: true) {
                    autoCommitSentenceText(commit)
                    return true
                }
            }
            return true
        }
        // 拼音：`'` 是分词符（`xi'an` 不让它读成「先」），微软/搜狗类方案的 `;` 是 `ing` 键位，
        // 两者都要进缓冲区；其余标点交回 punctuationKeyHandler 出中文标点。
        if _pinyinActive, string == "'" || (string == ";" && PinyinEngineCenter.shared.engine.usesSemicolon) {
            if _originalString.count >= PinyinEngine.maxRawKeys {
                return nil
            }
            _originalString += string
            return true
        }
        // 整句激活时 ;/' 是选重符（虎整句 alphabet），吸收进编码固定用字但不上屏；
        // 空闲时交回 punctuationKeyHandler 出标点
        if _sentenceActive, string == ";" || string == "'" {
            if _originalString.count >= SentenceConfig.maxRawLength {
                return nil
            }
            _originalString += string
            SentenceEngine.shared.evidenceInvalidated(_sentenceSession)
            return true
        }
        return nil
    }

    // 整句自动上屏：插入文字，组字区只保留未消费的键
    private func autoCommitSentenceText(_ commit: SentenceAutoCommit) {
        let text = commit.text
        // 统计需要真实编码：insertText 的 clean() 会清空 _originalString，
        // 先在此捕获上屏前完整 raw，上屏消耗掉的编码 = raw 去掉 retainedRaw 后缀
        let rawBefore = _originalString
        insertText(text)
        // insertText 内部 clean() 会清空 _originalString，这里恢复未消费的尾码
        _originalString = commit.retainedRaw
        if commit.retainedRaw.isEmpty {
            CandidatesWindow.shared.close()
        }
        notifySentenceCommit(text, code: autoCommitCode(rawBefore: rawBefore))
    }

    /// 自动上屏消耗掉的原始编码（raw 的前缀，长度为 raw − retainedRaw）
    private func autoCommitCode(rawBefore: String) -> String {
        let retained = _originalString
        let consumedLength = max(0, min(rawBefore.count, rawBefore.count - retained.count))
        return String(rawBefore.prefix(consumedLength))
    }

    // 自动上屏计入统计，否则"统计"里会漏掉整句自动上屏的字数
    // code 必须是实际消耗的编码（而非上屏文字），否则"平均码长"会把文字长度当码长
    private func notifySentenceCommit(_ text: String, code: String) {
        let candidate = Candidate(code: code, text: text, type: .sentence)
        if text.contains(where: { $0.isChineseChar }) {
            Fire.shared.recentCommittedTexts.append(text)
            if Fire.shared.recentCommittedTexts.count > 20 {
                Fire.shared.recentCommittedTexts.removeFirst()
            }
        }
        NotificationQueue.default.enqueue(
            Notification(name: Fire.candidateInserted,
                        object: nil,
                        userInfo: ["candidate": candidate,
                                  "appBundleId": client()?.bundleIdentifier() ?? "",
                                  // 自动上屏无提交键，键数 = 实际消耗的编码长度
                                  "keyCount": max(1, code.count),
                                  // 自动上屏恒为首选：学习信号记 rank 0（通道 B 记账用）
                                  "rank": 0, "top1Text": "", "rawCode": code, "ctx": ""]),
            postingStyle: .whenIdle)
    }

    private func numberKeyHandlder(event: NSEvent) -> Bool? {
        // 获取输入的字符
        let string = event.characters!
        // 当前输入的是数字,选择当前候选列表中的第N个字符 v
        if let pos = Int(string) {
            if _originalString.count > 0 {
                // 整句激活时数字照常选候选（虎整句"数字当选重符"的语义已取消）；
                // 越界数字吞掉，避免数字混进编码被 parse_selector 当选重符解析
                if highlightDrivenCandidates {
                    let index = pos - 1
                    if index >= 0 && index < _candidates.count {
                        insertCandidate(_candidates[index])
                    }
                    return true
                }
                let index = pos - 1
                if index >= 0 && index < _candidates.count {
                    insertCandidate(_candidates[index])
                } else {
                    _originalString += string
                }
                return true
            }
            if Defaults[.enableWhitespaceBetweenZhEn] && Utils.shared.shouldConcatWithWhitespace(_lastCommittedText, string) {
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
        // 整句/拼音激活时 ;/' 不选词（拼音的 `'` 是分词符、`;` 在部分双拼方案里是键位）
        if highlightDrivenCandidates { return nil }
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

    private func isTempEnModeActive() -> Bool {
        !Defaults[.disableTempEnMode]
            && !_originalString.isEmpty
            && _originalString.first == DictManager.shared.tempEnTriggerPunctuation
    }

    private func enterKeyHandler(event: NSEvent) -> Bool? {
        if event.keyCode == kVK_Return && _originalString.count > 0 {
            if _originalString.first == "`" {
                clean()
            } else if isTempEnModeActive(), let first = _candidates.first {
                insertCandidate(first)
            } else {
                insertText(_originalString)
            }
            return true
        }
        return nil
    }

    private func spaceKeyHandler(event: NSEvent) -> Bool? {
        // 空格键输入转换后的中文字符（整句时上屏当前高亮候选）
        if event.keyCode == kVK_Space && _originalString.count > 0 {
            if let selected = sentenceSelectedCandidate() {
                insertCandidate(selected)
            }
            return true
        }
        return nil
    }

    /// 当前应上屏的候选：整句激活时为高亮项，否则为首选
    private func sentenceSelectedCandidate() -> Candidate? {
        if _sentenceActive, _sentenceHighlightIndex < _candidates.count {
            return _candidates[_sentenceHighlightIndex]
        }
        return _candidates.first
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

    private func extraCandidateKeyHandler(event: NSEvent) -> Bool? {
        guard inputMode == .zhhans,
              _originalString.count > 0,
              !isTempEnModeActive(),
              let string = event.characters else {
            return nil
        }
        // 整句激活时额外选择键不选词（虎整句用 Tab 循环定位）
        if highlightDrivenCandidates { return nil }

        let mode = Defaults[.extraCandidateSelectKeys]
        guard mode != .disabled else { return nil }

        let index: Int?
        switch mode {
        case .semicolonQuote:
            switch string {
            case ";": index = 1
            case "'": index = 2
            default: index = nil
            }
        case .commaPeriod:
            switch string {
            case ",": index = 1
            case ".": index = 2
            default: index = nil
            }
        case .disabled:
            index = nil
        }

        guard let index = index, index < _candidates.count else {
            return nil
        }

        insertCandidate(_candidates[index])
        return true
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
            if let selected = sentenceSelectedCandidate(), selected.type != .placeholder {
                insertText(selected.text + converted)
            } else {
                insertText(_originalString + converted)
            }
            return true
        }

        // 如果输入的字符是标点符号，转换标点符号为中文符号
        if inputMode == .zhhans, let result = PunctuationConversion.shared.conversion(punctuationInput) {
            if _originalString.count > 0,
               !isTempEnModeActive(),
               let selected = sentenceSelectedCandidate(),
               selected.type != .placeholder {
                insertCandidate(selected)
                insertText(result)
            } else {
                insertText(result)
            }
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
        fireLog("[FireInputController] handle: \(event.debugDescription)")

        // 在activateServer中有把IMKInputController绑定给CandidatesWindow
        // 然而在实际运行中发现，在Safari地址栏输入部分原码后，再按shift切到英文输入模式下时，候选窗消失了，但原码没有上屏
        // 排查发现，因为shift切换中英文是通过CandidatesWindow调用绑定的inputController方法实现的，而在safari地址栏时，接受键盘输入的inputController
        // 和CandidatesWindow绑定的inputController并不是同一个，所以出现了此问题
        // 这里猜测之所以会出现不一致，是因为在Safari地址栏输入场景下，会有多个TextInputClient而创建多个inputController, activateServer也会多次执行
        // 但是activateServer的调用顺序并不能保证最后调用的就是接受输入事件的TextInputClient对应的inputController
        // 所以仅是在activateServer中绑定inputController是不行的，需要在此处再绑定一下
        CandidatesWindow.shared.inputController = self

        let handler = Utils.shared.processHandlers(handlers: [
            deleteConfirmHandler,
            combineHandler,
            hotkeyHandler,
            flagChangedHandler,
            enModeHandler,
            predictorHandler,
            tabKeyHandler,
            pageKeyHandler,
            deleteKeyHandler,
            charKeyHandler,
            numberKeyHandlder,
            candidateSelectKeyHandler,
            escKeyHandler,
            enterKeyHandler,
            spaceKeyHandler,
            reverseLookupKeyHandler,
            extraCandidateKeyHandler,
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
                _pageCount = 0
                _sentenceActive = false
                return
            }
            let (candidates, hasNext) = DictManager.shared.getReverseLookupCandidates(query: pyQuery, page: curPage)
            _candidates = candidates
            _hasNext = hasNext
            _pageCount = resolvePageCount(hasNext: hasNext) {
                DictManager.shared.getReverseLookupCandidatesCount(query: pyQuery)
            }
            _sentenceActive = false
            return
        }

        let mode = Defaults[.commitMode]
        let count = _originalString.count

        // For M二顶/M三顶, build composite candidates when input length > prefixLength
        // 整句可用时不走常规顶字组词：候选与编码消费完全归整句引擎
        if mode == .commitAtM2 || mode == .commitAtM3,
           _originalString.first != DictManager.shared.tempEnTriggerPunctuation,
           !sentenceBranchAllowed() {
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
                _pageCount = resolvePageCount(hasNext: suffixHasNext) {
                    DictManager.shared.getCandidatesCount(query: suffix)
                }
                _sentenceActive = false
                return
            }
        }

        // 拼音方案分支：候选与编码消费全部归拼音引擎（切分 / 简拼 / 模糊音 / 纠错 / 双拼）。
        // 位置在整句分支之前：拼音的「整句」就是引擎的首条 Sentence 候选，
        // 不再走虎整句边表；引擎未就绪（首次载入索引的百多毫秒）时回落到普通词库分支。
        if Defaults[.codeMode] == .pinyin, updatePinyinCandidates() {
            return
        }

        // 整句分支：可用时候选栏全部来自整句引擎（z键重复上屏等特例除外）
        if Defaults[.enableSentenceMode] {
            SentenceEngine.shared.prepareIfNeeded()
            if sentenceBranchAllowed() {
                // 词表换代或设置变更（整句/自动上屏开关）后重置会话
                if _sentenceSession.engineEpoch != SentenceEngine.shared.epoch {
                    SentenceEngine.shared.resetSession(_sentenceSession)
                    _sentenceSession.engineEpoch = SentenceEngine.shared.epoch
                    _sentenceSession.lexiconGeneration = SentenceLexicon.shared.generation
                    // resetSession 清空了光标前语境（滑杆改语境字数也会走到这里），
                    // 当前编码还在继续组字，立刻补读一次
                    refreshSentenceContext()
                }
                if let result = SentenceEngine.shared.candidates(
                    session: _sentenceSession, raw: _originalString) {
                    _sentenceActive = true
                    // 用户自定义短语与整句候选按文字归并（text-keyed consolidation）：
                    // 同一文字只占一个槽位——整句已产出的（如 `edfrw` 的「逸码」）
                    // 复用整句候选（保留分段码与语境得分）并提到首组，不新增重复槽位；
                    // 整句没覆盖的纯用户短语（如 `date {yyyy}{MM}{dd}`）才新开槽位。
                    let userMatches = DictManager.shared.getUserCandidates(matching: _originalString)
                    var userTexts = Set<String>()
                    for user in userMatches { userTexts.insert(user.text) }
                    // 「候选词数量」照常生效：整句候选按页切，-/= 翻页，
                    // Tab/方向键在页内循环高亮
                    let all = result.candidates
                    _sentenceTotalCount = all.count
                    // 全量可见列表（学习信号按它取 rank 与被弃首选；
                    // 顺序与用户所见一致：用户短语在首页首组，其余整句候选接后）
                    // 「显示打分」开启时附带各维度加权得分串
                    let scoreEnabled = Defaults[.enableSentenceScore]
                    let allSentenceCandidates = all.map { completed in
                        Candidate(code: completed.segmented.isEmpty ? _originalString : completed.segmented,
                                  text: completed.text,
                                  type: .sentence,
                                  scoreText: scoreEnabled ? completed.dimensions.displayText() : nil)
                    }
                    if userMatches.isEmpty {
                        _sentenceAllCandidates = allSentenceCandidates
                    } else {
                        var byText: [String: Candidate] = [:]
                        for c in allSentenceCandidates { byText[c.text] = c }
                        var fullVisible: [Candidate] = []
                        if curPage == 1 {
                            for user in userMatches {
                                fullVisible.append(byText[user.text] ?? user)
                            }
                        }
                        fullVisible.append(contentsOf: allSentenceCandidates.filter { !userTexts.contains($0.text) })
                        _sentenceAllCandidates = fullVisible
                    }
                    let pageSize = max(1, Defaults[.candidateCount])
                    let pageCount = max(1, (all.count + pageSize - 1) / pageSize)
                    if curPage > pageCount { curPage = pageCount }
                    let start = (curPage - 1) * pageSize
                    let pageItems = Array(all[start..<min(start + pageSize, all.count)])
                    let pageCandidates = pageItems.map { completed in
                        Candidate(code: completed.segmented.isEmpty ? _originalString : completed.segmented,
                                  text: completed.text,
                                  type: .sentence,
                                  scoreText: scoreEnabled ? completed.dimensions.displayText() : nil)
                    }
                    var list: [Candidate]
                    if userMatches.isEmpty {
                        list = pageCandidates
                    } else {
                        // 首组按用户词库存放顺序；命中整句的复用整句候选对象
                        var byText: [String: Candidate] = [:]
                        for c in pageCandidates { byText[c.text] = c }
                        var frontGroup: [Candidate] = []
                        if curPage == 1 {
                            for user in userMatches {
                                frontGroup.append(byText[user.text] ?? user)
                            }
                        }
                        // 其余页同样剔除同名槽位（槽位全局唯一，已摆在首页首组）
                        let rest = pageCandidates.filter { !userTexts.contains($0.text) }
                        list = frontGroup + rest
                        // 清证据防止紧随其后的键抢先提前上屏（短语已在榜首，等显式选择）
                        SentenceEngine.shared.evidenceInvalidated(_sentenceSession)
                    }
                    _candidates = list
                    _hasNext = curPage < pageCount
                    _pageCount = pageCount
                    if _sentenceHighlightIndex >= _candidates.count {
                        _sentenceHighlightIndex = max(0, _candidates.count - 1)
                    }
                    return
                }
                // 编码含选重符（锁定用字）时不回落到普通词候选——
                // 虎整句里带选重符的输入只由整句方案消化，无可解时保持空菜单
                if SentenceEngine.containsSelector(_originalString) {
                    _candidates = []
                    _hasNext = false
                    _pageCount = 0
                    _sentenceActive = true
                    _sentenceHighlightIndex = 0
                    _sentenceTotalCount = 0
                    curPage = 1
                    return
                }
            }
        }
        _sentenceActive = false

        let (candidates, hasNext) = Fire.shared.getCandidates(origin: self._originalString, page: curPage)
        _candidates = candidates
        _hasNext = hasNext
        _pageCount = resolvePageCount(hasNext: hasNext) {
            DictManager.shared.getCandidatesCount(query: self._originalString)
        }
    }

    /// 页码指示的总页数：单页菜单不查总数（最常见路径零开销）；
    /// 多页时才查一次候选总数。总数因过滤可能略偏小时以当前页码兜底，
    /// 保证指示器不会出现 "n > m"。
    /// 候选在全量可见列表里的序号（拼音）：页内候选与全量列表按 text+code 对齐，
    /// 同名不同码（同一个词的不同读音）不能互相顶名。
    private func visiblePinyinIndex(of candidate: Candidate) -> Int? {
        _pinyinAll.firstIndex { $0.text == candidate.text && $0.code == candidate.code }
            ?? _pinyinAll.firstIndex { $0.text == candidate.text }
    }

    private func resolvePageCount(hasNext: Bool, totalProvider: () -> Int) -> Int {
        if !hasNext && curPage <= 1 { return 1 }
        let pageSize = max(1, Defaults[.candidateCount])
        let total = totalProvider()
        guard total > 0 else { return 1 }
        return max(curPage, (total + pageSize - 1) / pageSize)
    }

    /// 拼音候选分支：查询引擎、并入用户自定义短语、按页切候选。
    /// 返回 false = 本分支不接手（索引未就绪 / 这串键解不出东西），
    /// 调用方继续走常规码表——宁可不智能，不能打不出字。
    private func updatePinyinCandidates() -> Bool {
        func standDown() -> Bool {
            _pinyinActive = false
            _pinyinAll = []
            _pinyinAllConsumed = []
            _pinyinConsumed = []
            _pinyinMarked = ""
            return false
        }
        guard Defaults[.codeMode] == .pinyin, !_originalString.isEmpty else { return standDown() }
        guard !isTempEnModeActive(), _originalString.first != "`" else { return standDown() }
        let center = PinyinEngineCenter.shared
        center.prepareIfNeeded()
        guard center.ready else { return standDown() }

        let context = Defaults[.enableSentenceMode] ? _sentenceSession.contextText : ""
        guard let composing = center.engine.compose(_originalString, leftContext: context),
              !composing.candidates.isEmpty else {
            return standDown()
        }
        _pinyinMarked = composing.marked

        // 用户自定义短语按「解出来的拼音」命中：双拼下用户短语表里的码仍是全拼，
        // 拿敲的键去比对会一条也对不上。命中即置顶并吃掉全部已敲键（短语本来就是整码替换）
        let phraseScope = composing.decoded.map { $0.pinyin } ?? _originalString
        let userMatches = phraseScope.isEmpty ? [] : DictManager.shared.getUserCandidates(matching: phraseScope)
        var userTexts = Set<String>()
        for user in userMatches { userTexts.insert(user.text) }

        var all: [Candidate] = []
        var consumed: [Int] = []
        if !userMatches.isEmpty {
            for user in userMatches {
                all.append(user)
                consumed.append(_originalString.count)
            }
        }
        for item in composing.candidates where !userTexts.contains(item.text) {
            all.append(Candidate(code: item.code.isEmpty ? _originalString : item.code,
                                 text: item.text,
                                 type: item.isSentence ? .sentence : .py))
            consumed.append(max(1, min(item.consumedKeys, _originalString.count)))
        }
        guard !all.isEmpty else { return standDown() }

        _pinyinAll = all
        _pinyinAllConsumed = consumed
        let pageSize = max(1, Defaults[.candidateCount])
        let pageCount = max(1, (all.count + pageSize - 1) / pageSize)
        if curPage > pageCount { curPage = pageCount }
        let start = (curPage - 1) * pageSize
        let end = min(start + pageSize, all.count)
        _candidates = Array(all[start ..< end])
        _pinyinConsumed = Array(consumed[start ..< end])
        _hasNext = curPage < pageCount
        _pageCount = pageCount
        if _sentenceHighlightIndex >= _candidates.count {
            _sentenceHighlightIndex = max(0, _candidates.count - 1)
        }
        _pinyinActive = true
        _sentenceActive = false
        return true
    }

    /// 整句候选分支是否可用：开关 + 引擎可用 + 不落入各特例早退分支。
    /// 拼音方案不走这里：它的整句由 `PinyinEngine` 自己出（候选栏里第 1 条），
    /// 把拼音键送进虎整句边表只会整句全打不中。
    private func sentenceBranchAllowed() -> Bool {
        guard Defaults[.enableSentenceMode] else { return false }
        guard Defaults[.codeMode] != .pinyin else { return false }
        guard _originalString.first != "`" else { return false }
        guard !isTempEnModeActive() else { return false }
        if Defaults[.zKeyRepeat] && _originalString == "z" { return false }
        return SentenceEngine.shared.available
    }

    /// Tab / Shift+Tab 循环定位整句 / 拼音候选
    private func tabKeyHandler(event: NSEvent) -> Bool? {
        guard event.keyCode == kVK_Tab, inputMode == .zhhans else { return nil }
        guard highlightDrivenCandidates, _candidates.count > 1 else { return nil }
        // 与虎整句一致：手动选候选时挂起自动上屏（拼音本来就没有自动上屏）
        if _sentenceActive {
            SentenceEngine.shared.suspendAutoCommit(_sentenceSession)
        }
        let step = event.modifierFlags.contains(.shift) ? -1 : 1
        _sentenceHighlightIndex = (_sentenceHighlightIndex + step + _candidates.count) % _candidates.count
        refreshCandidatesWindow()
        return true
    }

    // 更新候选窗口
    func refreshCandidatesWindow() {
        updateCandidates(client())
        if shouldAutoCommitCandidate() {
            return
        }
        if Defaults[.hideCandidatesWindow] {
            CandidatesWindow.shared.close()
            return
        }
        if !Defaults[.showCodeInWindow] && _candidates.count <= 0 {
            // 不在候选框显示输入码时，如果候选词为空，则不显示候选框
            CandidatesWindow.shared.close()
            return
        }
        let candidatesData = (list: _candidates, hasPrev: curPage > 1, hasNext: _hasNext,
                              page: curPage, pageCount: _pageCount)
        CandidatesWindow.shared.setCandidates(
            candidatesData,
            originalString: _originalString,
            caretRect: getCaretRect(),
            highlightIndex: _sentenceActive ? _sentenceHighlightIndex : 0
        )
        // 候选词更新后重新 mark，确保组字区跟随焦点候选：
        // 「显示首选项」模式下显示焦点候选文字；整句态刷新分段码空格分组。
        // 非整句且非首选项模式时组字区不随候选变化，省一次 setMarkedText IPC。
        if !Defaults[.showCodeInWindow],
           Defaults[.codeInWindowMode] == .firstCandidate || _sentenceActive {
            markText()
        }
    }

    override func selectionRange() -> NSRange {
        if _combineCount != nil {
            // 组词模式下为 1 长度的占位合成串，与 markCombineText 保持一致
            return NSRange(location: 0, length: 1)
        }
        if Defaults[.showCodeInWindow] {
            return NSRange(location: 0, length: min(1, _originalString.count))
        }
        if Defaults[.codeInWindowMode] == .firstCandidate {
            // 与 markText 保持一致：整句态下取焦点候选，否则取首选
            let selected = sentenceFocusedCandidate() ?? _candidates.first
            if let selected = selected {
                return NSRange(location: 0, length: selected.text.count)
            }
        } else if let segmented = sentenceSegmentedPreedit() {
            // 分段码比原码多出字间空格，selection 需覆盖完整分段串
            return NSRange(location: 0, length: segmented.count)
        }
        return NSRange(location: 0, length: _originalString.count)
    }

    /// 候选窗鼠标点选上屏用：点选无提交键，只计已敲入的编码键数
    var currentRawKeyCount: Int { _originalString.count }

    /// 上屏候选并计入统计。
    /// committedKeys：本次上屏消耗的真实按键数，用于"平均码长 = 总键数/总字数"。
    /// 手动选择（空格/数字/;/标点提交）不传，按"编码串 + 1 个提交键"计；
    /// 顶屏/定时等自动上屏没有提交键，由调用方传入实际消耗的编码键数。
    func insertCandidate(_ candidate: Candidate, committedKeys: Int? = nil) {
        // insertText 内部 clean() 会清空 _originalString，键数必须先取
        // 拼音：调用方没给键数时按这条候选实际覆盖的键数算（前缀词只吃自己那一段），
        // 剩下的键上屏后回到组字区继续组句
        var pinyinRemaining = ""
        var effectiveKeys = committedKeys
        let wasPinyin = _pinyinActive
        if _pinyinActive, committedKeys == nil,
           let index = visiblePinyinIndex(of: candidate) {
            let keys = _pinyinAllConsumed[index]
            effectiveKeys = keys
            pinyinRemaining = String(_originalString.dropFirst(min(keys, _originalString.count)))
        }
        let keys = max(1, effectiveKeys ?? (_originalString.count + 1))
        // 学习信号（clean() 会重置会话与 _sentenceActive，全部先捕获）：
        // rawCode = 本次上屏的原始编码；ctx = 上屏前的会话上下文末 2 字；
        // rank = 可见候选列表中的命中序号（0 = 首选）；top1Text = 被放弃的首选
        let rawCode = _originalString
        let ctxText = _sentenceSession.contextText
        var rank = 0
        var top1Text = ""
        if _pinyinActive, !_pinyinAll.isEmpty {
            top1Text = _pinyinAll[0].text
            if let index = visiblePinyinIndex(of: candidate) {
                rank = index
            }
        } else if _sentenceActive, !_sentenceAllCandidates.isEmpty {
            top1Text = _sentenceAllCandidates[0].text
            if let index = _sentenceAllCandidates.firstIndex(where: { $0.text == candidate.text }) {
                rank = index
            }
        } else if !_candidates.isEmpty {
            top1Text = _candidates[0].text
            if let index = _candidates.firstIndex(where: {
                $0.text == candidate.text && $0.code == candidate.code
            }) {
                rank = index
            }
        }
        if rank >= 1, Defaults[.enableLearning] {
            _pendingCommitLearning = CommitLearningInfo(
                rank: rank, top1Text: top1Text, code: rawCode, ctx: ctxText)
        }
        Fire.shared.lastCommittedText = candidate.text
        // 记录中文候选词上屏，供"快速加词"组词使用
        if candidate.type != .placeholder, candidate.text.contains(where: { $0.isChineseChar }) {
            Fire.shared.recentCommittedTexts.append(candidate.text)
            if Fire.shared.recentCommittedTexts.count > 20 {
                Fire.shared.recentCommittedTexts.removeFirst()
            }
        }
        // 整句模式：手动选词上屏的文字也计入 n-gram 留存语境
        if Defaults[.enableSentenceMode], candidate.type != .placeholder {
            _sentenceSession.recordContext(candidate.text)
        }
        insertText(candidate.text)
        // 拼音选了前缀词：把没消耗完的键送回组字区（set 会重画组字区并重查候选）
        if wasPinyin, !pinyinRemaining.isEmpty {
            _originalString = pinyinRemaining
        }
        let appBundleId = client()?.bundleIdentifier() ?? ""
        let notification = Notification(
            name: Fire.candidateInserted,
            object: nil,
            userInfo: [ "candidate": candidate, "appBundleId": appBundleId, "keyCount": keys,
                        "rank": rank, "top1Text": top1Text, "rawCode": rawCode, "ctx": ctxText ]
        )
        // 异步派发事件，防止阻塞当前线程
        NotificationQueue.default.enqueue(notification, postingStyle: .whenIdle)
    }

    // 往输入框插入当前字符
    func insertText(_ text: String) {
        fireLog("insertText: \(text)")
        if text.count > 0 {
            var newText = text
            if Defaults[.enableWhitespaceBetweenZhEn] {
                var lastText = getPreviousText()
                if lastText.isEmpty {
                    lastText = getPreviousTextIgnoringMarked()
                }
                if lastText.isEmpty {
                    lastText = _lastCommittedText
                }
                if Utils.shared.shouldConcatWithWhitespace(lastText, text) {
                    newText = " " + newText
                    fireLog("[FireInputController] insertCandidate should append whitespace: \(newText)")
                }
            }
            let selectedRange = client().selectedRange()
            // 上屏前先定插入位置：合成区(replaceRange)有效时其 location 即插入位置；
            // 否则无合成区，光标位置即插入位置。两者都不可用时记 nil，撤销时按光标校验
            var insertionLocation: Int?
            let replaceRange = replacementRange()
            let markedRange = client().markedRange()
            if replaceRange.location != NSNotFound && replaceRange.location < 1_000_000 {
                insertionLocation = replaceRange.location
            } else if selectedRange.location != NSNotFound && selectedRange.location < 1_000_000 {
                insertionLocation = selectedRange.location
                // 某些 App（如 TextEdit）把合成区文字计入文档长度、光标报在组字区之后
                //（实测 wob 合成态 sel={3,0}，上屏后光标回落到 1）：
                // 光标恰在组字区末尾时，真实插入点 = 光标 − 组字区长度
                if markedRange.location != NSNotFound, markedRange.length > 0,
                   selectedRange.location == markedRange.location + markedRange.length {
                    insertionLocation = markedRange.location
                }
            }
            let value = NSAttributedString(string: newText)
            client()?.insertText(value, replacementRange: replacementRange())
            _lastInputIsAlphanumeric = newText.last.map { $0.isASCII && ($0.isNumber || $0.isLetter) } ?? false
            _lastInputIsNumber = newText.last != nil && Int(String(newText.last!)) != nil
            _lastPunctuationKeyCode = nil
            _lastCommittedText = newText
            // 通道 A：会话缓存记录（所有真实插入文档的文字，跨 clean 存活）
            if Defaults[.enableSentenceMode] {
                _sentenceSession.decoder.cacheModel.record(newText)
            }
            // 与 LearnerCenter.applyCommit 同口径：学习开启且含中文才算实时学过
            let wasLearned = Defaults[.enableLearning]
                && newText.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            _committedRecords.append(CommittedRecord(
                text: newText, location: insertionLocation,
                learning: _pendingCommitLearning, wasLearned: wasLearned))
            _pendingCommitLearning = nil
            if _committedRecords.count > Self.maxUndoDepth {
                _committedRecords.removeFirst(_committedRecords.count - Self.maxUndoDepth)
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
        // 整句激活：所有顶屏/空码顶字规则失效，上屏完全交给整句引擎
        if _sentenceActive { return false }
        // 整句模式开启（非反查）：常规码表索引一律不得自动消费编码前缀。
        // 否则会出现 `ngjswr` 被 M码顶悄悄顶成常规表「每个月」、preedit
        // 只剩 `wr` 这类隐形消费——候选框里根本看不到那个词。
        // 顶屏/空码顶字全部由整句引擎的 tryEarlyCommit/tryEmptyCodeCommit 负责。
        if Defaults[.enableSentenceMode], _originalString.first != "`" { return false }
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
                    // 唯一候选满码自动上屏，无提交键
                    insertCandidate(first, committedKeys: count)
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
                        // 空码顶字：末键是下一码首键，本屏只消耗前缀键
                        insertCandidate(candidate, committedKeys: count - 1)
                        _originalString = lastChar
                        return true
                    }
                }
                insertOriginText()
                return true
            }
            return false
        case .emptyCodeDirect:
            cancelAutoCommit()
            // 顶屏：前缀是完整编码（长度 > 1）时，下一码触发上屏
            if count > 1 {
                let prefix = String(_originalString.dropLast())
                let lastChar = String(_originalString.suffix(1))
                if prefix.count > 1 {
                    let (prefixCandidates, _) = Fire.shared.getCandidates(origin: prefix, page: 1)
                    if let prefixFirst = prefixCandidates.first, prefixFirst.type != .placeholder,
                       prefixFirst.code == prefix {
                        // 空码直接上屏的顶屏：末键是下一码首键，本屏只消耗前缀键
                        insertCandidate(prefixFirst, committedKeys: count - 1)
                        _originalString = lastChar
                        return true
                    }
                }
            }
            if first.type == .placeholder {
                insertOriginText()
                return true
            }
            if first.code == _originalString {
                if _candidates.count == 1 {
                    // 唯一候选完整编码自动上屏，无提交键
                    insertCandidate(first, committedKeys: count)
                    return true
                }
                // 完整编码有多个候选且编码长度 > 1：300ms 后自动上屏首选
                if count > 1 {
                    scheduleAutoCommit(candidate: first)
                }
                return false
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
        // 顶屏无提交键：本屏消耗前缀 prefixLength 键，其余键留给下一码
        insertCandidate(candidate, committedKeys: prefixLength)
        _originalString = remaining
        return true
    }

    // 获取光标行矩形（候选窗锚点）：组字串非空时取组字串末字符的行矩形——
    // 行内组字时组字串很长，index 0 是组字串开头而非光标，候选窗必须锚在光标（组字串末尾）；
    // 面板模式组字区只有单个空格，末字符即光标处。应用给不出时退化为鼠标位置处的一行
    func getCaretRect() -> NSRect {
        var rect = NSRect()
        var index = 0
        let marked = client()?.markedRange() ?? NSMakeRange(NSNotFound, 0)
        if marked.location != NSNotFound, marked.length > 0 {
            index = marked.length - 1
        }
        client()?.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
        if rect.equalTo(NSRect.zero) && index != 0 {
            // 个别客户端对末字符给不出矩形时退回首字符
            client()?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        }
        if rect.equalTo(NSRect.zero) {
            let mouse = NSEvent.mouseLocation
            return NSRect(x: mouse.x, y: mouse.y, width: 0, height: 16)
        }
        // 光标紧跟在末字符之后：锚点取该字符右缘，宽度归零（纯锚点）
        return NSRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
    }

    // 获取当前输入的光标位置（候选窗左上角钉位点，供提示窗等沿用）
    func getOriginPoint() -> NSPoint {
        let rect = getCaretRect()
        return NSPoint(x: rect.minX, y: rect.minY - 4)
    }

    func clean() {
        fireLog("[FireInputController] clean")
        cancelAutoCommit()
        _originalString = ""
        curPage = 1
        _pendingDeleteCandidate = nil
        _combineCount = nil
        _sentenceActive = false
        _pinyinActive = false
        _pinyinConsumed = []
        _pinyinAll = []
        _pinyinAllConsumed = []
        _pinyinMarked = ""
        _sentenceHighlightIndex = 0
        _sentenceTotalCount = 0
        _pageCount = 0
        _sentenceAllCandidates = []
        _pendingCommitLearning = nil
        // 整句会话整体重置（空格/回车/Esc/上屏都走到这里）
        SentenceEngine.shared.resetSession(_sentenceSession)
        CandidatesWindow.shared.close()
    }

    /// 删除指定区段的文字，逐级兜底：
    ///   1. 空串替换区间（多数客户端支持，立即生效）；
    ///   2. 非空替换：把"区间之后到光标"的内容替换进区间（部分客户端如
    ///      TextEdit 忽略空串替换，但非空替换普遍支持）；
    ///   3. 私有事件源投递删除键：事件经 TSM 路由后照常到达应用完成删除
    ///      （需辅助功能权限；非 ESC，不会触发应用的 Esc 行为）。
    /// 删除可能异步生效（尤其兜底3走事件队列）：兜底1/2轮询回读确认，
    /// 兜底3投递成功即确认；全部失败返回 false，调用方保留撤销栈不误报成功。
    @discardableResult
    private func deleteRange(_ range: NSRange) -> Bool {
        client()?.insertText(NSAttributedString(string: ""), replacementRange: range)
        if isRangeDeleted(range) { return true }
        // 兜底2：非空替换（undoLastCommit 保证目标区段整体在光标之前）
        let sel = client().selectedRange()
        if sel.location != NSNotFound, sel.location >= range.location + range.length {
            let after = client().attributedSubstring(
                from: NSRange(location: range.location + range.length,
                             length: sel.location - range.location - range.length))?.string ?? ""
            if !after.isEmpty {
                client()?.insertText(NSAttributedString(string: after), replacementRange: range)
                if isRangeDeleted(range) { return true }
            }
        }
        // 兜底3：删除键（光标须恰在目标末尾，逐码元退格）。
        // 投递成功即视为删除生效：删除经事件队列异步到达应用，
        // 立即回读 attributedSubstring 可能拿到删除前的缓存而误判失败；
        // 光标守卫已确认状态，此处信任标准删除语义，避免撤销栈卡死。
        guard AXIsProcessTrusted() else { return false }
        let selNow = client().selectedRange()
        guard selNow.length == 0, selNow.location == range.location + range.length else { return false }
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<range.length {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Delete), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Delete), keyDown: false) else { break }
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
        return true
    }

    /// 轮询回读确认区段已空（删除可能异步生效，最长约 250ms）。
    /// 指数退避：同步生效的客户端首读（0ms）即命中；异步生效的从 1ms 起步探测，
    /// 把常见路径的固定 25ms 步进等待压到毫秒级，总确认窗口与语义不变。
    private func isRangeDeleted(_ range: NSRange) -> Bool {
        var delay: UInt32 = 1_000 // 首次退避 1ms
        var elapsed: UInt32 = 0
        while elapsed < 250_000 {
            if (client().attributedSubstring(from: range)?.string ?? "").isEmpty { return true }
            usleep(delay)
            elapsed += delay
            delay = min(delay * 2, 32_000)
        }
        return (client().attributedSubstring(from: range)?.string ?? "").isEmpty
    }

    /// 清空上屏撤销记录（切换输入框/客户端时调用），
    /// 避免在新输入框里误撤销上一个输入框中上屏的文字；
    /// 会话缓存同步清空（新输入框 = 新主题）
    func clearCommitUndoRecords() {
        _committedRecords.removeAll()
        _sentenceSession.decoder.cacheModel.clear()
        // 换输入框 = 换文档：光标前语境作废，下一次组字重读
        _sentenceSession.cursorContext = ""
    }

    /// 撤消上屏：回退最近一次上屏的文字（Ctrl+U 默认）。
    /// 定位策略：
    ///   1. 记录里有上屏时的插入位置：校验该区段文字与记录一致后删除，
    ///      并要求光标仍在该文字末尾，避免误删用户后续编辑的内容；
    ///   2. 记录里没有位置（上屏时应用未报告位置）：按光标位置回推文字长度，
    ///      校验光标前文字与记录一致后删除。
    /// 校验不通过（用户已移动光标或改动文字）时不强行撤销，放行给应用处理。
    private func undoLastCommit() -> Bool {
        guard _originalString.isEmpty, _combineCount == nil, _pendingDeleteCandidate == nil else { return false }
        guard let record = _committedRecords.last else { return false }
        let text = record.text
        guard !text.isEmpty else {
            _committedRecords.removeLast()
            return false
        }
        let selectedRange = client().selectedRange()
        guard selectedRange.location != NSNotFound && selectedRange.location < 1_000_000 else {
            return false
        }

        var range: NSRange
        if let location = record.location {
            // 有记录位置：先按记录校验；失败再尝试光标回退
            //（某些 App 上屏前后 selectedRange 基准不一致，记录位置可能与实际错位）
            if selectedRange.location == location + record.utf16Length {
                range = NSRange(location: location, length: record.utf16Length)
            } else if selectedRange.length == 0,
                    selectedRange.location >= record.utf16Length {
                let backRange = NSRange(location: selectedRange.location - record.utf16Length, length: record.utf16Length)
                if client().attributedSubstring(from: backRange)?.string == text {
                    range = backRange
                } else {
                    return false
                }
            } else {
                return false
            }
        } else {
            // 无记录位置：从光标回推。光标前若已有选区则不撤销，避免覆盖用户选择
            guard selectedRange.length == 0, selectedRange.location >= record.utf16Length else {
                return false
            }
            range = NSRange(location: selectedRange.location - record.utf16Length, length: record.utf16Length)
        }
        // 删除前校验区段文字确实是当初上屏的内容，防止误删
        let found = client().attributedSubstring(from: range)?.string ?? ""
        guard found == text else {
            return false
        }

        // 执行删除（deleteRange 三级兜底）。
        // 删除失败则保留撤销栈，放行给应用（不误报成功）
        guard deleteRange(range) else {
            return false
        }
        _committedRecords.removeLast()
        _lastCommittedText = _committedRecords.last?.text ?? ""
        // 学习系统负样本：仅当该条文字实时学过（与 statistics.learned 同口径）
        // 才回退——通道 B 计数回退、纠错对回退；会话缓存窗口始终回退
        if record.wasLearned || record.learning != nil {
            var userInfo: [AnyHashable: Any] = [
                "text": text,
                "appBundleId": client()?.bundleIdentifier() ?? ""
            ]
            if let learning = record.learning {
                userInfo["rank"] = learning.rank
                userInfo["top1Text"] = learning.top1Text
                userInfo["code"] = learning.code
                userInfo["ctx"] = learning.ctx
            }
            NotificationQueue.default.enqueue(
                Notification(name: Fire.commitUndone, object: nil, userInfo: userInfo),
                postingStyle: .whenIdle)
        }
        if Defaults[.enableSentenceMode] {
            _sentenceSession.decoder.cacheModel.removeLast(text)
        }
                // 撤销的是整句上屏的文字时，同步弹出对应的 n-gram 留存段
        if Defaults[.enableSentenceMode],
           let last = _sentenceSession.contextSegments.last,
           last == text {
            _sentenceSession.contextSegments.removeLast()
        }
        // 文档被改（撤销上屏）：光标前语境作废，下一次组字重读
        _sentenceSession.cursorContext = ""
        return true
    }
}

extension Character {
    // 是否为 CJK 统一表意文字(常用汉字区)
    var isChineseChar: Bool {
        unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) }
    }
}
