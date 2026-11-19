// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "429Lounge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lounge429", targets: ["Lounge429"]),
        .executable(name: "lounge-scan", targets: ["lounge-scan"]),
        .library(name: "LoungeCore", targets: ["LoungeCore"]),
    ],
    targets: [
        // 메뉴바 앱 (SwiftUI)
        .executableTarget(
            name: "Lounge429",
            dependencies: ["LoungeCore"],
            resources: [.copy("Resources/Fonts")]
        ),
        // 토큰 로그 파싱, 칩 경제 등 UI와 무관한 로직
        .target(name: "LoungeCore"),
        // 디버그용 CLI: 지금 로그에서 읽히는 사용량/리밋 상태를 출력
        .executableTarget(name: "lounge-scan", dependencies: ["LoungeCore"]),
        .testTarget(name: "LoungeCoreTests", dependencies: ["LoungeCore"]),
    ]
)
