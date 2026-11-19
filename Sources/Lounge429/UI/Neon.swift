import SwiftUI

/// 네온관 밝기. 0.1초 단위 패턴으로 "치지직" 깜빡임을 만든다 (DESIGN.md §10).
enum Neon: Int, Comparable {
    case off, dim, on

    static func < (a: Neon, b: Neon) -> Bool { a.rawValue < b.rawValue }

    var opacity: Double {
        switch self {
        case .off: 0.18
        case .dim: 0.5
        case .on: 1
        }
    }

    /// 간판 전체: 4.7초 주기, 앞쪽에 짧게 두 번 꺼졌다 켜지고 한 번 흐려짐
    private static let signPattern = Array("._.-..oooooooooooooooooooooooooooooooooooooooo")
    /// "9" 혼자: 3.1초 주기 (간판 주기와 어긋나서 반복이 덜 티 난다)
    private static let tubePattern = Array("ooooooooooooooooooooooo-.o-oooo")

    static func sign(at t: TimeInterval) -> Neon { level(signPattern, t) }
    static func brokenTube(at t: TimeInterval) -> Neon { level(tubePattern, t) }

    /// 승리 연출용 빠른 점멸 (0.15초 간격)
    static func strobe(at t: TimeInterval) -> Neon { Int(t / 0.15) % 2 == 0 ? .on : .dim }

    private static func level(_ pattern: [Character], _ t: TimeInterval) -> Neon {
        switch pattern[Int(t * 10) % pattern.count] {
        case ".": .off
        case "-", "_": .dim
        default: .on
        }
    }
}

/// 카지노 전구 띠. 5pt 전구 + 4pt 간격, 왼쪽 정렬로 정수 좌표 유지.
/// offset을 바꾸면 한 칸씩 흐르고, allOn이면 전부 켜진 채 번쩍인다(빅 윈).
struct MarqueeBulbs: View {
    let count: Int
    var offset: Int = 0
    var allOn: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                let phase = allOn ? 0 : (i + offset) % 3
                Rectangle()
                    .fill(phase == 0 ? Theme.gold : phase == 1 ? Theme.bulbOff : Theme.neon)
                    .frame(width: 5, height: 5)
                    .glow(phase == 0 ? Theme.gold : .clear, radius: 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 주어진 폭에 들어가는 전구 개수
    static func count(for width: CGFloat) -> Int { Int((width + 4) / 9) }
}
