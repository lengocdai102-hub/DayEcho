// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DayEcho",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "DayEchoKit", targets: ["DayEchoKit"]),
        .executable(name: "DayEchoCLI", targets: ["DayEchoCLI"]),
        .executable(name: "DayEchoTestRunner", targets: ["DayEchoTestRunner"]),
        .executable(name: "SyntaxCheck", targets: ["SyntaxCheck"]),
        .executable(name: "ApiAudit", targets: ["ApiAudit"]),
        .executable(name: "PlistAudit", targets: ["PlistAudit"]),
        .executable(name: "KitVisibilityCheck", targets: ["KitVisibilityCheck"]),
        .executable(name: "ProtocolConformanceCheck", targets: ["ProtocolConformanceCheck"])
    ],
    targets: [
        .target(
            name: "DayEchoKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // ★ 共享测试用例 target ★
        //
        // 66 条测试全部住在这里，两个 runner 都依赖它：
        //   - DayEchoTestRunner（自研，无 Xcode 也能跑）
        //   - DayEchoTestCasesTests（XCTest，swift test 能跑）
        //
        // ★ 为什么测试代码在 library 而不是 executable 里 ★
        //
        // executableTarget 里的代码不能被别的 target import。
        // 放成 library 才能两个 runner 共用同一份测试代码 ——
        // 不会出现「自研 runner 过了但 XCTest 没测到」的漏网。
        .target(
            name: "DayEchoTestCases",
            dependencies: ["DayEchoKit"],
            path: "Sources/DayEchoTestCases",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DayEchoCLI",
            dependencies: ["DayEchoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // ★ DayEchoApp 的 SwiftPM target 已删除 ★
        //
        // 它不是「没人用」这么简单 —— 它**让 swift test 整个失败**：
        //   error: no such module 'WatchConnectivity'
        //   Found unhandled resource at .../Sources/DayEchoApp/Resources
        //
        // 原因：
        // ① DayEchoApp 是 iOS 专属源码（import WatchConnectivity），
        //    macOS 上根本没这个模块 —— SwiftPM 却在 macOS 上编译它。
        // ② 它没有任何 target 依赖，也不在 products 里 —— 纯多余。
        //
        // ★ iOS App 的源码照样被 Xcode 工程编译 ★
        // legal/gen_xcodeproj.rb 独立列出了这些源文件，
        // Xcode 工程用的是自己那套，与 SwiftPM 这里无关：
        //   Sources/DayEchoApp/DayEchoApp.swift
        //   Sources/DayEchoApp/ContentView.swift
        //   Sources/DayEchoApp/PhoneReceiveChannel.swift
        //
        // ★ 本地化资源没丢 ★
        // iOS/Watch App 的本地化由 Xcode 工程负责（gen_xcodeproj.rb 直接引用
        // Sources/DayEchoApp/Resources 和 Sources/DayEchoWatchApp/WatchResources），
        // 与 SwiftPM 这里无关。L10nCheck 也改成直接读这两个源目录。

        .executableTarget(
            name: "L10nCheck",
            dependencies: ["DayEchoKit"],
            path: "Sources/L10nCheck",
            // ★ 不再声明 resources ★
            //
            // 之前用 resources: [.process("../DayEchoApp/Resources")] 跨 target
            // 引用资源目录，SwiftPM 报：
            //     Found unhandled resource at .../Sources/DayEchoApp/Resources
            //     Found unhandled resource at .../Sources/DayEchoWatchApp/WatchResources
            // 连带 `swift test` 整个失败。
            //
            // L10nCheck 现在直接读仓库里的 .lproj 源目录（它检查的就是源文件），
            // 不需要构建产物，于是整个 resources 依赖被移除。
            //
            // ★ 注意：iOS/Watch App 的本地化仍由 Xcode 工程负责 ★
            // legal/gen_xcodeproj.rb 直接引用这两个源目录生成 Xcode 的
            // Localization group —— 与 SwiftPM 这里无关。
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // ★ XCTest target ★
        //
        // 让 `swift test` 能跑这个工程（标准工具链入口）。
        // 测试代码不在这里 —— 全部复用 DayEchoTestCases。
        .testTarget(
            name: "DayEchoTestCasesTests",
            dependencies: ["DayEchoTestCases"],
            path: "Tests/DayEchoTestCasesTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ApiAudit",
            path: "Sources/ApiAudit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SyntaxCheck",
            path: "Sources/SyntaxCheck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PlistAudit",
            path: "Sources/PlistAudit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "KitVisibilityCheck",
            path: "Sources/KitVisibilityCheck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ProtocolConformanceCheck",
            path: "Sources/ProtocolConformanceCheck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DayEchoTestRunner",
            dependencies: ["DayEchoKit", "DayEchoTestCases"],
            path: "Sources/DayEchoTestRunner",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
