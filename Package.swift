// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "429Lounge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lounge429", targets: ["Lounge429"]),
        .executable(name: "lounge-bot", targets: ["lounge-bot"]),
        .executable(name: "lounge-scan", targets: ["lounge-scan"]),
        .library(name: "LoungeCore", targets: ["LoungeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1"),
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.55.0"),
    ],
    targets: [
        // 메뉴바 앱 (SwiftUI)
        .executableTarget(
            name: "Lounge429",
            dependencies: ["LoungeCore", "LoungeNet", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Resources/Fonts"), .copy("Resources/Sounds")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // 토큰 로그 파싱, 칩 경제 등 UI와 무관한 로직
        .target(name: "LoungeCore"),
        // Supabase 연동: 인증, 홀짝 테이블 RPC, Realtime
        .target(name: "LoungeNet", dependencies: [.product(name: "Supabase", package: "supabase-swift")]),
        // 개발용 봇: 테이블에 앉아서 랜덤 베팅 (혼자서 멀티 테스트)
        .executableTarget(name: "lounge-bot", dependencies: ["LoungeNet"]),
        // 디버그용 CLI: 지금 로그에서 읽히는 사용량/리밋 상태를 출력
        .executableTarget(name: "lounge-scan", dependencies: ["LoungeCore"]),
        .testTarget(name: "LoungeCoreTests", dependencies: ["LoungeCore"]),
        .testTarget(name: "LoungeNetTests", dependencies: ["LoungeNet"]),
    ]
)
