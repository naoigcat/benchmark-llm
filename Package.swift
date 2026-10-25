// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Benchmark",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "Benchmark", targets: ["Benchmark"]),
    .executable(name: "benchmark", targets: ["BenchmarkCLI"]),
  ],
  targets: [
    .target(name: "Benchmark"),
    .executableTarget(name: "BenchmarkCLI", dependencies: ["Benchmark"]),
    .testTarget(name: "BenchmarkTests", dependencies: ["Benchmark"]),
  ]
)
