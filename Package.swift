// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMTP",
    platforms: [.macOS("27.0")],
    targets: [
        .systemLibrary(name: "CLibUSB", pkgConfig: "libusb-1.0", providers: [.brew(["libusb"])]),
        .target(name: "USB", dependencies: ["CLibUSB"]),
        .target(name: "UpdateSupport"),
        .target(name: "FinderSupport"),
        .executableTarget(name: "MacMTP", dependencies: ["USB", "UpdateSupport", "FinderSupport"]),
        .executableTarget(name: "MacMTPUpdate", dependencies: ["UpdateSupport"]),
        .testTarget(name: "MacMTPTests", dependencies: ["MacMTP", "USB", "UpdateSupport", "FinderSupport"])
    ],
    swiftLanguageModes: [.v5]
)
