import AppKit
import SwiftUI

/// 문자 격자로 정의하는 도트 스프라이트. 팔레트에 없는 문자('.')는 투명.
struct PixelSprite: Sendable {
    let rows: [String]
    let palette: [Character: Color]

    var width: Int { rows.map(\.count).max() ?? 0 }
    var height: Int { rows.count }
}

/// 정수 배율로 사각형을 찍어서 그린다. 보간이 없으니 어떤 배율에서도 또렷하다.
struct PixelView: View {
    let sprite: PixelSprite
    var scale: CGFloat = 2

    var body: some View {
        Canvas { ctx, _ in
            for (y, row) in sprite.rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let color = sprite.palette[ch] else { continue }
                    let rect = CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(sprite.width) * scale, height: CGFloat(sprite.height) * scale)
    }
}
