import SwiftUI

/// 소수결 화면에 그릴 값 (DESIGN.md §9 소수결)
/// 평일 8·11·14시에 열린다. 참가비를 걸고 고르면 3시간 뒤 적게 고른 쪽이 이긴다
struct MinorityScreen {
    struct Round {
        let question: String
        let options: (String, String)
        let closesAt: Date
        let stake: Int64
        let participants: Int
        /// 내가 고른 쪽 (0 / 1). 안 골랐으면 nil
        var myPick: Int?
    }

    /// 쉬는 시간에만 보여주는 내 지난 판 한 줄
    struct Mine {
        let question: String
        /// 이긴 쪽 이름. nil = 무효
        let winner: String?
        let amount: Int64?
        let net: Int64
    }

    /// 지금 열린 판. nil이면 쉬는 시간
    var round: Round?
    /// 다음 판 여는 시각 (쉬는 시간일 때)
    var nextOpensAt: Date?
    var mine: Mine?
}

struct MinorityView: View {
    let screen: MinorityScreen
    let chips: Int
    var picking = false
    var message: String?
    var onPick: (Int) -> Void = { _ in }
    var onBack: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 10) {
                topBar
                status(now: context.date)
                felt
                controls
                bottomBar
            }
            .padding(14)
            .frame(width: LoungeView.width)
            .background(Theme.bg)
        }
        .foregroundStyle(Theme.cream)
    }

    // MARK: - Top / bottom

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Text("‹ 라운지").font(Fonts.small()).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            GameSoundButton()
            Spacer()
            Text("소수결").font(Fonts.bold()).foregroundStyle(Theme.neon).glow(Theme.neon)
            Spacer()
            Text("평일 8 · 11 · 14시").font(Fonts.small()).foregroundStyle(Theme.muted)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            PixelView(sprite: Sprites.chip, scale: 1)
            Text(chips.formatted(.number)).font(Fonts.mono()).foregroundStyle(Theme.gold)
            Spacer()
            if let message {
                Text(message).font(Fonts.small()).foregroundStyle(Theme.neon)
            } else if let round = screen.round {
                Text("한 판 \(round.stake.formatted(.number))칩").font(Fonts.small()).foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: - 상태 줄: 남은 시간 · 참가 인원 (질문과 따로)

    private func status(now: Date) -> some View {
        HStack(spacing: 6) {
            if let r = screen.round {
                Text(Self.countdown(r.closesAt.timeIntervalSince(now))).font(Fonts.mono()).foregroundStyle(Theme.gold)
                Text("뒤 \(Self.hour(r.closesAt)) 공개").font(Fonts.small()).foregroundStyle(Theme.muted)
                Spacer()
                Rectangle().fill(r.participants > 0 ? Theme.green : Theme.dim).frame(width: 6, height: 6)
                Text(r.participants == 0 ? "아직 아무도" : "\(r.participants)명 참가").font(Fonts.small())
                    .foregroundStyle(r.participants > 0 ? Theme.green : Theme.dim)
            } else {
                Text("쉬는 시간").font(Fonts.small()).foregroundStyle(Theme.muted)
                Spacer()
                if let next = screen.nextOpensAt {
                    Text("다음 판 \(Self.day(next, now: now)) \(Self.hour(next))").font(Fonts.small()).foregroundStyle(Theme.gold)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .pixelBox()
    }

    // MARK: - 펠트: 질문만

    private var felt: some View {
        VStack(spacing: 6) {
            if let r = screen.round {
                Text(r.question).font(Fonts.bold(2)).foregroundStyle(Theme.cream)
                    .lineLimit(1)
                Text("적게 고른 쪽이 이겨요").font(Fonts.small()).foregroundStyle(Theme.cream.opacity(0.75))
            } else {
                Text("오늘 판은 끝났어요").font(Fonts.bold()).foregroundStyle(Theme.cream)
                if let m = screen.mine {
                    Text(Self.mineLine(m)).font(Fonts.small())
                        .foregroundStyle(m.net > 0 ? Theme.gold : Theme.cream.opacity(0.75))
                } else {
                    Text("평일 8시, 11시, 14시에 질문이 올라와요").font(Fonts.small()).foregroundStyle(Theme.cream.opacity(0.75))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 84)
        .background(Theme.felt)
        .overlay(Rectangle().strokeBorder(Theme.feltLine, lineWidth: 2).padding(4))
        .pixelBox(fill: Theme.felt, border: Theme.gold)
    }

    static func mineLine(_ m: MinorityScreen.Mine) -> String {
        guard let w = m.winner else {
            let amount = m.amount?.formatted(.number) ?? "건 칩"
            return "지난 판 「\(m.question)」 무효 · \(amount) 돌려받음"
        }
        let me = m.net > 0 ? "나 +\(m.net.formatted(.number))" : "나 -\((-m.net).formatted(.number))"
        return "지난 판 「\(m.question)」 \(w) 승 · \(me)"
    }

    // MARK: - 고르기 (질문 바로 아래)

    @ViewBuilder private var controls: some View {
        if let r = screen.round {
            if let pick = r.myPick {
                Text("\(pick == 0 ? r.options.0 : r.options.1) 쪽에 \(r.stake.formatted(.number)) 걸었어요 · \(Self.hour(r.closesAt)) 공개")
                    .font(Fonts.small()).foregroundStyle(Theme.gold)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .pixelBox(fill: Theme.goldBg, border: Theme.gold)
            } else {
                let enabled = Int64(chips) >= r.stake && !picking
                HStack(spacing: 8) {
                    optionButton(r.options.0, index: 0, enabled: enabled)
                    optionButton(r.options.1, index: 1, enabled: enabled)
                }
            }
        }
    }

    /// 질문의 단어를 그대로 버튼에. 1번은 네온, 2번은 크림 (홀짝 버튼과 같은 짝)
    private func optionButton(_ label: String, index: Int, enabled: Bool) -> some View {
        Button { onPick(index) } label: {
            Text(label)
                .font(Fonts.bold())
                .foregroundStyle(index == 0 ? Theme.cream : Theme.bg)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 38)
                .pixelBox(fill: index == 0 ? Theme.neon : Theme.cream,
                          border: index == 0 ? Theme.neonDeep : Theme.creamDeep)
                .glow(index == 0 && enabled ? Theme.neon : .clear)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    // MARK: - 시간 표시

    static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    private static var kst: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return cal
    }

    /// 11시 / 14시 / 17시 (KST)
    static func hour(_ date: Date) -> String { "\(kst.component(.hour, from: date))시" }

    /// 오늘 / 내일 / 월요일
    static func day(_ date: Date, now: Date) -> String {
        let cal = kst
        if cal.isDate(date, inSameDayAs: now) { return "오늘" }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: t) { return "내일" }
        let names = ["", "일요일", "월요일", "화요일", "수요일", "목요일", "금요일", "토요일"]
        return names[cal.component(.weekday, from: date)]
    }
}

/// 로비 5번째 타일에 쓸 소수결 상태
enum MinorityTileState {
    /// 열려 있음. picked면 이미 걸었음
    case open(closesAt: Date, picked: Bool)
    case closed(nextOpensAt: Date)

    func line(now: Date) -> String {
        switch self {
        case .open(let closesAt, let picked):
            let s = max(0, Int(closesAt.timeIntervalSince(now)))
            let left = "\(s / 3600):\(String(format: "%02d", s / 60 % 60)) 남음"
            return picked ? "걸었어요 · \(left)" : "OPEN · \(left)"
        case .closed(let next):
            return "다음 판 \(MinorityView.day(next, now: now)) \(MinorityView.hour(next))"
        }
    }

    var open: Bool { if case .open = self { true } else { false } }
}
