import LoungeNet
import SwiftUI

/// 블랙잭 도트 그림. 시안(Claude Design "429 Lounge 블랙잭 시안")의 격자 코드를 그대로 옮겼다.
/// 문자 격자 대신 칸마다 색 번호를 담아 계산으로 만든다 (펠트 곡선, 버스트처럼 모양을 수식으로 그리는 것들).
enum Ink: UInt8, Sendable {
    case clear, bg, panel, line, felt, feltLine, gold, goldBg, goldLight, goldDark
    case neon, neonDeep, cream, creamDeep, muted, dim, green, outline

    var color: Color {
        switch self {
        case .clear: .clear
        case .bg: Theme.bg
        case .panel: Theme.panel
        case .line: Theme.line
        case .felt: Theme.felt
        case .feltLine: Theme.feltLine
        case .gold: Theme.gold
        case .goldBg: Theme.goldBg
        case .goldLight: Theme.goldLight
        case .goldDark: Theme.goldDark
        case .neon: Theme.neon
        case .neonDeep: Theme.neonDeep
        case .cream: Theme.cream
        case .creamDeep: Theme.creamDeep
        case .muted: Theme.muted
        case .dim: Theme.dim
        case .green: Theme.green
        case .outline: Theme.outline
        }
    }
}

/// 색 번호 격자. 정수 배율로만 그린다 (DESIGN.md §5)
struct PixelGrid: Sendable {
    let width: Int
    let height: Int
    var cells: [Ink]

    init(width: Int, height: Int, fill: Ink = .clear) {
        self.width = width
        self.height = height
        cells = Array(repeating: fill, count: width * height)
    }

    subscript(x: Int, y: Int) -> Ink {
        get { cells[y * width + x] }
        set { if x >= 0, y >= 0, x < width, y < height { cells[y * width + x] = newValue } }
    }

    init(rows: [String], map: [Character: Ink]) {
        self.init(width: rows.map(\.count).max() ?? 0, height: rows.count)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() { if let ink = map[ch] { self[x, y] = ink } }
        }
    }

    func mirrored() -> PixelGrid {
        var g = PixelGrid(width: width, height: height)
        for y in 0..<height { for x in 0..<width { g[width - 1 - x, y] = self[x, y] } }
        return g
    }

    /// 다른 격자를 (ox, oy)에 덮어 찍는다 (투명 칸은 건너뜀)
    mutating func stamp(_ other: PixelGrid, x ox: Int, y oy: Int) {
        for y in 0..<other.height { for x in 0..<other.width where other[x, y] != .clear { self[ox + x, oy + y] = other[x, y] } }
    }
}

/// 같은 색이 이어진 칸을 한 사각형으로 합쳐 그린다
struct GridView: View {
    let grid: PixelGrid
    var scale: CGFloat = 2

    var body: some View {
        Canvas { ctx, _ in GridView.draw(grid, in: &ctx, scale: scale) }
            .frame(width: CGFloat(grid.width) * scale, height: CGFloat(grid.height) * scale)
    }

    static func draw(_ grid: PixelGrid, in ctx: inout GraphicsContext, scale: CGFloat, origin: CGPoint = .zero) {
        for y in 0..<grid.height {
            var x = 0
            while x < grid.width {
                let ink = grid[x, y]
                guard ink != .clear else { x += 1; continue }
                var end = x + 1
                while end < grid.width && grid[end, y] == ink { end += 1 }
                let rect = CGRect(x: origin.x + CGFloat(x) * scale, y: origin.y + CGFloat(y) * scale,
                                  width: CGFloat(end - x) * scale, height: scale)
                ctx.fill(Path(rect), with: .color(ink.color))
                x = end
            }
        }
    }
}

@MainActor
enum BlackjackArt {
    // MARK: - 카드 (13×17)

    static let cardSize = (w: 13, h: 17)

    private static let ranks: [String: [String]] = [
        "A": [".X.", "X.X", "XXX", "X.X", "X.X"], "2": ["XXX", "..X", "XXX", "X..", "XXX"],
        "3": ["XXX", "..X", ".XX", "..X", "XXX"], "4": ["X.X", "X.X", "XXX", "..X", "..X"],
        "5": ["XXX", "X..", "XXX", "..X", "XXX"], "6": ["XXX", "X..", "XXX", "X.X", "XXX"],
        "7": ["XXX", "..X", ".X.", ".X.", ".X."], "8": ["XXX", "X.X", "XXX", "X.X", "XXX"],
        "9": ["XXX", "X.X", "XXX", "..X", "XXX"], "0": ["XXX", "X.X", "X.X", "X.X", "XXX"],
        "1": [".X", "XX", ".X", ".X", ".X"], "J": ["..X", "..X", "..X", "X.X", ".X."],
        "Q": [".X.", "X.X", "X.X", "XX.", ".XX"], "K": ["X.X", "X.X", "XX.", "X.X", "X.X"],
    ]
    /// 스페이드 · 하트 · 다이아 · 클럽 (BJCard.suit 순서)
    private static let suits: [[String]] = [
        ["...X...", "..XXX..", ".XXXXX.", "XXXXXXX", "XX.X.XX", "..XXX.."],
        [".XX.XX.", "XXXXXXX", "XXXXXXX", ".XXXXX.", "..XXX..", "...X..."],
        ["...X...", "..XXX..", ".XXXXX.", ".XXXXX.", "..XXX..", "...X..."],
        ["..XXX..", "..XXX..", "XX.X.XX", "XXXXXXX", "XX.X.XX", "..XXX.."],
    ]

    private static var cardCache: [Int: PixelGrid] = [:]

    /// code < 0 = 뒷면
    static func card(_ code: Int) -> PixelGrid {
        if let g = cardCache[code] { return g }
        let w = cardSize.w, h = cardSize.h
        var g = PixelGrid(width: w, height: h, fill: .cream)
        for y in 0..<h { for x in 0..<w where x == 0 || y == 0 || x == w - 1 || y == h - 1 { g[x, y] = .outline } }
        for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] { g[x, y] = .clear }
        for (x, y) in [(1, 1), (w - 2, 1), (1, h - 2), (w - 2, h - 2)] { g[x, y] = .outline }
        if code < 0 {
            for y in 2..<(h - 2) { for x in 2..<(w - 2) { g[x, y] = ((x + y) % 4 == 0 || (x - y + 40) % 4 == 0) ? .gold : .neon } }
        } else {
            let c = BJCard(code)
            let ink: Ink = c.red ? .neon : .outline
            func put(_ glyph: [String], _ ox: Int, _ oy: Int) {
                for (j, row) in glyph.enumerated() { for (i, ch) in row.enumerated() where ch == "X" { g[ox + i, oy + j] = ink } }
            }
            if c.label == "10" { put(ranks["1"]!, 2, 2); put(ranks["0"]!, 5, 2) } else { put(ranks[c.label]!, 2, 2) }
            put(suits[c.suit], 3, 9)
        }
        cardCache[code] = g
        return g
    }

    // MARK: - 칩 더미 · 금화

    static func chips(stacks: Int) -> PixelGrid {
        let one = [".LLLL.", "LGGGGL", "DGGGGD", ".DDDD."]
        let map: [Character: Ink] = ["L": .goldLight, "G": .gold, "D": .goldDark]
        var g = PixelGrid(width: stacks * 7 - 1, height: 8)
        for s in 0..<stacks {
            for c in stride(from: 2, through: 0, by: -1) {
                g.stamp(PixelGrid(rows: one, map: map), x: s * 7, y: c * 2)
            }
        }
        return g
    }

    // MARK: - 스탬프 (BUST, BLACKJACK …)

    static func burst(rx: Int, ry: Int, fill: Ink, edge: Ink) -> PixelGrid {
        var g = PixelGrid(width: rx * 2, height: ry * 2)
        for y in 0..<g.height {
            for x in 0..<g.width {
                let nx = (Double(x) + 0.5 - Double(rx)) / Double(rx)
                let ny = (Double(y) + 0.5 - Double(ry)) / Double(ry)
                let r = (nx * nx + ny * ny).squareRoot(), a = atan2(ny, nx)
                let edgeR = 1 - 0.26 * (0.5 + 0.5 * cos(12 * a)) + 0.05 * sin(5 * a)
                if r < edgeR { g[x, y] = r > edgeR - 0.16 ? edge : fill }
            }
        }
        return g
    }

    // MARK: - 딜러 (가슴 아래부터, 154×50)

    /// 왼쪽 절반(24칸)을 계산해 좌우 대칭으로. 단추 줄부터 시작해서 얼굴·나비넥타이는 화면 밖
    private static var dealerRows: [String] {
        (0..<17).map { r in
            let arm = r < 12 ? "...kvvvk." : r == 12 ? "...kwwwk." : r < 16 ? (r == 13 ? "..kccccck" : ".kcccccck") : "..kkkkkk."
            let w = r < 4 ? 3 : r < 8 ? 2 : 1
            let strip = String((0..<w).map { i in (i == w - 1 && r % 4 == 1) ? "g" : "w" })
            let torso = "k" + String(repeating: "v", count: 14 - w)
            let left = arm + torso + strip
            return left + String(left.reversed())
        }
    }

    private static var dealerCache: [Bool: PixelGrid] = [:]

    static func dealer(focus: Bool) -> PixelGrid {
        if let g = dealerCache[focus] { return g }
        var g = PixelGrid(width: 154, height: 50)
        for y in 0..<17 { for x in 0..<154 { g[x, y] = .bg } }
        for x in 0..<154 { g[x, 17] = .outline; g[x, 22] = .gold }
        for y in 18..<22 { for x in 0..<154 { g[x, y] = .goldBg } }
        let rack: [Ink] = [.gold, .neon, .cream, .green, .gold, .neon]
        for c in 0..<14 { for y in 18..<22 { g[49 + c * 4, y] = rack[c % rack.count]; g[50 + c * 4, y] = rack[c % rack.count] } }
        for y in 23..<50 { for x in 0..<154 { g[x, y] = .felt } }
        let map: [Character: Ink] = ["k": .outline, "w": .cream, "v": .line, "g": .gold, "c": .cream]
        g.stamp(PixelGrid(rows: dealerRows, map: map), x: 53, y: 0)
        // 카드 슈
        for y in 25..<41 { for x in 132..<149 { g[x, y] = (y == 25 || y == 40 || x == 132 || x == 148) ? .outline : (y < 29 ? .neon : .line) } }
        if focus { focusLines(&g) }
        dealerCache[focus] = g
        return g
    }

    // MARK: - 테이블 펠트

    /// 큰 타원 테이블 하나를 좌석마다 다른 곳에서 잘라 본다 (시안 곡선 A)
    nonisolated static let rx = 300.0, ry = 160.0, rail = 7.0

    struct Seat: Hashable, Sendable {
        /// 타원 위 각도 (90 = 맨 아래, 정면)
        let phi: Double
        /// 창 안에서 레일이 지나는 점
        let ax: Int, ay: Int
        let w: Int, h: Int
    }

    struct Frame: Sendable {
        let anchor: CGPoint
        /// 테이블 안쪽(딜러 쪽) 방향
        let n: CGVector
        /// 레일을 따라 오른쪽으로
        let t: CGVector
        let p: CGPoint
    }

    nonisolated static func frame(_ s: Seat) -> Frame {
        let a = s.phi * .pi / 180
        var nx = -cos(a) / rx, ny = -sin(a) / ry
        let l = (nx * nx + ny * ny).squareRoot()
        nx /= l; ny /= l
        var tx = -ny, ty = nx
        if tx < 0 { tx = -tx; ty = -ty }
        return Frame(anchor: CGPoint(x: s.ax, y: s.ay), n: CGVector(dx: nx, dy: ny), t: CGVector(dx: tx, dy: ty),
                     p: CGPoint(x: rx * cos(a), y: ry * sin(a)))
    }

    private static func classify(_ x: Double, _ y: Double) -> Ink {
        func e(_ a: Double) -> Double { x * x / ((rx + a) * (rx + a)) + y * y / ((ry + a) * (ry + a)) }
        if e(0) < 1 { return (e(-22) >= 1 && e(-21) < 1) ? .feltLine : .felt }
        if e(1) < 1 { return .gold }
        if e(rail) < 1 { return .line }
        if e(rail + 1) < 1 { return .outline }
        return .clear
    }

    private struct FeltKey: Hashable { let seat: Seat; let focus: Bool }
    private static var feltCache: [FeltKey: PixelGrid] = [:]

    static func felt(_ s: Seat, focus: Bool) -> PixelGrid {
        let key = FeltKey(seat: s, focus: focus)
        if let g = feltCache[key] { return g }
        let f = frame(s)
        var g = PixelGrid(width: s.w, height: s.h)
        for y in 0..<s.h {
            for x in 0..<s.w {
                g[x, y] = classify(f.p.x + Double(x - s.ax) + 0.5, f.p.y + Double(y - s.ay) + 0.5)
            }
        }
        if focus { focusLines(&g) }
        feltCache[key] = g
        return g
    }

    /// 만화 집중선: 가장자리에서 안쪽으로 도트 줄
    static func focusLines(_ g: inout PixelGrid) {
        let cx = Double(g.width) / 2, cy = Double(g.height) / 2
        for k in 0..<28 {
            let ang = (Double(k) * 360 / 28 + 5) * .pi / 180
            let dx = cos(ang), dy = sin(ang)
            let tx = dx > 0 ? (Double(g.width - 1) - cx) / dx : dx < 0 ? -cx / dx : 1e9
            let ty = dy > 0 ? (Double(g.height - 1) - cy) / dy : dy < 0 ? -cy / dy : 1e9
            let t = min(tx, ty), len = [5, 9, 7][k % 3]
            for s in stride(from: 0, to: len, by: 2) {
                let px = Int((cx + dx * (t - Double(s))).rounded()), py = Int((cy + dy * (t - Double(s))).rounded())
                g[px, py] = .cream
            }
        }
    }

    /// 말풍선 꼬리 (왼쪽 아래로)
    static func tail(fill: Ink, edge: Ink = .outline) -> PixelGrid {
        PixelGrid(rows: ["kccck", ".kcck", "..kck", "...kk"], map: ["k": edge, "c": fill])
    }
}
