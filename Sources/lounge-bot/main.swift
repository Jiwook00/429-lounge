// 개발용 봇: 홀짝 테이블에 앉아서 매 판 랜덤 베팅한다.
// 사용법: swift run lounge-bot [--name 봇이름] [--room LOUNGE]
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

    // 라운지 접속: 홀짝 테이블을 보는 중, 코딩 중. --blink면 7초마다 보는 중을 껐다 켠다 (Presence 갱신 테스트)
    let blink = CommandLine.arguments.contains("--blink")
    var presence = Member(id: me.id, name: me.name, viewing: true, place: .oddeven, status: .coding)
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

    var current: Int64?
    var placed = false
    while true {
        let round = try await client.tick(room: room)
        if round.id != current {
            if current != nil, let last = try await client.lastSettled(room: room), let m = last.marbles {
                let mine = try await client.bets(roundID: last.id).first { $0.playerId == me.id }
                let chips = try await client.me()?.chips ?? 0
                let outcome = mine.map { ($0.payout ?? 0) > 0 ? "승 +\($0.payout!)" : "패 -\($0.amount)" } ?? "안 걸었음"
                log("🎱 #\(last.id) 구슬 \(m)개 → \(last.result!.label) · \(outcome) · 칩 \(chips)")
            }
            current = round.id
            placed = false
        }

        let now = Date()
        if !placed, now >= round.opensAt, round.closesAt.timeIntervalSince(now) > 2 {
            // 사람처럼 잠깐 고민하다 건다
            try await Task.sleep(for: .seconds(Double.random(in: 1...min(6, round.closesAt.timeIntervalSince(now) - 1.5))))
            let side = Side.allCases.randomElement()!
            let amount = Int64([10, 20, 50, 100].randomElement()!)
            do {
                _ = try await client.bet(room: room, side: side, amount: amount)
                log("🪙 #\(round.id) \(side.label)에 \(amount)")
            } catch {
                log("⚠️ \(error.localizedDescription)")
            }
            placed = true
            continue
        }

        // 다음 깨어날 시각: 오픈 전이면 오픈 시각, 진행 중이면 마감 직후 (최대 5초마다 재동기화)
        let target = now < round.opensAt ? round.opensAt : round.closesAt.addingTimeInterval(0.2)
        try await Task.sleep(for: .seconds(min(5, max(0.3, target.timeIntervalSinceNow))))
    }
} catch {
    log("💥 \(error)")
    exit(1)
}
