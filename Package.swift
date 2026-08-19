// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NFCromancer",
    platforms: [.iOS(.v14)],
    products: [
        .library(
            name: "NFCromancer",
            targets: ["NFCromancer"]
        ),
    ],
    targets: [
        .target(
            name: "NFCromancer",
            path: "Sources/NFCromancer",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreNFC"),
            ]
        ),
    ]
)
