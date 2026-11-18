// swift-tools-version:5.9
// Paquete con la lógica común de la app (modelos y parsers de listas).
// No depende de UIKit/SwiftUI: se puede compilar y probar también en Windows/Linux.
import PackageDescription

let package = Package(
    name: "HLSCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "HLSCore", targets: ["HLSCore"])
    ],
    targets: [
        .target(name: "HLSCore"),
        .executableTarget(name: "CencProbe", dependencies: ["HLSCore"]),
        .executableTarget(name: "RelayProbe", dependencies: ["HLSCore"]),
        .executableTarget(name: "MediaProbe", dependencies: ["HLSCore"]),
        .executableTarget(name: "MkvProbe", dependencies: ["HLSCore"]),
        .testTarget(name: "HLSCoreTests", dependencies: ["HLSCore"])
    ]
)
