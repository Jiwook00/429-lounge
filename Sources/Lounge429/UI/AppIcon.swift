import AppKit
import SwiftUI

/// 앱 아이콘 (알림 배너, Finder). 메뉴바 슬롯머신을 정수 배율로 올린다.
/// 빌드할 때 `Lounge429 --app-icon out.png`로 1024px PNG를 만들고 build-app.sh가 .icns로 묶는다
///
/// 바깥 윤곽은 macOS 아이콘 격자(1024 안의 824px 둥근 사각형)를 그대로 따른다.
/// 모양이 다르면 macOS가 회색 판 위에 작게 올려 버린다. 안쪽 도트는 32px 격자라 절반씩 줄여도 안 번진다
enum AppIcon {
    private static let canvas = 1024
    private static let cell = 32
    /// macOS 아이콘 격자: 100px 여백, 824px, 모서리 반경 약 185px
    private static let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    private static let radius: CGFloat = 185

    static func write(to path: String) -> Bool {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor(Theme.bg).setFill()
        NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()
        for (x, y, color) in dots() {
            NSColor(color).setFill()
            // 비트맵은 아래에서 위로 → y를 뒤집는다
            NSRect(x: x * cell, y: canvas - (y + 1) * cell, width: cell, height: cell).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// 32×32 격자 위의 도트: 위아래 전구 띠(로고처럼 골드 / 꺼진 전구 / 레드) + 가운데 슬롯머신
    private static func dots() -> [(Int, Int, Color)] {
        var out: [(Int, Int, Color)] = []
        let bulbs = [Theme.gold, Theme.bulbOff, Theme.neon]
        for (n, x) in stride(from: 6, through: 24, by: 2).enumerated() {
            out.append((x, 5, bulbs[n % 3]))
            out.append((x, 26, bulbs[(n + 1) % 3]))
        }
        // 슬롯머신 18×14 → 가로 7칸, 세로 9칸 띄워서 가운데
        let machine = Sprites.slotMachine()
        for (y, row) in machine.rows.enumerated() {
            for (x, ch) in row.enumerated() {
                if let color = machine.palette[ch] { out.append((7 + x, 9 + y, color)) }
            }
        }
        return out
    }
}
