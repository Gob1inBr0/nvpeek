// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "nvpeek",
    platforms: [.macOS(.v13)],
    targets: [
        // 所有逻辑和界面都放在这个库里，方便单元测试
        .target(name: "nvpeekCore", path: "Sources/nvpeekCore"),
        // 程序入口，只负责启动 AppKit
        .executableTarget(name: "nvpeek", dependencies: ["nvpeekCore"], path: "Sources/nvpeekExec"),
        .testTarget(name: "nvpeekTests", dependencies: ["nvpeekCore"], path: "Tests/nvpeekTests"),
    ]
)
