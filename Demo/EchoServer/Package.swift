// swift-tools-version:3.1

import PackageDescription

let package = Package(
    name: "EchoServer",
    dependencies: [
        .Package(url: "https://github.com/csujedihy/SwiftDSSocket.git", "0.0.4")
    ]
)
