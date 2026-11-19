import AppKit
import SwiftUI

/// 임시 도트 에셋. 디자인 확정되면 같은 형식으로 교체.
enum Sprites {
    private static let base: [Character: Color] = [
        "k": Theme.outline, "R": Theme.neon, "W": Theme.cream, "Y": Theme.gold,
        "G": Theme.felt, "d": Theme.line,
    ]

    static let chip = PixelSprite(rows: [
        "...kkkkkk...",
        "..kRRWWRRk..",
        ".kRRRRRRRRk.",
        "kWRRYYYYRRWk",
        "kWRYRRRRYRWk",
        "kRRYRRRRYRRk",
        "kRRYRRRRYRRk",
        "kWRYRRRRYRWk",
        "kWRRYYYYRRWk",
        ".kRRRRRRRRk.",
        "..kRRWWRRk..",
        "...kkkkkk...",
    ], palette: base)

    static let goldChip = PixelSprite(rows: chip.rows, palette: base.merging(
        ["R": Theme.gold, "Y": Theme.goldLight, "W": Theme.goldDark]) { $1 })

    static let lock = PixelSprite(rows: [
        "...kkkk...",
        "..kYYYYk..",
        ".kYk..kYk.",
        ".kYk..kYk.",
        "kkkkkkkkkk",
        "kYYYYYYYYk",
        "kYYYkkYYYk",
        "kYYYkkYYYk",
        "kYYYYkYYYk",
        "kYYYYYYYYk",
        "kkkkkkkkkk",
    ], palette: base)

    static let seven = PixelSprite(rows: [
        "............",
        ".RRRRRRRRRR.",
        ".RRRRRRRRRR.",
        "........RRR.",
        ".......RRR..",
        "......RRR...",
        ".....RRR....",
        ".....RRR....",
        "....RRR.....",
        "....RRR.....",
        "....RRR.....",
        "............",
    ], palette: base)

    static let spade = PixelSprite(rows: [
        ".....WW.....",
        "....WWWW....",
        "...WWWWWW...",
        "..WWWWWWWW..",
        ".WWWWWWWWWW.",
        "WWWWWWWWWWWW",
        "WWWWWWWWWWWW",
        "WWWWWWWWWWWW",
        ".WWW.WW.WWW.",
        ".....WW.....",
        "....WWWW....",
        "...WWWWWW...",
    ], palette: base)

    static let dice = PixelSprite(rows: [
        "WWWWWW......",
        "WkWWkW......",
        "WWWWWW......",
        "WWWWWW......",
        "WkWWkW......",
        "WWWWWW......",
        "......RRRRRR",
        "......RWRRRR",
        "......RRRRRR",
        "......RRRRRR",
        "......RRRRWR",
        "......RRRRRR",
    ], palette: base)

    static let roulette = PixelSprite(rows: [
        "...dRdRdR...",
        "..RdWdRdRd..",
        ".dRGGGGGGRd.",
        "RdGGGGGGGGdR",
        "dRGGGYYGGGRd",
        "RdGGYYYYGGdR",
        "dRGGYYYYGGRd",
        "RdGGGYYGGGdR",
        "dRGGGGGGGGRd",
        ".RdGGGGGGdR.",
        "..dRdRdRdR..",
        "...RdRdRd...",
    ], palette: base)

    /// 홀짝: 엎어 둔 그릇 (구슬을 덮고 있음)
    static let bowl = PixelSprite(rows: [
        "....kkkkkkkk....",
        "..kkRRRRRRRRkk..",
        ".kRRWRRRRRRRRRk.",
        ".kRWRRRRRRRRRRk.",
        "kRRRRRRRRRRRRRRk",
        "kRRRRRRRRRRRRRRk",
        "kYYYYYYYYYYYYYYk",
        "kkkkkkkkkkkkkkkk",
        "..dddddddddddd..",
    ], palette: base)

    /// 홀짝: 유리 구슬
    static let marble = PixelSprite(rows: [
        ".kkkk.",
        "kWWYYk",
        "kWYYYk",
        "kYYYbk",
        "kYYbbk",
        ".kkkk.",
    ], palette: base.merging(["b": Theme.goldDark]) { $1 })

    /// 메뉴바 아이콘: 16×16 칩 실루엣. 평소엔 템플릿(시스템 색), 리밋 중엔 골드.
    static func menuBarIcon(gold: Bool) -> NSImage {
        let n = 16
        let c = Double(n - 1) / 2
        let image = NSImage(size: NSSize(width: n, height: n), flipped: true) { _ in
            (gold ? NSColor(Theme.gold) : .black).setFill()
            for y in 0..<n {
                for x in 0..<n {
                    let dx = Double(x) - c, dy = Double(y) - c
                    let d = (dx * dx + dy * dy).squareRoot()
                    let notch = d >= 5.6 && (abs(dx) < 1.5 || abs(dy) < 1.5)
                    let ring = d >= 3.6 && d < 4.6
                    if d <= 7.6 && !notch && !ring {
                        NSRect(x: x, y: y, width: 1, height: 1).fill()
                    }
                }
            }
            return true
        }
        image.isTemplate = !gold
        return image
    }
}
