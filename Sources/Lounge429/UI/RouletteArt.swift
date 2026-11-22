import Foundation
import LoungeNet

/// 미니 룰렛 도트 그림. 시안(Claude Design "429 Lounge 블랙잭 시안"의 미니 룰렛 줄)의 격자 코드를 옮겼다.
/// 휠은 돌지 않는다(픽셀 규칙). 공만 칸을 건너뛴다.
@MainActor
enum RouletteArt {
    /// 휠 격자 크기 (×2로 그려서 120pt)
    static let size = 60
    /// 공이 도는 길의 반지름 (격자 칸)
    static let track = 15.0

    private static let digits: [Character: [String]] = [
        "0": ["XXX", "X.X", "X.X", "X.X", "XXX"], "1": [".X", "XX", ".X", ".X", ".X"], "2": ["XXX", "..X", "XXX", "X..", "XXX"],
        "3": ["XXX", "..X", ".XX", "..X", "XXX"], "4": ["X.X", "X.X", "XXX", "..X", "..X"], "5": ["XXX", "X..", "XXX", "..X", "XXX"],
        "6": ["XXX", "X..", "XXX", "X.X", "XXX"], "7": ["XXX", "..X", ".X.", ".X.", ".X."], "8": ["XXX", "X.X", "XXX", "X.X", "XXX"],
        "9": ["XXX", "X.X", "XXX", "..X", "XXX"],
    ]
    private static let seg = 2 * Double.pi / Double(Roulette.wheel.count)

    /// 휠 칸 i의 가운데 각도 (0번 칸이 맨 위, 시계 방향)
    static func angle(_ i: Int) -> Double { (Double(i) + 0.5) * seg - .pi / 2 }

    private static var wheelCache: [Int: PixelGrid] = [:]

    /// 고정 원판. highlight가 있으면 그 칸 바깥 테두리를 골드로
    static func wheel(highlight: Int?) -> PixelGrid {
        let key = highlight ?? -1
        if let g = wheelCache[key] { return g }
        let n = size
        var g = PixelGrid(width: n, height: n)
        let c = Double(n) / 2
        for y in 0..<n {
            for x in 0..<n {
                let dx = Double(x) + 0.5 - c, dy = Double(y) + 0.5 - c
                let r = (dx * dx + dy * dy).squareRoot()
                guard r < 30 else { continue }
                var a = atan2(dy, dx) + .pi / 2
                if a < 0 { a += 2 * .pi }
                let t = a / seg, idx = Int(t) % Roulette.wheel.count, f = t - floor(t)
                let num = Roulette.wheel[idx]
                let ink: Ink
                if r >= 28 { ink = num == highlight ? .gold : .goldDark }
                else if r >= 27 { ink = .outline }
                else if r >= 19 {
                    ink = min(f, 1 - f) * seg * r < 0.75 ? .gold : num == 0 ? .felt : Roulette.red.contains(num) ? .neon : .outline
                }
                else if r >= 18 { ink = .outline }
                else if r >= 12 { ink = .panel }
                else if r >= 11 { ink = .goldDark }
                else if r < 3 { ink = .goldLight }
                else if r < 4 { ink = .gold }
                else if abs(dx) < 1 || abs(dy) < 1 { ink = .goldDark }
                else { ink = r >= 10 ? .feltLine : .felt }
                g[x, y] = ink
            }
        }
        // 칸 번호 (3×5 도트 숫자)
        for (i, num) in Roulette.wheel.enumerated() {
            let s = Array(String(num))
            let w = s.enumerated().reduce(0) { $0 + digits[$1.element]![0].count + ($1.offset > 0 ? 1 : 0) }
            let p = angle(i)
            var ox = Int((c + 22.8 * cos(p) - Double(w) / 2).rounded())
            let oy = Int((c + 22.8 * sin(p) - 2.5).rounded())
            for ch in s {
                let glyph = digits[ch]!
                for (j, row) in glyph.enumerated() { for (q, cell) in row.enumerated() where cell == "X" { g[ox + q, oy + j] = .cream } }
                ox += glyph[0].count + 1
            }
        }
        wheelCache[key] = g
        return g
    }

    /// 휠 칸 i에 놓인 공(6×6)의 왼쪽 위 (격자 칸)
    static func ball(at i: Int) -> (x: Int, y: Int) {
        let p = angle(i), c = Double(size) / 2
        return (Int((c + track * cos(p) - 3).rounded()), Int((c + track * sin(p) - 3).rounded()))
    }

    /// 칸 위에 놓인 칩 (6×4). 황금 칩은 한 단계 밝게
    static func chip(golden: Bool) -> PixelGrid {
        PixelGrid(rows: [".LLLL.", "LGGGGL", "DGGGGD", ".DDDD."],
                  map: golden ? ["L": .cream, "G": .goldLight, "D": .gold] : ["L": .goldLight, "G": .gold, "D": .goldDark])
    }

    /// 다른 회원 수 표시용 사람 (4×6)
    static let person = PixelGrid(rows: [".XX.", ".XX.", "....", "XXXX", "XXXX", "XXXX"], map: ["X": .cream])
}
