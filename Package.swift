// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMTP",
    platforms: [.macOS("27.0")],
    targets: [
        .systemLibrary(name: "CLibUSB", pkgConfig: "libusb-1.0", providers: [.brew(["libusb"])]),
        .target(name: "USB", dependencies: ["CLibUSB"]),
        .target(name: "UpdateSupport"),
        .executableTarget(name: "MacMTP", dependencies: ["USB", "UpdateSupport"]),
        .executableTarget(name: "MacMTPUpdate", dependencies: ["UpdateSupport"]),
        .testTarget(name: "MacMTPTests", dependencies: ["MacMTP", "USB", "UpdateSupport"])
    ],
    swiftLanguageModes: [.v5]
)
