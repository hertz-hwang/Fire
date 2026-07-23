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

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    var fire: Fire!
    var statistics: Statistics!
    var statusBar: StatusBar!
    var cliServer: FireCLIServer!
    var preferencesHotkeyMonitor: Any?
    private var preferencesHotkeyTap: CFMachPort?
    private var preferencesHotkeyRunLoopSource: CFRunLoopSource?

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
        if !commandHandler() {
            return
        }
        if !hasDict() {
            NSLog("[Fire] first run，build dict")
            buildDict()
        }
        NSLog("[Fire] app is running")
        fire = Fire.shared
        statistics = Statistics.shared
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
        installPreferencesHotkeyTap()
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
