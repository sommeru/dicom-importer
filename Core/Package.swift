// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DICOMImporterCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DICOMImporterCore", targets: ["DICOMImporterCore"]),
    ],
    targets: [
        .target(name: "DICOMImporterCore"),
        .testTarget(name: "DICOMImporterCoreTests", dependencies: ["DICOMImporterCore"]),
    ]
)
