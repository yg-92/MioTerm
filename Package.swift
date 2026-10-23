// swift-tools-version:5.9

import PackageDescription
import Foundation

// CommandLineTools 把 TestingMacros 放在 plugins/testing/ 子目录，
// 编译器只自动发现 plugins/ 顶层的插件，所以要把该目录加入宏插件搜索路径。
// 用 Xcode 或换机器时该路径不存在，条件判断保证清单仍然可用。
let testingMacrosDirectory = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
var testingSettings: [SwiftSetting] {
    guard FileManager.default.fileExists(atPath: testingMacrosDirectory) else { return [] }
    return [.unsafeFlags(["-plugin-path", testingMacrosDirectory])]
}

let package = Package(
    name: "MioTerm",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.99.0")
    ],
    targets: [
        .target(
            name: "MioTermCore",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/MioTermCore"
        ),
        .executableTarget(
            name: "MioTerm",
            dependencies: ["MioTermCore"],
            path: "Sources/MioTerm"
        ),
        .testTarget(
            name: "MioTermTests",
            dependencies: ["MioTermCore"],
            path: "Tests/MioTermTests",
            swiftSettings: testingSettings
        )
    ]
)
