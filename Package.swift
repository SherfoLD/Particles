// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Particles",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Particles", targets: ["Particles"])],
    targets: [
        .target(name: "LayoutCore"),
        .executableTarget(name: "Particles", dependencies: ["LayoutCore"], resources: [
            .copy("Resources/CannonWheel.png"),
            .copy("Resources/CannonBarrel.png")
        ])
    ]
)
