import AppKit
import LoungeCore
import SwiftUI

/// 개발용: 팝오버를 실제 로그 데이터로 PNG 렌더링 (2x)
@MainActor
enum Snapshot {
    static func render(to path: String, locked: Bool) {
        var snapshot = UsageScanner().scan()
        if locked {
            snapshot.lastLimitHit = RateLimitHit(
                hitAt: .now, resetsAt: .now.addingTimeInterval(2 * 3600 + 13 * 60), type: "five_hour")
        }
        let view = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: Sprites.menuBarIcon(gold: false))
                Image(nsImage: Sprites.menuBarIcon(gold: true))
                Text("메뉴바 아이콘").font(Fonts.small()).foregroundStyle(.white)
            }
            .padding(6)
            .background(Color(white: 0.75))
            LoungeView(snapshot: snapshot, lastScan: .now)
        }
        .padding(8)
        .background(Color(white: 0.3))
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
