//
//  ShuangpinEditorView.swift
//  Fire
//
//  自定义双拼键位编辑器：模拟键盘图 + 可拖拽的声母 / 韵元素。
//
//  交互：
//  * 把右侧的韵母 / 声母拖到键盘上的某个键 → 绑到那个键（一个键可以挂多个韵母，
//    从上到下就是优先级；同一个韵母只会在一个键上，拖到新键等于搬走）。
//  * 声母同样可改（不只翘舌）：拖到已有声母的键上是**互换**（l 拖到 n，n 接住 l 的键）；
//    拖到元音键上是搬走，原键不再当声母；选中键帽还能单独禁用 / 恢复某个键作声母。
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
            // 元素面板：宽度写死。SwiftUI 的 ScrollView 给内容的是「无限主轴宽度」，
            // LazyVGrid 的 adaptive 列在里面会按无限宽铺下去，实测把整个窗口撑爆、
            // 键盘被挤出可见区。固定列 + 固定容器宽度才是这里要的形状。
            HStack(alignment: .top, spacing: 14) {
                palette(title: "韵母（拖到键上）", items: PinyinSyllables.finals, kind: .final,
                        width: 178)
                palette(title: "声母（拖到键上）", items: PinyinSyllables.initials, kind: .initial, width: 178)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text("提示").font(.caption.weight(.medium))
                    Text("拖动元素到键帽上绑定；先点键帽再点元素同样能绑。\n一个韵母只会在一个键上，拖到新键就是搬走；声母拖到已有声母的键上是互换。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 260, alignment: .leading)
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
            Toggle("占用 ; 键", isOn: Binding(
                get: { editor.table.semicolon },
                set: { on in
                    editor.setUsesSemicolon(on)
                    if selectedKey == ";" && !on { selectedKey = nil }
                    revalidate()
                }
            ))
            .toggleStyle(.checkbox)
            .help("微软 / 搜狗系把 ing 放在 ; 上。勾上后 ; 算一个键位（会出现在第三排末尾，输入时进组字区而不是出标点）")
            Spacer()
            Button("取消") { onFinish(false, nil) }
            Button("保存") {
                // 两类硬伤都只拦一次（确认后仍可保存）：缺韵母键位 = 那些音根本打不出来，
                // 编不成两键 = 那些音节在这个方案下没有写法。
                var problems: [String] = []
                let unbound = editor.unboundFinals()
                if !unbound.isEmpty {
                    problems.append("\(unbound.count) 个韵母还没给键位（\(unbound.prefix(3).joined(separator: " "))…）")
                }
                if !unencodable.isEmpty {
                    problems.append("\(unencodable.count) 个音节编不成两键（\(unencodable.prefix(3).joined(separator: " / "))…）")
                }
                guard problems.isEmpty else {
                    alertText = problems.joined(separator: "；") + "。保存后这些音打不出来，确认继续？"
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

    /// 键帽上的小字：有映射声母时先写声母（墓碑画 ✕），再挂最多两个韵母
    private func capSummary(key: String, finals: [String], initial: String?) -> String {
        let head = finals.prefix(2).joined(separator: "/")
        // 键帽同时要挂声母与韵母时（v = zh + ui/v）用 · 分隔，
        // 直接拼空格会读成「sh u」这种看不出谁是谁的样子
        if let initial {
            // 墓碑：这键被拖走/禁用后不再当声母，光看韵母会忘掉它以前是声母键
            if initial.isEmpty { return head.isEmpty ? "✕" : "✕ · " + head }
            return head.isEmpty ? initial : initial + " · " + head
        }
        return head
    }

    private func hint(for key: String) -> String {
        var lines: [String] = ["键「\(key)」"]
        if let initial = table.mappedInitial(for: key) {
            lines.append(initial.isEmpty ? "声母：已禁用（不再当声母）" : "声母：\(initial)")
        } else if let implicit = scheme.initial(key) {
            lines.append("声母：\(implicit)（默认，把别的声母拖过来即换键）")
        }
        let finals = table.finals(for: key)
        if !finals.isEmpty {
            lines.append("韵母（按优先级）：" + finals.joined(separator: "、"))
        }
        if finals.isEmpty && table.mappedInitial(for: key) == nil {
            lines.append(scheme.initial(key) != nil
                         ? "还没挂韵母：把右侧韵母拖过来"
                         : "未绑定：把右侧元素拖过来")
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
                    if let initial = table.mappedInitial(for: key), !initial.isEmpty {
                        Text("声母 \(initial)")
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                        Button("解绑声母") { editor.unbindInitial(key); revalidate() }
                            .help("删掉这条映射：辅音键回到「字母自己当声母」")
                            .controlSize(.small)
                    } else if table.mappedInitial(for: key) == "" {
                        Text("不作声母")
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                        Button("恢复默认声母") { editor.unbindInitial(key); revalidate() }
                            .controlSize(.small)
                    } else if let implicit = scheme.initial(key) {
                        Text("声母 \(implicit)（默认）")
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        Button("禁用") { editor.disableInitial(key); revalidate() }
                            .help("把这个键从声母里摘出去；原声母会暂时没有键，编不出的音节会列在下方")
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

    private func palette(title: String, items: [String], kind: ShuangpinDragPayload.Element,
                         width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.fixed(52), spacing: 6), GridItem(.fixed(52), spacing: 6),
                                    GridItem(.fixed(52), spacing: 6)],
                          alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        chip(item, kind: kind)
                    }
                }
                .padding(2)
            }
        }
        // 高度钉在**外层容器**上并 clipped：只给 ScrollView 加 frame(height:) 时
        // 父 VStack 仍按内容的理想高度铺，实测 34 个韵母铺到 ~600pt、
        // 直接压到下面的「试打」行上（frame 只是提议尺寸，不裁切绘制内容）
        .frame(width: width, height: 172, alignment: .topLeading)
        .clipped()
    }

    private func chip(_ item: String, kind: ShuangpinDragPayload.Element) -> some View {
        // 声母的当前键位要问方案：显式绑定与「字母自己」（默认键位）都算已绑
        let boundKeys: [String] = kind == .final
            ? table.keysBinding(final: item)
            : [scheme.key(forInitial: item)].compactMap { $0 }
        return Text(item)
            .font(.system(size: 11, design: .rounded))
            .frame(width: 52)
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
                NSItemProvider(object: ShuangpinDragPayload.encode(kind, item) as NSString)
            }
            // 拖不动的场合（触控板手势不灵、辅助输入）给一条点击路径：
            // 先点键帽选中，再点元素 = 绑到选中键
            .onTapGesture {
                guard let key = selectedKey else { return }
                bind(kind, item, to: key)
            }
            .help(boundKeys.isEmpty ? "拖到键盘上的键位绑定"
                    : kind == .initial && boundKeys.first == item
                    ? "默认就在 \(item) 键，拖到别的键即换（与那键的声母互换）"
                    : "已绑在 \(boundKeys.joined(separator: "、"))")
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

    private func bind(_ kind: ShuangpinDragPayload.Element, _ value: String, to key: String) {
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

/// 键帽的拖拽接收端：进入/离开给出高亮，松手异步取负载。
private struct KeyDropHandler: DropDelegate {
    let key: String
    let onHover: (Bool) -> Void
    let onDrop: (_ element: ShuangpinDragPayload.Element, _ name: String) -> Void

    // 不在 validateDrop 里读负载：那是主线程上的同步调用点，
    // 而 NSItemProvider 的取数据回调可能就要在主线程交付 —— 等它就是自锁。
    // 这里只认「有没有文本」，负载内容留到松手后异步解。
    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: [UTType.text]).isEmpty
    }

    func dropEntered(info: DropInfo) { onHover(true) }
    func dropExited(info: DropInfo) { onHover(false) }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String,
                  let parsed = ShuangpinDragPayload.decode(text) else { return }
            DispatchQueue.main.async { self.onDrop(parsed.element, parsed.name) }
        }
        return true
    }
}

/// 编辑器窗口（与「学习数据」窗口同款：单例 + isReleasedWhenClosed = false）
public enum ShuangpinEditorWindow {
    private static var window: NSWindow?

    /// 关闭即清静态引用：下次打开重新按**当前已保存的键位表**建窗口。
    /// 留着不清，「取消 → 再点编辑键位」会把刚刚丢掉的那份编辑又摆回屏幕上。
    private final class Handler: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            guard let win = notification.object as? NSWindow else { return }
            if win === ShuangpinEditorWindow.window { ShuangpinEditorWindow.window = nil }
        }
    }
    private static let handler = Handler()

    /// 入口（偏好设置「编辑键位…」按钮调）
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


/// 编辑器窗口的入口自检（命令行 `Fire --shuangpin-editor-selftest`，跑完即退）。
///
/// 「编辑键位点不开」这种毛病错在接线而不是错在逻辑：按钮设了个没人读的状态、
/// 窗口建了没排到屏前，代码读着全对。所以这里真走一遍入口：开窗口、确认它到了屏前、
/// 确认二次入口不重复建窗、关掉后确认静态引用清了（不清，下次打开还是那份被丢掉的编辑）。
enum ShuangpinEditorWindowSelfCheck {
    private static let title = "自定义双拼键位"

    static func run() {
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            print("[shuangpin-editor] \(ok ? "PASS" : "FAIL") \(what)")
            if !ok { failures += 1 }
        }
        let savedLayout = Defaults[.pinyinLayout]
        let savedTable = Defaults[.pinyinCustomTable]
        // 没有已保存的键位表也要能开：回落小鹤，别给个空键盘
        Defaults[.pinyinCustomTable] = ""
        ShuangpinEditorWindow.open()
        let opened = visibleEditorWindows()
        expect(opened.count == 1, "open() 后屏前有一扇「\(title)」窗口（实得 \(opened.count)）")
        let firstWindow = opened.first
        expect(firstWindow?.contentView is NSHostingView<ShuangpinEditorView>,
               "窗口内容是键位编辑器本体")
        // 再点一次入口：只把那扇拉到前面，不叠第二扇
        ShuangpinEditorWindow.open()
        expect(visibleEditorWindows().count == 1, "重复 open() 不叠第二扇窗口")
        // 关掉必须清掉静态引用，否则下次打开拿到的是上次丢掉的那份编辑
        for window in visibleEditorWindows() { window.close() }
        expect(visibleEditorWindows().isEmpty, "close() 后窗口不再屏前")
        // 清完再开：重新按当前设置建窗口，内容跟着新的键位表走
        var custom = ShuangpinTables.xiaohe
        custom.finals = custom.finals.map { entry in
            var next = entry
            if entry.key == "k" { next.finals = ["uai"] }
            return next
        }
        Defaults[.pinyinCustomTable] = (try? JSONEncoder().encode(custom)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        ShuangpinEditorWindow.open()
        let reopened = visibleEditorWindows()
        // 重建而不是拉回旧窗口：静态引用没清的话这里拿回的仍是上一轮点了「取消」那一份编辑
        expect(reopened.count == 1 && reopened.first !== firstWindow,
               "关掉后重新 open() 重建窗口（不是把旧那份拉回屏前）")
        for window in visibleEditorWindows() { window.close() }
        Defaults[.pinyinLayout] = savedLayout
        Defaults[.pinyinCustomTable] = savedTable
        print("[shuangpin-editor] 键位编辑器入口自检：\(failures == 0 ? "全部通过" : "\(failures) 项失败")")
        exit(failures == 0 ? 0 : 1)
    }

    /// 屏前的键位编辑器窗口
    private static func visibleEditorWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.title == title && $0.isVisible }
    }
}

/// 离屏渲染预览（调试：`Fire --preview-shuangpin [输出目录]`）。
///
/// 键位编辑器是「拖拽 + 键盘图」这种一眼能看出好坏的界面，光看代码不知道
/// 键帽会不会挤成一团、错位排得对不对。渲成 PNG 直接看（照 CandidatesPreviewRenderer 那套）。
enum ShuangpinEditorPreview {
    static func run() {
        let directory = CommandLine.arguments.count > 2
            ? CommandLine.arguments[2] : NSTemporaryDirectory()
        let presets: [(String, ShuangpinKeyTable)] = [
            ("xiaohe", ShuangpinTables.xiaohe),
            ("ziranma", ShuangpinTables.ziranma),
            ("microsoft", ShuangpinTables.microsoft),
        ]
        for (name, table) in presets {
            // 预览时给一个确切尺寸（不是 minHeight）：只给下界时 SwiftUI 会按内容的
            // 理想高度铺，离屏窗口里就成了「上下都溢出、键盘被顶出可见区」
            // 背景与外观要显式给：只捕 contentView 时没有窗口底色，
            // 而 primary 文字会按 light 解析成黑色 —— 渲出来是「黑纸上的黑字」，
            // 键盘整块看着像没画（其实是画了，看不见）
            let view = ShuangpinEditorView(table: table) { _, _ in }
                .background(Color(NSColor.windowBackgroundColor))
                .frame(width: 820, height: 588, alignment: .topLeading)
            let hosting = NSHostingView(rootView: view)
            // 直接渲 NSHostingView 会拿到一张只有按钮的黑图：没有窗口就没有窗口级
            // 布局环境（动态字体、effectiveAppearance、SwiftUI 的 layout  Pass 都不全）。
            // 挂到一个从不 orderFront 的窗口上、显式 display() 一次，布局与绘制才跑完。
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = hosting
            window.setFrame(NSRect(x: 0, y: 0, width: 820, height: 620), display: false)
            hosting.frame = window.contentLayoutRect
            window.display()
            guard let content = window.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                print("[preview] \(name): 拿不到位图上下文")
                continue
            }
            content.cacheDisplay(in: content.bounds, to: rep)
            rep.size = content.bounds.size
            let path = "\(directory)/shuangpin-\(name).png"
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                print("[preview] \(path) \(Int(content.bounds.width))x\(Int(content.bounds.height))")
            }
        }
                exit(0)
    }
}
