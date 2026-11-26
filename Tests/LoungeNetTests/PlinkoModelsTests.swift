import Foundation
import Supabase
import Testing
@testable import LoungeNet

/// 로컬 DB(`plinko_resolve`)에서 뽑은 실제 응답에 `plinko_drop`이 붙이는 필드를 더한 것
@Suite struct PlinkoModelsTests {
    static func decode(_ json: String) throws -> PlinkoDrop {
        try AnyJSON.decoder.decode(PlinkoDrop.self, from: Data(json.utf8))
    }

    static let split = #"""
{"ball":{"js":[1,2,3,4,5,6,7,8,7,8,9],"from":1,"gold":0,"mult":4,"clone":{"js":[7],"from":11,"gold":0,"mult":1.3,"clone":null,"split":null,"bucket":9,"payout":65,"pocket":false},"split":10,"bucket":11,"payout":200,"pocket":false},"fever":false,"payout":265,"pocket":null,"top_mult":4,"fever_balls":[],"lane":-1,"power":833,"grade":"perfect","amount":50,"golden":false,"player":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"철수","chips":4290,"golden_chips":1,"golden_until":"2026-11-27T03:00:00+00:00","named":true,"last_daily":"2026-11-26"}}
"""#

    static let pocket = #"""
{"ball":{"js":[-1,-2,-1,0,-1,0],"from":1,"gold":0,"mult":0,"clone":null,"split":null,"bucket":null,"payout":0,"pocket":true},"fever":false,"payout":10,"pocket":{"fever":false,"reels":["429","429","404"],"refund":10},"top_mult":0,"fever_balls":[],"lane":1,"power":833,"grade":"perfect","amount":50,"golden":false,"player":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"철수","chips":4290,"golden_chips":1,"golden_until":"2026-11-27T03:00:00+00:00","named":true,"last_daily":"2026-11-26"}}
"""#

    static let fever = #"""
{"ball":{"js":[0,-1,0,-1,-2,-1,0],"from":0,"gold":0,"mult":0,"clone":null,"split":null,"bucket":null,"payout":0,"pocket":true},"fever":true,"payout":1195,"pocket":{"fever":true,"reels":["429","429","429"],"refund":0},"top_mult":2.6,"fever_balls":[{"js":[0,1,0,1,0,-1,-2,-1,-2,-1,-2,-3],"from":0,"gold":0,"mult":1.2,"clone":null,"split":null,"bucket":5,"payout":60,"pocket":false},{"js":[0,1,0,1,2,1,0,-1,-2,-3,-4,-5],"from":0,"gold":0,"mult":2.6,"clone":null,"split":null,"bucket":3,"payout":130,"pocket":false},{"js":[1,2,3,2,3,4,5,4,3,2,1],"from":1,"gold":0.3,"mult":1.1,"clone":null,"split":null,"bucket":6,"payout":55,"pocket":false},{"js":[1,0,1,2,3,4,5,4,5,4,3],"from":1,"gold":0.3,"mult":1.5,"clone":null,"split":null,"bucket":7,"payout":75,"pocket":false},{"js":[1,0,1,2,1,0,-1,0,1,0,1],"from":1,"gold":0,"mult":1.2,"clone":null,"split":null,"bucket":7,"payout":60,"pocket":false},{"js":[0,-1,0,-1,-2,-3,-2,-1,0,-1,0,1],"from":0,"gold":0,"mult":1.2,"clone":null,"split":null,"bucket":7,"payout":60,"pocket":false},{"js":[1,2,3,4,3,4,5,6,5,4,3],"from":1,"gold":0,"mult":2.0,"clone":null,"split":null,"bucket":8,"payout":100,"pocket":false},{"js":[-1,-2,-1,0,-1,-2,-3,-4,-5,-4,-5],"from":1,"gold":0.3,"mult":2.3,"clone":null,"split":null,"bucket":4,"payout":115,"pocket":false},{"js":[-1,0,-1,-2,-1,-2,-3,-4,-3,-2,-3],"from":1,"gold":0.3,"mult":1.5,"clone":null,"split":null,"bucket":5,"payout":75,"pocket":false},{"js":[1,0,1,2,1,0,1,2,3,4,5],"from":1,"gold":0,"mult":2.0,"clone":null,"split":null,"bucket":8,"payout":100,"pocket":false},{"js":[0,1,2,1,0,1,0,-1,0,-1,0,-1],"from":0,"gold":0,"mult":0.8,"clone":null,"split":null,"bucket":6,"payout":40,"pocket":false},{"js":[-1,-2,-3,-4,-5,-4,-5,-4,-3,-2,-1],"from":1,"gold":0.3,"mult":1.1,"clone":null,"split":null,"bucket":6,"payout":55,"pocket":false},{"js":[-1,-2,-1,0,-1,-2,-3,-2,-1,-2,-1],"from":1,"gold":0,"mult":0.8,"clone":null,"split":null,"bucket":6,"payout":40,"pocket":false},{"js":[0,-1,-2,-1,0,1,2,3,4,5,4,5],"from":0,"gold":0.3,"mult":2.3,"clone":null,"split":null,"bucket":8,"payout":115,"pocket":false},{"js":[1,0,1,2,1,2,3,4,3,4,3],"from":1,"gold":0.3,"mult":2.3,"clone":null,"split":null,"bucket":8,"payout":115,"pocket":false}],"lane":0,"power":833,"grade":"perfect","amount":50,"golden":false,"player":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"철수","chips":4290,"golden_chips":1,"golden_until":"2026-11-27T03:00:00+00:00","named":true,"last_daily":"2026-11-26"}}
"""#

    @Test func split() throws {
        let d = try Self.decode(Self.split)
        #expect(d.lane == -1 && d.grade == .perfect && d.amount == 50)
        #expect(d.ball.split == 10 && d.ball.from == 1 && d.ball.bucket == 11)
        #expect(d.ball.clone?.from == 11 && d.ball.clone?.bucket == 9 && d.ball.clone?.clone == nil)
        #expect(d.pocket == nil && d.feverBalls.isEmpty)
        #expect(d.payout == d.ball.payout + (d.ball.clone?.payout ?? 0))
        #expect(d.player.chips == 4290)
    }

    @Test func pocket() throws {
        let d = try Self.decode(Self.pocket)
        #expect(d.ball.pocket && d.ball.bucket == nil)
        #expect(d.pocket?.refund == 10 && d.pocket?.fever == false)
        #expect(d.pocket?.reach == true)
        #expect(d.payout == 10)
    }

    @Test func fever() throws {
        let d = try Self.decode(Self.fever)
        #expect(d.fever && d.pocket?.fever == true)
        #expect(d.pocket?.reels == ["429", "429", "429"])
        #expect(d.feverBalls.count == 15)
        #expect(d.feverBalls.allSatisfy { $0.clone == nil && $0.bucket != nil })
        #expect(d.payout == d.feverBalls.reduce(0) { $0 + $1.payout })
    }

    @Test func roundTrip() throws {
        let d = try Self.decode(Self.split)
        let again = try JSONDecoder().decode(PlinkoDrop.self, from: JSONEncoder().encode(d))
        #expect(again.ball == d.ball)
    }

    @Test func gauge() {
        // 서버 plinko_grade와 같은 칸 경계
        #expect(PlinkoGauge.cell(power: 0) == 0 && PlinkoGauge.cell(power: 1000) == 23)
        #expect(PlinkoGauge.grade(power: 833) == .good)     // 19칸
        #expect(PlinkoGauge.grade(power: 834) == .perfect)  // 20칸
        #expect(PlinkoGauge.grade(power: 874) == .perfect)
        #expect(PlinkoGauge.grade(power: 875) == .good)     // 21칸
        #expect(PlinkoGauge.grade(power: 791) == .good)     // 18칸
        #expect(PlinkoGauge.grade(power: 100) == .none)
        #expect(PlinkoGauge.grade(power: 1000) == .none)
        // 왕복 파형
        #expect(PlinkoGauge.power(held: 0) == 0)
        #expect(PlinkoGauge.power(held: 0.54) == 500)
        #expect(PlinkoGauge.power(held: 1.08) == 1000)
        #expect(PlinkoGauge.power(held: 1.62) == 500)
        #expect(PlinkoGauge.power(held: 2.16) == 0)
    }
}
