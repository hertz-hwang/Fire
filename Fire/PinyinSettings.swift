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
        Defaults.observe(keys: .pinyinLayout, .pinyinCustomTable,
                         .pinyinFuzzyRules, .pinyinTypoCorrection) { [weak self] in
            self?.applySettings()
        }
        .tieToLifetime(of: self)
        Defaults.observe(keys: .pyTablePath) { [weak self] in
            guard let self else { return }
            self.reload()
            self.prepareIfNeeded()
        }
        .tieToLifetime(of: self)
        Defaults.observe(keys: .sentenceModelPath) { [weak self] in
            // 换 ngram 模型：格子分数与词级先验全部过期
            self?.engine.clearCaches()
        }
        .tieToLifetime(of: self)
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
