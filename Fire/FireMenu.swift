//
//  menu.swift
//  Fire
//
//  Created by marchyang on 2020/10/26.
//  Copyright © 2020 qwertyyb. All rights reserved.
//

import Foundation
import AppKit
import Sparkle
import Defaults
import UniformTypeIdentifiers

extension FireInputController {
    /// 状态栏快捷菜单开关项的标识（representedObject）
    private enum QuickKey: String {
        case enableSentenceMode
        case enableSentenceScore
        case enableSentenceAutoCommit
        case enableSentenceAllowDuplicateSingle
        case wubiCodeTip
        case enableCharDivTip
    }

    /* -- menu actions start -- */
    @objc func openAbout (_ sender: Any!) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(sender)
    }
    @objc func checkForUpdates(_ sender: Any!) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        SUUpdater.shared()?.checkForUpdates(sender)
    }
    override func showPreferences(_ sender: Any!) {
        // 侧边栏风格首选项窗口由控制器负责激活策略与前台激活
        FirePreferencesController.shared.show()
    }
    @objc func showUserDictPrefs(_ sender: Any!) {
        FirePreferencesController.shared.showPane("用户词库")
    }

    /// 输入法菜单由系统进程托管显示：自定义项经序列化往返后，
    /// 点击回传的 sender 不是原始 NSMenuItem，而是包在
    /// ["IMKCommandMenuItem": NSMenuItem] 字典里（同 setAppicationMode 的口径）。
    /// 统一在此解包。
    private func quickMenuItem(from sender: Any?) -> NSMenuItem? {
        if let item = sender as? NSMenuItem {
            return item
        }
        if let dict = sender as? [String: Any],
           let item = dict["IMKCommandMenuItem"] as? NSMenuItem {
            return item
        }
        return nil
    }

    // MARK: - 便捷开关动作
    // 注意：这些菜单项一律不设 target（走响应链），
    // 系统输入法菜单中显式 target 会在序列化后失效导致点击无响应。

    /// 状态栏快捷开关：翻转对应 Defaults 开关，引擎侧 observer 自动生效
    @objc func toggleQuickSetting(_ sender: Any!) {
        guard let item = quickMenuItem(from: sender),
              let raw = item.representedObject as? String,
              let key = QuickKey(rawValue: raw) else {
            NSLog("[FireMenu] toggleQuickSetting: unrecognized sender \(String(describing: sender))")
            return
        }
        switch key {
        case .enableSentenceMode:
            Defaults[.enableSentenceMode].toggle()
        case .enableSentenceScore:
            Defaults[.enableSentenceScore].toggle()
        case .enableSentenceAutoCommit:
            Defaults[.enableSentenceAutoCommit].toggle()
        case .enableSentenceAllowDuplicateSingle:
            Defaults[.enableSentenceAllowDuplicateSingle].toggle()
        case .wubiCodeTip:
            Defaults[.wubiCodeTip].toggle()
        case .enableCharDivTip:
            Defaults[.enableCharDivTip].toggle()
        }
        // 拼音方案锁定项兜底归一（引擎 epochObserver 也会再兜一次）
        enforcePinyinInputModeDefaults()
        NSLog("[FireMenu] toggleQuickSetting: \(raw) -> \(quickValue(key))")
    }

    private func quickValue(_ key: QuickKey) -> Bool {
        switch key {
        case .enableSentenceMode: return Defaults[.enableSentenceMode]
        case .enableSentenceScore: return Defaults[.enableSentenceScore]
        case .enableSentenceAutoCommit: return Defaults[.enableSentenceAutoCommit]
        case .enableSentenceAllowDuplicateSingle: return Defaults[.enableSentenceAllowDuplicateSingle]
        case .wubiCodeTip: return Defaults[.wubiCodeTip]
        case .enableCharDivTip: return Defaults[.enableCharDivTip]
        }
    }

    /// 候选词排列：横向/竖向单选
    @objc func selectDirection(_ sender: Any!) {
        guard let raw = quickMenuItem(from: sender)?.representedObject as? String else { return }
        switch raw {
        case "horizontal":
            Defaults[.candidatesDirection] = .horizontal
        case "vertical":
            Defaults[.candidatesDirection] = .vertical
        default:
            return
        }
        NSLog("[FireMenu] selectDirection: \(raw)")
    }

    /// 选择内置码表
    @objc func selectTable(_ sender: Any!) {
        guard let path = quickMenuItem(from: sender)?.representedObject as? String else { return }
        applyTableSelection(path)
    }

    /// 「自定义码表…」：弹文件面板选本地码表
    @objc func selectCustomTable(_ sender: Any!) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let openPanel = NSOpenPanel()
        let schemasDir = SchemaCatalog.schemasDirectory
        openPanel.directoryURL = FileManager.default.fileExists(atPath: schemasDir)
            ? URL(fileURLWithPath: schemasDir)
            : Bundle.main.resourceURL
        openPanel.prompt = "选择码表文件"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        var types: [UTType] = []
        for ext in SchemaCatalog.supportedExtensions {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        openPanel.allowedContentTypes = types
        guard openPanel.runModal() == .alertFirstButtonReturn,
              let path = openPanel.url?.path else { return }
        applyTableSelection(path)
    }

    /// 切换码表：持久化路径并后台重建索引，与「常规」面板 applyTableSelection 同义。
    /// wbTablePath 变化由 SentenceEngine 的 epochObserver 监听并打脏整句词图。
    private func applyTableSelection(_ path: String) {
        let changed = path != Defaults[.wbTablePath]
        Defaults[.wbTablePath] = path
        // 无配套整句码表的方案（五笔86/98 等）：整句强制关闭
        enforceTableSentenceSupport()
        NSLog("[FireMenu] applyTableSelection: \(path), changed=\(changed)")
        guard changed else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            DictManager.shared.close()
            buildDict()
            DictManager.shared.reinit()
            // 整句词图跟随词库重建
            SentenceLexicon.shared.markDirty()
        }
    }

    // MARK: - 便捷开关菜单项构造

    /// 开关项：不可用时 action 置 nil（灰显且不会被误触发），✓ 状态照常显示
    private func toggleItem(title: String, key: QuickKey, enabled: Bool, help: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: enabled ? #selector(toggleQuickSetting(_:)) : nil,
                              keyEquivalent: "")
        item.representedObject = key.rawValue
        item.state = quickValue(key) ? .on : .off
        item.isEnabled = enabled
        if let help = help {
            item.toolTip = help
        }
        return item
    }

    /// 灰色分组标题（不可点，仅作视觉分组）
    private func sectionHeader(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// 码表扁平组：系统托管的输入法菜单对二级子菜单的点击回传不可靠，
    /// 直接平铺：分组标题 + 内置可选表（✓ + 描述/作者悬浮提示）+ 自定义路径提示
    /// + 「自定义码表…」
    private func buildTableItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = [sectionHeader(title: "选择码表")]
        let currentPath = Defaults[.wbTablePath]

        // 当前为自定义路径（或 #visible=0 的内置表）：展示文件名
        if !currentPath.isEmpty, !SchemaCatalog.isSelectableBuiltin(path: currentPath) {
            let current = NSMenuItem(title: "当前：\((currentPath as NSString).lastPathComponent)",
                                      action: nil,
                                      keyEquivalent: "")
            current.isEnabled = false
            current.state = .on
            items.append(current)
        }

        for info in SchemaCatalog.builtinTables() {
            let item = NSMenuItem(title: info.name,
                                  action: #selector(selectTable(_:)),
                                  keyEquivalent: "")
            item.representedObject = info.path
            item.state = (info.path == currentPath) ? .on : .off
            if !info.tooltip.isEmpty {
                item.toolTip = info.tooltip
            }
            items.append(item)
        }

        let custom = NSMenuItem(title: "自定义码表…",
                                 action: #selector(selectCustomTable(_:)),
                                 keyEquivalent: "")
        items.append(custom)
        return items
    }

    /// 候选词排列扁平组：横向/竖向 单选
    private func buildDirectionItems() -> [NSMenuItem] {
        let direction = Defaults[.candidatesDirection]
        let horizontal = NSMenuItem(title: "候选词排列：横向",
                                     action: #selector(selectDirection(_:)),
                                     keyEquivalent: "")
        horizontal.representedObject = "horizontal"
        horizontal.state = direction == .horizontal ? .on : .off
        let vertical = NSMenuItem(title: "候选词排列：竖向",
                                   action: #selector(selectDirection(_:)),
                                   keyEquivalent: "")
        vertical.representedObject = "vertical"
        vertical.state = direction == .vertical ? .on : .off
        return [horizontal, vertical]
    }

    /// 便捷功能快捷区：门控口径与「常规」设置面板一致
    /// （拼音方案锁整句/空格上屏/提示编码；无配套整句码表的方案整句不可开；
    /// 打分/自动上屏/单字重码组句仅整句开启时可用）
    private func buildQuickSettingItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let isPinyin = Defaults[.codeMode] == .pinyin
        let sentenceOn = Defaults[.enableSentenceMode]

        // 码表（仅码表方案；选项来自 Resources/schemas，扁平化保证点击可靠）
        if !isPinyin {
            items.append(contentsOf: buildTableItems())
        }

        // 整句：拼音方案强制开（锁定）；无配套整句码表（五笔86/98等）不可开
        let sentenceEnabled = !isPinyin
            && SchemaCatalog.supportsSentence(selectedTablePath: Defaults[.wbTablePath])
        let sentenceHelp = sentenceEnabled
            ? nil
            : (isPinyin ? "拼音方案强制整句" : "所选码表无配套整句码表")
        items.append(toggleItem(title: "整句", key: .enableSentenceMode,
                                 enabled: sentenceEnabled, help: sentenceHelp))

        items.append(toggleItem(title: "显示打分", key: .enableSentenceScore,
                                 enabled: sentenceOn,
                                 help: "在各整句候选末尾显示各维度加权得分（通用ngram、用户ngram等）"))
        items.append(toggleItem(title: "自动上屏", key: .enableSentenceAutoCommit,
                                 enabled: sentenceOn && !isPinyin,
                                 help: isPinyin ? "拼音方案统一空格上屏" : nil))
        items.append(toggleItem(title: "单字重码组句", key: .enableSentenceAllowDuplicateSingle,
                                 enabled: sentenceOn && !isPinyin,
                                 help: isPinyin ? "拼音方案固定启用" : "允许同码非首选单字参与组句"))
        items.append(toggleItem(title: "提示编码", key: .wubiCodeTip,
                                 enabled: !isPinyin,
                                 help: isPinyin ? "拼音方案整句走精确码边，固定关闭" : nil))

        // 候选词排列：横向/竖向（扁平两项，不用子菜单）
        items.append(contentsOf: buildDirectionItems())

        items.append(toggleItem(title: "拆分信息悬浮提示", key: .enableCharDivTip,
                                 enabled: true,
                                 help: "鼠标悬停候选词时显示拆分信息"))
        return items
    }

    @objc func setAppicationMode(_ sender: Any!) {
        if let menuWrapper = sender as? [String: Any],
           let menuItem = menuWrapper["IMKCommandMenuItem"] as? NSMenuItem,
           let dict = menuItem.representedObject as? [String: Any],
           let bundleID = dict["bundleID"] as? String,
           let mode = dict["mode"] as? InputMode {
            NSLog("[FireInputController] setApplicationMode, \(bundleID), \(mode)")
            var appSettings = Defaults[.appSettings]
            appSettings[bundleID] = ApplicationSettingItem(bundleId: bundleID, inputMs: mode == .zhhans ? .zhhans : .enUS)
            Defaults[.appSettings] = appSettings
        }
    }
    override func menu() -> NSMenu! {
        NSLog("[FireInputController] menu")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.items = [
            NSMenuItem(title: "首选项", action: #selector(showPreferences(_:)), keyEquivalent: ""),
            NSMenuItem(title: "用户词库", action: #selector(showUserDictPrefs(_:)), keyEquivalent: ""),
        ]
        // 便捷功能快捷区：码表/整句/显示打分/自动上屏/单字重码组句/
        // 提示编码/候选词排列/拆分信息悬浮提示
        menu.items.append(NSMenuItem.separator())
        menu.items.append(contentsOf: buildQuickSettingItems())
        if !Defaults[.disableEnMode],
            let controller = CandidatesWindow.shared.inputController,
            let bundleID = controller.client()?.bundleIdentifier() {
            var displayName = bundleID
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                displayName = FileManager.default.displayName(atPath: url.path)
            }
            let title = "设置“\(displayName)”的预设为\(Fire.shared.inputMode == .zhhans ? "中文" : "英文")"
            let menuItem = NSMenuItem(title: title, action: #selector(setAppicationMode(_:)), keyEquivalent: "")
            menuItem.representedObject = [
                "bundleID": bundleID,
                "mode": Fire.shared.inputMode
            ]
            menu.items.append(contentsOf: [
                NSMenuItem.separator(),
                menuItem,
            ])
        }
        menu.items.append(contentsOf: [
            NSMenuItem.separator(),
            NSMenuItem(title: "检查更新", action: #selector(checkForUpdates(_:)), keyEquivalent: ""),
            NSMenuItem(title: "关于业火输入法", action: #selector(openAbout(_:)), keyEquivalent: "")
        ])
        return menu
    }
}
