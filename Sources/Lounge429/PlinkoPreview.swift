import Foundation
import LoungeNet

/// 개발용: 서버 규칙(`plinko_path`)을 그대로 옮긴 가짜 응답 생성기. 스냅샷 장면을 만드는 데만 쓴다.
@MainActor
enum PlinkoFake {
    struct Rules {
        var forceCatch = false
        var fever = false
    }

    /// `plinko_path`: 줄마다 `dirs[r]`(없으면 난수)로 좌우를 정한다
    static func path(j start: Int, row: Int, dirs: [Int], cloneDirs: [Int] = [], rules: Rules, amount: Int64,
                     used: Bool = false, gold startGold: Double = 0, rng: inout SplitMix) -> PlinkoBall {
        var r = row, j = start, js: [Int] = [], gold = startGold, usedSplit = used
        var splitRow: Int?
        var clone: PlinkoBall?
        while true {
            js.append(j)
            if r == 6, j == 0, !rules.fever, rules.forceCatch {
                return PlinkoBall(from: row, js: js, bucket: nil, gold: gold, pocket: true, split: splitRow, clone: clone)
            }
            if r == 8, abs(j) == 4 { gold += 0.3 }
            let d = r < dirs.count ? dirs[r] : (Bool.random(using: &rng) ? 1 : -1)
            if r == 10, abs(j) == 8, !usedSplit, !rules.fever {
                usedSplit = true
                splitRow = r
                clone = path(j: j - d, row: r + 1, dirs: Array(repeating: 0, count: r + 1) + cloneDirs, rules: rules,
                             amount: amount, used: true, gold: gold, rng: &rng)
            }
            if r == 11 {
                var jf = j + d
                if jf > 12 { jf = j - 1 }
                if jf < -12 { jf = j + 1 }
                let bucket = (jf + 12) / 2
                let mult = PlinkoTable.multipliers[bucket] * (rules.fever ? PlinkoTable.feverMult : 1) + gold
                return PlinkoBall(from: row, js: js, bucket: bucket, gold: gold, mult: mult,
                                  payout: Int64((Double(amount) * mult).rounded(.down)), split: splitRow, clone: clone)
            }
            r += 1
            j += d
        }
    }

    static func launch(lane: Int, dirs: [Int], cloneDirs: [Int] = [], rules: Rules = Rules(), amount: Int64,
                       rng: inout SplitMix) -> PlinkoBall {
        lane == 0
            ? path(j: 0, row: 0, dirs: dirs, cloneDirs: cloneDirs, rules: rules, amount: amount, rng: &rng)
            : path(j: lane, row: 1, dirs: dirs, cloneDirs: cloneDirs, rules: rules, amount: amount, rng: &rng)
    }

    /// 조건에 맞는 한 판이 나올 때까지 시드를 바꿔 가며 뽑는다 (장면을 고정하기 위해)
    static func drop(player: Player, lane: Int, amount: Int64 = 100, grade: PlinkoDrop.Grade = .none,
                     forceCatch: Bool = false, reels: [String]? = nil, fever: Bool = false,
                     ceiling: Bool = false, letters: Int = 0, vip: Bool = false,
                     matching: (PlinkoBall) -> Bool = { _ in true }) -> PlinkoDrop {
        var seed: UInt64 = 429
        while true {
            seed += 1
            var rng = SplitMix(seed: seed)
            let dirs = (0..<12).map { _ in Bool.random(using: &rng) ? 1 : -1 }
            let cloneDirs = (0..<12).map { _ in Bool.random(using: &rng) ? 1 : -1 }
            let ball = launch(lane: lane, dirs: dirs, cloneDirs: cloneDirs, rules: Rules(forceCatch: forceCatch),
                              amount: amount, rng: &rng)
            guard matching(ball) else { continue }
            var total = ball.payout + (ball.clone?.payout ?? 0)
            var pocket: PlinkoPocket?
            var feverBalls: [PlinkoBall] = []
            if ball.pocket {
                if fever {
                    for _ in 0..<40 {
                        let l = Int.random(in: -1...1, using: &rng)
                        let fb = launch(lane: l, dirs: [], rules: Rules(fever: true), amount: amount, rng: &rng)
                        feverBalls.append(fb)
                        total += fb.payout
                    }
                    pocket = PlinkoPocket(reels: ["429", "429", "429"], fever: true, refund: 0, ceiling: ceiling)
                } else {
                    let refund = amount / 5
                    total += refund
                    pocket = PlinkoPocket(reels: reels ?? ["429", "429", "7"], fever: false, refund: refund)
                }
            }
            let after = Player(id: player.id, name: player.name, chips: player.chips - amount + total)
            return PlinkoDrop(ball: ball, pocket: pocket, feverBalls: feverBalls, payout: total,
                              topMult: ball.mult, fever: fever && ball.pocket, lane: lane, power: 500, grade: grade,
                              amount: amount, letters: letters, vip: vip, player: after)
        }
    }
}

extension PlinkoTable {
    /// 스냅샷용: 서버 응답을 받은 것처럼 공을 띄운다
    func preview(drop d: PlinkoDrop) { receive(d) }

    /// 스냅샷용: 파워를 모으는 중인 화면
    func previewCharging(power: Int) {
        fixedPower = power
        charging = true
    }
}
