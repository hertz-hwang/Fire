//
//  PinyinSelfCheck.swift
//  Fire
//
//  拼音方案自检（命令行 `Fire --pinyin-selftest`，跑完即退，不初始化输入法）。
//
//  与离线 harness（`tmp/pinyin/`）的分工：harness 只编 `Fire/Pinyin/`，证的是算法；
//  这里跑的是 **app 里那一遍**——Defaults → `PinyinEngineCenter` → 引擎 → 候选，
//  包括换方案 / 换自定义键位表之后配置真的落到引擎上、码表真的载得进来。
//  这类接线错误（设置写了、引擎没读）离线测不到，只能让 app 自己报。
//

import Foundation
import Defaults

enum PinyinSelfCheck {
    private static var failures: [String] = []
    private static var passed = 0

    static func run() {
        failures.removeAll()
        passed = 0
        // 自检要逐项改设置，先把用户现值原样存一份，跑完原样还回去——
        // 这是带 bundle id 的正式偏好域，留一手「调试跑一次、输入法方案被改了」是罪过
        let restore = (codeMode: Defaults[.codeMode], layout: Defaults[.pinyinLayout],
                       fuzzy: Defaults[.pinyinFuzzyRules], typo: Defaults[.pinyinTypoCorrection],
                       custom: Defaults[.pinyinCustomTable], model: Defaults[.sentenceModelPath])
        func restoreAll() {
            Defaults[.codeMode] = restore.codeMode
            Defaults[.pinyinLayout] = restore.layout
            Defaults[.pinyinFuzzyRules] = restore.fuzzy
            Defaults[.pinyinTypoCorrection] = restore.typo
            Defaults[.pinyinCustomTable] = restore.custom
            Defaults[.sentenceModelPath] = restore.model
        }
        // 注意别只靠 defer：下面用 exit() 收尾，defer 不会跑，设置就留在自检态了

        Defaults[.pinyinLayout] = .fullPinyin
        Defaults[.pinyinFuzzyRules] = ""
        Defaults[.pinyinTypoCorrection] = true
        Defaults[.pinyinCustomTable] = ""
        // 模型路径：仓库里那份（用户没装过整句模型时也能自检）
        if Defaults[.sentenceModelPath].isEmpty || !FileManager.default.fileExists(atPath: Defaults[.sentenceModelPath]) {
            Defaults[.sentenceModelPath] = Bundle.main.resourceURL?
                .appendingPathComponent("sentence-ngram-mobile.bin").path ?? ""
        }

        let center = PinyinEngineCenter.shared
        check(!Defaults[.pyTablePath].isEmpty, "拼音码表路径可解析：\(Defaults[.pyTablePath])")
        // ---- 词库容器 ----
        // 内置拼音词库是随包分发的 `.hdict`（二进制头 + 压缩负载）：包装坏了、
        // 同步盘只拉了一半……都得在自检里当场报出来，而不是等用户发现「某个词打不出来」。
        let bundledDict = SchemaCatalog.schemasDirectory.appending("/py.hdict")
        check(FileManager.default.fileExists(atPath: bundledDict),
              "内置拼音词库在包内：\((bundledDict as NSString).lastPathComponent)")
        let containerProblems = HDict.verify(at: bundledDict)
        check(containerProblems.isEmpty, "容器体检：\(containerProblems.first ?? "头部/负载 CRC / 词条数全部对上")")
        if let head = HDict.header(at: bundledDict) {
            check(head.kind == .pinyin, "容器 kind = 拼音：\(String(describing: head.kind))")
            check(head.hasWeightColumn, "容器带词频列（同码重码按它排序）")
            check(head.entryCount > 100_000, "容器词条 \(head.entryCount)")
            check(head.storedBytes < head.payloadBytes, "容器已压缩：\(head.storedBytes)/\(head.payloadBytes) 字节")
        }
        check(center.prepareSync(), "音节索引载入")
        check(center.ready, "引擎就绪")
        // 生效词库就是这份容器时，解析条数必须与头部声明一致（少一批词条 = 表被改过）
        if Defaults[.pyTablePath] == bundledDict, let head = HDict.header(at: bundledDict) {
            check(PinyinLexicon.shared.entryCount == head.entryCount,
                  "索引词条 \(PinyinLexicon.shared.entryCount) == 容器声明 \(head.entryCount)")
        }
        check(NgramModel.shared.loaded, "字级 ngram 模型已载入（拼音的分数全靠它）")
        let engine = center.engine

        // ---- 全拼 ----
        center.applySettings()
        check(engine.scheme == nil, "全拼下引擎不带双拼方案")
        expect(engine.compose("nihao")?.candidates.first?.text == "你好", "全拼 nihao 首选你好")
        expect(engine.compose("nihao")?.candidates.first?.consumedKeys == 5, "全拼整词吃满 5 键")
        expect(engine.compose("nihao")?.marked == "ni'hao", "组字区显示分段拼音")
        // 候选栏前五固定给整句引擎「单字重码组句」打分的 top5（拼音 / 双拼同路）
        if let top = engine.compose("nihao")?.candidates.prefix(5), top.count == 5 {
            expect(top.allSatisfy { $0.isSentence && $0.consumedKeys == 5 },
                   "前五全是吃满全码的整句打分候选：\(top.map(\.text))")
            expect(Set(top.map(\.text)).count == 5, "前五彼此不同文")
        } else {
            fail("nihao 前五应有 5 条")
        }
        expect(engine.compose("ni")?.candidates.first?.isSentence == false,
               "单音节没有组句，前五仍是词级单字重码")
        expect(engine.compose("kf")?.candidates.contains { $0.text == "开发" } == true,
               "简拼 kf 出 开发（今天的拼音路径做不到这一条）")
        expect(engine.compose("kaif")?.candidates.contains { $0.text == "开" } == true,
               "未打完的 kaif 也出前缀词")

        // ---- 小鹤双拼 ----
        Defaults[.pinyinLayout] = .xiaohe
        center.applySettings()
        check(engine.scheme?.table == ShuangpinTables.xiaohe, "设置→引擎：小鹤表生效")
        let xiaohe = engine.compose("nihc")
        expect(xiaohe?.candidates.first?.text == "你好", "小鹤 nihc 首选你好")
        expect(xiaohe?.marked == "ni'hao", "小鹤组字区显示解出的全拼")
        expect(xiaohe?.candidates.first?.consumedKeys == 4, "小鹤 4 键吃 4 键")
        expect(xiaohe?.candidates.contains { $0.text == "你" && $0.consumedKeys == 2 } == true,
               "小鹤前缀词「你」只吃 2 键")
        expect(engine.compose("vsgo")?.marked == "zhong'guo", "小鹤 vsgo → zhong'guo")

        // ---- 自然码双拼 ----
        Defaults[.pinyinLayout] = .ziranma
        center.applySettings()
        expect(engine.compose("nihk")?.candidates.first?.text == "你好", "自然码 nihk 首选你好")
        expect(engine.compose("udpn")?.marked == "shuang'pin",
               "自然码 udpn → shuang'pin（实际 \(engine.compose("udpn")?.marked ?? "∅")）")

        // ---- 整句词图也要吃 `.hdict` ----
        // 拼音引擎没就绪时控制器回落到词库分支，整句那条路读的是同一份容器；
        // 解析器只认两列的老格式，就会「拼音能打字但整句没词」，很难往词库上想。
        SentenceLexicon.shared.rebuildSync(codeMode: .pinyin)
        let graph = SentenceLexicon.shared
        check(graph.built && graph.entryCount > 10_000,
              "拼音整句词图从容器建出：\(graph.entryCount) 边 / \(graph.codeCount) 码")
        check(graph.loadedPath == Defaults[.pyTablePath],
              "整句词图用的就是所选拼音词库：\(graph.loadedPath ?? "∅")")
        check((graph.edges(for: "kaifa") ?? []).contains { $0.text == "开发" }, "整句边表 kaifa 有 开发")

        // ---- 自定义双拼：改一个键位，引擎要跟着改 ----
        var custom = ShuangpinTables.xiaohe
        custom.finals = custom.finals.map { entry in
            var next = entry
            if entry.key == "k" { next.finals = ["uai"] }
            if entry.key == "y" { next.finals = ["ing", "un"] }
            return next
        }
        // 普通声母也改一个：n / l 互换键位（编辑器里 bind(initial:to:) 干的就是这个）
        var swapped = ShuangpinKeyEditor(table: custom)
        swapped.bind(initial: "l", to: "n")
        custom = swapped.table
        guard let json = try? JSONEncoder().encode(custom),
              let jsonString = String(data: json, encoding: .utf8) else {
            fail("自定义表 JSON 编码失败")
            restoreAll()
            print("拼音自检：通过 \(passed) 项，失败 \(failures.count) 项")
            exit(1)
        }
        Defaults[.pinyinCustomTable] = jsonString
        Defaults[.pinyinLayout] = .custom
        center.applySettings()
        check(engine.scheme?.table == custom, "设置→引擎：自定义表生效")
        expect(engine.compose("xypy")?.marked == "xing'ping",
               "自定义表把 ing 挪到 y 后 xypy 解成 xing'ping")
        expect(engine.compose("lihc")?.marked == "ni'hao", "n/l 互换后 lihc 解成 ni'hao")
        expect(engine.compose("nihc")?.marked == "li'hao", "n/l 互换后 nihc 解成 li'hao")
        // 坏 JSON 不能把拼音方案整个打死：回落小鹤
        Defaults[.pinyinCustomTable] = "{坏掉的键位表"
        center.applySettings()
        expect(engine.scheme?.table == ShuangpinTables.xiaohe, "坏 JSON 回落小鹤而不是打不出字")
        Defaults[.pinyinCustomTable] = jsonString

        // ---- 模糊音 ----
        Defaults[.pinyinLayout] = .fullPinyin
        PinyinSettings.save(fuzzyRules: .none)
        center.applySettings()
        let zRules = varRules { $0.zZh = true }
        PinyinSettings.save(fuzzyRules: zRules)
        center.applySettings()
        check(engine.fuzzy.zZh, "设置→引擎：模糊音 z↔zh 生效")
        expect(engine.compose("zongguo")?.candidates.contains { $0.text == "中国" } == true,
               "开 z↔zh 后 zongguo 能出 中国")
        PinyinSettings.save(fuzzyRules: .none)
        center.applySettings()

        // ---- 敲错纠正 ----
        Defaults[.pinyinTypoCorrection] = true
        center.applySettings()
        check(engine.typoEnabled && engine.correctionEnabled, "设置→引擎：敲错纠正开启")
        expect(engine.compose("nihooma")?.candidates.contains { $0.text == "你好吗" } == true,
               "nihooma 纠正后能出 你好吗")
        Defaults[.pinyinTypoCorrection] = false
        center.applySettings()
        check(!engine.typoEnabled && !engine.correctionEnabled, "设置→引擎：关掉纠正")
        Defaults[.pinyinTypoCorrection] = true
        center.applySettings()

        // ---- 语境参与 ----
        let bare = engine.compose("ba")?.candidates.first?.text ?? ""
        let after = engine.compose("ba", leftContext: "做了")?.candidates.first?.text ?? ""
        check(!bare.isEmpty && !after.isEmpty, "单音节在有无语境下都出候选（\(bare) / \(after)）")

        // ---- 「显示打分」的拆解 ----
        // 这个开关以前只接了形码整句，拼音 / 双拼的候选栏一个分都看不到；而拆解是
        // 显示时现走一遍逐字链算的，不是解码时记的账——不对账就等于在骗人。
        func dims(_ item: PinyinComposingCandidate) -> SentenceScoreDimensions {
            SentenceScoreDimensions(pinyin: item,
                                    chain: engine.modelScoreParts(for: item, leftContext: ""))
        }
        if let word = engine.compose("kf")?.candidates.first(where: { !$0.isSentence }) {
            let parts = dims(word)
            check(abs(parts.sum - word.score) < 1e-9,
                  "词级候选的打分拆解与总分守恒（\(word.text)）")
            check(abs(parts.structural) < 1e-9,
                  "词级候选没有组句结构项（实得 \(parts.structural)）")
            check(!parts.generalNgram.isZero, "词级候选拆得出通用ngram分")
        } else {
            fail("kf 应该有候选（打分拆解无从验证）")
        }
        if let frame = engine.compose("woxiangqubeijingdeshihou"),
           let sentence = frame.candidates.first(where: { $0.isSentence }) {
            let parts = dims(sentence)
            check(abs(parts.sum - sentence.score) < 1e-9,
                  "整句候选的打分拆解与总分守恒（\(sentence.text)）")
            let shown = parts.displayText()
            check(shown.contains("通用ngram")
                  && (abs(parts.structural) < 0.005 || shown.contains("组句项")),
                  "整句打分串拿得出维度标签：\(shown)")
        } else {
            fail("woxiangqubeijingdeshihou 应该出整句候选（打分拆解无从验证）")
        }
        // 模糊音 / 敲错的代价要单开一项：混进通用分里就看不出这条候选是被改过的读法
        PinyinSettings.save(fuzzyRules: varRules { $0.zZh = true })
        center.applySettings()
        let altered = engine.compose("zongguo")?.candidates.first { $0.penalty > 0 }
        PinyinSettings.save(fuzzyRules: .none)
        center.applySettings()
        if let altered {
            let parts = dims(altered)
            check(parts.spelling < 0 && parts.displayText().contains("写法"),
                  "模糊音命中的候选拆得出「写法」代价：\(parts.displayText())")
            check(abs(parts.sum - altered.score) < 1e-9, "扣了写法代价后拆解仍与总分守恒")
        } else {
            fail("开 z↔zh 后 zongguo 应有一条带写法代价的候选（代价归因无从验证）")
        }
        // 学习通道的分要能归到它自己那一头上（混进「通用ngram」就是假归因）。
        // 注意拆解必须在钩子还挂着的时候算：拆的是「现在这条钩子加了多少分」，
        // 摘了钩子再去拆一个带着学习分算出来的 score，两边对不上账。
        let savedBlend = engine.decoder.learningBonusProvider
        engine.decoder.learningBonusProvider = { _, _, _, target in
            PinyinLearningBonus(sessionCache: target == "世".unicodeScalars.first!.value ? 1.5 : 0)
        }
        let boostedFrame = engine.compose("shijie")
        let boostedWorld = boostedFrame?.candidates.first(where: { $0.text == "世界" })
        let attributed = boostedWorld.map(dims)
        engine.decoder.learningBonusProvider = savedBlend
        if let parts = attributed, let boostedWorld {
            check(abs(parts.sessionCache - 1.5) < 1e-9 && parts.userNgram.isZero,
                  "会话缓存的加分落在「会话缓存」项（\(parts.sessionCache)）")
            check(abs(parts.sum - boostedWorld.score) < 1e-9, "混入学习分后拆解仍与总分守恒")
        } else {
            fail("shijie 应该出 世界（通道归因无从验证）")
        }

        // ---- 个性化钩子（学习通道 A/B 的接口）----
        // 不碰真实学习数据（CLI 跑自检时不该开 sqlite / Keychain），
        // 只验证「钩子装上去，拼音的分数真的跟着走」——那两个通道以前长在整句解码器里，
        // 拼音换了自己的解码器，接口断在这里就等于「越用越准」对拼音用户悄悄消失。
        let plain = engine.compose("shijie")?.candidates.first?.score ?? 0
        let saved = engine.decoder.learningBonusProvider
        engine.decoder.learningBonusProvider = { _, _, _, target in
            PinyinLearningBonus(userNgram: target == "世".unicodeScalars.first!.value ? 3.0 : 0)
        }
        let boosted = engine.compose("shijie")
        engine.decoder.learningBonusProvider = saved
        let boostedTop = boosted?.candidates.first?.score ?? 0
        check(boostedTop > plain || boosted?.candidates.first?.text != engine.compose("shijie")?.candidates.first?.text,
              "逐字分数钩子生效（\(String(format: "%.2f", plain)) → \(String(format: "%.2f", boostedTop))）")
        // 钩子撤掉后必须回到纯通用模型的分数（评测台跑的就是这个口径）
        check(abs((engine.compose("shijie")?.candidates.first?.score ?? 0) - plain) < 1e-9,
              "钩子摘掉后分数回到纯通用模型口径")

        // ---- 长度上限 ----
        let long = String(repeating: "wo", count: 40)
        expect(engine.compose(long)?.candidates.isEmpty == false, "超长串仍出候选且不卡死")

        center.applySettings()
        let code: Int32 = failures.isEmpty ? 0 : 1
        restoreAll()
        print("拼音自检：通过 \(passed) 项，失败 \(failures.count) 项")
        for line in failures { print("  FAIL \(line)") }
        exit(code)
    }

    // MARK: 断言

    private static func varRules(_ mutate: (inout PinyinFuzzyRules) -> Void) -> PinyinFuzzyRules {
        var rules = PinyinFuzzyRules.none
        mutate(&rules)
        return rules
    }

    private static func check(_ condition: Bool, _ what: String) {
        if condition { passed += 1 } else { fail(what) }
    }

    private static func expect(_ condition: Bool, _ what: String) {
        if condition { passed += 1 } else { fail(what) }
    }

    private static func fail(_ what: String) {
        failures.append(what)
    }
}
