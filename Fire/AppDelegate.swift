//
//  AppDelegate.swift
//  Fire
//
//  Created by 虚幻 on 2019/9/15.
//  Copyright © 2019 qwertyyb. All rights reserved.
//

import AppKit
import Carbon
import Defaults
import ApplicationServices
import InputMethodKit

#if LEAN_BUILD
@main
#else
@NSApplicationMain
#endif
class AppDelegate: NSObject, NSApplicationDelegate {

#if LEAN_BUILD
    // 精简工具链（仅 Command Line Tools，无 ibtool）构建时不编译 MainMenu.xib，
    // 且 Info.plist 没有 NSMainNibFile —— NSApplicationMain 找不到主 nib 的
    // File's Owner，delegate 为 nil，applicationDidFinishLaunching 永不触发：
    // Fire.shared（含 IMKServer 实例）从不创建，imklaunchagent 永远
    // "NO Endpoint"，选中输入法后按键全部直通。这里用代码显式接上 delegate，
    // 与 nib 的 File's Owner 连线完全等价；Xcode 构建不走此分支。
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
#endif

    var fire: Fire!
    var statistics: Statistics!
    var statusBar: StatusBar!
    var cliServer: FireCLIServer!
    private var preferencesHotkeyTap: CFMachPort?
    private var preferencesHotkeyRunLoopSource: CFRunLoopSource?
    // 全局快捷键：优先 Carbon RegisterEventHotKey（不把输入法主线程放进
    // 系统按键链路），注册失败时才退回事件 tap。
    private var preferencesHotKeyRef: EventHotKeyRef?
    private var preferencesHotKeyHandler: EventHandlerRef?
    private var preferencesHotkeyObserver: Defaults.Observation?

    func installInputSource() {
        print("install input source")
        InputSource.shared.registerInputSource()
        InputSource.shared.activateInputSource()
        InputSource.shared.selectInputSource { _ in
            NSApp.terminate(self)
        }
    }

    func stop() {
        InputSource.shared.deactivateInputSource()
        NSApp.terminate(nil)
    }

    private func commandHandler() -> Bool {
        if CommandLine.arguments.count > 1 {
            let command = CommandLine.arguments[1]
            if command == "--install" {
                print("[Fire] launch argument: \(command)")
                installInputSource()
                return false
            }
            if command == "--build-dict" {
                print("[Fire] launch argument: \(command)")
                print("[Fire] build dict")
                buildDict()
                NSApp.terminate(nil)
                return false
            }
            if command == "--replay-eval" {
                // 离线回放评估：统计历史整句的 top-1 命中率（学习基线/对比）
                let code = ReplayTuner.run()
                exit(code)
            }
            if command == "--decode-probe" {
                // 整句解码探针：打印候选的各维度打分拆解（显示打分验证/调参归因）
                exit(SentenceDecodeProbe.run(codes: Array(CommandLine.arguments.dropFirst(2))))
            }
            if command == "--preview-shuangpin" {
                // 键位编辑器离屏渲染（调试）：渲成 PNG 后退出，看键盘图排得对不对
                ShuangpinEditorPreview.run()
                return false
            }
            if command == "--shuangpin-editor-selftest" {
                // 键位编辑器入口自检：「编辑键位…」能不能真的把窗口拉到屏前
                ShuangpinEditorWindowSelfCheck.run()
                return false
            }
            if command == "--pinyin-selftest" {
                // 拼音方案自检：跑一遍「设置 → 引擎 → 候选」的接线断言后退出
                PinyinSelfCheck.run()
                return false
            }
            if command == "--learning-selftest" {
                // 学习数据 TCSKNM02 导入导出自检（合成计数往返 + 真实读取器交叉验证）
                exit(LearningSelfTest.run())
            }
            if command == "--rebuild-learning" {
                // 全量重建通道 B：清空计数 + 重置 learned 标记 + 重放全部历史
                let semaphore = DispatchSemaphore(value: 0)
                LearnerCenter.shared.rebuildFromHistory { processed, finished in
                    if finished {
                        print("[Learning] rebuild finished: \(processed) records")
                        semaphore.signal()
                    }
                }
                semaphore.wait()
                exit(0)
            }
            if command == "--export-learning" {
                guard CommandLine.arguments.count > 2 else {
                    print("usage: --export-learning <path>")
                    exit(1)
                }
                let path = CommandLine.arguments[2]
                // 回调在后台线程交付：信号量同步等待，处理完即退出，
                // 不落入完整应用启动（避免与 Statistics.shared 并发初始化）
                let semaphore = DispatchSemaphore(value: 0)
                var exitCode: Int32 = 0
                LearnerCenter.shared.exportNgramData { result in
                    switch result {
                    case .success(let data):
                        do {
                            try data.write(to: URL(fileURLWithPath: path))
                            print("[Learning] exported \(data.count) bytes -> \(path)")
                        } catch {
                            print("[Learning] write failed: \(error)")
                            exitCode = 1
                        }
                    case .failure(let error):
                        print("[Learning] export failed: \(error)")
                        exitCode = 1
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                exit(exitCode)
            }
            if command == "--import-learning" {
                guard CommandLine.arguments.count > 2 else {
                    print("usage: --import-learning <path>")
                    exit(1)
                }
                let path = CommandLine.arguments[2]
                let data: Data
                do {
                    data = try Data(contentsOf: URL(fileURLWithPath: path))
                } catch {
                    print("[Learning] read failed: \(error)")
                    exit(1)
                }
                let semaphore = DispatchSemaphore(value: 0)
                var exitCode: Int32 = 0
                LearnerCenter.shared.importNgramData(data) { result in
                    switch result {
                    case .success(let entries):
                        print("[Learning] imported \(entries) entries from \(path)")
                    case .failure(let error):
                        print("[Learning] import failed: \(error)")
                        exitCode = 1
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                exit(exitCode)
            }
            if command == "--stop" {
                print("[Fire] launch argument: \(command)")
                print("[Fire] stop")
                stop()
                return false
            }
            if command == "--get-mode" {
                let cli = FireCLI()
                cli.getMode()
                return false
            }
            if command == "--set-mode" {
                if CommandLine.arguments.count < 2 {
                    print("[Fire] commandHandler: no mode specifiy (enUs/zhhans)")
                }
                let mode = CommandLine.arguments[2]
                let showTip = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] != "false" : true
                let cli = FireCLI()
                cli.setMode(mode, showTip: showTip)
                return false
            }
        }
        return true
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // macOS 27 InputMethodKit 起，Legacy DistributedObjects 服务端的
        // NSConnection 注册名固定为 "<bundleID>_Connection"，而客户端改按
        // +[IMKServer connectionNameFor:] 的白名单规范化结果 "<bundleID>.Connection"
        // 查找（白名单只含 Apple 自家 IME，日志: Refusing connection name for
        // bundle: unrecognized 'InputMethodConnectionName' value），两者永远
        // 差一个分隔符 → imklaunchagent 始终 "NO Endpoint, Bail"，选中输入法
        // 后按键全部直通应用。macOS 27+ 打开 Modern XPC 模式：endpoint 直接
        // 通过 setIMKXPCEndpoint 交给 agent 与客户端，不再依赖连接名字符串。
        // 必须在 Fire.shared（内部创建 IMKServer）之前注册。
        if #available(macOS 27, *) {
            UserDefaults.standard.register(defaults: ["IMKServerRunLoopModern": true])
        }
        // 已下线的「码表拼音混合」方案：老配置先归到「码表」，再让任何逻辑读 codeMode
        migrateRemovedMixedCodeMode()
        if !commandHandler() {
            return
        }
        // 候选框渲染预览（调试）：离屏渲染各状态 PNG 后退出，不初始化输入法
        if CommandLine.arguments.contains("--preview-candidates") {
            CandidatesPreviewRenderer.run()
            return
        }
        // 候选窗动画自检（调试）：驱动渐入/尺寸/渐出全流程采样断言后退出
        if CommandLine.arguments.contains("--preview-window-anim") {
            WindowAnimationSelfCheck.run()
            return
        }
        // 拼音方案锁定项归一（覆盖老版本升级残留的自由配置）
        enforcePinyinInputModeDefaults()
        // 拼音方案在用：就把音节索引先载好（约 1.9s，后台跑），别让第一次敲字付这笔钱
        if Defaults[.codeMode] == .pinyin {
            PinyinEngineCenter.shared.prepareIfNeeded()
        }
        // 老版本平铺在 Resources 根的码表路径迁移到 Resources/schemas
        SchemaCatalog.migrateLegacyTablePaths()
        // 内置默认主题升级
        migrateDefaultThemeIfNeeded()
        // 无配套整句码表的方案（五笔86/98 等）：整句强制关闭
        enforceTableSentenceSupport()
        if !hasDict() {
            NSLog("[Fire] first run，build dict")
            buildDict()
        }
        NSLog("[Fire] app is running")
        fire = Fire.shared
        statistics = Statistics.shared
        // 学习系统：订阅上屏/撤销信号，加载 user-learning.db，必要时自动回填
        _ = LearnerCenter.shared
        statusBar = StatusBar.shared
        cliServer = FireCLIServer()
        registerURLHandler()
        installPreferencesHotkeyMonitor()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    // MARK: - URL Scheme

    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard
            let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: urlString)
        else { return }
        handleIncomingURL(url)
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "fire" else { return }
        let host = url.host?.lowercased()
        let path = url.path.lowercased()

        // 兼容 fire://theme/import 与 fire://import-theme 两种写法
        let isImport = (host == "theme" && path == "/import") || host == "import-theme"
        guard isImport else { return }

        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let dataItem = components.queryItems?.first(where: { $0.name == "data" }),
            let encoded = dataItem.value
        else {
            showImportAlert(success: false, message: "导入链接缺少 data 参数")
            return
        }

        guard let json = decodeBase64URL(encoded) else {
            showImportAlert(success: false, message: "导入链接的 data 解码失败")
            return
        }

        switch parseThemeConfig(jsonData: json) {
        case .failure(let error):
            showImportAlert(success: false, message: error.localizedDescription)
        case .success(let config):
            confirmAndImport(config)
        }
    }

    private func decodeBase64URL(_ s: String) -> String? {
        var str = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        let pad = 4 - (str.count % 4)
        if pad < 4 { str.append(String(repeating: "=", count: pad)) }
        guard let data = Data(base64Encoded: str) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func confirmAndImport(_ config: ThemeConfig) {
        let alert = NSAlert()
        alert.messageText = "导入主题 \(config.name)(\(config.id))？"
        alert.informativeText = "作者：\(config.author)\n确认后将覆盖现有的已导入主题。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            applyImportedTheme(config)
            showImportAlert(success: true, message: "主题 \(config.name) 导入成功")
        }
    }

    private func showImportAlert(success: Bool, message: String) {
        let alert = NSAlert()
        alert.messageText = success ? "导入成功" : "导入失败"
        alert.informativeText = message
        alert.alertStyle = success ? .informational : .warning
        alert.addButton(withTitle: "确定")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Preferences Hotkey
extension AppDelegate {
    private func installPreferencesHotkeyMonitor() {
        applyPreferencesHotkey()
        // 快捷键改了要重新注册；Carbon 热键是按当前键位一次性注册的
        preferencesHotkeyObserver = Defaults.observe(
            keys: .openPreferencesShortcutModifier, .openPreferencesShortcutKey
        ) { [weak self] in
            guard let self else { return }
            if Thread.isMainThread {
                self.applyPreferencesHotkey()
            } else {
                DispatchQueue.main.async { self.applyPreferencesHotkey() }
            }
        }
    }

    /// 卸载并重装全局快捷键：先试 Carbon 热键，失败（fn 修饰键 / 组合键被占用 /
    /// 注册失败）再退回事件 tap。Carbon 路径不需要辅助功能权限。
    private func applyPreferencesHotkey() {
        uninstallPreferencesHotkey()
        if registerPreferencesHotKey() {
            NSLog("[Fire] preferences hotkey registered via Carbon")
            return
        }
        NSLog("[Fire] Carbon hotkey unavailable, falling back to event tap")
        installPreferencesHotkeyTap()
    }

    private func uninstallPreferencesHotkey() {
        if let ref = preferencesHotKeyRef {
            UnregisterEventHotKey(ref)
            preferencesHotKeyRef = nil
        }
        if let handler = preferencesHotKeyHandler {
            RemoveEventHandler(handler)
            preferencesHotKeyHandler = nil
        }
        if let tap = preferencesHotkeyTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = preferencesHotkeyRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
            preferencesHotkeyTap = nil
            preferencesHotkeyRunLoopSource = nil
        }
    }

    private static func carbonModifiers(for key: ModifierKey) -> UInt32? {
        switch key {
        case .control:
            return UInt32(controlKey)
        case .command:
            return UInt32(cmdKey)
        case .option:
            return UInt32(optionKey)
        case .shift, .leftShift, .rightShift:
            return UInt32(shiftKey)
        case .function:
            // Carbon 没有可用的 fn 修饰键掩码，交给事件 tap 兜底
            return nil
        }
    }

    private func registerPreferencesHotKey() -> Bool {
        guard let modifiers = AppDelegate.carbonModifiers(
                for: Defaults[.openPreferencesShortcutModifier]) else { return false }
        let key = Defaults[.openPreferencesShortcutKey].lowercased()
        guard let keyCode = AppDelegate.keyCode(for: key) else { return false }

        if preferencesHotKeyHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData -> OSStatus in
                    guard let userData else { return OSStatus(eventNotHandledErr) }
                    DispatchQueue.main.async {
                        FirePreferencesController.shared.show()
                    }
                    return noErr
                },
                1, &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &preferencesHotKeyHandler)
            guard status == noErr, preferencesHotKeyHandler != nil else { return false }
        }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x46495245), id: 1) // 'FIRE'
        let status = RegisterEventHotKey(
            UInt32(keyCode), modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let hotKeyRef else {
            NSLog("[Fire] RegisterEventHotKey status=%d", status)
            return false
        }
        preferencesHotKeyRef = hotKeyRef
        return true
    }

    private static let modifierMask: NSEvent.ModifierFlags = [
        .shift, .control, .option, .command, .function
    ]

    private static func modifiersMatch(_ flags: NSEvent.ModifierFlags,
                                       required: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection(modifierMask)
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
}

// MARK: - Event Tap
extension AppDelegate {
    private func installPreferencesHotkeyTap() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            NSLog("[Fire] Accessibility permission not granted. Hotkey may not work until allowed.")
        }

        let mask: CGEventMask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = app.preferencesHotkeyTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            if app.handlePreferencesHotkey(event) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        preferencesHotkeyTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let tap = preferencesHotkeyTap else {
            NSLog("[Fire] Failed to create event tap for hotkey.")
            return
        }

        preferencesHotkeyRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = preferencesHotkeyRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func handlePreferencesHotkey(_ event: CGEvent) -> Bool {
        let key = Defaults[.openPreferencesShortcutKey].lowercased()
        guard let keyCode = AppDelegate.keyCode(for: key) else { return false }
        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == keyCode else { return false }

        let required = AppDelegate.modifierFlag(for: Defaults[.openPreferencesShortcutModifier])
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        if AppDelegate.modifiersMatch(flags, required: required) {
            DispatchQueue.main.async {
                FirePreferencesController.shared.show()
            }
            return true
        }
        return false
    }
}
