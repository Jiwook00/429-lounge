import LoungeCore
import LoungeNet
import SwiftUI

/// 메뉴바 팝오버. 스냅샷 렌더링을 위해 store 대신 값을 받는다.
struct LoungeView: View {
    let snapshot: UsageSnapshot
    let lastScan: Date?
    var chips: Int
    var golden: Int = 0
    var toast: LoungeStore.Toast?
    var online: Bool = false
    /// 지금 라운지 접속 현황 + 전광판 이벤트
    var crowd: LoungeCrowd = .empty
    /// 직접 정한 닉네임. 아직 안 정했으면 nil → 게임 대신 닉네임 카드
    var name: String?
    var onRename: (String) async -> String? = { _ in nil }
    /// 스냅샷용: 이름 바꾸기 카드를 펼친 상태로
    var nicknameDraft: (text: String, error: String?)?
    var onOddEven: () -> Void = {}
    var onSlot: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onQuit: () -> Void = {}

    static let width: CGFloat = 340

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renaming = false

    var body: some View {
        // 0.1초 틱: 네온 깜빡임과 전구 띠용. 팝오버가 열려 있을 때만 그려진다.
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let lock = snapshot.activeLock(at: context.date)
            VStack(spacing: 12) {
                header(locked: lock != nil, now: context.date)
                // 전광판: 잭팟·빅 윈 직후에만 나타난다
                if !crowd.events.isEmpty {
                    EventTicker(events: crowd.events, now: context.date, still: reduceMotion)
                }
                wallet
                if let lock { vipBanner(lock, now: context.date) }
                if let toast { toastView(toast) }
                if online && (name == nil || renaming || nicknameDraft != nil) {
                    NicknameCard(
                        current: name,
                        onSave: { new in
                            let error = await onRename(new)
                            if error == nil { renaming = false }
                            return error
                        },
                        onCancel: name == nil ? nil : { renaming = false },
                        initialText: nicknameDraft?.text ?? "",
                        initialError: nicknameDraft?.error
                    )
                } else {
                    if online { PresenceStrip(crowd: crowd) }
                    games
                }
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
        MarqueeBulbs(count: 35, offset: offset)
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
            Button(action: onSlot) {
                GameTile(sprite: Sprites.seven, title: "슬롯", mode: "SOLO", soon: !online, live: online,
                         badge: crowd.slot > 0 ? "\(crowd.slot)명" : nil)
            }
            .buttonStyle(.plain)
            .disabled(!online)
            GameTile(sprite: Sprites.spade, title: "블랙잭", mode: "SOLO · TABLE")
            Button(action: onOddEven) {
                // 1배 크기 타일은 좁아서 인원을 아래 줄에 쓴다 (사람이 있으면 더 강하게 발광)
                GameTile(sprite: Sprites.dice, title: "구슬 홀짝",
                         mode: !online ? "TABLE" : crowd.oddEven > 0 ? "TABLE · \(crowd.oddEven)명 앉음" : "TABLE · 비어 있음",
                         soon: !online, live: online, hot: crowd.oddEven > 0)
            }
            .buttonStyle(.plain)
            .disabled(!online)
            GameTile(sprite: Sprites.roulette, title: "룰렛", mode: "TABLE")
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Rectangle().fill(online ? Theme.green : Theme.dim).frame(width: 6, height: 6)
            Text(online ? (name ?? "라운지 연결됨") : "오프라인")
                .foregroundStyle(online && name != nil ? Theme.cream : Theme.muted)
            Spacer()
            if online, name != nil, !renaming {
                Button("이름 바꾸기") { renaming = true }.padding(.trailing, 6)
            }
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
    /// 오른쪽 위 인원 배지 (시안)
    var badge: String?
    /// 테이블에 사람이 앉아 있음: 아래 줄 강조 + 더 강한 발광
    var hot = false

    var body: some View {
        HStack(spacing: 10) {
            PixelView(sprite: sprite, scale: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Fonts.body())
                Text(mode).font(Fonts.small()).foregroundStyle(live ? Theme.neon : Theme.muted)
                    .glow(hot ? Theme.neon : .clear)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .pixelBox(border: live ? Theme.neon : Theme.line)
        .glow(live ? Theme.neon : .clear, radius: hot ? 6 : 4, strong: hot)
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if let badge {
                Text(badge)
                    .font(Fonts.small())
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 4)
                    .background(Theme.cyan)
                    .padding(6)
            } else if soon { Text("SOON")
                .font(Fonts.small())
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 3)
                .background(Theme.muted)
                .padding(6) }
        }
    }
}
