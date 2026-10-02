// swift-tools-version:5.8
// 精简环境（仅 Command Line Tools，无完整 Xcode）下的 SPM 依赖构建清单。
// 用 `swift build --package-path scripts/lean-build --scratch-path build/lean/deps -c release`
// 产出 build/lean/deps/out/Products/Release/{Defaults,KeychainSwift,NanoID,LeanDeps}.o(+swiftmodule)
// 与 Sparkle.framework（二进制 artifact），供 swiftc 直接链接。
// 版本与 Fire.xcodeproj 的 Package.resolved 完全对齐。
import PackageDescription

let package = Package(
    name: "lean-build",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LeanDeps", targets: ["LeanDeps"]),
    ],
    dependencies: [
        // Defaults 上游 main 分支依赖：预先 clone 到 build/lean/vendor/Defaults（pin 见 build_app.sh）
        .package(name: "Defaults", path: "../../build/lean/vendor/Defaults"),
        .package(url: "https://github.com/evgenyneu/keychain-swift.git", exact: "20.0.0"),
        .package(url: "https://github.com/Tundaware/NanoID.git", exact: "1.0.4"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "1.26.0"),
    ],
    targets: [
        .target(
            name: "LeanDeps",
            dependencies: [
                .product(name: "Defaults", package: "defaults"),
                .product(name: "KeychainSwift", package: "keychain-swift"),
                .product(name: "NanoID", package: "nanoid"),
                .product(name: "Sparkle", package: "sparkle"),
            ]
        ),
    ]
)
