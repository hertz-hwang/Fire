//
//  PinyinSettings.swift
//  Fire
//
//  放在 app 侧（不在 Fire/Pinyin/ 里）：拼音内核要保持零 app 依赖，
//  才能脱离 sqlite / UI 单编单跑做离线评测。
//
//  拼音方案的运行时装配：把偏好设置翻成 `PinyinEngine` 的配置，
//  并在码表 / 模型变化时重建音节索引。控制器只问「引擎好了吗、查一下」。
//
//  索引载入约 180ms（八万条码 → 逐条码切音节 + 排序），不能放在按键路径上：
//  首次用到时在后台队列跑，`ready` 之前控制器走原有词库分支兜底，不会打不出字。
//

import Foundation
import Defaults

/// 拼音引擎持有者（进程内单例）。
final class PinyinEngineCenter {
    static let shared = PinyinEngineCenter()

    /// 查询用的引擎（配置由 `applySettings` 刷进来）
    let engine = PinyinEngine()

    /// 索引就绪：就绪前控制器不要走拼音分支
    private(set) var ready = false
    /// 正在载入（避免重复起任务）
    private var loading = false
    /// 已载入的码表路径（换表要重建）
    private var loadedPath: String?
    private let queue = DispatchQueue(label: "fire.pinyin.lexicon", qos: .userInitiated)

    /// 索引就绪通知（控制器收到后刷新当前候选）
    static let didBecomeReady = Notification.Name("FirePinyinReady")

    /// 设置一改就装到引擎上；换码表则作废索引重来。
    /// 面板只管写 Defaults、不直接戳引擎——不然「面板改了、控制器还拿旧配置」
    /// 这类不一致迟早出现在某个没人点到的角落。
    private init() {
        // 三个 observe 都不要 [.initial]：默认会在注册时立刻回调一次，
        // 于是「第一次碰到 PinyinEngineCenter」就把学习系统（LearnerCenter →
        // statistics.db → Keychain）整条拉起来。从命令行跑自检时这会在
        // Keychain 授权上挂死（实测 Release 目录里那份就卡住了）。
        // 配置的对齐本来就有显式入口：applySettings / prepareIfNeeded / beginQuery。
        Defaults.observe(keys: .pinyinLayout, .pinyinCustomTable,
                         .pinyinFuzzyRules, .pinyinTypoCorrection,
                         options: []) { [weak self] in
            self?.applySettings()
        }
        .tieToLifetime(of: self)
        Defaults.observe(keys: .pyTablePath, options: []) { [weak self] in
            guard let self else { return }
            self.reload()
            self.prepareIfNeeded()
        }
        .tieToLifetime(of: self)
        Defaults.observe(keys: .sentenceModelPath, options: []) { [weak self] in
            // 换 ngram 模型：格子分数与词级先验全部过期
            self?.engine.clearCaches()
        }
        .tieToLifetime(of: self)
        Defaults.observe(keys: .enableLearning, .enableLearningUserNgram,
                         .enableLearningSessionCache, options: []) { [weak self] in
            self?.refreshLearningFlags()
        }
        .tieToLifetime(of: self)
        // 用户词库（加权词）改了：词级排序的用户分要跟着换
        NotificationCenter.default.addObserver(
            forName: DictManager.userDictUpdated, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshUserWeights()
        }
        installHooks()
    }

    // MARK: 个性化（学习通道 A / B + 用户加权词）
    //
    // 拼音以前也吃这套：它走整句解码器，那两个通道就长在解码器里。现在拼音有自己的
    // 解码器，不在这里接回来的话，「越用越准」对拼音用户直接消失。
    // 接法是把钩子留在内核、把实现放在这里：内核不 import 学习模块，
    // 才能继续脱离 sqlite / Keychain 单编单跑做评测。

    /// 通道 B 快照与代次（代次换代时作废格子缓存：分数全过期）
    private var learningSnapshot: LearningSnapshot = .empty
    private var learningGeneration = -1
    private var learningTuning = LearningTuning()
    private var ngramActive = false
    private var cacheActive = false
    /// 当前会话（通道 A 的会话缓存在 decoder 上，per-controller）
    private weak var activeSession: SentenceSession?
    /// 用户加权词：词 → 折算成「选过次数」的权重
    private var userWeights: [String: Int] = [:]

    /// 控制器每次查询前报上会话，并把学习状态对齐一次（代次比较，常数级）
    func beginQuery(session: SentenceSession) {
        activeSession = session
        refreshUserWeightsIfNeeded()
        refreshLearningFlags()
    }

    private func installHooks() {
        engine.decoder.logpBlender = { [weak self] base, prev2, prev1, target in
            guard let self else { return base }
            var score = base
            if self.ngramActive, let ngram = self.learningSnapshot.ngram,
               let blended = ngram.blendedLogp(base: base, prev2: prev2, prev1: prev1,
                                               target: target, tuning: self.learningTuning,
                                               generalUnigram: NgramModel.shared
                                                   .generalUnigramProbability(target)) {
                score = blended
            }
            if self.cacheActive, let session = self.activeSession {
                score += session.decoder.cacheModel.reward(
                    prev1: prev1, target: target,
                    weight: self.learningTuning.cacheWeight * self.learningTuning.strength,
                    maxReward: self.learningTuning.cacheMaxReward,
                    unigramFactor: self.learningTuning.cacheUnigramFactor)
            }
            return score
        }
        engine.weightProvider = { [weak self] text in self?.userWeights[text] ?? 0 }
    }

    /// 加权词表：只在拼音真的在用（`beginQuery`）时才查用户词库——
    /// 它开 sqlite，不该被「有人读了单例」这种理由拉起来。
    private func refreshUserWeightsIfNeeded() {
        if userWeightsLoaded { return }
        userWeightsLoaded = true
        refreshUserWeights()
    }

    private var userWeightsLoaded = false

    /// 学习开关 / 快照代次对齐。逐字钩子里不做这些（每键要问上千次），
    /// 只在这次查询开头问一次。
    private func refreshLearningFlags() {
        let enabled = Defaults[.enableLearning]
        learningTuning = enabled ? LearningTuning.fromDefaults() : LearningTuning()
        let generation = enabled ? LearnerCenter.shared.ngramGeneration : 0
        if generation != learningGeneration {
            learningSnapshot = enabled ? LearnerCenter.shared.snapshot : .empty
            learningGeneration = generation
            // 用户 n-gram 数据变了：旧格子的先验与分数全部过期
            engine.clearCaches()
        }
        ngramActive = enabled && Defaults[.enableLearningUserNgram]
            && learningSnapshot.ngram?.hasData == true
        cacheActive = enabled && Defaults[.enableLearningSessionCache]
            && activeSession.map { !$0.decoder.cacheModel.isEmpty } ?? false
    }

    /// 加权词 → 「选过的次数」当量。词库权重 1000 是缺省（等于没加权，不给分），
    /// 往上按每 100 记一次，封顶交给引擎自己的对数 + 封顶（最多约 1.5 分），
    /// 让语境仍能压过它——参考实现的 weightBonus 就是这个道理。
    private func refreshUserWeights() {
        var next: [String: Int] = [:]
        for entry in DictManager.shared.getUserSupplementEntries() {
            guard entry.weight > 1000 else { continue }
            next[entry.text] = min(20, (entry.weight - 1000) / 100)
        }
        userWeights = next
        engine.clearCaches()
    }

    /// 需要时载入 / 重建音节索引（幂等，可在每次进中文模式时调）
    func prepareIfNeeded() {
        applySettings()
        // 模型也要在这里确保载入：拼音模式不再走整句分支，而 `SentenceEngine.prepareIfNeeded`
        // 是那条分支唯一会拉模型的地方——不补这一步，拼音的逐字分全是 0，
        // 整句与词级排序直接退化成「谁排在码表前面算谁赢」
        NgramModel.shared.ensureLoaded()
        // 码表方案 / 混合方案不载拼音索引（启动时白付 180ms 没意义）；
        // 切到拼音方案时控制器查询前会再调一次
        guard Defaults[.codeMode] == .pinyin else { return }
        let path = Defaults[.pyTablePath]
        guard !path.isEmpty else { return }
        if ready, loadedPath == path { return }
        guard !loading else { return }
        if !FileManager.default.fileExists(atPath: path) { return }
        // 已在别的线程载好（同步路径）就直接标记就绪
        if PinyinLexicon.shared.isLoaded, loadedPath == path {
            ready = true
            return
        }
        loading = true
        queue.async { [weak self] in
            guard let self else { return }
            let ok = PinyinLexicon.shared.load(path: path)
            self.queue.async {
                self.loading = false
                if ok {
                    self.loadedPath = path
                    self.ready = true
                    self.engine.clearCaches()
                    NotificationCenter.default.post(name: Self.didBecomeReady, object: nil)
                }
            }
        }
    }

    /// 同步载入（启动时已知要用拼音、或离线工具用）：跑在当前线程，返回即就绪
    @discardableResult
    func prepareSync() -> Bool {
        applySettings()
        NgramModel.shared.ensureLoaded()
        let path = Defaults[.pyTablePath]
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return false }
        if ready, loadedPath == path { return true }
        guard PinyinLexicon.shared.load(path: path) else { return false }
        loadedPath = path
        ready = true
        engine.clearCaches()
        return true
    }

    /// 设置 → 引擎配置。方案 / 模糊音 / 纠错任一改动后都要调一次。
    func applySettings() {
        let layout = Defaults[.pinyinLayout]
        if let table = layout.keyTable {
            engine.scheme = ShuangpinScheme(table: table)
        } else {
            engine.scheme = nil
        }
        engine.fuzzy = PinyinSettings.fuzzyRules()
        engine.typoEnabled = Defaults[.pinyinTypoCorrection]
        engine.correctionEnabled = Defaults[.pinyinTypoCorrection]
        // 码表 / 学习词库变了要作废格子缓存（分数与候选都来自它们）
        engine.invalidateCachesIfNeeded()
    }

    /// 换码表后强制重建（词库面板「重新载入」用）
    func reload() {
        ready = false
        loadedPath = nil
        engine.clearCaches()
    }
}

/// 设置项的编解码helper：模糊音存一份 JSON，面板与引擎共用同一份口径。
enum PinyinSettings {
    static func fuzzyRules() -> PinyinFuzzyRules {
        let json = Defaults[.pinyinFuzzyRules]
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let rules = try? JSONDecoder().decode(PinyinFuzzyRules.self, from: data) else {
            return PinyinFuzzyRules.none
        }
        return rules
    }

    static func save(fuzzyRules: PinyinFuzzyRules) {
        guard let data = try? JSONEncoder().encode(fuzzyRules),
              let json = String(data: data, encoding: .utf8) else { return }
        Defaults[.pinyinFuzzyRules] = json
    }

    /// 模糊音条目（面板逐条列出的复选框）：标题 + 读写键。
    struct FuzzyItem {
        let title: String
        let detail: String
        let get: (PinyinFuzzyRules) -> Bool
        let set: (inout PinyinFuzzyRules, Bool) -> Void
    }

    static let fuzzyItems: [FuzzyItem] = [
        .init(title: "z ↔ zh", detail: "在 / 再", get: \.zZh, set: { $0.zZh = $1 }),
        .init(title: "c ↔ ch", detail: "菜 / 彩", get: \.cCh, set: { $0.cCh = $1 }),
        .init(title: "s ↔ sh", detail: "散 / 三", get: \.sSh, set: { $0.sSh = $1 }),
        .init(title: "n ↔ l", detail: "南 / 兰", get: \.nL, set: { $0.nL = $1 }),
        .init(title: "f ↔ h", detail: "福 / 胡", get: \.fH, set: { $0.fH = $1 }),
        .init(title: "l ↔ r", detail: "路 / 入", get: \.lR, set: { $0.lR = $1 }),
        .init(title: "an ↔ ang", detail: "「安 / 昂」，含 ian/uang 等",
              get: \.anAng, set: { $0.anAng = $1 }),
        .init(title: "en ↔ eng", detail: "「恩 / 鞥」", get: \.enEng, set: { $0.enEng = $1 }),
        .init(title: "in ↔ ing", detail: "「因 / 英」", get: \.inIng, set: { $0.inIng = $1 }),
    ]
}
