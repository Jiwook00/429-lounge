import LoungeCore
import SwiftUI

/// 메뉴바 팝오버. 스냅샷 렌더링을 위해 store 대신 값을 받는다.
struct LoungeView: View {
    let snapshot: UsageSnapshot
    let lastScan: Date?
    var chips: Int
    var golden: Int = 0
    var toast: LoungeStore.Toast?
    var online: Bool = false
    var onOddEven: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onQuit: () -> Void = {}

    static let width: CGFloat = 340

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 0.1초 틱: 네온 깜빡임과 전구 띠용. 팝오버가 열려 있을 때만 그려진다.
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let lock = snapshot.activeLock(at: context.date)
            VStack(spacing: 12) {
                header(locked: lock != nil, now: context.date)
                wallet
                if let lock { vipBanner(lock, now: context.date) }
                if let toast { toastView(toast) }
                games
                footer
            }
            .padding(14)
            .frame(width: Self.width)
            .background(Theme.bg)
        }
        .foregroundStyle(Theme.cream)
    }

    // MARK: - Sections

    /// 네온 간판 + 위아래 전구 띠 (DESIGN.md §10)
    private func header(locked: Bool, now: Date) -> some View {
        let t = now.timeIntervalSinceReferenceDate
        // 전구: 평소 0.5초, VIP HOUR 0.25초마다 한 칸씩 흐른다
        let chase = reduceMotion ? 0 : Int(t / (locked ? 0.25 : 0.5)) % 3
        let sign = reduceMotion ? Neon.on : Neon.sign(at: t)
        return VStack(spacing: 6) {
            bulbs(offset: chase)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 0) {
                    neonDigit("4", sign)
                    neonDigit("2", sign)
                    // 접촉 불량인 마지막 관: 간판 전체 깜빡임 + 혼자 한 번 더
                    neonDigit("9", reduceMotion ? sign : min(sign, Neon.brokenTube(at: t)))
                }
                Text("LOUNGE")
                    .font(Fonts.bold())
                    .foregroundStyle(Theme.cyan)
                    .glow(Theme.cyan)
                Spacer()
                HStack(spacing: 4) {
                    let color = locked ? Theme.gold : Theme.green
                    Rectangle().fill(color).frame(width: 6, height: 6)
                    Text(locked ? "VIP HOUR" : "OPEN")
                        .font(Fonts.small())
                        .foregroundStyle(color)
                }
                .glow(locked ? Theme.gold : .clear)
            }
            bulbs(offset: chase + 1)
        }
    }

    private func neonDigit(_ digit: String, _ level: Neon) -> some View {
        Text(digit)
            .font(Fonts.bold(2))
            .foregroundStyle(Theme.neon.opacity(level.opacity))
            .glow(level == .on ? Theme.neon : .clear, radius: 5, strong: true)
    }

    private func bulbs(offset: Int) -> some View {
        // 5pt 전구 + 4pt 간격 × 35개 = 311pt (안쪽 폭 312pt), 왼쪽 정렬로 정수 좌표 유지
        HStack(spacing: 4) {
            ForEach(0..<35, id: \.self) { i in
                let phase = (i + offset) % 3
                Rectangle()
                    .fill(phase == 0 ? Theme.gold : phase == 1 ? Theme.bulbOff : Theme.neon)
                    .frame(width: 5, height: 5)
                    .glow(phase == 0 ? Theme.gold : .clear, radius: 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var wallet: some View {
        HStack(spacing: 12) {
            PixelView(sprite: Sprites.chip, scale: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(chips.formatted(.number))
                    .font(Fonts.mono(2))
                    .foregroundStyle(Theme.gold)
                Text("오늘 \(snapshot.today.fresh.formatted(.number)) tok → +\((snapshot.today.fresh / 1_000).formatted(.number))칩")
                    .font(Fonts.small())
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            if golden > 0 {
                VStack(spacing: 2) {
                    PixelView(sprite: Sprites.goldChip, scale: 2)
                    Text("×\(golden)").font(Fonts.mono()).foregroundStyle(Theme.gold)
                }
            }
        }
        .padding(12)
        .pixelBox()
    }

    private func vipBanner(_ lock: RateLimitHit, now: Date) -> some View {
        HStack(spacing: 10) {
            PixelView(sprite: Sprites.goldChip, scale: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("429 Too Many Requests")
                    .font(Fonts.bold())
                    .foregroundStyle(Theme.gold)
                Text("리셋까지 \(Self.countdown(lock.resetsAt.timeIntervalSince(now))) · 황금 칩 타임")
                    .font(Fonts.small())
                Text(golden > 0 ? "황금 칩 \(golden)개 = 공짜 100칩 베팅 \(golden)번" : "황금 칩을 다 썼어요")
                    .font(Fonts.small())
                    .foregroundStyle(Theme.gold.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .pixelBox(fill: Theme.goldBg, border: Theme.gold)
        .glow(Theme.gold, radius: 6)
    }

    private func toastView(_ t: LoungeStore.Toast) -> some View {
        Text(t.text)
            .font(Fonts.body())
            .foregroundStyle(t.golden ? Theme.bg : Theme.gold)
            .frame(maxWidth: .infinity, minHeight: 26)
            .pixelBox(fill: t.golden ? Theme.gold : Theme.goldBg, border: Theme.gold)
    }

    private var games: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            GameTile(sprite: Sprites.seven, title: "슬롯", mode: "SOLO")
            GameTile(sprite: Sprites.spade, title: "블랙잭", mode: "SOLO · TABLE")
            Button(action: onOddEven) {
                GameTile(sprite: Sprites.dice, title: "구슬 홀짝", mode: "TABLE", soon: !online, live: online)
            }
            .buttonStyle(.plain)
            .disabled(!online)
            GameTile(sprite: Sprites.roulette, title: "룰렛", mode: "TABLE")
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Rectangle().fill(online ? Theme.green : Theme.dim).frame(width: 6, height: 6)
            Text(online ? "라운지 연결됨" : "오프라인")
            Spacer()
            Button("새로고침", action: onRefresh).padding(.trailing, 6)
            Button("종료", action: onQuit)
        }
        .font(Fonts.small())
        .foregroundStyle(Theme.muted)
        .buttonStyle(.plain)
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

private struct GameTile: View {
    let sprite: PixelSprite
    let title: String
    let mode: String
    var soon = true
    /// 지금 들어갈 수 있는 테이블: 네온 테두리 + 발광
    var live = false

    var body: some View {
        HStack(spacing: 10) {
            PixelView(sprite: sprite, scale: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Fonts.body())
                Text(mode).font(Fonts.small()).foregroundStyle(live ? Theme.neon : Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .pixelBox(border: live ? Theme.neon : Theme.line)
        .glow(live ? Theme.neon : .clear)
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if soon { Text("SOON")
                .font(Fonts.small())
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 3)
                .background(Theme.muted)
                .padding(6) }
        }
    }
}

/// 네온관 밝기. 0.1초 단위 패턴으로 "치지직" 깜빡임을 만든다.
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

    private static func level(_ pattern: [Character], _ t: TimeInterval) -> Neon {
        switch pattern[Int(t * 10) % pattern.count] {
        case ".": .off
        case "-", "_": .dim
        default: .on
        }
    }
}
