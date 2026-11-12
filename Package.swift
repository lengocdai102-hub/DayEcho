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
        .executable(name: "PlistAudit", targets: ["PlistAudit"])
    ],
    targets: [
        .target(
            name: "DayEchoKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DayEchoCLI",
            dependencies: ["DayEchoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DayEchoApp",
            dependencies: ["DayEchoKit"],
            path: "Sources/DayEchoApp",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "L10nCheck",
            dependencies: ["DayEchoKit"],
            path: "Sources/L10nCheck",
            resources: [
                .copy("../DayEchoApp/Resources"),
                .copy("../DayEchoWatchApp/WatchResources"),
            ],
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
            name: "DayEchoTestRunner",
            dependencies: ["DayEchoKit"],
            path: "Sources/DayEchoTestRunner",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
