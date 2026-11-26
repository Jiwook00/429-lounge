import Foundation

/// 버전 하나의 "새로 들어온 것" 문구 (앱이 버전별로 넣어 둔다)
public struct ReleaseNote: Sendable, Equatable {
    public let version: String
    public let lines: [String]
    /// 해보기로 갈 게임 (화면 쪽 이름)
    public let game: String?
    /// `NEW` 라벨을 붙일 게임들
    public let newGames: Set<String>

    public init(version: String, lines: [String], game: String? = nil, newGames: Set<String> = []) {
        self.version = version
        self.lines = lines
        self.game = game
        self.newGames = newGames
    }
}

/// 업데이트 뒤 한 번 보여 줄 카드 내용. 건너뛴 버전들의 문구를 한데 모은다
public struct ReleaseDigest: Sendable, Equatable {
    /// 모은 문구 중 가장 오래된 버전 (한 버전뿐이면 nil)
    public let from: String?
    /// 모은 문구 중 가장 최신 버전
    public let to: String
    /// 최신 버전 문구부터, 최대 `maxLines`줄
    public let lines: [String]
    /// 가장 최신 버전의 해보기 게임
    public let game: String?
    /// 모은 버전들의 `NEW` 게임 전부
    public let newGames: Set<String>
}

public enum ReleaseNotes {
    /// - current: 지금 앱 버전. 숫자가 아니면("dev") 아무것도 없다
    /// - seen: 마지막으로 카드를 본 버전. 비었거나 숫자가 아니면(처음 설치, 카드가 생기기 전 버전에서 올라옴)
    ///   지금 버전 이하 중 가장 최신 문구 하나만 (0.13.1 → 0.14.1이면 0.14.0 문구)
    /// - 그 외: seen < 버전 ≤ current 인 문구를 최신부터 모은다 (0.14 → 0.18로 건너뛰면 0.15~0.18)
    public static func digest(_ notes: [ReleaseNote], current: String, seen: String, maxLines: Int = 4) -> ReleaseDigest? {
        guard let now = AppVersion(current) else { return nil }
        let picked: [(AppVersion, ReleaseNote)]
        if let last = AppVersion(seen) {
            picked = notes.compactMap { n in AppVersion(n.version).map { ($0, n) } }
                .filter { $0.0 > last && $0.0 <= now }
        } else {
            picked = notes.compactMap { n in AppVersion(n.version).map { ($0, n) } }
                .filter { $0.0 <= now }
                .max { $0.0 < $1.0 }
                .map { [$0] } ?? []
        }
        let newest = picked.sorted { $0.0 > $1.0 }
        guard let top = newest.first else { return nil }
        return ReleaseDigest(
            from: newest.count > 1 ? newest.last?.0.description : nil,
            to: top.0.description,
            lines: Array(newest.flatMap { $0.1.lines }.prefix(maxLines)),
            game: top.1.game,
            newGames: newest.reduce(into: Set<String>()) { $0.formUnion($1.1.newGames) }
        )
    }
}
