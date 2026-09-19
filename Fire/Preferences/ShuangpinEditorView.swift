//
//  ShuangpinEditorView.swift
//  Fire
//
//  自定义双拼键位编辑器：模拟键盘图 + 可拖拽的声母 / 韵元素。
//
//  交互：
//  * 把右侧的韵母 / 翘舌声母拖到键盘上的某个键 → 绑到那个键（一个键可以挂多个韵母，
//    从上到下就是优先级；同一个韵母只会在一个键上，拖到新键等于搬走）。
//  * 点键帽选中它，下方列出它当前的绑定，可以逐个解绑、调整优先级。
//  * 「按键位重算零声母」把 a/ai/an/… 的两键写法按当前韵母键位重推一遍
//    （自定义方案最容易忘的就是这一栏，忘了一半的零声母音节打不出来）。
//  * 底部实时试打：敲几个键，看解出来的是什么拼音 —— 一眼看出键位合不合手。
//
//  校验：改完对全部 413 个音节做一遍「能不能编成两键」，编不出的直接列出来。
//  音节编不出来 = 那个音打不了，这种键位不该让用户保存了才发现。
//

import SwiftUI
import AppKit
import Defaults
import UniformTypeIdentifiers

/// 拖拽负载前缀：区分韵元素与声元素（都走同一条 onDrop 通道）。
private let finalPayloadPrefix = "fire-final:"
private let initialPayloadPrefix = "fire-initial:"

public struct ShuangpinEditorView: View {
    /// 正在编辑的键位（保存前不写回设置）。
    /// 规则都在 `ShuangpinKeyEditor` 里（纯函数、可单测），这里只负责画与转发
    @State private var editor: ShuangpinKeyEditor
    /// 选中键（点键帽选中，下方显示它的绑定明细）
    @State private var selectedKey: String?
    /// 拖拽悬停的键（高亮反馈）
    @State private var dropTarget: String?
    /// 试打缓冲
    @State private var probe = ""
    /// 校验结果
    @State private var unencodable: [String] = []
    @State private var ambiguous: [(keys: String, readings: [String])] = []
    @State private var alertText: String?
    let onFinish: (_ save: Bool, _ table: ShuangpinKeyTable?) -> Void

    private let rows: [[String]]
    private var table: ShuangpinKeyTable { editor.table }
    private var scheme: ShuangpinScheme { editor.scheme }

    init(table: ShuangpinKeyTable, onFinish: @escaping (Bool, ShuangpinKeyTable?) -> Void) {
        _editor = State(initialValue: ShuangpinKeyEditor(table: table))
        _probe = State(initialValue: "")
        self.onFinish = onFinish
        // 标准 QWERTY 三排；用到 `;` 的方案把它接在第三排后面
        var layout = [
            ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
            ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
            ["z", "x", "c", "v", "b", "n", "m"],
        ]
        if table.semicolon { layout[2].append(";") }
        rows = layout
        _unencodable = State(initialValue: ShuangpinEditorView.validate(table))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            keyboard
            selectionDetail
            HStack(alignment: .top, spacing: 14) {
                palette(title: "韵母（拖到键上）", items: PinyinSyllables.finals, kind: .final)
                palette(title: "翘舌声母", items: ["zh", "ch", "sh"], kind: .initial)
                    .frame(maxWidth: 180)
            }
            probeLine
            if !editor.unboundFinals().isEmpty {
                Text("还有 \(editor.unboundFinals().count) 个韵母没给键位：\(editor.unboundFinals().prefix(12).joined(separator: " "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !ambiguous.isEmpty {
                Text("一对键撞在多个零声母音节上：\(ambiguous.map { "\($0.keys)=\($0.readings.joined(separator: "/"))" }.joined(separator: " "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !unencodable.isEmpty {
                Text("编不出的音节 \(unencodable.count) 个：\(unencodable.prefix(24).joined(separator: " "))"
                    + (unencodable.count > 24 ? " …" : ""))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 560)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            Text("双拼键位").font(.headline)
            Menu("从预设开始…") {
                ForEach(ShuangpinTables.presets, id: \.name) { preset in
                    Button(preset.label) { load(preset.table) }
                }
            }
            .fixedSize()
            Button("重算零声母写法") {
                editor.deriveZeroInitials()
                revalidate()
            }
            .help("按当前韵母键位把 a/ai/an/ang/… 的两键写法重推一遍")
            Spacer()
            Button("取消") { onFinish(false, nil) }
            Button("保存") {
                if !editor.unboundFinals().isEmpty {
                Text("还有 \(editor.unboundFinals().count) 个韵母没给键位：\(editor.unboundFinals().prefix(12).joined(separator: " "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !ambiguous.isEmpty {
                Text("一对键撞在多个零声母音节上：\(ambiguous.map { "\($0.keys)=\($0.readings.joined(separator: "/"))" }.joined(separator: " "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !unencodable.isEmpty {
                    let samples = unencodable.prefix(3).joined(separator: " / ")
                    let count = unencodable.count
                    alertText = "还有 \(count) 个音节编不成两键（例如 \(samples)），保存后这些音打不出来。确认继续？"
                    return
                }
                onFinish(true, table)
            }
            .keyboardShortcut(.defaultAction)
        }
        .alert("键位不完整", isPresented: Binding(
            get: { alertText != nil }, set: { if !$0 { alertText = nil } }
        )) {
            Button("仍要保存") { onFinish(true, table) }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text(alertText ?? "")
        }
    }

    private func load(_ preset: ShuangpinKeyTable) {
        var next = preset
        // 从预设起步时保留「是否占用 ; 键」的事实：它决定 ; 进不进缓冲区
        next.semicolon = preset.semicolon
        editor = ShuangpinKeyEditor(table: next)
        selectedKey = nil
        revalidate()
    }

    // MARK: 键盘

    private var keyboard: some View {
        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, keys in
                // QWERTY 错位：第二排起每排整体右移半个键位
                HStack(spacing: 6) {
                    ForEach(keys, id: \.self) { key in
                        keyCap(key)
                    }
                }
                .padding(.leading, CGFloat(rowIndex) * 14)
            }
        }
    }

    private func keyCap(_ key: String) -> some View {
        let finals = table.finals(for: key)
        let initial = table.mappedInitial(for: key)
        let isSelected = selectedKey == key
        let isDropping = dropTarget == key
        return VStack(spacing: 2) {
            Text(key)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text(capSummary(key: key, finals: finals, initial: initial))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if finals.count > 2 {
                Text("+\(finals.count - 2)")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 52, height: 46)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropping ? Color.accentColor.opacity(0.35)
                        : isSelected ? Color.accentColor.opacity(0.18)
                        : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                              lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { selectedKey = key }
        .onDrop(of: [UTType.text], delegate: KeyDropHandler(
            key: key,
            onHover: { inside in dropTarget = inside ? key : (dropTarget == key ? nil : dropTarget) },
            onDrop: { kind, value in bind(kind, value, to: key); dropTarget = nil }
        ))
        .help(hint(for: key))
    }

    /// 键帽上的小字：有映射声母时先写声母，再挂最多两个韵母
    private func capSummary(key: String, finals: [String], initial: String?) -> String {
        let head = finals.prefix(2).joined(separator: "/")
        if let initial { return initial + " " + head }
        return head
    }

    private func hint(for key: String) -> String {
        var lines: [String] = ["键「\(key)」"]
        if let initial = table.mappedInitial(for: key) {
            lines.append("声母：\(initial)")
        }
        let finals = table.finals(for: key)
        if !finals.isEmpty {
            lines.append("韵母（按优先级）：" + finals.joined(separator: "、"))
        }
        if finals.isEmpty && table.mappedInitial(for: key) == nil {
            lines.append("未绑定：把右侧元素拖过来")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 选中键的明细

    @ViewBuilder private var selectionDetail: some View {
        if let key = selectedKey {
            let finals = table.finals(for: key)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("键「\(key)」").font(.callout.weight(.medium))
                    if let initial = table.mappedInitial(for: key) {
                        Text("声母 \(initial)")
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                        Button("解绑声母") { editor.unbindInitial(key); revalidate() }
                            .controlSize(.small)
                    }
                    Spacer()
                }
                if finals.isEmpty {
                    Text("这个键还没挂任何韵母。从右侧把韵母拖上来即可。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    // 优先级：同一键挂多个韵母时，从上往下第一个能拼成合法音节的算数
                    ForEach(Array(finals.enumerated()), id: \.element) { index, final in
                        HStack(spacing: 8) {
                            Text("\(index + 1)").font(.caption).foregroundStyle(.secondary)
                                .frame(width: 16, alignment: .leading)
                            Text(final)
                            Spacer()
                            Button("↑") { editor.moveFinal(in: key, at: index, by: -1); revalidate() }
                                .disabled(index == 0).controlSize(.small)
                            Button("↓") { editor.moveFinal(in: key, at: index, by: 1); revalidate() }
                                .disabled(index == finals.count - 1).controlSize(.small)
                            Button("移除") { editor.remove(final: final, from: key); revalidate() }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    // MARK: 元素面板

    private func palette(title: String, items: [String], kind: PaletteKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 6)], spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        chip(item, kind: kind)
                    }
                }
                .padding(2)
            }
            .frame(maxWidth: .infinity, maxHeight: 150)
        }
    }

    private func chip(_ item: String, kind: PaletteKind) -> some View {
        let boundKeys: [String] = kind == .final
            ? table.keysBinding(final: item)
            : table.keysBinding(initial: item)
        return Text(item)
            .font(.system(size: 11, design: .rounded))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(boundKeys.isEmpty ? Color.primary.opacity(0.06)
                        : Color.green.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if let key = boundKeys.first {
                    Text(key)
                        .font(.system(size: 8))
                        .padding(1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                        .foregroundStyle(.white)
                        .offset(x: 3, y: -3)
                }
            }
            .onDrag {
                NSItemProvider(object: kind.payloadPrefix + item as NSString)
            }
            // 拖不动的场合（触控板手势不灵、辅助输入）给一条点击路径：
            // 先点键帽选中，再点元素 = 绑到选中键
            .onTapGesture {
                guard let key = selectedKey else { return }
                bind(kind, item, to: key)
            }
            .help(boundKeys.isEmpty ? "拖到键盘上的键位绑定" : "已绑在 \(boundKeys.joined(separator: "、"))")
    }

    // MARK: 试打

    private var probeLine: some View {
        HStack(spacing: 10) {
            Text("试打").font(.callout)
            TextField("敲几个键（如 nihc）", text: $probe)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            let decoded = scheme.decode(probe.lowercased())
            Text(probe.isEmpty ? "—" : "→ \(decoded.marked)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(decoded.tail.isEmpty || probe.isEmpty ? Color.secondary : Color.orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    // MARK: 编辑动作（规则在 ShuangpinKeyEditor，这里只管点完要重算校验）

    private func bind(_ kind: PaletteKind, _ value: String, to key: String) {
        switch kind {
        case .final: editor.bind(final: value, to: key)
        case .initial: editor.bind(initial: value, to: key)
        }
        selectedKey = key
        revalidate()
    }

    private func revalidate() {
        unencodable = editor.unencodableSyllables()
        ambiguous = editor.ambiguousKeyPairs()
    }

    /// 全部音节能不能编成两键（编不出 = 那个音打不出来）
    static func validate(_ table: ShuangpinKeyTable) -> [String] {
        ShuangpinKeyEditor(table: table).unencodableSyllables()
    }
}

/// 键帽的拖拽接收端：进入/离开给出高亮，松手解析负载。
private struct KeyDropHandler: DropDelegate {
    let key: String
    let onHover: (Bool) -> Void
    let onDrop: (_ kind: PaletteKind, _ value: String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        PaletteKind.parse(from: info) != nil
    }

    func dropEntered(info: DropInfo) { onHover(true) }
    func dropExited(info: DropInfo) { onHover(false) }

    func performDrop(info: DropInfo) -> Bool {
        guard let parsed = PaletteKind.parse(from: info) else { return false }
        onDrop(parsed.kind, parsed.value)
        return true
    }
}

/// 可拖拽的元素种类：韵母 / 声母。
enum PaletteKind {
    case final, initial

    /// 负载前缀，见文件头 `finalPayloadPrefix` / `initialPayloadPrefix`
    var payloadPrefix: String { self == .final ? finalPayloadPrefix : initialPayloadPrefix }

    /// 从拖拽负载解出「哪类元素 + 元素名」；不是本编辑器的负载就返回 nil（不接外部拖拽）
    static func parse(from info: DropInfo) -> (kind: PaletteKind, value: String)? {
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return nil }
        var result: (kind: PaletteKind, value: String)?
        let semaphore = DispatchSemaphore(value: 0)
        provider.loadObject(ofClass: NSString.self) { object, _ in
            defer { semaphore.signal() }
            guard let text = object as? String else { return }
            for kind in [PaletteKind.final, .initial] {
                if text.hasPrefix(kind.payloadPrefix) {
                    result = (kind, String(text.dropFirst(kind.payloadPrefix.count)))
                    break
                }
            }
        }
        _ = semaphore.wait(timeout: .now() + 0.2)
        return result
    }
}

/// 编辑器窗口（与「学习数据」窗口同款：单例 + isReleasedWhenClosed = false）
public enum ShuangpinEditorWindow {
    private static var window: NSWindow?
    private final class Handler: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {}
    }
    private static let handler = Handler()

    static func open() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let start = PinyinLayout.customKeyTable(from: Defaults[.pinyinCustomTable])
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = "自定义双拼键位"
        win.contentView = NSHostingView(rootView: ShuangpinEditorView(table: start) { save, table in
            if save, let table {
                if let data = try? JSONEncoder().encode(table),
                   let json = String(data: data, encoding: .utf8) {
                    Defaults[.pinyinCustomTable] = json
                    Defaults[.pinyinLayout] = .custom
                    PinyinEngineCenter.shared.applySettings()
                }
            }
            window?.close()
        })
        win.contentMinSize = NSSize(width: 760, height: 560)
        win.isReleasedWhenClosed = false
        win.delegate = handler
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
