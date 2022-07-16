// swift-tools-version: 5.6

import PackageDescription

let package = Package(
  name: "Bitfield",
  products: [
    .library(name: "Bitfield", targets: ["Bitfield"]),
    .library(name: "BitfieldDLL", type: .dynamic, targets: ["Bitfield"]),
  ],
  dependencies: [],
  targets: [
    .target(name: "Bitfield", dependencies: []),
    .testTarget(name: "BitfieldTests", dependencies: ["Bitfield"]),
  ]
)
