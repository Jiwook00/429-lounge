import SwiftUI

/// 429 드롭 도트 에셋 (시안과 같은 6×6 공·동전, 12×12 타일)
extension Sprites {
    private static let plinkoBase: [Character: Color] = [
        "k": Theme.outline, "R": Theme.neon, "W": Theme.cream, "Y": Theme.gold,
    ]

    /// 공: 평소엔 회보라, 골드 핀을 맞았거나 FEVER면 금색
    static func plinkoBall(golden: Bool) -> PixelSprite {
        PixelSprite(rows: [
            ".kkkk.",
            "khhbbk",
            "khbbbk",
            "kbbbsk",
            "kbbssk",
            ".kkkk.",
        ], palette: [
            "k": Theme.outline,
            "b": golden ? Theme.gold : Theme.muted,
            "s": golden ? Theme.goldDark : Theme.dim,
            "h": golden ? Theme.goldLight : Theme.cream,
        ])
    }

    /// 큰 판정 때 튀는 동전
    static let plinkoCoin = PixelSprite(rows: [
        ".kkkk.",
        "kLYYYk",
        "kYsYYk",
        "kYsYYk",
        "kYYYsk",
        ".kkkk.",
    ], palette: [
        "k": Theme.outline, "L": Theme.goldLight, "Y": Theme.gold, "s": Theme.goldDark,
    ])

    /// 레인 선택 화살표 (6×4, 아래로)
    static func laneArrow(_ color: Color) -> PixelSprite {
        PixelSprite(rows: [
            "AAAAAA",
            ".AAAA.",
            "..AA..",
            "......",
        ], palette: ["A": color])
    }

    /// 로비 타일: 공 하나와 핀, 배수 칸
    static let plinko = PixelSprite(rows: [
        "....kkkk....",
        "...kWRRRk...",
        "...kRRRRk...",
        "....kkkk....",
        "............",
        ".....Y.Y....",
        "....Y.Y.Y...",
        "...Y.Y.Y.Y..",
        "............",
        "RR.YY.RR.YY.",
        "RR.YY.RR.YY.",
        "kkkkkkkkkkkk",
    ], palette: plinkoBase)
}
