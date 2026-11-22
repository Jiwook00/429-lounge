import SwiftUI


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
