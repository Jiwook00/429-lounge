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

    /// 라운지 벽화 타일: 벽돌 줄눈 사이에 칠한 칸들 (12×12)
    static let wall = PixelSprite(rows: [
        "dddddddddddd",
        "dRRdCCdYYddd",
        "dRRdCCdYYdWd",
        "dddddddddddd",
        "dYYdWWdRRdCd",
        "dYYdWWdRRdCd",
        "dddddddddddd",
        "dCCdRRdWWdYd",
        "dCCdRRdWWdYd",
        "dddddddddddd",
        "dWWdYYdCCdRd",
        "dddddddddddd",
    ], palette: base.merging(["C": Theme.cyan]) { $1 })

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

    /// 메뉴바 아이콘: 18×14 슬롯머신. 메뉴바에서 바로 눈에 띄게 컬러로 그린다 (템플릿 아님).
    /// 평소엔 레드 기계에 골드 777, VIP HOUR엔 골드 기계에 네온 429.
    /// busy면 홀짝 테이블에 다른 회원이 있다는 뜻으로 레버 공이 시안으로 켜진다.
    static func menuBarIcon(vip: Bool = false, busy: Bool = false) -> NSImage {
        let sprite = slotMachine(vip: vip, busy: busy)
        let image = NSImage(size: NSSize(width: sprite.width, height: sprite.height), flipped: true) { _ in
            for (y, row) in sprite.rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let color = sprite.palette[ch] else { continue }
                    NSColor(color).setFill()
                    NSRect(x: x, y: y, width: 1, height: 1).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 메뉴바·앱 아이콘이 같이 쓰는 18×14 슬롯머신 격자
    static func slotMachine(vip: Bool = false, busy: Bool = false) -> PixelSprite {
        let seven = ["777", "..7", "..7", ".7.", ".7."]
        let reels = vip
            ? [["7.7", "7.7", "777", "..7", "..7"], ["777", "..7", "777", "7..", "777"], ["777", "7.7", "777", "..7", "777"]]
            : [seven, seven, seven]
        // T 꼭대기 · C 기계 · W 릴 창 · 7 릴 글자 · D 받침 그림자 · B 레버 공 · S 레버 막대
        var rows = [
            "....TTTTTTT.......",
            "..CCCCCCCCCCC...BB",
            "CCCCCCCCCCCCCCC.BB",
            "CWWWWWWWWWWWWWC..S",
        ]
        for i in 0..<5 {
            let lever = i == 3 ? "SSS" : i == 4 ? "..." : "..S"
            rows.append("CW" + reels.map { $0[i].replacingOccurrences(of: ".", with: "W") }.joined(separator: "W") + "WC" + lever)
        }
        rows += ["CWWWWWWWWWWWWWC...", "CCCCCCCCCCCCCCC...", "CDDDDDDDDDDDDDC...", "TTTTTTTTTTTTTTT..."]

        let palette: [Character: Color] = [
            "T": vip ? Theme.neon : Theme.gold,
            "C": vip ? Theme.gold : Theme.neon,
            "D": vip ? Theme.goldDark : Theme.neonDeep,
            "W": Theme.outline,
            "7": vip ? Theme.neon : Theme.gold,
            "B": busy ? Theme.cyan : (vip ? Theme.neon : Theme.gold),
            "S": Theme.dim,
        ]
        return PixelSprite(rows: rows, palette: palette)
    }
}
