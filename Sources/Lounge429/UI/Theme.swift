import CoreText
import SwiftUI

/// A. 라스베가스 팔레트 (DESIGN.md §7). 뷰에 hex를 직접 쓰지 말고 이 토큰만 쓴다.
enum Theme {
    static let bg       = Color(hex: 0x0B0710) // 밤하늘
    static let panel    = Color(hex: 0x1A0E22)
    static let line     = Color(hex: 0x3A1F4D)
    static let outline  = Color(hex: 0x0A0410)
    static let felt     = Color(hex: 0x0B6B3A)
    static let feltLine = Color(hex: 0x138A4D)
    static let gold     = Color(hex: 0xFFC93C)
    static let goldBg   = Color(hex: 0x2B1A08)
    static let neon     = Color(hex: 0xFF2E63)
    static let cyan     = Color(hex: 0x2EE6D6)
    static let cream    = Color(hex: 0xFFF4E0)
    static let muted    = Color(hex: 0xB9A3C9)
    static let dim      = Color(hex: 0x7D6A8A)
    static let green    = Color(hex: 0x3DDC84)
    /// 꺼진 전구
    static let bulbOff  = Color(hex: 0x5A3A12)
    /// "보는 중" 칩 바탕
    static let cyanBg   = Color(hex: 0x0E2A2E)
    /// 전광판 바탕
    static let marquee  = Color(hex: 0x120806)
    /// 버튼 테두리 (홀 / 짝)
    static let neonDeep  = Color(hex: 0xB81E46)
    static let creamDeep = Color(hex: 0xC9BFA8)
    /// 황금 칩 스프라이트 하이라이트 / 그림자
    static let goldLight = Color(hex: 0xFFF1B8)
    static let goldDark  = Color(hex: 0xB8862B)
}

extension View {
    /// 네온 발광. 로고, 결과, 내 베팅, VIP 배너, 활성 테이블에만 쓴다 (DESIGN.md §3)
    func glow(_ color: Color, radius: CGFloat = 4, strong: Bool = false) -> some View {
        self
            .shadow(color: color.opacity(strong ? 0.85 : 0.6), radius: radius)
            .shadow(color: color.opacity(strong ? 0.5 : 0), radius: radius * 2.5)
    }
}

/// Galmuri는 지정 크기(11 → 12pt, 9 → 10pt)와 그 정수배에서 가장 또렷하다.
enum Fonts {
    static func body(_ scale: CGFloat = 1) -> Font { .custom("Galmuri11-Regular", fixedSize: 12 * scale) }
    static func bold(_ scale: CGFloat = 1) -> Font { .custom("Galmuri11-Bold", fixedSize: 12 * scale) }
    static func small() -> Font { .custom("Galmuri9-Regular", fixedSize: 10) }
    static func mono(_ scale: CGFloat = 1) -> Font { .custom("GalmuriMono11-Regular", fixedSize: 12 * scale) }

    static func register() {
        let urls = LoungeResources.bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// 모서리를 1칸 깎은 도트 스타일 테두리 박스
struct PixelBox: ViewModifier {
    var fill: Color = Theme.panel
    var border: Color = Theme.line
    var unit: CGFloat = 2

    func body(content: Content) -> some View {
        content
            .background(fill)
            .overlay(Rectangle().strokeBorder(border, lineWidth: unit))
            .overlay(alignment: .topLeading) { corner }
            .overlay(alignment: .topTrailing) { corner }
            .overlay(alignment: .bottomLeading) { corner }
            .overlay(alignment: .bottomTrailing) { corner }
    }

    private var corner: some View {
        Rectangle().fill(Theme.bg).frame(width: unit, height: unit)
    }
}

extension View {
    func pixelBox(fill: Color = Theme.panel, border: Color = Theme.line) -> some View {
        modifier(PixelBox(fill: fill, border: border))
    }
}
