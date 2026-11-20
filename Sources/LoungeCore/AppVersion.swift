import Foundation

/// 앱 버전 "0.3.0" / 태그 "v0.3.0". 비교만 하면 돼서 숫자 세 칸만 본다 (빠진 칸은 0)
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    /// 숫자가 아닌 칸이 있으면 nil ("dev" 같은 번들 없는 실행 포함)
    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let nums = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(nums.count), nums.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        parts = nums.compactMap { $0 } + Array(repeating: 0, count: 3 - nums.count)
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}

/// 새 버전 안내. 지금 버전보다 최신 릴리스가 높거나 서버 최소 버전에 못 미칠 때만 생긴다
public struct AppUpdate: Equatable, Sendable {
    /// 지금 버전
    public let current: AppVersion
    /// 받아야 할 버전 (최신 릴리스, 최소 버전 중 높은 쪽)
    public let target: AppVersion
    /// 서버 최소 버전보다 낮다 → 테이블을 막는다
    public let required: Bool

    public init(current: AppVersion, target: AppVersion, required: Bool) {
        self.current = current
        self.target = target
        self.required = required
    }

    /// current가 nil(개발 실행)이면 안내하지 않는다
    public static func check(current: AppVersion?, latest: AppVersion?, minimum: AppVersion?) -> AppUpdate? {
        guard let current else { return nil }
        let required = minimum.map { current < $0 } ?? false
        let target = [latest, required ? minimum : nil].compactMap { $0 }.max()
        guard let target, target > current else { return nil }
        return AppUpdate(current: current, target: target, required: required)
    }
}
