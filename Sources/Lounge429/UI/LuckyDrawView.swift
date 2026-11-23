import SwiftUI

struct LuckyDrawView: View {
    let chips: Int
    let number: Int
    let amount: Int?
    var busy = false
    var available = true
    var message: String?
    var destination = "라운지"
    var onScratch: () -> Void = {}
    var onBack: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("‹ " + destination, action: onBack).foregroundStyle(Theme.muted)
                Spacer()
                Text("럭키 드로우").font(Fonts.bold()).foregroundStyle(Theme.neon)
                Spacer()
                Text("\(chips.formatted())칩").font(Fonts.mono()).foregroundStyle(Theme.gold)
            }
            .disabled(busy)
            ticket.padding(16).frame(maxWidth: .infinity).pixelBox()
            HStack {
                Text(amount == nil ? "오늘 \(number)번째 티켓" : "오늘 \(number)장 받았어요")
                Spacer()
                Text("하루 3장")
            }.foregroundStyle(Theme.muted)
            if let message { Text(message).font(Fonts.small()).foregroundStyle(Theme.cream) }
            Button(action: amount == nil ? onScratch : onBack) {
                Text(amount != nil ? "\(destination) 돌아가기" : busy ? "긁는 중…" : "티켓 긁기")
                    .font(Fonts.bold()).foregroundStyle(Theme.gold)
                    .frame(maxWidth: .infinity, minHeight: 28).pixelBox()
            }
            .disabled(amount == nil && (busy || !available))
        }
        .buttonStyle(.plain).font(Fonts.body()).padding(14)
        .frame(width: LoungeView.width).background(Theme.bg)
        .onChange(of: amount) { _, value in
            guard value == 429, !reduceMotion else { return }
            flash = true
            withAnimation(.easeOut(duration: 0.6)) { flash = false }
        }
    }

    private var ticket: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("429 LOUNGE").font(Fonts.bold())
                    Spacer()
                    Text("무료 티켓").font(Fonts.small())
                }
                ZStack {
                    if let amount {
                        Text("+\(amount)칩").font(Fonts.mono(2)).foregroundStyle(Theme.gold)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.goldBg)
                    } else {
                        ZStack {
                            Canvas { ctx, size in
                                for x in stride(from: 4, to: Int(size.width), by: 8) {
                                    for y in stride(from: 4, to: Int(size.height), by: 8)
                                        where (x + y) % 24 == 0 {
                                        ctx.fill(Path(CGRect(x: x, y: y, width: 2, height: 2)), with: .color(Theme.dim))
                                    }
                                }
                            }
                            Text(busy ? "긁는 중…" : "긁어 보세요").padding(3).background(Theme.creamDeep)
                        }
                        .background(Theme.creamDeep)
                        .transition(.asymmetric(insertion: .identity, removal: .move(edge: .trailing)))
                    }
                }
                .frame(height: 40).clipped().border(Theme.line, width: 2)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.32), value: amount)
                .contentShape(Rectangle())
                .onTapGesture { scratch() }
                .gesture(DragGesture(minimumDistance: 4).onChanged { _ in scratch() })
                Text("50~429칩").font(Fonts.small())
            }
            Canvas { ctx, size in
                for y in stride(from: 0, to: Int(size.height), by: 8) {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: 2, height: 4)), with: .color(Theme.creamDeep))
                }
            }.frame(width: 2)
            VStack(spacing: 5) {
                HStack(spacing: 2) {
                    ForEach(Array([2,1,3,2,1,2,3,1,2].enumerated()), id: \.offset) { _, width in
                        Rectangle().frame(width: CGFloat(width))
                    }
                }.frame(height: 36)
                Text("429").font(Fonts.bold()).foregroundStyle(flash ? Theme.gold : Theme.line)
            }
        }
        .foregroundStyle(Theme.line).padding(12).frame(height: 104)
        .background(Theme.cream)
        .overlay(alignment: .leading) { notch }
        .overlay(alignment: .trailing) { notch }
    }

    private var notch: some View { Rectangle().fill(Theme.panel).frame(width: 5, height: 10) }

    private func scratch() {
        if amount == nil && available && !busy { onScratch() }
    }
}
