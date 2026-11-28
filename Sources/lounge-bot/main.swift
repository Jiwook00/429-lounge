// 개발용 봇: 미니 룰렛 테이블에 앉아서 매 판 랜덤으로 한두 칸에 건다.
// 사용법: swift run lounge-bot [--name 봇이름] [--room LOUNGE] [--blackjack]
// --blackjack: 룰렛 대신 블랙잭 테이블에 앉는다 (판마다 걸고, 간단한 기본 전략으로 친다)
// --plinko: 429 드롭에 공을 계속 떨어뜨린다 (무작위 레인·파워, 잔액 부족이면 쉬었다 다시)
// --wall: 라운지 벽화에 2~5초마다 한 칸씩 칠한다 (버킷이 비면 429를 받고 기다림)
// --poker [--bots N]: 인디언 포커. 자리 있는 테이블에 앉고, 없으면 컴퓨터 N명(기본 2)과 새 테이블.
//                    1초마다 tick, 내 차례면 1~3초 고민하다 상대 카드만 보고 친다. 가끔 생각에 잠겨 시간 초과
import Foundation
import LoungeNet

func arg(_ flag: String, default value: String) -> String {
    guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return value }
    return CommandLine.arguments[i + 1]
}

setvbuf(stdout, nil, _IOLBF, 0) // 파이프로 연결해도 줄 단위로 바로 출력

let name = arg("--name", default: "딜러봇")
let room = arg("--room", default: "LOUNGE")
let client = LoungeClient(profile: "bot-\(name)")
let clock = Date.FormatStyle(date: .omitted, time: .standard)

func log(_ s: String) { print("[\(Date().formatted(clock))] \(s)") }

do {
    let me = try await client.signIn(name: name)
    log("🤖 \(me.name) 착석 · ROOM \(room) · 칩 \(me.chips)")

    // 라운지 접속: 룰렛 테이블을 보는 중, 코딩 중. --blink면 7초마다 보는 중을 껐다 켠다 (Presence 갱신 테스트)
    let blink = CommandLine.arguments.contains("--blink")
    var presence = Member(id: me.id, name: me.name, viewing: true, place: .roulette, status: .coding)
    let link = client.joinLounge(as: presence)
    // --watch면 라운지 회원 목록이 바뀔 때마다 출력 (다른 회원 화면에 내가 어떻게 보이는지 확인용)
    let watch = CommandLine.arguments.contains("--watch")
    Task {
        var lastLine = ""
        for await signal in link.signals {
            guard watch, case .members(let list) = signal else { continue }
            let line = list.filter { $0.id != me.id }.sorted { $0.name < $1.name }
                .map { "\($0.name)\($0.viewing ? "👁" : "")@\($0.place.rawValue)\($0.status.map { "·" + $0.rawValue } ?? "")" }
                .joined(separator: ", ")
            if line != lastLine { log("라운지: [\(line)]"); lastLine = line }
        }
    }
    if blink {
        Task {
            while true {
                try? await Task.sleep(for: .seconds(7))
                presence.viewing.toggle()
                await link.update(presence)
                log("👁 보는 중 \(presence.viewing ? "켬" : "끔")")
            }
        }
    }

    if CommandLine.arguments.contains("--wall") {
        presence.place = .lounge
        await link.update(presence)
        try await paintWall()
    }

    if CommandLine.arguments.contains("--plinko") {
        presence.place = .lounge // 옛 앱이 모르는 위치 값이라 라운지로
        await link.update(presence)
        try await dropPlinko()
    }

    if CommandLine.arguments.contains("--poker") {
        presence.place = .lounge // 옛 앱이 모르는 위치 값이라 라운지로
        await link.update(presence)
        try await playPoker(me: me)
    }

    if CommandLine.arguments.contains("--blackjack") {
        presence.place = .lounge // 옛 앱 호환: 블랙잭도 라운지로 (ADR-0014)
        await link.update(presence)
        try await playBlackjack(me: me)
    }

    try await playRoulette(me: me)
} catch {
    log("💥 \(error)")
    exit(1)
}

/// 429 드롭: 무작위 레인·파워로 공을 계속 던진다. 한 줄에 한 판 (분열·포켓·FEVER 포함)
func dropPlinko() async throws -> Never {
    while true {
        let amount = Int64([10, 50, 50, 100, 200].randomElement()!)
        let lane = Int.random(in: -1...1)
        let power = Int.random(in: 0...1000)
        do {
            let d = try await client.plinkoDrop(amount: amount, lane: lane, power: power)
            let split = d.ball.clone != nil ? " 분열" : ""
            let where_ = d.ball.pocket ? "포켓(\(d.pocket?.reels.joined(separator: " ") ?? ""))" : "칸 \(d.ball.bucket ?? -1) ×\(d.ball.mult)"
            let fever = d.fever ? " FEVER 공 \(d.feverBalls.count)개" : ""
            log("⚪️ \(amount)칩 레인 \(lane) 파워 \(power) \(d.grade.rawValue) → \(where_)\(split)\(fever) · 지급 \(d.payout) · 칩 \(d.player.chips)")
            // 공이 다 내려오는 시간(약 2.4초, FEVER면 +10초)만큼 쉰다: 앱 화면에서 같이 보이게
            try await Task.sleep(for: .seconds(d.fever ? 14 : Double.random(in: 0.6...2.2)))
        } catch {
            log("⚠️ \(error.localizedDescription)")
            try await Task.sleep(for: .seconds(5))
        }
    }
}

/// 블랙잭: 판이 없거나 베팅 중이면 걸고, 내 차례면 잠깐 고민하다 친다
func playBlackjack(me: Player) async throws -> Never {
    var reported: Int64?
    while true {
        let s = try await client.bjTick(room: room)
        let mine = s.seats.first { $0.playerId == me.id }
        let r = s.round
        let idle = r == nil || (r!.phase == .done && (r!.nextAt ?? .distantPast) <= s.now)

        if let r, r.phase == .done, let mine, let net = mine.net, reported != r.id {
            reported = r.id
            let chips = try await client.me()?.chips ?? 0
            let dealer = BJCard.total(r.dealerCards.map(BJCard.init)).value
            log("🃏 #\(r.id) 나 \(BJCard.total(mine.cards.map(BJCard.init)).value) vs 딜러 \(dealer) → \(mine.result?.rawValue ?? "?") \(net >= 0 ? "+" : "")\(net) · 칩 \(chips)")
        }

        if idle || (r?.phase == .betting && mine == nil && s.seats.count < 4) {
            try await Task.sleep(for: .seconds(Double.random(in: 1...2.5)))
            let amount = Int64([10, 30, 50, 100].randomElement()!)
            do {
                let after = try await client.bjBet(room: room, amount: amount)
                log("🪙 #\(after.round?.id ?? -1) \(amount) 걸고 \(after.seats.first { $0.playerId == me.id }?.seat ?? 0)번 자리")
            } catch {
                log("⚠️ \(error.localizedDescription)")
            }
            continue
        }

        if let r, r.phase == .playing, let mine, r.turnSeat == mine.seat, mine.state == .playing,
           s.now >= r.betClosesAt.addingTimeInterval(3) {
            try await Task.sleep(for: .seconds(Double.random(in: 1...3)))
            let mineTotal = BJCard.total(mine.cards.map(BJCard.init))
            let up = BJCard.total(r.dealerCards.map(BJCard.init)).value
            let action: BJSeat.Action
            if mine.cards.count == 2, (10...11).contains(mineTotal.value), up < 10, !mine.golden {
                action = .double
            } else if mineTotal.value >= 17 || (mineTotal.value >= 13 && !mineTotal.soft && up <= 6) {
                action = .stand
            } else {
                action = .hit
            }
            do {
                let after = try await client.bjAction(room: room, action)
                let now = after.seats.first { $0.playerId == me.id }
                log("👉 \(action.rawValue) → \(now.map { "\(BJCard.total($0.cards.map(BJCard.init)).value) \($0.state.rawValue)" } ?? "?")")
            } catch {
                log("⚠️ \(error.localizedDescription)")
            }
            continue
        }
        try await Task.sleep(for: .milliseconds(500))
    }
}

/// 인디언 포커: 앉을 테이블을 찾고, 판마다 상대 카드만 보고 친다. 자리에서 빠지면(잔액·잠수) 로비로 돌아간다
func playPoker(me: Player) async throws -> Never {
    let bots = Int(arg("--bots", default: "2")) ?? 2
    var table: Int64?
    var reported: Int64?
    var acted: String?
    while true {
        guard let t = table else {
            do {
                let lobby = try await client.ipLobby()
                if let mine = lobby.myTable {
                    table = mine
                } else if let open = lobby.tables.first(where: { !$0.full }) {
                    table = try await client.ipJoin(table: open.id).table.id
                    log("🪑 테이블 #\(open.id) 입장 (\(open.humans + 1)/\(open.capacity))")
                } else {
                    table = try await client.ipCreate(bots: bots).table.id
                    log("🪑 테이블 #\(table!) 만듦 · 컴퓨터 \(bots)명")
                }
            } catch {
                log("⚠️ \(error.localizedDescription)")
                try await Task.sleep(for: .seconds(5))
            }
            continue
        }

        let s = try await client.ipTick(table: t)
        if !s.me.member {
            log("🚪 테이블 #\(t)에서 빠짐 (\(s.me.leftReason?.rawValue ?? s.table.status.rawValue))")
            table = nil
            try await Task.sleep(for: .seconds(3))
            continue
        }
        if let h = s.hand, h.phase == .done, reported != h.id, let mine = s.mySeat {
            reported = h.id
            let cards = s.seats.map { "\($0.name)\($0.bot ? "🤖" : "") \($0.card.map(String.init) ?? "?")\($0.folded ? "✕" : "")" }
            log("🂠 #\(h.handNo) 판돈 \(h.pot) · \(cards.joined(separator: ", ")) → 나 \(mine.net.map { $0 >= 0 ? "+\($0)" : "\($0)" } ?? "?") · 칩 \(mine.chips ?? 0)")
        }
        if let h = s.hand, let o = s.myOptions(at: s.now), acted != "\(h.id):\(h.turnNo)" {
            acted = "\(h.id):\(h.turnNo)"
            if Double.random(in: 0..<1) < 0.05 {
                log("💤 생각에 잠김 (11초 시간 초과)")
                continue
            }
            try await Task.sleep(for: .seconds(Double.random(in: 1...3)))
            // 상대 최고 카드가 낮으면 강하게, 높으면 약하게
            let top = s.seats.filter { $0.seat != s.mySeat?.seat && !$0.folded }.compactMap(\.card).max() ?? 5
            let roll = Double.random(in: 0..<1)
            let (action, amount): (IPSeat.Action, Int64?) =
                if top <= 4, o.canRaise, roll < 0.6 { (o.opened ? .raise : .bet, max(o.minRaise, 20)) }
                else if o.canCheck { (.check, nil) }
                else if top <= 7 || roll < 0.2 { (.call, nil) }
                else { (.fold, nil) }
            do {
                let after = try await client.ipAction(table: t, hand: h.id, turn: h.turnNo, action, amount: amount)
                if let why = after.rejected {
                    log("⚠️ \(action.rawValue) 거절: \(why)")
                    continue
                }
                let mine = after.mySeat
                log("👉 \(action.rawValue)\(mine?.lastAmount.map { $0 > 0 ? " \($0)" : "" } ?? "")\(mine?.allIn == true ? " (올인)" : "") · 상대 최고 \(top) · 판돈 \(after.hand?.pot ?? 0)")
            } catch {
                log("⚠️ \(action.rawValue): \(error.localizedDescription)")
            }
            continue
        }
        try await Task.sleep(for: .seconds(1))
    }
}

/// 룰렛: 판이 없거나 베팅 중이면 잠깐 고민하다 한두 칸에 건다. 끝난 판은 한 줄로 알린다
func playRoulette(me: Player) async throws -> Never {
    var placed: Int64?
    var reported: Int64?
    while true {
        let s = try await client.rouletteTick(room: room)
        let r = s.round
        let idle = r == nil || s.now >= r!.nextAt
        let mine = s.bets.filter { $0.playerId == me.id }

        if let r, let n = r.result, !mine.isEmpty, reported != r.id, mine.allSatisfy({ $0.payout != nil }) {
            reported = r.id
            let staked = mine.reduce(0) { $0 + $1.staked }, paid = mine.reduce(0) { $0 + ($1.payout ?? 0) }
            let chips = try await client.me()?.chips ?? 0
            log("🎡 #\(r.id) \(Roulette.describe(n).joined(separator: " · ")) → \(paid - staked >= 0 ? "+" : "")\(paid - staked) · 칩 \(chips)")
        }

        let betting = r.map { s.now < $0.betClosesAt.addingTimeInterval(-1.5) } ?? false
        if idle || (betting && placed != r?.id) {
            try await Task.sleep(for: .seconds(Double.random(in: 1...3)))
            let spots: [Roulette.Spot] = (0..<Int.random(in: 1...2)).map { _ in
                Bool.random() ? Roulette.Spot.outside.randomElement()! : .number(Int.random(in: 1...12))
            }
            for spot in spots {
                let amount = Int64([10, 50, 100].randomElement()!)
                do {
                    let after = try await client.rouletteBet(room: room, spot: spot, amount: amount)
                    placed = after.round?.id
                    log("🪙 #\(after.round?.id ?? -1) \(spot.label)에 \(amount)")
                } catch {
                    log("⚠️ \(error.localizedDescription)")
                    break
                }
            }
            continue
        }
        try await Task.sleep(for: .milliseconds(700))
    }
}


/// 라운지 벽화: 무작위 자리에서 시작해 옆 칸으로 걸어가며 칠한다 (선처럼 보이게)
func paintWall() async throws -> Never {
    var x = Int.random(in: 0..<32), y = Int.random(in: 0..<32)
    let color = Int.random(in: 0..<8)
    while true {
        let s = try await client.pixelPaint(x: x, y: y, color: color)
        switch s.status {
        case .limited:
            let wait = max(1, s.nextAt.map { $0.timeIntervalSince(s.now) } ?? 30)
            log("🎨 429 Too Many Pixels · \(Int(wait))초 대기")
            try await Task.sleep(for: .seconds(wait + 0.2))
            continue
        default:
            log("🎨 \(x + 1),\(y + 1) \(s.status?.rawValue ?? "-") · 남은 \(s.left)/\(s.cap)")
        }
        x = min(31, max(0, x + Int.random(in: -1...1)))
        y = min(31, max(0, y + Int.random(in: -1...1)))
        try await Task.sleep(for: .seconds(Double.random(in: 2...5)))
    }
}
