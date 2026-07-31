// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Caffeine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Caffeine", targets: ["Caffeine"]),
        .executable(name: "CaffeineHelper", targets: ["CaffeineHelper"])
    ],
    targets: [
        .target(
            name: "CaffeineIPC"
        ),
        .target(
            name: "CaffeineCore"
        ),
        .target(
            name: "CaffeineLaunchdSupport"
        ),
        .target(
            name: "CaffeineSPI",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "CaffeineHelperCore"
        ),
        .executableTarget(
            name: "Caffeine",
            dependencies: [
                "CaffeineCore",
                "CaffeineIPC",
                "CaffeineLaunchdSupport"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "CaffeineHelper",
            dependencies: [
                "CaffeineHelperCore",
                "CaffeineIPC",
                "CaffeineSPI"
            ],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "CaffeineCoreTests",
            dependencies: ["CaffeineCore"]
        ),
        .testTarget(
            name: "CaffeineHelperCoreTests",
            dependencies: ["CaffeineHelperCore"]
        ),
        .testTarget(
            name: "CaffeineIPCTests",
            dependencies: ["CaffeineIPC"]
        ),
        .testTarget(
            name: "CaffeineLaunchdSupportTests",
            dependencies: ["CaffeineLaunchdSupport"]
        ),
        .testTarget(
            name: "CaffeineTests",
            dependencies: [
                "Caffeine",
                "CaffeineCore"
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
