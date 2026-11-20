import AppKit
import LoungeNet
import SwiftUI

/// 홀짝 판 현황 요약 (DESIGN.md §9 "판 현황").
/// 인원이 많아도 높이가 늘지 않게: 줄다리기 바 + 이름 칩(최대 두 줄, 넘치면 +N명).
struct BetBoard {
    struct Tally {
        var count = 0
        var total: Int64 = 0
        var payout: Int64 = 0
        var cost: Int64 = 0
    }

    struct Chip: Identifiable {
        let id: UUID
        let label: String
        let side: Side
        let mine: Bool
        /// 결과 공개 중이면 이겼는지, 베팅 중이면 nil
        let won: Bool?
    }

    struct Mine {
        let label: String
    }

    var odd = Tally()
    var even = Tally()
    /// 내 베팅이 맨 앞, 그다음 금액 큰 순
    let chips: [Chip]
    let result: Side?
    let mine: Bet?
    /// 이번 판 가장 많이 받은 사람 (결과 공개 중에만)
    let bigWinner: (name: String, payout: Int64)?

    init(bets: [Bet], result: Side?, myID: UUID?, name: (UUID) -> String) {
        self.result = result
        mine = bets.first { $0.playerId == myID }

        for b in bets {
            if b.side == .odd {
                odd.count += 1; odd.total += b.amount; odd.payout += b.payout ?? 0; odd.cost += b.cost
            } else {
                even.count += 1; even.total += b.amount; even.payout += b.payout ?? 0; even.cost += b.cost
            }
        }

        let sorted = bets.sorted {
            if ($0.playerId == myID) != ($1.playerId == myID) { return $0.playerId == myID }
            return $0.amount > $1.amount
        }
        chips = sorted.map { b in
            let isMine = b.playerId == myID
            let who = isMine ? "나" : name(b.playerId)
            let won = result.map { $0 == b.side }
            let figure: String
            switch won {
            case .some(true): figure = "+\((b.payout ?? b.amount * 2).formatted(.number))"
            case .some(false): figure = b.cost == 0 ? "±0" : "-\(b.cost.formatted(.number))"
            case .none: figure = b.amount.formatted(.number)
            }
            return Chip(id: b.playerId, label: "\(who) \(figure)", side: b.side, mine: isMine, won: won)
        }

        if result != nil, let top = bets.filter({ ($0.payout ?? 0) > 0 }).max(by: { ($0.payout ?? 0) < ($1.payout ?? 0) }) {
            bigWinner = (top.playerId == myID ? "나" : name(top.playerId), top.payout ?? 0)
        } else {
            bigWinner = nil
        }
    }

    var isEmpty: Bool { chips.isEmpty }
    var pot: Int64 { odd.total + even.total }
    /// 홀 쪽 막대 비율. 아무도 안 걸었으면 반반.
    var oddRatio: Double { pot == 0 ? 0.5 : Double(odd.total) / Double(pot) }

    func tally(_ side: Side) -> Tally { side == .odd ? odd : even }
}

/// 이름 칩을 몇 개까지 보여줄지: 최대 `maxLines`줄, 넘치면 마지막 줄에 "+N명" 칩 자리를 남긴다.
@MainActor
enum ChipFit {
    static let font = NSFont(name: "Galmuri9-Regular", size: 10) ?? .systemFont(ofSize: 10)
    /// 좌우 여백 5pt + 테두리 2pt
    static let chrome: CGFloat = 14
    nonisolated static let spacing: CGFloat = 4

    static func width(_ label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: font]).width) + chrome
    }

    static func overflowLabel(_ hidden: Int) -> String { "+\(hidden)명" }

    static func visibleCount(_ labels: [String], width: CGFloat, maxLines: Int = 2) -> Int {
        visibleCount(itemWidths: labels.map(Self.width), width: width, maxLines: maxLines)
    }

    /// 칩마다 아이콘 같은 추가 폭이 있을 때
    static func visibleCount(itemWidths: [CGFloat], width: CGFloat, maxLines: Int = 2) -> Int {
        for shown in stride(from: itemWidths.count, through: 0, by: -1) {
            var widths = Array(itemWidths.prefix(shown))
            if shown < itemWidths.count { widths.append(Self.width(overflowLabel(itemWidths.count - shown))) }
            if lines(widths, width: width) <= maxLines { return shown }
        }
        return 0
    }

    static func lines(_ widths: [CGFloat], width: CGFloat) -> Int {
        guard !widths.isEmpty else { return 0 }
        var lines = 1, x: CGFloat = 0
        for w in widths {
            if x > 0, x + spacing + w > width {
                lines += 1
                x = w
            } else {
                x += (x > 0 ? spacing : 0) + w
            }
        }
        return lines
    }
}

/// 줄바꿈되는 가로 배치. 위치와 크기를 정수 pt로 맞춰 도트가 번지지 않게 한다.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4 // ChipFit.spacing와 같게

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY.rounded()
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX.rounded()
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, view) in subviews.enumerated() {
            let raw = view.sizeThatFits(.unspecified)
            let size = CGSize(width: ceil(raw.width), height: ceil(raw.height))
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
