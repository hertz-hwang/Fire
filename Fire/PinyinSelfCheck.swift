//
//  PinyinSelfCheck.swift
//  Fire
//
//  拼音方案自检（命令行 `Fire --selfcheck-pinyin`，跑完即退，不初始化输入法）。
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
        check(center.prepareSync(), "音节索引载入")
        check(center.ready, "引擎就绪")
        check(NgramModel.shared.loaded, "字级 ngram 模型已载入（拼音的分数全靠它）")
        let engine = center.engine

        // ---- 全拼 ----
        center.applySettings()
        check(engine.scheme == nil, "全拼下引擎不带双拼方案")
        expect(engine.compose("nihao")?.candidates.first?.text == "你好", "全拼 nihao 首选你好")
        expect(engine.compose("nihao")?.candidates.first?.consumedKeys == 5, "全拼整词吃满 5 键")
        expect(engine.compose("nihao")?.marked == "ni'hao", "组字区显示分段拼音")
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

        // ---- 自定义双拼：改一个键位，引擎要跟着改 ----
        var custom = ShuangpinTables.xiaohe
        custom.finals = custom.finals.map { entry in
            var next = entry
            if entry.key == "k" { next.finals = ["uai"] }
            if entry.key == "y" { next.finals = ["ing", "un"] }
            return next
        }
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

        // ---- 个性化钩子（学习通道 A/B 的接口）----
        // 不碰真实学习数据（CLI 跑自检时不该开 sqlite / Keychain），
        // 只验证「钩子装上去，拼音的分数真的跟着走」——那两个通道以前长在整句解码器里，
        // 拼音换了自己的解码器，接口断在这里就等于「越用越准」对拼音用户悄悄消失。
        let plain = engine.compose("shijie")?.candidates.first?.score ?? 0
        let saved = engine.decoder.logpBlender
        engine.decoder.logpBlender = { base, _, _, target in
            base + (target == "世".unicodeScalars.first!.value ? 3.0 : 0.0)
        }
        let boosted = engine.compose("shijie")
        engine.decoder.logpBlender = saved
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
