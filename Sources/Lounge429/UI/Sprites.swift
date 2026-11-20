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

    // MARK: - 슬롯 심볼 (12×12)

    static let cherry = PixelSprite(rows: [
        "............",
        ".....ggg....",
        "....g...g...",
        "...g.....g..",
        "..g......g..",
        ".kkk....kkk.",
        "kRRRk..kRRRk",
        "kRWRk..kRWRk",
        "kRRRk..kRRRk",
        ".kkk....kkk.",
        "............",
        "............",
    ], palette: base.merging(["g": Theme.green]) { $1 })

    static let bell = PixelSprite(rows: [
        ".....kk.....",
        "....kYYk....",
        "...kYYYYk...",
        "...kYWYYk...",
        "..kYWYYYYk..",
        "..kYYYYYYk..",
        "..kYYYYYYk..",
        ".kYYYYYYYYk.",
        "kkkkkkkkkkkk",
        ".....kk.....",
        "....kYYk....",
        ".....kk.....",
    ], palette: base)

    static let bar = PixelSprite(rows: [
        "............",
        "............",
        "RRRRRRRRRRRR",
        "WWWWWWWWWWWW",
        "WkkWWWkWWkkW",
        "WkWkWkWkWkWk",
        "WkkWWkkkWkkW",
        "WkWkWkWkWkWk",
        "WkkWWkWkWkWk",
        "WWWWWWWWWWWW",
        "RRRRRRRRRRRR",
        "............",
    ], palette: base)

    /// HTTP 상태 코드 배지: 위아래 테두리 + 3×5 숫자 세 개 (12×12)
    static func badge(_ code: String, border: Color, digit: Color) -> PixelSprite {
        let glyphs: [Character: [String]] = [
            "0": ["XXX", "X.X", "X.X", "X.X", "XXX"],
            "2": ["XXX", "..X", "XXX", "X..", "XXX"],
            "4": ["X.X", "X.X", "XXX", "..X", "..X"],
            "5": ["XXX", "X..", "XXX", "..X", "XXX"],
            "9": ["XXX", "X.X", "XXX", "..X", "XXX"],
        ]
        let chars = Array(code)
        let digits = (0..<5).map { y in
            "k" + chars.map { (glyphs[$0]?[y] ?? "...").replacingOccurrences(of: "X", with: "D")
                .replacingOccurrences(of: ".", with: "k") }.joined(separator: "k")
        }
        let rows = ["............", "............", "BBBBBBBBBBBB", "kkkkkkkkkkkk"]
            + digits + ["kkkkkkkkkkkk", "BBBBBBBBBBBB", "............"]
        return PixelSprite(rows: rows, palette: base.merging(["B": border, "D": digit]) { $1 })
    }

    /// 잭팟 심볼 "429"
    static let s429 = badge("429", border: Theme.neon, digit: Theme.gold)
    /// 와일드 "200 OK"
    static let ok200 = badge("200", border: Theme.green, digit: Theme.green)
    /// 빈칸 "404" (흐릿한 유령)
    static let nf404 = badge("404", border: Theme.line, digit: Theme.dim)
    /// 글리치 "500"
    static let err500 = badge("500", border: Theme.neon, digit: Theme.cream)

    static let blank = PixelSprite(rows: Array(repeating: "............", count: 12), palette: base)

    /// 라운지 띠 "보는 중" 눈 (7×5)
    static let eye = PixelSprite(rows: [
        "..CCC..",
        ".C...C.",
        "C..W..C",
        ".C...C.",
        "..CCC..",
    ], palette: ["C": Theme.cyan, "W": Theme.cream])

    /// 메뉴바 아이콘: 16×16 칩 실루엣.
    /// 평소엔 템플릿(시스템 색). dot이면 홀짝 테이블에 다른 회원이 있다는 네온 점을 오른쪽 위에 찍는다.
    /// 템플릿 이미지는 단색이라 점이 있을 땐 칩을 메뉴바 글자색(labelColor)으로 직접 그린다.
    /// (VIP HOUR 골드 칩은 아이콘 디자인이 정해질 때까지 보류)
    static func menuBarIcon(dot: Bool = false) -> NSImage {
        let n = 16
        let c = Double(n - 1) / 2
        let image = NSImage(size: NSSize(width: n, height: n), flipped: true) { _ in
            (dot ? NSColor.labelColor : .black).setFill()
            for y in 0..<n {
                for x in 0..<n {
                    let dx = Double(x) - c, dy = Double(y) - c
                    let d = (dx * dx + dy * dy).squareRoot()
                    let notch = d >= 5.6 && (abs(dx) < 1.5 || abs(dy) < 1.5)
                    let ring = d >= 3.6 && d < 4.6
                    // 점 자리 둘레 1칸은 비워서 점이 칩에 묻히지 않게
                    let dotHole = dot && x >= 11 && y <= 4
                    if d <= 7.6 && !notch && !ring && !dotHole {
                        NSRect(x: x, y: y, width: 1, height: 1).fill()
                    }
                }
            }
            if dot {
                NSColor(Theme.neon).setFill()
                NSRect(x: 12, y: 0, width: 4, height: 4).fill()
            }
            return true
        }
        image.isTemplate = !dot
        return image
    }
}
