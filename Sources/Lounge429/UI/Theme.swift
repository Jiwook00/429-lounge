import CoreText
import SwiftUI

/// 디자인 방향 확정 전 임시 팔레트: 심야 라운지 + 네온 429 + 골드 칩
enum Theme {
    static let bg      = Color(hex: 0x15111C)
    static let panel   = Color(hex: 0x211A2C)
    static let line    = Color(hex: 0x3A2F4A)
    static let outline = Color(hex: 0x0A0810)
    static let felt    = Color(hex: 0x0F4D3A)
    static let gold    = Color(hex: 0xF2C14E)
    static let neon    = Color(hex: 0xFF3D5A)
    static let cream   = Color(hex: 0xF4EBD0)
    static let muted   = Color(hex: 0x8C8099)
    static let green   = Color(hex: 0x5BD68A)
}

/// Galmuri는 지정 크기(11 → 12pt, 9 → 10pt)와 그 정수배에서 가장 또렷하다.
enum Fonts {
    static func body(_ scale: CGFloat = 1) -> Font { .custom("Galmuri11-Regular", fixedSize: 12 * scale) }
    static func bold(_ scale: CGFloat = 1) -> Font { .custom("Galmuri11-Bold", fixedSize: 12 * scale) }
    static func small() -> Font { .custom("Galmuri9-Regular", fixedSize: 10) }
    static func mono(_ scale: CGFloat = 1) -> Font { .custom("GalmuriMono11-Regular", fixedSize: 12 * scale) }

    static func register() {
        let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
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
