// LeanDeps 聚合目标：本身无代码，只为让 `swift build` 把四个第三方模块
// （Defaults / KeychainSwift / NanoID / Sparkle）全部编译出来。
// 应用源码仍按各自模块名 import。
@_exported import Defaults
@_exported import KeychainSwift
@_exported import NanoID
@_exported import Sparkle
