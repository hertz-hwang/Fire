//
//  SentenceEngine.swift
//  Fire
//
//  整句会话状态机：概率型提前上屏 + 空码自动上屏
//  （移植虎整句 try_early_commit / try_commit_mature_prefix /
//   capture_empty_code_candidate / try_empty_code_commit / processor 挂起规则）。
//
//  与虎整句的已确认差异：
//  - 会话状态住在 FireInputController 实例上（IMK 多 client 多 controller，
//    _originalString 本身就是 per-controller 的），不需要 Rime property 那层绕路；
//  - 自动上屏后组字区只保留未消费的键（虎整句保留 committed_raw 作为解码
//    左上下文；Fire 从保留键本地续解码，提前上屏仍按局部整句后验成熟触发）。
//

import Foundation
import Defaults

/// 每个输入控制器一个会话。decoder 持有增量 lattice 缓存，随会话走。
final class SentenceSession {
    let decoder = SentenceDecoder()

    /// 已自动上屏的文字（用于撤销与统计，解码不再回溯它）
    var committedText: String = ""
    /// 已自动上屏的编码长度（虎整句 committed_raw 的等价物，统计/回溯用；
    /// 选重符 `;`/数字直接写在 _originalString 里，由 decode 的 parse_selector 消化）
    var committedRawLength: Int = 0
    /// 上下键/翻页/Tab/退格后挂起自动上屏
    var suspended: Bool = false
    /// 空码上屏后的延续标记（保留给后续规则，行为对齐虎整句）
    var continuationAfterAutoCommit: Bool = false

    // 提前上屏证据
    var trackers: [String: SentenceTracker] = [:]
    var lastSeenRaw: String = ""
    var lastAutoCommitRawLength: Int = 0

    // 空码上屏
    var emptyCodePending: SentenceEmptyPending?

    /// 兜底语境：最近上屏的文字片段（旧→新，最多存 2 段）。
    /// 只在读不到输入框文本时（应用不支持 attributedSubstring、
    /// 无辅助功能权限）顶上，避免跨上屏组句语境整个失效
    /// （「回」已上屏，再打 gbmqbk 才能组出承前的句子）。
    /// 不受 resetAll 影响：上屏的文字已进文档，clean/换码都不该丢这个语境。
    var contextSegments: [String] = []

    /// 左上下文主来源：本次组字开始时从光标插入点向前读的最近 N 个汉字
    /// （「N-gram语境字数」0/1/2）。由 controller 在组字开始/会话重置时刷新，
    /// 一次组字期内复用同一份值——逐键重读既多一次 IPC，光标抖动还会
    /// 让解码器的增量 lattice 反复整体作废。
    var cursorContext: String = ""

    /// 组句用的左上下文：优先取光标前文本，取不到时回落历史上屏文字。
    /// 按语境字数（0/1/2）实时裁剪：滑杆调小立刻生效，不必等下一次组字。
    var contextText: String {
        let depth = min(2, max(0, Defaults[.sentenceContextDepth]))
        guard depth > 0 else { return "" }
        guard !cursorContext.isEmpty else {
            return contextSegments.suffix(depth).joined()
        }
        return String(cursorContext.suffix(depth))
    }

    func recordContext(_ text: String) {
        guard !text.isEmpty else { return }
        contextSegments.append(text)
        if contextSegments.count > 2 {
            contextSegments.removeFirst(contextSegments.count - 2)
        }
    }

    /// 本次会话累计敲入的键数（前 4 键豁免用，跨自动上屏不清零）
    var sessionKeyCount: Int = 0
    /// 会话绑定的词表代数；换词库后由 controller 重置会话
    var lexiconGeneration: Int = -1
    /// 会话绑定的引擎纪元；整句/自动上屏开关变化后由 controller 重置会话
    var engineEpoch: Int = -1

    func resetEvidence() {
        trackers = [:]
        lastSeenRaw = ""
    }

    func resetAll() {
        decoder.reset()
        committedText = ""
        committedRawLength = 0
        suspended = false
        continuationAfterAutoCommit = false
        resetEvidence()
        lastAutoCommitRawLength = 0
        emptyCodePending = nil
        sessionKeyCount = 0
        // 文档变过（上屏/撤销/换输入框）：光标前语境必须重读，
        // 由 controller 在下一次组字开始时刷新
        cursorContext = ""
    }
}

final class SentenceEngine {
    static let shared = SentenceEngine()

    /// 设置变更纪元：整句/自动上屏/编码模式变化 +1，会话检测后重置并清 decode 缓存
    private(set) var epoch: Int = 0
    private var epochObserver: Defaults.Observation?
    private var duplicateObserver: Defaults.Observation?
    private var lexiconObserver: Any?

    private init() {
        // supplement 词源 = 用户词库中带权重的词条（`[权重] 词条` 行）
        SentenceSupplement.shared.entriesProvider = {
            DictManager.shared.getUserSupplementEntries()
        }
        // wbTablePath 变化：整句码表按方案自动匹配不同文件，必须打脏重建
        epochObserver = Defaults.observe(keys: .enableSentenceMode, .enableSentenceAutoCommit,
                                         .codeMode, .sentenceModelPath, .wbTablePath, .pyTablePath) { [weak self] in
            guard let self = self else { return }
            // 拼音方案锁定输入行为（整句开/自动上屏关/空格上屏…），
            // 覆盖设置面板之外的任何写入路径；已锁定时内部判等不重复写入
            enforcePinyinInputModeDefaults()
            self.epoch += 1
            SentenceLexicon.shared.markDirty()
        }
        .tieToLifetime(of: self)
        // 单字重码组句只改边资格不改词表：重置会话但别把词表打脏重建
        duplicateObserver = Defaults.observe(keys: .enableSentenceAllowDuplicateSingle) { [weak self] in
            guard let self = self else { return }
            self.epoch += 1
        }
        .tieToLifetime(of: self)
        lexiconObserver = NotificationCenter.default.addObserver(
            forName: SentenceLexicon.updated, object: nil, queue: .main) { [weak self] _ in
            self?.epoch += 1
        }
    }

    private var lexicon: SentenceLexicon { SentenceLexicon.shared }
    private var model: NgramModel { NgramModel.shared }

    /// 整句是否可用：开关 + 词库就绪 + 模型就绪
    var available: Bool {
        Defaults[.enableSentenceMode] && lexicon.usable && isModelLoaded()
    }

    func isModelLoaded() -> Bool {
        model.ensureLoaded()
        return model.loaded
    }

    /// 词库跟随：codeMode / 用户词库 / 重建索引
    func prepareIfNeeded() {
        guard Defaults[.enableSentenceMode] else { return }
        lexicon.rebuildIfNeeded()
        model.ensureLoaded()
    }

    // MARK: - 候选

    /// 整句候选（type = .sentence，code 为分段码，供候选栏展示）。
    /// 不可用时返回 nil，调用方回落普通词候选。
    /// raw 里的选重符（`;`/`'`/数字）原样进解码——parse_selector 会把它
    /// 解析成该段的显式 rank，锁定用字但不上屏；展示用的 segmented 在
    /// 解码器里已剥掉选重符。
    func candidates(session: SentenceSession, raw: String) -> SentenceDecodeResult? {
        guard available else { return nil }
        guard raw.first != "`" else { return nil }
        let result = session.decoder.decode(raw, includeEarlyCommit: false,
                                             context: session.contextText)
        if result.candidates.isEmpty { return nil }
        return result
    }

    // MARK: - 按键入口

    /// 字母键追加到 raw（追加后的完整原码）之后调用；先空码上屏再提前上屏。
    /// 返回命中时：commitText 上屏，retainedRaw 是组字区应保留的编码。
    func keyPressed(session: SentenceSession, raw: String,
                    appendedLetter: Bool) -> SentenceAutoCommit? {
        guard available else { return nil }
        session.sessionKeyCount += 1

        guard Defaults[.enableSentenceAutoCommit] else {
            // 关闭自动上屏：证据也不积累，保持干净
            session.resetEvidence()
            session.emptyCodePending = nil
            return nil
        }

        // 非纯字母码（含数字等）不参与自动上屏
        guard SentenceDecoder.normalize(raw) != nil else {
            session.resetEvidence()
            session.emptyCodePending = nil
            return nil
        }

        // ---- 空码自动上屏 ----
        if appendedLetter && !session.suspended {
            if let commit = tryEmptyCodeCommit(session: session, raw: raw) {
                return commit
            }
        } else {
            session.emptyCodePending = nil
        }

        // ---- 概率型提前上屏 ----
        if !session.suspended {
            if let commit = tryEarlyCommit(session: session, raw: raw) {
                return commit
            }
        } else {
            session.resetEvidence()
        }
        return nil
    }

    /// 编码被外部改写（空格/回车/组词等）后由 controller 调用
    func resetSession(_ session: SentenceSession) {
        session.resetAll()
    }

    /// 上下键 / 翻页 / Tab / 退格 → 挂起并清空证据
    func suspendAutoCommit(_ session: SentenceSession) {
        session.resetEvidence()
        session.suspended = true
        session.emptyCodePending = nil
    }

    /// 退格：挂起证据但保留会话（原始码还在继续编辑）
    func evidenceInvalidated(_ session: SentenceSession) {
        session.resetEvidence()
        session.emptyCodePending = nil
    }

    // MARK: - 概率型提前上屏（Lua try_early_commit）

    private func tryEarlyCommit(session: SentenceSession, raw: String) -> SentenceAutoCommit? {
        // 前 4 键永不计入证据（sessionKeyCount 跨提交累计）
        if session.sessionKeyCount <= SentenceConfig.firstKeysImmunity {
            session.resetEvidence()
            return nil
        }

        let result = session.decoder.decode(raw, includeEarlyCommit: true,
                                             context: session.contextText)
        let evidence = result.evidence
        // 临近组字区上限：调低前缀置信阈值兜底出字（防止触顶拒键）。
        // beam 截断只让证据质量降级，兜底时照常使用——长编码歧义段恰是
        // 截断高发区，若截断即作废，兜底永远等不到材料。
        let nearCap = raw.count >= SentenceConfig.autoCommitMaxRawLength
            - SentenceConfig.nearCapCommitGenerations
        if evidence.confidenceTruncated && !nearCap {
            session.resetEvidence()
            return nil
        }

        if session.lastSeenRaw == raw {
            return commitMaturePrefixOrNearCapFallback(session: session, raw: raw,
                                                       result: result)
        }

        // 生成代必须是"上次证据编码 + 一键"，否则历史作废
        let extendsPrevious = session.lastSeenRaw.isEmpty
            || (raw.count == session.lastSeenRaw.count + 1
                && raw.hasPrefix(session.lastSeenRaw))
        if !extendsPrevious {
            session.trackers = [:]
        }
        session.lastSeenRaw = raw

        let minimumShare = nearCap
            ? SentenceConfig.nearCapMinimumShare
            : SentenceConfig.earlyCommitMinimumShare

        // 榜首带 supplement 奖励时，只接受它的文字前缀（虎整句 accepted_top：
        // 加权新词保护期内不被其它分歧前缀提前截走）
        var acceptedTop: String? = nil
        if let top = result.candidates.first, top.supplementScore > 0 {
            acceptedTop = top.text
        }
        let mergedIncompleteTail = evidence.mergedIncompleteTail
        var qualifying: [String: SentencePrefixEvidence] = [:]
        for prefix in evidence.prefixes {
            if prefix.text.isEmpty { continue }
            // 兜底时边界闭合门槛同步降到 nearCapMinimumShare
            let boundaryClosed = prefix.boundaryClosed
                || (nearCap && prefix.boundaryShare >= SentenceConfig.nearCapMinimumShare)
            guard boundaryClosed else { continue }
            if prefix.share < minimumShare { continue }
            if prefix.rawLength <= 0 || prefix.rawLength >= raw.count { continue }
            if prefix.textCharCount <= 0 { continue }
            if !mergedIncompleteTail && !prefixBelongsToVisible(prefix, result.candidates) {
                continue
            }
            if let acceptedTop = acceptedTop, !acceptedTop.hasPrefix(prefix.text) {
                continue
            }
            qualifying[prefix.text + "\u{1F}" + String(prefix.rawLength)] = prefix
        }

        let retainWithoutCounting = qualifying.isEmpty
            && (evidence.neutralLowConfidence || mergedIncompleteTail)
        if retainWithoutCounting {
            // 中性间隔：最多 3 代不计证据地保住旧 tracker
            retainTrackersWithoutCounting(session: session, prefixes: evidence.prefixes)
            return commitMaturePrefixOrNearCapFallback(session: session, raw: raw,
                                                       result: result)
        }

        var nextTrackers: [String: SentenceTracker] = [:]
        for (key, prefix) in qualifying {
            let tracker = session.trackers[key]
                ?? SentenceTracker(text: prefix.text,
                                  textCharCount: prefix.textCharCount,
                                  rawLength: prefix.rawLength)
            tracker.evidenceCount = min(SentenceConfig.earlyCommitRequiredEvidence,
                                         tracker.evidenceCount + 1)
            tracker.strongCount = prefix.share >= SentenceConfig.earlyCommitStrongShare
                ? min(SentenceConfig.earlyCommitRequiredStrong, tracker.strongCount + 1)
                : 0
            tracker.gapCount = 0
            tracker.lastShare = prefix.share
            nextTrackers[key] = tracker
        }
        session.trackers = nextTrackers
        return commitMaturePrefixOrNearCapFallback(session: session, raw: raw,
                                                   result: result)
    }

    /// 成熟前缀上屏，失败时尝试临近上限的最后一档兜底
    private func commitMaturePrefixOrNearCapFallback(session: SentenceSession,
                                                     raw: String,
                                                     result: SentenceDecodeResult) -> SentenceAutoCommit? {
        if let commit = tryCommitMaturePrefix(session: session, raw: raw) {
            return commit
        }
        return tryNearCapLastResort(session: session, raw: raw, result: result)
    }

    /// 临近上限的最后一档兜底：连 nearCapMinimumShare 占比的闭合前缀都没有
    /// （后验持平）时，按榜首候选自身的分段边界强制出字到"留足保留键"的
    /// 最长边界——触顶拒键（键漏给系统）比出字更不可接受。
    private func tryNearCapLastResort(session: SentenceSession,
                                       raw: String,
                                       result: SentenceDecodeResult) -> SentenceAutoCommit? {
        let retain = SentenceConfig.earlyCommitRetainedRawLength
        guard raw.count >= SentenceConfig.autoCommitMaxRawLength
            - SentenceConfig.nearCapCommitGenerations,
            raw.count - retain >= 1,
            let top = result.candidates.first else { return nil }

        var boundaryNode: SentenceState? = top.path
        while let node = boundaryNode, node.rawLength > 0,
              node.rawLength > raw.count - retain {
            boundaryNode = node.previous
        }
        guard let node = boundaryNode, node.rawLength > 0, !node.text.isEmpty else {
            return nil
        }

        let commit = node.text
        session.committedText = committedTextByAppending(session.committedText, commit)
        session.committedRawLength += node.rawLength
        session.recordContext(commit)
        session.lastAutoCommitRawLength = node.rawLength
        session.continuationAfterAutoCommit = false
        session.resetEvidence()
        session.emptyCodePending = nil

        return SentenceAutoCommit(text: commit, retainedRaw: String(raw.dropFirst(node.rawLength)))
    }

    /// 成熟 tracker 中选最优并上屏（Lua try_commit_mature_prefix）。
    private func tryCommitMaturePrefix(session: SentenceSession,
                                        raw: String) -> SentenceAutoCommit? {
        let retain = SentenceConfig.earlyCommitRetainedRawLength
        // 临近上限：兜底出字免除成熟代数（只剩几代可敲，等不起 3 代）；
        // 会话级保留间隔也一并豁免——上轮大段上屏后 raw 已收缩重建，
        // `raw.count - lastAutoCommitRawLength` 坐标错位，触顶场景宁滥勿缺。
        let nearCap = raw.count >= SentenceConfig.autoCommitMaxRawLength
            - SentenceConfig.nearCapCommitGenerations
        let requiredEvidence = nearCap ? 1 : SentenceConfig.earlyCommitRequiredEvidence
        var selected: SentenceTracker?
        for tracker in session.trackers.values {
            if (tracker.evidenceCount >= requiredEvidence
                || tracker.strongCount >= SentenceConfig.earlyCommitRequiredStrong)
                && tracker.rawLength > 0
                && tracker.rawLength <= raw.count
                && raw.count - tracker.rawLength >= retain
                && tracker.textCharCount > 0 {
                if selected == nil || trackerBetter(tracker, selected!) {
                    selected = tracker
                }
            }
        }
        guard let tracker = selected else { return nil }
        guard nearCap || raw.count - session.lastAutoCommitRawLength >= retain else { return nil }
        guard !tracker.text.isEmpty else { return nil }

        let commit = tracker.text
        session.committedText = committedTextByAppending(session.committedText, commit)
        session.committedRawLength += tracker.rawLength
        session.recordContext(commit)
        session.lastAutoCommitRawLength = tracker.rawLength
        session.continuationAfterAutoCommit = false
        session.resetEvidence()
        session.emptyCodePending = nil

        let retainedRaw = String(raw.dropFirst(tracker.rawLength))
        return SentenceAutoCommit(text: commit, retainedRaw: retainedRaw)
    }

    private func trackerBetter(_ left: SentenceTracker, _ right: SentenceTracker) -> Bool {
        if left.textCharCount != right.textCharCount {
            return left.textCharCount > right.textCharCount
        }
        if left.lastShare != right.lastShare {
            return left.lastShare > right.lastShare
        }
        return left.rawLength < right.rawLength
    }

    private func prefixBelongsToVisible(_ prefix: SentencePrefixEvidence,
                                         _ visible: [SentenceCompleted]) -> Bool {
        for candidate in visible {
            guard candidate.text.hasPrefix(prefix.text) else { continue }
            var state: SentenceState? = candidate.path
            while let node = state {
                if node.rawLength == prefix.rawLength && node.text == prefix.text {
                    return true
                }
                state = node.previous
            }
        }
        return false
    }

    private func retainTrackersWithoutCounting(session: SentenceSession,
                                                prefixes: [SentencePrefixEvidence]) {
        var next: [String: SentenceTracker] = [:]
        for (key, tracker) in session.trackers {
            guard !prefixContradicted(tracker, prefixes) else { continue }
            guard let current = findPrefixEvidence(prefixes, tracker.text, tracker.rawLength) else { continue }
            tracker.gapCount += 1
            if tracker.gapCount <= SentenceConfig.earlyCommitMaximumNeutralGap {
                tracker.lastShare = current.share
                next[key] = tracker
            }
        }
        session.trackers = next
    }

    private func findPrefixEvidence(_ prefixes: [SentencePrefixEvidence],
                                    _ text: String, _ rawLength: Int) -> SentencePrefixEvidence? {
        prefixes.first { $0.text == text && $0.rawLength == rawLength }
    }

    /// 与当前证据出现"更优的分歧前缀"时，tracker 作废
    private func prefixContradicted(_ tracker: SentenceTracker,
                                    _ prefixes: [SentencePrefixEvidence]) -> Bool {
        if prefixes.isEmpty { return false }
        let selfEvidence = findPrefixEvidence(prefixes, tracker.text, tracker.rawLength)
        let selfShare = selfEvidence?.share ?? 0.0
        for prefix in prefixes {
            guard !prefix.text.isEmpty, prefix.text != tracker.text else { continue }
            if tracker.text.hasPrefix(prefix.text) || prefix.text.hasPrefix(tracker.text) {
                continue
            }
            let stem = commonTextPrefix(prefix.text, tracker.text)
            if !stem.isEmpty && stem.count < tracker.text.count {
                if selfEvidence == nil || prefix.share > selfShare {
                    return true
                }
            }
        }
        return false
    }

    private func commonTextPrefix(_ left: String, _ right: String) -> String {
        var indexLeft = left.startIndex
        var indexRight = right.startIndex
        var lastShared = left.startIndex
        var found = false
        while indexLeft < left.endIndex, indexRight < right.endIndex {
            guard left[indexLeft] == right[indexRight] else { break }
            lastShared = indexLeft
            indexLeft = left.index(after: indexLeft)
            indexRight = right.index(after: indexRight)
            found = true
        }
        return found ? String(left[left.startIndex...lastShared]) : ""
    }

    private func committedTextByAppending(_ committed: String, _ commit: String) -> String {
        // 撤销/统计用拼接文本（上屏片段本身由 controller insertText 处理）
        committed + commit
    }

    // MARK: - 空码自动上屏（Lua capture_empty_code_candidate / try_empty_code_commit）

    private func tryEmptyCodeCommit(session: SentenceSession,
                                     raw: String) -> SentenceAutoCommit? {
        guard raw.count >= 2 else { return nil }
        let fullBefore = String(raw.dropLast())
        let pending = session.emptyCodePending
            ?? captureEmptyCodeCandidate(session: session, fullBefore: fullBefore)
        session.emptyCodePending = pending
        guard let pending = pending else { return nil }

        // 新键进来后整段仍可被词图完整覆盖 → 继续等待
        if hasCompleteCandidate(raw) {
            session.emptyCodePending = nil
            return nil
        }

        guard pending.baseRawLength >= 0, pending.baseRawLength < raw.count,
              pending.lastSegmentStart >= 0, pending.lastSegmentStart < raw.count else {
            session.emptyCodePending = nil
            return nil
        }

        // 扩展后的末段仍是合法码前缀 → 用户可能还在打词，不截断
        let extendedLastSegment = String(raw.dropFirst(pending.lastSegmentStart))
        if lexicon.isProperPrefix(extendedLastSegment) {
            return nil
        }

        let commit = pending.candidateText
        guard !commit.isEmpty else {
            session.emptyCodePending = nil
            return nil
        }

        let retainedRaw = String(raw.dropFirst(pending.baseRawLength))
        session.committedText = committedTextByAppending(session.committedText, commit)
        session.committedRawLength += pending.baseRawLength
        session.recordContext(commit)
        session.lastAutoCommitRawLength = pending.baseRawLength
        session.trackers = [:]
        session.lastSeenRaw = ""
        session.suspended = false
        session.emptyCodePending = nil
        session.continuationAfterAutoCommit = true

        return SentenceAutoCommit(text: commit, retainedRaw: retainedRaw)
    }

    /// 捕获"上一段编码"的首个整句候选（Lua capture_empty_code_candidate）。
    /// Fire 无显式选重，资格候选恒为 maxRank ≤ 1 且只认第一个；
    /// 多个候选时要求榜首后验占比 ≥ strongShare。
    private func captureEmptyCodeCandidate(session: SentenceSession,
                                            fullBefore: String) -> SentenceEmptyPending? {
        let decoded = session.decoder.decode(fullBefore, includeEarlyCommit: false,
                                              context: session.contextText)
        guard !decoded.candidates.isEmpty else { return nil }
        let visibleTop = decoded.candidates[0]
        // 虎整句：编码里带显式选重符时全 rank 都有资格；否则只认隐式首选。
        // 语境压倒性领先改序（contextDecisiveLead）时同样放开资格：那一刻 rank1 已经
        // 不是用户看见的首选，再拿 maxRank ≤ 1 当兜底文字会「候选栏显示 A、上屏 B」；
        // 放开后由下面的后验占比闸门把关，不够压倒性就不上屏（宁缺不错）
        let restrict = !Selector.hasSelectionSuffix(Array(fullBefore.utf8))
            && !decoded.orderedByContextLead
        let eligible = restrict
            ? decoded.candidates.filter { $0.maxRank <= 1 }
            : decoded.candidates
        guard let first = eligible.first else { return nil }
        guard !first.text.isEmpty else { return nil }

        if eligible.count > 1 {
            guard !decoded.evidence.confidenceTruncated else { return nil }
            guard first.text == visibleTop.text else { return nil }
            var maxScore = eligible[0].confidenceScore
            for candidate in eligible.dropFirst() where candidate.confidenceScore > maxScore {
                maxScore = candidate.confidenceScore
            }
            var total = 0.0
            var own = 0.0
            for candidate in eligible {
                let mass = Foundation.exp(candidate.confidenceScore - maxScore)
                total += mass
                if candidate === first {
                    own += mass
                }
            }
            guard total > 0, own / total >= SentenceConfig.earlyCommitStrongShare else {
                return nil
            }
        }

        let previous = first.path.previous
        return SentenceEmptyPending(
            candidateText: first.text,
            committedText: "",
            baseRawLength: fullBefore.count,
            lastSegmentStart: previous?.rawLength ?? 0)
    }

    /// 编码里是否含选重符（`;`/`'`/数字）
    static func containsSelector(_ raw: String) -> Bool {
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            if v == 0x3B || v == 0x27 || (v >= 0x30 && v <= 0x39) { return true }
        }
        return false
    }

    /// raw 能否被精确码边完整覆盖（Lua has_complete_candidate）
    func hasCompleteCandidate(_ raw: String) -> Bool {
        guard let bytes = SentenceDecoder.normalize(raw), !bytes.isEmpty else {
            return false
        }
        let n = bytes.count
        let allowDuplicate = Defaults[.enableSentenceAllowDuplicateSingle]
        var reachable = [Bool](repeating: false, count: n + 1)
        reachable[0] = true
        for position in 0..<n {
            guard reachable[position] else { continue }
            for codeLength in lexicon.lengths {
                let end = position + codeLength
                if end > n { continue }
                let selector = Selector.parse(bytes, end)
                let consumedEnd = selector.consumedEnd
                if consumedEnd > n { continue }
                if n > 1 && consumedEnd - position < 2 { continue }
                let code = String(decoding: bytes[position..<end], as: UTF8.self)
                guard let edges = lexicon.edges(for: code) else { continue }
                let wholeInputEdge = position == 0 && consumedEnd == n
                let selected = eligibleEdges(edges,
                                            selectedRank: selector.rank,
                                            wholeInputEdge: wholeInputEdge,
                                            allowDuplicateSingle: allowDuplicate)
                if !selected.isEmpty {
                    reachable[consumedEnd] = true
                }
            }
        }
        return reachable[n]
    }
}
