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

    // 页面指示器颜色
    let pageIndicatorColor: ColorData
    // 页面指示器置灰色
    let pageIndicatorDisabledColor: ColorData

    let fontName: String
    let fontSize: Float
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

let defaultThemeConfig = ThemeConfig(
    schemaVersion: 1,
    id: "default",
    name: "默认",
    author: "业火输入法",
    light: ApperanceThemeConfig(
        windowBackgroundColor: ColorData(red: 1, green: 1, blue: 1, opacity: 1),
        windowPaddingTop: 6,
        windowPaddingLeft: 10,
        windowPaddingRight: 10,
        windowPaddingBottom: 6,
        windowBorderRadius: 6,
        originCodeColor: ColorData(red: 0.3, green: 0.3, blue: 0.3, opacity: 1),
        originCandidatesSpace: 6,
        candidateSpace: 8,
        candidateIndexColor: ColorData(red: 0.1, green: 0.1, blue: 0.1, opacity: 1),
        candidateTextColor: ColorData(red: 0.1, green: 0.1, blue: 0.1, opacity: 1),
        candidateCodeColor: ColorData(red: 0.3, green: 0.3, blue: 0.3, opacity: 0.8),
        selectedIndexColor: ColorData(red: 0.863, green: 0.078, blue: 0.235, opacity: 1),
        selectedTextColor: ColorData(red: 0.863, green: 0.078, blue: 0.235, opacity: 1),
        selectedCodeColor: ColorData(red: 0.863, green: 0.078, blue: 0.235, opacity: 0.8),
        pageIndicatorColor: ColorData(red: 0.863, green: 0.078, blue: 0.235, opacity: 1),
        pageIndicatorDisabledColor: ColorData(red: 0.863, green: 0.078, blue: 0.235, opacity: 0.4),
        fontName: "system",
        fontSize: 20),
    dark: ApperanceThemeConfig(
        windowBackgroundColor: ColorData(red: 0, green: 0, blue: 0, opacity: 1),
        windowPaddingTop: 6,
        windowPaddingLeft: 10,
        windowPaddingRight: 10,
        windowPaddingBottom: 6,
        windowBorderRadius: 6,
        originCodeColor: ColorData(red: 1, green: 1, blue: 1, opacity: 1),
        originCandidatesSpace: 6,
        candidateSpace: 8,
        candidateIndexColor: ColorData(red: 0.9, green: 0.9, blue: 0.9, opacity: 1),
        candidateTextColor: ColorData(red: 0.9, green: 0.9, blue: 0.9, opacity: 1),
        candidateCodeColor: ColorData(red: 0.7, green: 0.7, blue: 0.7, opacity: 0.8),
        selectedIndexColor: ColorData(red: 0.863, green: 0.078, blue: 0.235, opacity: 1),
        selectedTextColor: ColorData(red: 0.863, green: 0.078, blue: 0.235, opacity: 1),
        selectedCodeColor: ColorData(red: 0.863, green: 0.078, blue: 0.235, opacity: 0.8),
        pageIndicatorColor: ColorData(red: 0.863, green: 0.078, blue: 0.235, opacity: 1),
        pageIndicatorDisabledColor: ColorData(red: 0.863, green: 0.078, blue: 0.235, opacity: 0.4),
        fontName: "system",
        fontSize: 20
    )
)

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
