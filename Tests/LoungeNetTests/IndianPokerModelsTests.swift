import Foundation
import Supabase
import Testing
@testable import LoungeNet

/// 로컬 DB에서 뽑은 실제 ip_state / ip_lobby 응답 (lounge-bot 두 개가 앉은 테이블)
@Suite struct IndianPokerModelsTests {
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try AnyJSON.decoder.decode(T.self, from: Data(json.utf8))
    }

    static let betting = #"""
{"me": {"seat": 1, "member": true, "hand_seat": 1, "left_reason": null}, "now": "2026-11-28T07:34:17.187583+00:00", "hand": {"id": 3487, "pot": 30, "phase": "betting", "hand_no": 6, "next_at": null, "min_raise": 10, "turn_seat": 3, "turn_no": 1, "first_seat": 3, "settled_at": null, "started_at": "2026-11-28T07:34:06.319176+00:00", "current_bet": 0, "turn_deadline": "2026-11-28T07:34:12.552421+00:00", "turn_started_at": "2026-11-28T07:34:08.319176+00:00"}, "seats": [{"bet": 0, "bot": false, "net": null, "put": 10, "card": null, "name": "철수", "seat": 1, "chips": 950, "all_in": false, "folded": false, "payout": null, "player_id": "6ac36505-77aa-42b1-a857-3b1a6b6a0c0f", "last_action": null, "last_amount": null}, {"bet": 0, "bot": false, "net": null, "put": 10, "card": 5, "name": "영희", "seat": 2, "chips": 1010, "all_in": false, "folded": false, "payout": null, "player_id": "24f77178-3895-48a4-a5f7-117e3e8b5d0c", "last_action": null, "last_amount": null}, {"bet": 0, "bot": true, "net": null, "put": 10, "card": 8, "name": "캐시봇", "seat": 3, "chips": null, "all_in": false, "folded": false, "payout": null, "player_id": null, "last_action": null, "last_amount": null}], "table": {"id": 206, "status": "open", "capacity": 3, "closed_at": null}, "members": [{"name": "철수", "seat": 1, "player_id": "6ac36505-77aa-42b1-a857-3b1a6b6a0c0f"}, {"name": "영희", "seat": 2, "player_id": "24f77178-3895-48a4-a5f7-117e3e8b5d0c"}]}
"""#

    static let lobby = #"""
{"now": "2026-11-28T07:34:17.411089+00:00", "tables": [{"id": 206, "names": ["철수", "영희"], "humans": 2, "hand_no": 6, "capacity": 3}, {"id": 207, "names": ["민수"], "humans": 1, "hand_no": null, "capacity": 2}], "my_table": null}
"""#

    @Test func bettingState() throws {
        let s = try Self.decode(IPState.self, Self.betting)
        #expect(s.table.id == 206 && s.table.capacity == 3 && s.table.status == .open)
        #expect(s.me.member && s.me.seat == 1 && s.me.handSeat == 1 && s.me.leftReason == nil)
        #expect(s.hand?.phase == .betting && s.hand?.turnSeat == 3 && s.hand?.pot == 30 && s.hand?.minRaise == 10)
        #expect(s.mySeat?.name == "철수" && s.mySeat?.card == nil)
        #expect(s.seats.filter { $0.seat != 1 }.allSatisfy { $0.card != nil })
        #expect(s.turn?.bot == true && s.turn?.chips == nil)
        #expect(!s.isMyTurn(at: s.now) && s.myOptions(at: s.now) == nil && s.rejected == nil)
        #expect(s.hand?.turnNo == 1)
        #expect(s.members.map(\.name) == ["철수", "영희"])
    }

    @Test func lobbyCountsHumansOnly() throws {
        let l = try Self.decode(IPLobby.self, Self.lobby)
        #expect(l.myTable == nil && l.tables.count == 2)
        #expect(l.tables[0].humans == 2 && l.tables[0].capacity == 3 && !l.tables[0].full)
        #expect(l.tables[1].handNo == nil)
    }

    func options(toCall: Int64, minRaise: Int64 = 10, stack: Int64, opened: Bool = true) -> IPOptions {
        IPOptions(toCall: toCall, minRaise: minRaise, stack: stack, opened: opened)
    }

    @Test func checkOnlyWhenNobodyBet() {
        #expect(options(toCall: 0, stack: 100, opened: false).canCheck)
        #expect(!options(toCall: 20, stack: 100).canCheck)
        #expect(options(toCall: 20, stack: 100).canCall)
    }

    @Test func shortStackGoesAllIn() {
        // 콜 40에 잔액 30 = 올인 콜, 위로 올릴 수 없음
        let short = options(toCall: 40, stack: 30)
        #expect(short.callIsAllIn && !short.canRaise && short.allInAmount == 0)
        // 콜 40 + 최소 폭 40에 잔액 70 = 올리면 올인뿐 (위로 30)
        let tight = options(toCall: 40, minRaise: 40, stack: 70)
        #expect(!tight.callIsAllIn && tight.canRaise && tight.raiseIsAllInOnly && tight.allInAmount == 30)
        let deep = options(toCall: 40, minRaise: 40, stack: 1000)
        #expect(!deep.raiseIsAllInOnly && deep.allInAmount == 960)
    }

    static func date(_ iso: String) -> Date { try! Date(iso, strategy: .iso8601) }

    @Test func myTurnOptionsFromState() throws {
        var json = Self.betting.replacingOccurrences(of: "\"turn_seat\": 3", with: "\"turn_seat\": 1")
        json = json.replacingOccurrences(of: "\"current_bet\": 0", with: "\"current_bet\": 20")
        let s = try Self.decode(IPState.self, json)
        let during = Self.date("2026-11-28T07:34:10Z")
        #expect(s.isMyTurn(at: during))
        #expect(s.myOptions(at: during) == IPOptions(toCall: 20, minRaise: 10, stack: 950, opened: true))
    }

    /// 딜 연출(차례 시작 전)과 마감 뒤엔 버튼을 끈다
    @Test func myTurnRespectsDealAndDeadline() throws {
        let json = Self.betting.replacingOccurrences(of: "\"turn_seat\": 3", with: "\"turn_seat\": 1")
        let s = try Self.decode(IPState.self, json)
        #expect(!s.isMyTurn(at: Self.date("2026-11-28T07:34:07Z"))) // 시작 07:34:08.3 전 (딜 연출)
        #expect(s.isMyTurn(at: Self.date("2026-11-28T07:34:09Z")))
        #expect(!s.isMyTurn(at: Self.date("2026-11-28T07:34:13Z"))) // 마감 07:34:12.5 뒤
    }

    @Test func rejectedActionStillCarriesState() throws {
        let json = Self.betting.replacingOccurrences(of: "\"members\":", with: "\"rejected\": \"stale_turn\", \"members\":")
        let s = try Self.decode(IPState.self, json)
        #expect(s.rejected == "stale_turn" && s.hand?.id == 3487)
        #expect(s.rejectedError?.errorDescription == "이미 지나간 차례예요")
    }
}

@Suite struct IndianPokerDisplayTests {
    let now = Date(timeIntervalSince1970: 1_000)

    func state(_ seats: [IPSeat], phase: IPHand.Phase = .betting) -> IPState {
        IPState(now: now, table: IPTable(id: 1, capacity: seats.count), me: IPMe(member: true, seat: 1, handSeat: 1),
                hand: IPHand(id: 1, handNo: 1, phase: phase, firstSeat: 1, startedAt: now),
                seats: seats)
    }

    func seat(_ n: Int, put: Int64, folded: Bool = false, allIn: Bool = false, card: Int? = nil) -> IPSeat {
        IPSeat(seat: n, playerId: UUID(), name: "\(n)", put: put, folded: folded, allIn: allIn, card: card)
    }

    @Test func noSidePotWithoutShortAllIn() {
        #expect(state([seat(1, put: 40), seat(2, put: 40)]).pots == nil)
        // 올인했지만 다른 사람이 더 안 냈으면 한 줄
        #expect(state([seat(1, put: 40, allIn: true), seat(2, put: 40)]).pots == nil)
    }

    @Test func splitsAtLowestAllIn() {
        // 시안 S05: 철수 올인 40, 민지 120, 나 40(콜 전), 도윤 폴드 10
        let s = state([seat(1, put: 40, allIn: true), seat(2, put: 120), seat(3, put: 40), seat(4, put: 10, folded: true)])
        guard let p = s.pots else { Issue.record("no pots"); return }
        #expect(p.main == 40 + 40 + 40 + 10 && p.side == 80)
        #expect(p.mainSeats == [1, 2, 3] && p.sideSeats == [2, 3] && p.cappedSeats == [1])
    }

    @Test func winnersIgnoreFolded() {
        let s = state([seat(1, put: 40, card: 8), seat(2, put: 40, card: 3), seat(3, put: 10, folded: true, card: 9)], phase: .done)
        #expect(s.winners == [1])
        let tie = state([seat(1, put: 20, card: 6), seat(2, put: 20, card: 6)], phase: .done)
        #expect(tie.winners == [1, 2])
        #expect(state([seat(1, put: 20, card: 6)]).winners.isEmpty)
    }
}
