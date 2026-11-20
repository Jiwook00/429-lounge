import AppKit
import LoungeNet
import SwiftUI

/// "지금 라운지" 띠 (DESIGN.md §9, ADR-0008)
/// 라운지 N명 (앱이 켜져 있는 회원) + 보는 중 (팝오버를 연 회원, 시안 네온) + 회원 칩 두 줄
struct PresenceStrip: View {
    let crowd: LoungeCrowd

    /// 띠 안쪽 폭: 팝오버 340 - 바깥 여백 28 - 박스 여백 20
    private static let innerWidth: CGFloat = LoungeView.width - 28 - 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Rectangle().fill(Theme.green).frame(width: 6, height: 6).glow(Theme.green, radius: 3)
                Text("라운지 \(crowd.total)명").font(Fonts.bold())
                Spacer()
                if crowd.othersViewing > 0 {
                    HStack(spacing: 4) {
                        PixelView(sprite: Sprites.eye, scale: 2)
                        Text("\(crowd.viewing)명 보는 중").font(Fonts.small())
                    }
                    .foregroundStyle(Theme.cyan)
                    .glow(Theme.cyan)
                } else if crowd.total <= 2 {
                    Text("조용한 밤").font(Fonts.small()).foregroundStyle(Theme.dim)
                }
            }
            if crowd.others.isEmpty {
                Text("누가 오면 여기 불이 켜져요").font(Fonts.small()).foregroundStyle(Theme.dim)
            } else {
                chips
            }
        }
        .padding(10)
        .pixelBox()
    }

    private var chips: some View {
        let items = crowd.others.map(Chip.init)
        let shown = ChipFit.visibleCount(itemWidths: items.map(\.width), width: Self.innerWidth)
        let hidden = items.count - shown
        return FlowLayout {
            ForEach(items.prefix(shown), id: \.member.id) { $0 }
            if hidden > 0 {
                Text(ChipFit.overflowLabel(hidden))
                    .font(Fonts.small())
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 2))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 회원 칩: 보는 중(시안 + 눈) / 429 VIP(골드) / 코딩 중(초록 점) / 쉬는 중(흐리게)
    private struct Chip: View {
        let member: Member

        init(_ member: Member) { self.member = member }

        private var label: String {
            if member.viewing { return member.name }
            switch member.status {
            case .vip: return "\(member.name) · 429 VIP"
            case .coding: return "\(member.name) · 코딩 중"
            case .resting: return "\(member.name) · 쉬는 중"
            case nil: return member.name
            }
        }

        private var showsDot: Bool { !member.viewing && member.status == .coding }

        /// 칩 폭 (줄 수 계산용): 글자 + 여백·테두리 + 아이콘
        var width: CGFloat {
            ChipFit.width(label) + (member.viewing ? 7 + 4 : 0) + (showsDot ? 4 + 4 : 0)
        }

        var body: some View {
            let style = Self.style(member)
            HStack(spacing: 4) {
                if member.viewing { PixelView(sprite: Sprites.eye, scale: 1) }
                if showsDot { Rectangle().fill(Theme.green).frame(width: 4, height: 4) }
                Text(label)
            }
            .font(Fonts.small())
            .foregroundStyle(style.text)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(style.fill)
            .overlay(Rectangle().strokeBorder(style.border, lineWidth: 2))
            .glow(member.viewing ? Theme.cyan : .clear)
        }

        private static func style(_ m: Member) -> (text: Color, fill: Color, border: Color) {
            if m.viewing { return (Theme.cyan, Theme.cyanBg, Theme.cyan) }
            switch m.status {
            case .vip: return (Theme.gold, Theme.goldBg, Theme.gold)
            case .coding: return (Theme.cream, Theme.panel, Theme.line)
            case .resting: return (Theme.dim, Theme.panel, Theme.line)
            case nil: return (Theme.muted, Theme.panel, Theme.line)
            }
        }
    }
}

/// 전광판: 평소엔 숨어 있다가 잭팟·빅 윈 직후 몇 분 동안만 나타나 흐른다
struct EventTicker: View {
    let events: [LoungeEvent]
    let now: Date
    var still = false

    private static let speed = 30.0 // pt/s
    private static let gap: CGFloat = 10
    private static let font = NSFont(name: "Galmuri9-Regular", size: 10) ?? .systemFont(ofSize: 10)

    private var items: [String] {
        events.map { e in
            let figure = "+\(e.amount.formatted(.number))"
            return e.kind == "jackpot" ? "\(e.name) JACKPOT \(figure)" : "\(e.name) BIG WIN \(figure)"
        }
    }

    private static func textWidth(_ s: String) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    var body: some View {
        let widths = items.map(Self.textWidth)
        // 한 바퀴 폭: (글자 + 간격 + 구분점 + 간격) × 개수
        let loop = widths.reduce(0) { $0 + $1 + Self.gap * 2 + 4 }
        let offset = still ? 0 : -(CGFloat(now.timeIntervalSinceReferenceDate * Self.speed).truncatingRemainder(dividingBy: max(loop, 1))).rounded()

        return HStack(spacing: 8) {
            Text("LIVE")
                .font(Fonts.bold())
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 3)
                .background(Theme.neon)
                .glow(Theme.neon)
            // overlay라서 흐르는 글자가 띠 폭을 늘리지 않는다
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 14)
                .overlay(alignment: .leading) {
                    HStack(spacing: 0) {
                        copy(widths)
                        copy(widths)
                        copy(widths)
                    }
                    .offset(x: offset)
                }
                .clipped()
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(Theme.marquee)
        .overlay(Rectangle().strokeBorder(Theme.bulbOff, lineWidth: 2))
    }

    private func copy(_ widths: [CGFloat]) -> some View {
        HStack(spacing: Self.gap) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, text in
                Text(text)
                    .font(Fonts.small())
                    .foregroundStyle(Theme.gold)
                    .glow(Theme.gold, radius: 3)
                    .frame(width: widths[i], alignment: .leading)
                Rectangle().fill(Theme.neon).frame(width: 4, height: 4)
            }
        }
        .padding(.trailing, Self.gap)
        .fixedSize()
    }
}
