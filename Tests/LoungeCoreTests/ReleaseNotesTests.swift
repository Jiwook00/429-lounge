import LoungeCore
import Testing

@Suite struct ReleaseNotesTests {
    static let notes = [
        ReleaseNote(version: "0.14.0", lines: ["드롭 1", "드롭 2", "드롭 3"], game: "plinko", newGames: ["plinko"]),
        ReleaseNote(version: "0.15.0", lines: ["블랙잭 1"], game: "blackjack", newGames: []),
        ReleaseNote(version: "0.16.0", lines: ["랭킹 1", "랭킹 2"], game: nil, newGames: ["wall"]),
    ]

    @Test func firstInstallShowsOnlyCurrent() {
        let d = ReleaseNotes.digest(Self.notes, current: "0.16.0", seen: "")
        #expect(d?.from == nil && d?.to == "0.16.0" && d?.lines == ["랭킹 1", "랭킹 2"])
    }

    @Test func oneStepShowsThatVersion() {
        let d = ReleaseNotes.digest(Self.notes, current: "0.15.0", seen: "0.14.0")
        #expect(d?.from == nil && d?.to == "0.15.0" && d?.game == "blackjack")
    }

    @Test func skippedVersionsAreMergedNewestFirstAndCapped() {
        let d = ReleaseNotes.digest(Self.notes, current: "0.16.0", seen: "0.13.1")
        #expect(d?.from == "0.14.0" && d?.to == "0.16.0")
        #expect(d?.lines == ["랭킹 1", "랭킹 2", "블랙잭 1", "드롭 1"])
        // 해보기는 최신 버전의 게임 (0.16은 없음 → nil), NEW는 모은 버전 전부
        #expect(d?.game == nil && d?.newGames == ["plinko", "wall"])
    }

    @Test func patchWithoutNoteStillShowsSkippedOne() {
        let d = ReleaseNotes.digest(Self.notes, current: "0.15.2", seen: "0.14.0")
        #expect(d?.to == "0.15.0" && d?.lines == ["블랙잭 1"])
    }

    @Test func nothingWhenSeenOrDev() {
        #expect(ReleaseNotes.digest(Self.notes, current: "0.16.0", seen: "0.16.0") == nil)
        #expect(ReleaseNotes.digest(Self.notes, current: "dev", seen: "") == nil)
        #expect(ReleaseNotes.digest(Self.notes, current: "0.13.1", seen: "") == nil)
    }
}
