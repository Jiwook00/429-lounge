import LoungeNet
import SwiftUI

/// 라운지 벽화 (ADR-0017). 32×32 공용 벽, 칸 9pt. 칩과 무관한 무료 놀이
struct PixelWallView: View {
    @Bindable var wall: PixelWall
    var onBack: () -> Void = {}

    private static let cell: CGFloat = 9
    private static var side: CGFloat { cell * CGFloat(PixelWall.size) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(spacing: 10) {
                topBar
                VStack(spacing: 6) {
                    board
                    infoLine(now)
                }
                responseLine(now)
                palette
                rateBox(now)
                painters
            }
            .padding(14)
            .frame(width: LoungeView.width)
            .background(Theme.bg)
        }
        .foregroundStyle(Theme.cream)
    }

    // MARK: - 상단

    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                Text("‹ 라운지").font(Fonts.small()).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            GameSoundButton()
            Spacer()
            Text("라운지 벽화").font(Fonts.bold()).foregroundStyle(Theme.neon).glow(Theme.neon)
            Spacer()
            Text("FREE").font(Fonts.small()).foregroundStyle(Theme.muted)
                .frame(width: 58, alignment: .trailing)
        }
    }

    // MARK: - 벽

    private var board: some View {
        let unit = Self.cell
        return Canvas { ctx, _ in
            ctx.fill(Path(CGRect(x: 0, y: 0, width: Self.side, height: Self.side)), with: .color(Theme.panel))
            for y in 0..<PixelWall.size {
                for x in 0..<PixelWall.size {
                    guard let p = wall.pixel(at: .init(x: x, y: y)), Theme.wall.indices.contains(p.c) else { continue }
                    let rect = CGRect(x: CGFloat(x) * unit, y: CGFloat(y) * unit, width: unit, height: unit)
                    ctx.fill(Path(rect), with: .color(Theme.wall[p.c].color))
                }
            }
            if let h = wall.hover, h != wall.selected {
                let rect = CGRect(x: CGFloat(h.x) * unit, y: CGFloat(h.y) * unit, width: unit, height: unit)
                ctx.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(Theme.muted), lineWidth: 1)
            }
            if let s = wall.selected {
                let rect = CGRect(x: CGFloat(s.x) * unit, y: CGFloat(s.y) * unit, width: unit, height: unit)
                ctx.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(Theme.gold), lineWidth: 2)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): wall.hover = cell(at: p)
            case .ended: wall.hover = nil
            }
        }
        .onTapGesture { p in
            if let c = cell(at: p) { wall.paint(c) }
        }
        .padding(2)
        .pixelBox(fill: Theme.panel, border: Theme.line)
    }

    private func cell(at p: CGPoint) -> PixelWall.Cell? {
        let x = Int(p.x / Self.cell), y = Int(p.y / Self.cell)
        guard (0..<PixelWall.size).contains(x), (0..<PixelWall.size).contains(y) else { return nil }
        return .init(x: x, y: y)
    }

    /// 올려 둔(없으면 마지막으로 누른) 칸을 누가 칠했는지
    private func infoLine(_ now: Date) -> some View {
        let target = wall.hover ?? wall.selected
        let pixel = target.flatMap(wall.pixel(at:))
        return HStack(spacing: 5) {
            if let target, let pixel {
                Rectangle().fill(Theme.wall[pixel.c].color).frame(width: 8, height: 8)
                    .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 1))
                Text("\(pixel.p) · \(Self.ago(pixel.at, now: now))").foregroundStyle(Theme.cream)
                Text("\(target.x + 1),\(target.y + 1)").foregroundStyle(Theme.dim)
            } else if let target {
                Text("빈 칸 · \(target.x + 1),\(target.y + 1)").foregroundStyle(Theme.muted)
            } else {
                Text("칸에 올리면 누가 칠했는지 보여요").foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            Text("월요일에 새 벽").foregroundStyle(Theme.dim)
        }
        .font(Fonts.small())
        .frame(width: Self.side + 4)
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "방금" }
        if s < 3600 { return "\(s / 60)분 전" }
        if s < 86_400 { return "\(s / 3600)시간 전" }
        return "\(s / 86_400)일 전"
    }

    // MARK: - 응답 줄

    private func responseLine(_ now: Date) -> some View {
        let left = wall.bucket?.left(at: now) ?? 1
        let (text, color, glow): (String, Color, Bool) = switch wall.response {
        case .limited where left <= 0:
            ("429 Too Many Pixels · \(PixelBucket.clock(wall.bucket?.untilNext(at: now) ?? 0))", Theme.neon, true)
        case .created(let c): ("PUT /wall/\(c.x + 1),\(c.y + 1)  201 Created", Theme.green, false)
        case .same: ("304 Not Modified · 같은 색이에요", Theme.muted, false)
        case .failed(let m): (m, Theme.neon, false)
        default: ("GET /wall  200 OK", Theme.muted, false)
        }
        return Text(text).font(Fonts.bold()).foregroundStyle(color).glow(glow ? color : .clear)
            .frame(maxWidth: .infinity)
    }

    // MARK: - 팔레트

    private var palette: some View {
        HStack(spacing: 6) {
            ForEach(Theme.wall.indices, id: \.self) { i in
                let picked = wall.color == i
                Button { wall.color = i } label: {
                    Rectangle().fill(Theme.wall[i].color)
                        .frame(height: 20)
                        .padding(2)
                        .pixelBox(fill: Theme.bg, border: picked ? Theme.gold : Theme.line)
                        .offset(y: picked ? -2 : 0)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Theme.wall[i].name)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - 버킷

    private func rateBox(_ now: Date) -> some View {
        let b = wall.bucket
        let cap = b?.cap ?? 10
        let left = b?.left(at: now) ?? cap
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("X-RateLimit-Remaining").font(Fonts.small()).foregroundStyle(Theme.muted)
                HStack(spacing: 3) {
                    ForEach(0..<cap, id: \.self) { i in
                        Rectangle().fill(i < left ? Theme.gold : Theme.line).frame(width: 8, height: 12)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(left)/\(cap)").font(Fonts.mono(2)).foregroundStyle(left > 0 ? Theme.gold : Theme.neon)
                Text(b?.untilNext(at: now).map { "다음 픽셀 \(PixelBucket.clock($0))" } ?? "가득 참")
                    .font(Fonts.small()).foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .pixelBox()
    }

    // MARK: - 이번 주 벽에 남은 칸

    /// 상위 3명. 내가 3위 밖이면 상위 2명 + 나
    static func shown(_ list: [PixelBoardState.Painter]) -> [PixelBoardState.Painter] {
        guard let me = list.dropFirst(3).first(where: \.me) else { return Array(list.prefix(3)) }
        return Array(list.prefix(2)) + [me]
    }

    private var painters: some View {
        let list = wall.state?.painters ?? []
        return HStack(spacing: 4) {
            if list.isEmpty {
                Text("아직 빈 벽이에요 · 첫 칸을 칠해 보세요").font(Fonts.small()).foregroundStyle(Theme.muted)
            } else {
                Text("벽에 남은 칸").font(Fonts.small()).foregroundStyle(Theme.muted).padding(.trailing, 2)
                ForEach(Array(Self.shown(list).enumerated()), id: \.offset) { _, p in
                    Text("\(p.name) · \(p.count)")
                        .font(Fonts.small())
                        .foregroundStyle(p.me ? Theme.gold : Theme.cream)
                        .lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .pixelBox(fill: p.me ? Theme.goldBg : Theme.panel, border: p.me ? Theme.gold : Theme.line)
                }
                if list.count > 3 {
                    Text("+\(list.count - 3)명").font(Fonts.small()).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 5).padding(.vertical, 3).pixelBox()
                }
            }
            Spacer(minLength: 0)
        }
    }
}
