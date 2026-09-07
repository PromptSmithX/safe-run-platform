// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SafeRunDomain",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "SafeRunDomain",
            targets: ["SafeRunDomain"]
        )
    ],
    targets: [
        .target(
            name: "SafeRunDomain"
        ),
        .testTarget(
            name: "SafeRunDomainTests",
            dependencies: ["SafeRunDomain"],
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)

