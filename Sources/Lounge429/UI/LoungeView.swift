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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let lock = snapshot.activeLock(at: context.date)
            VStack(spacing: 12) {
                header(locked: lock != nil)
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

    private func header(locked: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("429")
                .font(Fonts.bold(2))
                .foregroundStyle(Theme.neon)
                .shadow(color: Theme.neon.opacity(0.6), radius: 4)
            Text("LOUNGE")
                .font(Fonts.bold())
                .foregroundStyle(Theme.gold)
            Spacer()
            HStack(spacing: 4) {
                Rectangle().fill(locked ? Theme.gold : Theme.green).frame(width: 6, height: 6)
                Text(locked ? "VIP HOUR" : "OPEN")
                    .font(Fonts.small())
                    .foregroundStyle(locked ? Theme.gold : Theme.green)
            }
        }
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
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .pixelBox(fill: Color(hex: 0x2E2412), border: Theme.gold)
    }

    private func toastView(_ t: LoungeStore.Toast) -> some View {
        Text(t.text)
            .font(Fonts.body())
            .foregroundStyle(t.golden ? Theme.bg : Theme.gold)
            .frame(maxWidth: .infinity, minHeight: 26)
            .pixelBox(fill: t.golden ? Theme.gold : Color(hex: 0x2E2412), border: Theme.gold)
    }

    private var games: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            GameTile(sprite: Sprites.seven, title: "슬롯", mode: "SOLO")
            GameTile(sprite: Sprites.spade, title: "블랙잭", mode: "SOLO · TABLE")
            Button(action: onOddEven) {
                GameTile(sprite: Sprites.dice, title: "구슬 홀짝", mode: "TABLE", soon: !online)
            }
            .buttonStyle(.plain)
            .disabled(!online)
            GameTile(sprite: Sprites.roulette, title: "룰렛", mode: "TABLE")
        }
    }

    private var footer: some View {
        HStack {
            Text(online ? "라운지 연결됨" : "오프라인")
            Spacer()
            Button("새로고침", action: onRefresh)
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

    var body: some View {
        HStack(spacing: 10) {
            PixelView(sprite: sprite, scale: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Fonts.body())
                Text(mode).font(Fonts.small()).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .pixelBox()
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
