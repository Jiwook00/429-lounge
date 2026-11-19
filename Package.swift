// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "429Lounge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LoungeCore", targets: ["LoungeCore"]),
        .executable(name: "lounge-scan", targets: ["lounge-scan"]),
    ],
    targets: [
        // 토큰 로그 파싱, 칩 경제 등 UI와 무관한 로직
        .target(name: "LoungeCore"),
        // 디버그용 CLI: 지금 로그에서 읽히는 사용량/리밋 상태를 출력
        .executableTarget(name: "lounge-scan", dependencies: ["LoungeCore"]),
        .testTarget(name: "LoungeCoreTests", dependencies: ["LoungeCore"]),
    ]
)
