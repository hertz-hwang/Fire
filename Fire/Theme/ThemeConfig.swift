//
//  ThemeConfig.swift
//  Fire
//
//  Created by 虚幻 on 2022/3/19.
//  Copyright © 2022 qwertyyb. All rights reserved.
//

import Foundation
import AppKit
import SwiftUI
import Defaults

struct ColorData: Codable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }

        let chars = Array(s)
        var r: UInt64 = 0, g: UInt64 = 0, b: UInt64 = 0, a: UInt64 = 255

        func parse(_ str: String) -> UInt64? {
            return UInt64(str, radix: 16)
        }

        switch chars.count {
        case 3:
            guard let pr = parse(String(repeating: chars[0], count: 2)),
                  let pg = parse(String(repeating: chars[1], count: 2)),
                  let pb = parse(String(repeating: chars[2], count: 2)) else { return nil }
            (r, g, b) = (pr, pg, pb)
        case 4:
            guard let pr = parse(String(repeating: chars[0], count: 2)),
                  let pg = parse(String(repeating: chars[1], count: 2)),
                  let pb = parse(String(repeating: chars[2], count: 2)),
                  let pa = parse(String(repeating: chars[3], count: 2)) else { return nil }
            (r, g, b, a) = (pr, pg, pb, pa)
        case 6:
            guard let pr = parse(String(chars[0...1])),
                  let pg = parse(String(chars[2...3])),
                  let pb = parse(String(chars[4...5])) else { return nil }
            (r, g, b) = (pr, pg, pb)
        case 8:
            guard let pr = parse(String(chars[0...1])),
                  let pg = parse(String(chars[2...3])),
                  let pb = parse(String(chars[4...5])),
                  let pa = parse(String(chars[6...7])) else { return nil }
            (r, g, b, a) = (pr, pg, pb, pa)
        default:
            return nil
        }

        self.red = Double(r) / 255.0
        self.green = Double(g) / 255.0
        self.blue = Double(b) / 255.0
        self.opacity = Double(a) / 255.0
    }

    var hexString: String {
        func toHex(_ value: Double) -> String {
            let clamped = max(0, min(1, value))
            return String(format: "%02X", Int((clamped * 255).rounded()))
        }
        let base = "#\(toHex(red))\(toHex(green))\(toHex(blue))"
        if opacity >= 1.0 - .ulpOfOne {
            return base
        }
        return "\(base)\(toHex(opacity))"
    }

    private enum CodingKeys: String, CodingKey {
        case red, green, blue, opacity
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let hex = try? single.decode(String.self),
           let parsed = ColorData(hex: hex) {
            self.init(
                red: parsed.red,
                green: parsed.green,
                blue: parsed.blue,
                opacity: parsed.opacity
            )
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let red = try container.decode(Double.self, forKey: .red)
        let green = try container.decode(Double.self, forKey: .green)
        let blue = try container.decode(Double.self, forKey: .blue)
        let opacity = try container.decode(Double.self, forKey: .opacity)
        self.init(red: red, green: green, blue: blue, opacity: opacity)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}

extension Color {
    init(_ colorData: ColorData) {
        self.init(
            Color.RGBColorSpace.sRGB,
            red: colorData.red,
            green: colorData.green,
            blue: colorData.blue,
            opacity: colorData.opacity
        )
    }
}

struct ApperanceThemeConfig: Codable {
    let windowBackgroundColor: ColorData
    let windowPaddingTop: Float
    let windowPaddingLeft: Float
    let windowPaddingRight: Float
    let windowPaddingBottom: Float
    let windowBorderRadius: Float

    let originCodeColor: ColorData
    let originCandidatesSpace: Float
    let candidateSpace: Float

    let candidateIndexColor: ColorData
    let candidateTextColor: ColorData
    let candidateCodeColor: ColorData

    let selectedIndexColor: ColorData
    let selectedTextColor: ColorData
    let selectedCodeColor: ColorData
    // 选中候选的高亮底色。可缺省：老主题 JSON 升级后回落默认色
    let selectedBackgroundColor: ColorData?

    // 页面指示器颜色
    let pageIndicatorColor: ColorData
    // 页面指示器置灰色
    let pageIndicatorDisabledColor: ColorData

    let fontName: String
    let fontSize: Float
    // 序号字号。可缺省
    let candidateIndexFontSize: Float?
    // 编码提示字号。可缺省
    let candidateCodeFontSize: Float?
    // 候选行内上下留白。可缺省
    let candidateRowPadding: Float?

    private enum CodingKeys: String, CodingKey {
        case windowBackgroundColor, windowPaddingTop, windowPaddingLeft
        case windowPaddingRight, windowPaddingBottom, windowBorderRadius
        case originCodeColor, originCandidatesSpace, candidateSpace
        case candidateIndexColor, candidateTextColor, candidateCodeColor
        case selectedIndexColor, selectedTextColor, selectedCodeColor
        case selectedBackgroundColor
        case pageIndicatorColor, pageIndicatorDisabledColor
        case fontName, fontSize
        case candidateIndexFontSize, candidateCodeFontSize, candidateRowPadding
    }

    /// 兼容旧版主题 JSON：新增的可选字段缺省即视为未提供
    init(
        windowBackgroundColor: ColorData,
        windowPaddingTop: Float, windowPaddingLeft: Float,
        windowPaddingRight: Float, windowPaddingBottom: Float,
        windowBorderRadius: Float,
        originCodeColor: ColorData,
        originCandidatesSpace: Float, candidateSpace: Float,
        candidateIndexColor: ColorData, candidateTextColor: ColorData, candidateCodeColor: ColorData,
        selectedIndexColor: ColorData, selectedTextColor: ColorData, selectedCodeColor: ColorData,
        selectedBackgroundColor: ColorData? = nil,
        pageIndicatorColor: ColorData, pageIndicatorDisabledColor: ColorData,
        fontName: String, fontSize: Float,
        candidateIndexFontSize: Float? = nil,
        candidateCodeFontSize: Float? = nil,
        candidateRowPadding: Float? = nil
    ) {
        self.windowBackgroundColor = windowBackgroundColor
        self.windowPaddingTop = windowPaddingTop
        self.windowPaddingLeft = windowPaddingLeft
        self.windowPaddingRight = windowPaddingRight
        self.windowPaddingBottom = windowPaddingBottom
        self.windowBorderRadius = windowBorderRadius
        self.originCodeColor = originCodeColor
        self.originCandidatesSpace = originCandidatesSpace
        self.candidateSpace = candidateSpace
        self.candidateIndexColor = candidateIndexColor
        self.candidateTextColor = candidateTextColor
        self.candidateCodeColor = candidateCodeColor
        self.selectedIndexColor = selectedIndexColor
        self.selectedTextColor = selectedTextColor
        self.selectedCodeColor = selectedCodeColor
        self.selectedBackgroundColor = selectedBackgroundColor
        self.pageIndicatorColor = pageIndicatorColor
        self.pageIndicatorDisabledColor = pageIndicatorDisabledColor
        self.fontName = fontName
        self.fontSize = fontSize
        self.candidateIndexFontSize = candidateIndexFontSize
        self.candidateCodeFontSize = candidateCodeFontSize
        self.candidateRowPadding = candidateRowPadding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            windowBackgroundColor: try container.decode(ColorData.self, forKey: .windowBackgroundColor),
            windowPaddingTop: try container.decode(Float.self, forKey: .windowPaddingTop),
            windowPaddingLeft: try container.decode(Float.self, forKey: .windowPaddingLeft),
            windowPaddingRight: try container.decode(Float.self, forKey: .windowPaddingRight),
            windowPaddingBottom: try container.decode(Float.self, forKey: .windowPaddingBottom),
            windowBorderRadius: try container.decode(Float.self, forKey: .windowBorderRadius),
            originCodeColor: try container.decode(ColorData.self, forKey: .originCodeColor),
            originCandidatesSpace: try container.decode(Float.self, forKey: .originCandidatesSpace),
            candidateSpace: try container.decode(Float.self, forKey: .candidateSpace),
            candidateIndexColor: try container.decode(ColorData.self, forKey: .candidateIndexColor),
            candidateTextColor: try container.decode(ColorData.self, forKey: .candidateTextColor),
            candidateCodeColor: try container.decode(ColorData.self, forKey: .candidateCodeColor),
            selectedIndexColor: try container.decode(ColorData.self, forKey: .selectedIndexColor),
            selectedTextColor: try container.decode(ColorData.self, forKey: .selectedTextColor),
            selectedCodeColor: try container.decode(ColorData.self, forKey: .selectedCodeColor),
            selectedBackgroundColor: try container.decodeIfPresent(ColorData.self, forKey: .selectedBackgroundColor),
            pageIndicatorColor: try container.decode(ColorData.self, forKey: .pageIndicatorColor),
            pageIndicatorDisabledColor: try container.decode(ColorData.self, forKey: .pageIndicatorDisabledColor),
            fontName: try container.decode(String.self, forKey: .fontName),
            fontSize: try container.decode(Float.self, forKey: .fontSize),
            candidateIndexFontSize: try container.decodeIfPresent(Float.self, forKey: .candidateIndexFontSize),
            candidateCodeFontSize: try container.decodeIfPresent(Float.self, forKey: .candidateCodeFontSize),
            candidateRowPadding: try container.decodeIfPresent(Float.self, forKey: .candidateRowPadding)
        )
    }
}

extension ApperanceThemeConfig {
    /// 选中候选的高亮底色：sRGB(0, 0.48, 1) @ 16%（动态色，深浅色通用）
    var selectedBackground: ColorData {
        selectedBackgroundColor ?? ColorData(red: 0, green: 0.48, blue: 1, opacity: 0.16)
    }
    /// 序号字号
    var indexFontSize: Float { candidateIndexFontSize ?? 11 }
    /// 编码提示字号（顶部编码行同用）
    var codeFontSize: Float { candidateCodeFontSize ?? 12 }
    /// 候选行内上下留白
    var rowPadding: Float { candidateRowPadding ?? 4 }
}

struct ThemeConfig: Codable, Defaults.Serializable {
    let schemaVersion: Int?
    let id: String
    let name: String
    let author: String

    let light: ApperanceThemeConfig
    let dark: ApperanceThemeConfig?

    var current: ApperanceThemeConfig {
        light
    }

    subscript(colorScheme: ColorScheme) -> ApperanceThemeConfig {
        if let dark = self.dark, colorScheme == .dark {
            return dark
        }
        return light
    }
}

// 默认主题：
//  label/secondary/tertiary label、systemOrange、systemTeal、windowBackground、
//  高亮 = sRGB(0, 0.48, 1) @ 16%）
let defaultThemeConfig = ThemeConfig(
    schemaVersion: 2,
    id: "default",
    name: "默认",
    author: "业火输入法",
    light: ApperanceThemeConfig(
        windowBackgroundColor: ColorData(red: 0xF8/255.0, green: 0xF8/255.0, blue: 0xF8/255.0, opacity: 1),
        windowPaddingTop: 8,
        windowPaddingLeft: 8,
        windowPaddingRight: 8,
        windowPaddingBottom: 8,
        windowBorderRadius: 8,
        originCodeColor: ColorData(red: 0x6B/255.0, green: 0x6B/255.0, blue: 0x70/255.0, opacity: 1),
        originCandidatesSpace: 4,
        candidateSpace: 8,
        candidateIndexColor: ColorData(red: 0xA0/255.0, green: 0xA0/255.0, blue: 0xA6/255.0, opacity: 1),
        candidateTextColor: ColorData(red: 0x1D/255.0, green: 0x1D/255.0, blue: 0x1F/255.0, opacity: 1),
        candidateCodeColor: ColorData(red: 0x6B/255.0, green: 0x6B/255.0, blue: 0x70/255.0, opacity: 1),
        selectedIndexColor: ColorData(red: 0xA0/255.0, green: 0xA0/255.0, blue: 0xA6/255.0, opacity: 1),
        selectedTextColor: ColorData(red: 0x1D/255.0, green: 0x1D/255.0, blue: 0x1F/255.0, opacity: 1),
        selectedCodeColor: ColorData(red: 0x6B/255.0, green: 0x6B/255.0, blue: 0x70/255.0, opacity: 1),
        selectedBackgroundColor: ColorData(red: 0, green: 0.48, blue: 1, opacity: 0.16),
        pageIndicatorColor: ColorData(red: 0xA0/255.0, green: 0xA0/255.0, blue: 0xA6/255.0, opacity: 1),
        pageIndicatorDisabledColor: ColorData(red: 0xA0/255.0, green: 0xA0/255.0, blue: 0xA6/255.0, opacity: 0.4),
        fontName: "system",
        fontSize: 16,
        candidateIndexFontSize: 11,
        candidateCodeFontSize: 12,
        candidateRowPadding: 4),
    dark: ApperanceThemeConfig(
        windowBackgroundColor: ColorData(red: 0x2A/255.0, green: 0x2A/255.0, blue: 0x2C/255.0, opacity: 1),
        windowPaddingTop: 8,
        windowPaddingLeft: 8,
        windowPaddingRight: 8,
        windowPaddingBottom: 8,
        windowBorderRadius: 8,
        originCodeColor: ColorData(red: 0xAE/255.0, green: 0xAE/255.0, blue: 0xB2/255.0, opacity: 1),
        originCandidatesSpace: 4,
        candidateSpace: 8,
        candidateIndexColor: ColorData(red: 0x8E/255.0, green: 0x8E/255.0, blue: 0x93/255.0, opacity: 1),
        candidateTextColor: ColorData(red: 0xF5/255.0, green: 0xF5/255.0, blue: 0xF7/255.0, opacity: 1),
        candidateCodeColor: ColorData(red: 0xAE/255.0, green: 0xAE/255.0, blue: 0xB2/255.0, opacity: 1),
        selectedIndexColor: ColorData(red: 0x8E/255.0, green: 0x8E/255.0, blue: 0x93/255.0, opacity: 1),
        selectedTextColor: ColorData(red: 0xF5/255.0, green: 0xF5/255.0, blue: 0xF7/255.0, opacity: 1),
        selectedCodeColor: ColorData(red: 0xAE/255.0, green: 0xAE/255.0, blue: 0xB2/255.0, opacity: 1),
        selectedBackgroundColor: ColorData(red: 0, green: 0.48, blue: 1, opacity: 0.16),
        pageIndicatorColor: ColorData(red: 0x8E/255.0, green: 0x8E/255.0, blue: 0x93/255.0, opacity: 1),
        pageIndicatorDisabledColor: ColorData(red: 0x8E/255.0, green: 0x8E/255.0, blue: 0x93/255.0, opacity: 0.4),
        fontName: "system",
        fontSize: 16,
        candidateIndexFontSize: 11,
        candidateCodeFontSize: 12,
        candidateRowPadding: 4
    )
)

/// 内置默认主题升级：老版本残留的 schemaVersion < 2 默认主题替换为新版
/// ；用户自定义主题不动，
/// 其缺省的新字段在渲染时回落默认值。
func migrateDefaultThemeIfNeeded() {
    let stored = Defaults[.themeConfig]
    guard stored.id == defaultThemeConfig.id else { return }
    if (stored.schemaVersion ?? 1) < (defaultThemeConfig.schemaVersion ?? 1) {
        Defaults[.themeConfig] = defaultThemeConfig
    }
}

func loadThemeConfig(jsonData: String) -> ThemeConfig? {
    let decoder = JSONDecoder()
    do {
        return try decoder.decode(ThemeConfig.self, from: jsonData.data(using: .utf8)!)
    } catch {
        print(error)
        return nil
    }
}

func jsonThemeConfig(config: ThemeConfig) -> String? {
    let encoder = JSONEncoder()
    if let data = try? encoder.encode(config) {
        return String(data: data, encoding: .utf8)!
    }
    return nil
}

enum ThemeImportError: Error, LocalizedError {
    case invalidJSON
    case missingFields

    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "无效的主题 JSON"
        case .missingFields: return "主题缺少 ID、名称或作者"
        }
    }
}

/// 解析 JSON 字符串为 ThemeConfig 并做基础校验
func parseThemeConfig(jsonData: String) -> Result<ThemeConfig, ThemeImportError> {
    guard let config = loadThemeConfig(jsonData: jsonData) else {
        return .failure(.invalidJSON)
    }
    if config.id.isEmpty || config.name.isEmpty || config.author.isEmpty {
        return .failure(.missingFields)
    }
    return .success(config)
}

/// 写入导入的主题并立即应用为当前主题
func applyImportedTheme(_ config: ThemeConfig) {
    Defaults[.importedThemeConfig] = config
    Defaults[.themeConfig] = config
}
