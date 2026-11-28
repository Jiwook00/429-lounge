import Testing
@testable import LoungeCore

@Suite struct BetStakeTests {
    @Test func defaultIsPreserved() {
        let s = BetStake()
        #expect(s.amount == 30 && !s.touched)
    }

    @Test func firstTapSelectsLikeBefore() {
        for unit in BetStake.units {
            var s = BetStake()
            s.tap(unit)
            #expect(s.amount == unit)
        }
    }

    @Test func repeatedTapsAddUpToCap() {
        var s = BetStake()
        s.tap(100)
        s.tap(100)
        #expect(s.amount == 200)
        s.tap(10)
        #expect(s.amount == 200) // 상한을 넘기면 더하지 않는다
        var t = BetStake()
        t.tap(50); t.tap(50); t.tap(50); t.tap(30)
        #expect(t.amount == 180)
        t.tap(30)
        #expect(t.amount == 180)
        t.tap(10)
        #expect(t.amount == 190)
    }

    @Test func resetReturnsToDefault() {
        var s = BetStake()
        s.tap(100); s.tap(50)
        s.reset()
        #expect(s.amount == 30 && !s.touched)
    }

    @Test func canAddRespectsCapAndBalance() {
        var s = BetStake()
        #expect(s.canAdd(100, chips: 100)) // 첫 탭은 교체라 단위만 본다
        #expect(!s.canAdd(100, chips: 99))
        s.tap(100)
        #expect(s.canAdd(100, chips: 1000))
        #expect(!s.canAdd(100, chips: 150)) // 잔액 부족
        s.tap(100)
        #expect(!s.canAdd(10, chips: 1000)) // 상한
    }

    @Test func doubleNeedsBalance() {
        var s = BetStake()
        s.tap(100); s.tap(100)
        #expect(s.canDouble(chips: 400))
        #expect(!s.canDouble(chips: 399))
    }
}
