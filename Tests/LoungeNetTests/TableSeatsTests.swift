import Foundation
import Testing
@testable import LoungeNet

@Suite struct TableSeatsTests {
    let me = UUID(), a = UUID(), b = UUID()

    func member(_ id: UUID, viewing: Bool = true, place: Member.Place = .roulette) -> Member {
        Member(id: id, name: "x", viewing: viewing, place: place)
    }

    @Test func aloneAtTableCountsMe() {
        #expect(TableSeats.count(members: [], me: me, bettors: [UUID]()) == 1)
    }

    @Test func seatedViewerCountsBeforeBet() {
        #expect(TableSeats.count(members: [member(a)], me: me, bettors: [UUID]()) == 2)
    }

    @Test func bettorAndViewerAreNotCountedTwice() {
        #expect(TableSeats.count(members: [member(a)], me: me, bettors: [me, a]) == 2)
    }

    @Test func otherPlacesAndClosedPopoverAreNotSeated() {
        let others = [member(a, place: .lounge), member(b, viewing: false)]
        #expect(TableSeats.count(members: others, me: me, bettors: [UUID]()) == 1)
    }

    @Test func bettorWhoClosedPopoverStillCounts() {
        #expect(TableSeats.count(members: [member(a, viewing: false)], me: me, bettors: [a]) == 2)
    }
}
