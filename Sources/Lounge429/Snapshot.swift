import AppKit
import LoungeCore
import LoungeNet
import SwiftUI

/// 개발용: 실제 창에 띄운 429 드롭 (지갑 값이 바뀌면 다시 그린다)
private struct PlinkoLiveHost: View {
    let table: PlinkoTable
    let store: LoungeStore
    var body: some View {
        PlinkoView(table: table, chips: store.chips, golden: store.golden(),
                   vip: (store.me?.goldenUntil ?? .distantPast) > .now)
    }
}

@MainActor private var plinkoWindow: NSWindow?

/// 개발용: 화면을 PNG로 렌더링 (2x). 테이블 화면은 가짜 데이터로.
@MainActor
enum Snapshot {
    /// lobby-whatsnew-skip용 가짜 문구 (실제 버전에 없는 내용)
    static let fakeNotes = WhatsNew.notes + [
        ReleaseNote(version: "0.15.0", lines: ["블랙잭: 칩을 누를 때마다 더 걸려요 (최대 1,000)"],
                    game: WhatsNew.Game.blackjack.rawValue, newGames: []),
        ReleaseNote(version: "0.16.0", lines: ["게임마다 이번 주 최고 한 방이 떠요"]),
        ReleaseNote(version: "0.17.0", lines: ["벽화에 새 색 두 개"], game: WhatsNew.Game.wall.rawValue),
    ]

    static func render(to path: String, locked: Bool, table: String?) {
        var usage = UsageScanner().scan()
        if locked {
            usage.lastLimitHit = RateLimitHit(
                hitAt: .now, resetsAt: .now.addingTimeInterval(2 * 3600 + 13 * 60), type: "five_hour")
        }
        let me = Player(id: UUID(), name: "guest", chips: 1_250,
                        goldenChips: locked ? 3 : 0, goldenUntil: usage.lastLimitHit?.resetsAt)
        let store = LoungeStore(live: false)
        store.preview(me: me, snapshot: usage, toast: locked ? "429! 황금 칩 +3" : "토큰 환전 +12칩")

        let content: AnyView
        if let table, ["ticket-ready", "ticket-result", "ticket-429"].contains(table) {
            let amount = table == "ticket-ready" ? nil : table == "ticket-429" ? 429 : 50
            content = AnyView(LuckyDrawView(chips: 120 + (amount ?? 0), number: 1, amount: amount))
        } else if table == "settings" {
            content = AnyView(LoungeView(snapshot: usage, lastScan: .now, chips: store.chips,
                                         online: true, name: "새벽코더", showSettings: true))
        } else if table == "readme" {
            // README 대표 이미지: 라운지 · 룰렛 · 슬롯을 나란히 (--locked와 같이 쓰면 VIP HOUR)
            content = AnyView(HStack(alignment: .top, spacing: 20) {
                LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, golden: store.golden(),
                           toast: store.toast, online: true, name: "새벽코더")
                RouletteView(table: fakeRoulette(store: store, me: me, mode: "roulette-win"), chips: store.chips,
                             golden: store.golden())
                SlotView(machine: fakeSlot(store: store, me: me, mode: "slot-jackpot"), chips: store.chips,
                         golden: store.golden(), vip: locked)
            }
            .padding(24)
            .background(Theme.outline))
        } else if let table, table.hasPrefix("nickname") {
            // nickname: 처음 온 회원 / nickname-taken: 이름 바꾸다 중복
            let taken = table == "nickname-taken"
            content = AnyView(LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, online: true,
                                         name: taken ? "새벽코더" : nil,
                                         nicknameDraft: taken ? ("danny", "누가 벌써 쓰는 이름이에요") : nil))
        } else if let table, table.hasPrefix("update") {
            // update: 카드 펼침 / update-notice: 네온 안내 / update-required: 최소 버전 미달
            // update-sparkle: 앱에서 바로 설치할 수 있는 카드
            let required = table == "update-required"
            let cur = AppVersion(AppInfo.version) ?? AppVersion("0.3.0")!
            let next = AppVersion("\(cur.parts[0]).\(cur.parts[1] + 1).0")!
            content = AnyView(LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, golden: store.golden(),
                                         online: true, name: "새벽코더", appUpdate: AppUpdate.check(current: cur, latest: next, minimum: required ? next : nil),
                                         onInstallUpdate: table == "update-sparkle" ? {} : nil,
                                         showUpdate: table == "update" || table == "update-sparkle"))
        } else if let table, table.hasPrefix("lobby-") {
            // lobby-busy | lobby-quiet | lobby-ticker: 접속 현황 (가짜 회원)
            // lobby-board | lobby-board-me | lobby-board-empty: 카드 뒷면 큰손 / lobby-flip: 뒤집는 중(반쯤)
            // lobby-daily: 지갑의 오늘의 칩 버튼
            let crowd = fakeCrowd(me: me, mode: table)
            let back = table.hasPrefix("lobby-board")
            let daily = table == "lobby-daily"
            let whatsNew = table.hasPrefix("lobby-whatsnew") || table == "lobby-new"
            content = AnyView(LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, golden: store.golden(),
                                         online: true, crowd: crowd, board: fakeBoard(table),
                                         lastWeekRank: table.hasPrefix("lobby-board-10") || daily ? 3 : nil,
                                         dailyChipsAvailableAt: daily ? store.dailyChipsAvailableAt : nil,
                                         cardFace: back ? .back : .front, cardFrame: table == "lobby-flip" ? 1 : 0,
                                         name: "새벽코더", blackjackSeated: table == "lobby-busy" ? 2 : 0,
                                         pokerLine: table == "lobby-busy" ? "TABLE · 3명 앉음" : "TABLE · 비어 있음",
                                         pokerHot: table == "lobby-busy",
                                         // lobby-whatsnew: 업데이트 뒤 "새로 들어온 것" 카드 (0.14.1 → 0.15.0)
                                         // lobby-whatsnew-skip: 여러 버전을 건너뛰고 받았을 때 (가짜 0.15~0.17 문구, 0.14.0 → 0.17.0)
                                         // lobby-new: 카드를 닫은 뒤 NEW 라벨
                                         whatsNewVersion: table == "lobby-whatsnew-skip" ? "0.17.0" : whatsNew ? "0.15.0" : AppInfo.version,
                                         whatsNewNotes: table == "lobby-whatsnew-skip" ? Self.fakeNotes : WhatsNew.notes,
                                         whatsNewSeenOverride: table == "lobby-whatsnew-skip" ? "0.14.0" : whatsNew ? "0.14.1" : nil,
                                         newGamesOverride: table == "lobby-new" ? [WhatsNew.Game.plinko.rawValue] : whatsNew ? [] : nil,
                                         hideWhatsNew: table == "lobby-new"))
        } else if let table, table.hasPrefix("wall-") {
            // wall-idle | wall-painted | wall-same | wall-limited | wall-empty: 라운지 벽화 (ADR-0017)
            content = AnyView(PixelWallView(wall: fakeWall(store: store, mode: table)))
        } else if let table, table.hasPrefix("bj-") {
            // bj-idle | bj-betting | bj-full | bj-dealing | bj-deal | bj-myturn | bj-turn | bj-dealer | bj-result
            // bj-help: 설명 카드 (뒤는 내 차례 판)
            content = AnyView(BlackjackView(table: fakeBlackjack(store: store, me: me, mode: table == "bj-help" ? "bj-myturn" : table),
                                            chips: store.chips, golden: store.golden(), showHelp: table == "bj-help"))
        } else if let table, table.hasPrefix("ip-") {
            // ip-lobby | -lobby-broke | -lobby-empty | -lobby-left | -wait | -deal | -myturn | -raise | -allin | -result
            // | -check | -3p | -timeout: 인디언 포커 (시안 S01~S10) / -side (사이드 팟을 받은 결과) | -last (마지막 행동 알림) | -leaving
            // | -create | -create-2 (새 테이블 최대 인원 4 / 2, 시안 S11 · S12) | -wait-join (사람 합류, 시안 S13)
            let broke = table == "ip-lobby-broke"
            content = AnyView(IndianPokerView(table: fakePoker(store: store, me: me, mode: table), chips: broke ? 6 : 1_240))
        } else if let table, table.hasPrefix("roulette-") {
            // roulette-idle | -betting | -golden | -alone | -spin | -cut-near | -cut-edge | -cut-land | -closed | -win | -void | -help
            content = AnyView(RouletteView(table: fakeRoulette(store: store, me: me, mode: table == "roulette-help" ? "roulette-betting" : table),
                                           chips: store.chips, golden: table == "roulette-golden" ? 3 : store.golden(),
                                           showHelp: table == "roulette-help"))
        } else if let table, table.hasPrefix("plinko") {
            // plinko-idle | -charging | -flying | -win | -big | -max | -pocket | -letters | -hot | -fever | -fever-end | -vip
            let vip = locked || table == "plinko-vip"
            let plinko = fakePlinko(store: store, me: me, mode: table)
            plinko.vip = vip
            content = AnyView(PlinkoView(table: plinko, chips: store.chips, golden: vip ? 3 : store.golden(), vip: vip))
        } else if let table, table.hasPrefix("slot") {
            content = AnyView(SlotView(machine: fakeSlot(store: store, me: me, mode: table), chips: store.chips,
                                       golden: store.golden(), vip: locked))
        } else {
            content = AnyView(VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(nsImage: Sprites.menuBarIcon(vip: locked))
                    Image(nsImage: Sprites.menuBarIcon(vip: locked, busy: true))
                    Text("메뉴바 아이콘").font(Fonts.small()).foregroundStyle(.white)
                }
                .padding(6)
                .background(Color(white: 0.75))
                LoungeView(snapshot: usage, lastScan: .now, chips: store.chips, golden: store.golden(),
                           toast: store.toast, online: true, name: "새벽코더")
            })
        }

        let framed = table == "readme" ? content : AnyView(content.padding(8).background(Color(white: 0.3)))
        let renderer = ImageRenderer(content: framed.environment(\.snapshotting, true))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    /// 블랙잭 가짜 판: 시안과 같은 판 (린트봇 블랙잭, 나는 11에서 더블, 영희 버스트, 딜러 18)
    static func fakeBlackjack(store: LoungeStore, me: Player, mode: String) -> BlackjackTable {
        let table = BlackjackTable(store: store)
        let now = Date()
        let yhID = UUID()
        // 카드: 무늬 × 13 + 숫자 (0 스페이드, 1 하트, 2 다이아, 3 클럽 / 0 = A, 9 = 10, 12 = K)
        let ah = 13, kc = 51, td = 35, s8 = 7, h6 = 18, c5 = 43, tc = 48, d6 = 31, s9 = 8, ks = 12, c7 = 45, d2 = 27, qd = 37
        func seat(_ n: Int, _ name: String, id: UUID?, amount: Int64 = 0, cards: [Int], state: BJSeat.State,
                  action: BJSeat.Action? = nil, doubled: Bool = false, result: BJSeat.Result? = nil, payout: Int64? = nil) -> BJSeat {
            BJSeat(seat: n, playerId: id, name: name, amount: amount, doubled: doubled, cards: cards, state: state,
                   lastAction: action, result: result, payout: payout)
        }
        let lint = seat(1, "린트봇", id: nil, cards: [ah, kc], state: .blackjack)
        let build = seat(2, "빌드봇", id: nil, cards: [td, s8], state: .stood, action: .stand)
        func mine(_ cards: [Int], _ state: BJSeat.State, doubled: Bool = false, result: BJSeat.Result? = nil, payout: Int64? = nil) -> BJSeat {
            seat(3, "새벽코더", id: me.id, amount: 100, cards: cards, state: state, action: doubled ? .double : nil,
                 doubled: doubled, result: result, payout: payout)
        }
        func yh(_ cards: [Int], _ state: BJSeat.State, action: BJSeat.Action? = nil, result: BJSeat.Result? = nil, payout: Int64? = nil) -> BJSeat {
            seat(4, "영희", id: yhID, amount: 50, cards: cards, state: state, action: action, result: result, payout: payout)
        }
        func round(_ phase: BJRound.Phase, closed: TimeInterval, turn: Int? = nil, deadline: TimeInterval? = nil,
                   dealer: [Int], next: TimeInterval? = nil) -> BJRound {
            BJRound(id: 1, phase: phase, betClosesAt: now.addingTimeInterval(closed), turnSeat: turn,
                    turnDeadline: deadline.map { now.addingTimeInterval($0) }, dealerCards: dealer,
                    nextAt: next.map { now.addingTimeInterval($0) })
        }
        let at = { (s: TimeInterval) in now.addingTimeInterval(s) }
        switch mode {
        case "bj-idle":
            table.apply(BJState(now: now, round: nil, seats: []))
        case "bj-betting":
            table.apply(BJState(now: now, round: round(.betting, closed: 7, dealer: []),
                                seats: [seat(1, "영희", id: yhID, amount: 50, cards: [], state: .waiting)]))
        case "bj-raise", "bj-raise-max":
            // 칩을 반복해 눌러 판돈을 늘린 베팅창 (130 / 상한 200)
            table.apply(BJState(now: now, round: round(.betting, closed: 7, dealer: []),
                                seats: [seat(1, "영희", id: yhID, amount: 50, cards: [], state: .waiting)]))
            if mode == "bj-raise" { [50, 50, 30].forEach { table.betStake.tap($0) } } else { [100, 100].forEach { table.betStake.tap($0) } }
        case "bj-full":
            let names = ["영희", "철수", "민수", "지호"]
            table.apply(BJState(now: now, round: round(.betting, closed: 5, dealer: []),
                                seats: names.enumerated().map { seat($0 + 1, $1, id: UUID(), amount: 50, cards: [], state: .waiting) }))
        case "bj-dealing":
            // 딜 1.3초째: 둘째 장이 날아가는 중
            table.apply(BJState(now: now, round: round(.playing, closed: -1.55, dealer: [s9]),
                                seats: [lint, seat(2, "빌드봇", id: nil, cards: [td, s8], state: .playing),
                                        mine([h6, c5], .playing), yh([tc, d6], .playing)]))
        case "bj-deal":
            table.apply(BJState(now: now, round: round(.playing, closed: -3.1, deadline: 0, dealer: [s9]),
                                seats: [lint, seat(2, "빌드봇", id: nil, cards: [td, s8], state: .playing),
                                        mine([h6, c5], .playing), yh([tc, d6], .playing)]))
        case "bj-myturn":
            table.apply(BJState(now: now, round: round(.playing, closed: -20, turn: 3, deadline: 7, dealer: [s9]),
                                seats: [lint, build, mine([h6, c5], .playing), yh([tc, d6], .playing)]))
            table.preview(actions: [2: .init(action: .stand, cards: 2, at: at(-1))], myTurnSince: at(-1))
        case "bj-turn":
            // 영희가 히트: 카드가 날아가는 중 (서버는 이미 버스트지만 화면은 도착해야 안다)
            table.apply(BJState(now: now, round: round(.playing, closed: -40, turn: 4, deadline: 0.6, dealer: [s9]),
                                seats: [lint, build, mine([h6, c5, ks], .stood, doubled: true), yh([tc, d6, qd], .bust, action: .hit)]))
            table.preview(arrivals: ["s4-2": at(0.12)], actions: [4: .init(action: .hit, cards: 3, at: at(-0.2))])
        case "bj-dealer":
            table.apply(BJState(now: now, round: round(.dealer, closed: -50, deadline: 1, dealer: [s9, c7, d2]),
                                seats: [lint, build, mine([h6, c5, ks], .stood, doubled: true), yh([tc, d6, qd], .bust, action: .hit)]))
            table.preview(arrivals: ["d-1": at(-0.7), "d-2": at(0.15)])
        default: // bj-result
            table.apply(BJState(now: now, round: round(.done, closed: -60, dealer: [s9, c7, d2], next: 4),
                                seats: [seat(1, "린트봇", id: nil, cards: [ah, kc], state: .blackjack, result: .blackjack),
                                        seat(2, "빌드봇", id: nil, cards: [td, s8], state: .stood, result: .push),
                                        mine([h6, c5, ks], .stood, doubled: true, result: .win, payout: 400),
                                        yh([tc, d6, qd], .bust, result: .lose, payout: 0)]))
            table.preview(arrivals: ["d-2": at(-1.0)])
        }
        return table
    }

    /// 인디언 포커 가짜 테이블: 시안(S01~S10)과 같은 판. 나는 지우, 철수·도윤은 사람, 민지는 봇
    static func fakePoker(store: LoungeStore, me: Player, mode: String) -> IndianPokerTable {
        let table = IndianPokerTable()
        table.store = store
        let now = Date()
        let at = { (s: TimeInterval) in now.addingTimeInterval(s) }
        let cs = UUID(), dy = UUID()
        switch mode {
        case "ip-lobby", "ip-lobby-broke", "ip-lobby-left":
            table.preview(lobby: IPLobby(now: now, tables: [
                .init(id: 1, capacity: 4, humans: 2, names: ["철수", "도윤"], handNo: 12),
                .init(id: 2, capacity: 3, humans: 1, names: ["민지"], handNo: 5),
                .init(id: 3, capacity: 2, humans: 1, names: ["도윤"], handNo: 3),
                .init(id: 4, capacity: 4, humans: 4, names: ["하준", "서아", "윤호", "다은"], handNo: 30),
            ]), leftNotice: mode == "ip-lobby-left" ? .away : nil)
            return table
        case "ip-lobby-empty":
            table.preview(lobby: IPLobby(now: now, tables: []))
            return table
        case "ip-create", "ip-create-2":
            // 새 테이블 만들기: 최대 인원 4(기본) / 2 (시안 S11 · S12)
            table.preview(lobby: IPLobby(now: now, tables: []))
            table.creating = true
            table.maxSeats = mode == "ip-create" ? 4 : 2
            return table
        default: break
        }

        func seat(_ n: Int, _ name: String, id: UUID?, chips: Int64? = nil, put: Int64 = 10, bet: Int64 = 0,
                  folded: Bool = false, allIn: Bool = false, action: IPSeat.Action? = nil, amount: Int64? = nil,
                  card: Int?, payout: Int64? = nil) -> IPSeat {
            IPSeat(seat: n, playerId: id, name: name, chips: chips ?? (id == nil ? nil : 800), put: put, bet: bet, folded: folded,
                   allIn: allIn, lastAction: action, lastAmount: amount, card: card, payout: payout,
                   net: payout.map { $0 - put })
        }
        func hand(_ phase: IPHand.Phase = .betting, turn: Int?, deadline: TimeInterval = 8, started: TimeInterval = -3,
                  bet: Int64 = 0, minRaise: Int64 = 10, pot: Int64, next: TimeInterval? = nil) -> IPHand {
            IPHand(id: 7, handNo: 7, phase: phase, firstSeat: 1, turnSeat: turn, turnNo: 4,
                   turnStartedAt: turn == nil ? nil : at(started), turnDeadline: turn == nil ? nil : at(deadline),
                   currentBet: bet, minRaise: minRaise, pot: pot, startedAt: at(-20), settledAt: phase == .done ? at(-0.5) : nil,
                   nextAt: next.map(at))
        }
        func state(_ cap: Int, mySeat: Int?, members: [IPMember], hand: IPHand?, seats: [IPSeat]) -> IPState {
            IPState(now: now, table: IPTable(id: 1, capacity: cap),
                    me: IPMe(member: true, seat: members.first { $0.playerId == me.id }?.seat, handSeat: mySeat),
                    members: members, hand: hand, seats: seats)
        }
        let jw = IPMember(seat: 4, playerId: me.id, name: "지우")
        let fourP = [IPMember(seat: 1, playerId: cs, name: "철수"), IPMember(seat: 3, playerId: dy, name: "도윤"), jw]
        func alert(_ seat: Int, _ name: String, _ a: IPSeat.Action, _ amount: Int64? = nil, allIn: Bool = false,
                   ago: TimeInterval = 0.3) -> IndianPokerTable.Alert {
            .init(seat: seat, name: name, action: a, amount: amount, allIn: allIn, at: at(-ago))
        }

        switch mode {
        case "ip-wait":
            // 혼자 앉은 테이블, 직전 판이 끝나고 다음 판 3초 전 (시안 S02)
            let s = state(4, mySeat: nil, members: [IPMember(seat: 1, playerId: me.id, name: "지우")],
                          hand: hand(.done, turn: nil, pot: 40, next: 2.6),
                          seats: [seat(1, "캐시봇", id: nil, card: 4, payout: 0), seat(2, "민지", id: nil, card: 8, payout: 40),
                                  seat(3, "도윤", id: nil, card: 2, payout: 0), seat(4, "하준", id: nil, card: 5, payout: 0)])
            table.preview(state: s)
        case "ip-wait-join":
            // 혼자 봇과 치던 테이블에 철수가 합류: 다음 판부터 봇 한 자리를 받는다 (시안 S13)
            let s = state(4, mySeat: nil, members: [IPMember(seat: 1, playerId: me.id, name: "지우"),
                                                    IPMember(seat: 4, playerId: cs, name: "철수")],
                          hand: hand(.done, turn: nil, pot: 40, next: 2.6),
                          seats: [seat(1, "캐시봇", id: nil, card: 4, payout: 0), seat(2, "민지", id: nil, card: 8, payout: 40),
                                  seat(3, "도윤", id: nil, card: 2, payout: 0), seat(4, "하준", id: nil, card: 5, payout: 0)])
            table.preview(state: s)
        case "ip-deal":
            let s = state(4, mySeat: 4, members: fourP, hand: hand(turn: 1, deadline: 12.5, started: 1.5, pot: 40),
                          seats: [seat(1, "철수", id: cs, card: 7), seat(2, "민지", id: nil, card: 3),
                                  seat(3, "도윤", id: dy, card: 9), seat(4, "지우", id: me.id, chips: 1_230, card: nil)])
            table.preview(state: s)
        case "ip-myturn", "ip-raise":
            // 4인: 철수 베팅 30, 민지 콜, 도윤 폴드, 내 차례 (시안 S03 / S04)
            let s = state(4, mySeat: 4, members: fourP, hand: hand(turn: 4, bet: 30, minRaise: 30, pot: 100),
                          seats: [seat(1, "철수", id: cs, put: 40, bet: 30, action: .bet, amount: 30, card: 7),
                                  seat(2, "민지", id: nil, put: 40, bet: 30, action: .call, amount: 30, card: 3),
                                  seat(3, "도윤", id: dy, folded: true, action: .fold, amount: 0, card: 9),
                                  seat(4, "지우", id: me.id, chips: 1_230, card: nil)])
            table.preview(state: s, alert: mode == "ip-raise" ? nil : alert(3, "도윤", .fold),
                          raising: mode == "ip-raise" ? 60 : nil)
        case "ip-allin":
            // 철수 올인 40, 민지 레이즈 120 → 메인 팟 / 사이드 팟 (시안 S05)
            let s = state(4, mySeat: 4, members: fourP, hand: hand(turn: 4, deadline: 9, bet: 120, minRaise: 80, pot: 200),
                          seats: [seat(1, "철수", id: cs, chips: 0, put: 50, bet: 40, allIn: true, action: .bet, amount: 40, card: 7),
                                  seat(2, "민지", id: nil, put: 130, bet: 120, action: .raise, amount: 120, card: 3),
                                  seat(3, "도윤", id: dy, folded: true, action: .fold, amount: 0, card: 9),
                                  seat(4, "지우", id: me.id, chips: 1_230, card: nil)])
            table.preview(state: s, alert: alert(2, "민지", .raise, 120, ago: 2))
        case "ip-side":
            // 검증 재현: 철수 10이 35 올인, 민지 5가 60, 나 7이 60 콜 → 메인 105는 철수, 사이드 50은 나
            let s = state(3, mySeat: 3, members: [IPMember(seat: 1, playerId: cs, name: "철수"), IPMember(seat: 3, playerId: me.id, name: "지우")],
                          hand: hand(.done, turn: nil, pot: 155, next: 4.2),
                          seats: [seat(1, "철수", id: cs, chips: 105, put: 35, bet: 25, allIn: true, action: .bet, amount: 25, card: 10,
                                       payout: 105),
                                  seat(2, "민지", id: nil, put: 60, bet: 50, action: .raise, amount: 50, card: 5, payout: 0),
                                  seat(3, "지우", id: me.id, chips: 1_230, put: 60, bet: 50, action: .call, amount: 50, card: 7,
                                       payout: 50)])
            table.preview(state: s)
        case "ip-last":
            // 판을 끝낸 마지막 콜: 결과가 나와도 1.5초 동안 판돈 패널에 행동 알림
            let s = state(4, mySeat: 4, members: fourP, hand: hand(.done, turn: nil, pot: 130, next: 4.8),
                          seats: [seat(1, "철수", id: cs, put: 40, bet: 30, action: .call, amount: 30, card: 7, payout: 0),
                                  seat(2, "민지", id: nil, put: 40, bet: 30, action: .call, amount: 30, card: 3, payout: 0),
                                  seat(3, "도윤", id: dy, folded: true, action: .fold, amount: 0, card: 9, payout: 0),
                                  seat(4, "지우", id: me.id, chips: 1_320, put: 40, bet: 30, action: .bet, amount: 30, card: 8,
                                       payout: 130)])
            table.preview(state: s, alert: alert(2, "민지", .call, 30, ago: 0.2))
        case "ip-leaving":
            // 일어나기를 보냈지만 서버가 아직 확인 못 함 (다시 시도 중)
            let s = state(2, mySeat: 2, members: [IPMember(seat: 2, playerId: me.id, name: "지우")],
                          hand: hand(turn: 1, pot: 20), seats: [seat(1, "민지", id: nil, card: 6), seat(2, "지우", id: me.id, card: nil)])
            table.preview(state: s, leaving: 3)
        case "ip-result":
            // 8이 제일 높음, 도윤 9는 폴드 (시안 S06)
            let s = state(4, mySeat: 4, members: fourP, hand: hand(.done, turn: nil, pot: 130, next: 4.6),
                          seats: [seat(1, "철수", id: cs, put: 40, bet: 30, action: .call, amount: 30, card: 7, payout: 0),
                                  seat(2, "민지", id: nil, put: 40, bet: 30, action: .call, amount: 30, card: 3, payout: 0),
                                  seat(3, "도윤", id: dy, folded: true, action: .fold, amount: 0, card: 9, payout: 0),
                                  seat(4, "지우", id: me.id, chips: 1_320, put: 40, bet: 30, action: .bet, amount: 30, card: 8,
                                       payout: 130)])
            table.preview(state: s)
        case "ip-check":
            // 2인: 민지 체크, 나는 체크 · 베팅 (시안 S07)
            let s = state(2, mySeat: 2, members: [IPMember(seat: 2, playerId: me.id, name: "지우")],
                          hand: hand(turn: 2, deadline: 9.6, pot: 20),
                          seats: [seat(1, "민지", id: nil, action: .check, amount: 0, card: 6),
                                  seat(2, "지우", id: me.id, chips: 1_230, card: nil)])
            table.preview(state: s, alert: alert(1, "민지", .check))
        case "ip-3p":
            // 3인: 철수 베팅 20, 민지(봇) 고르는 중
            let s = state(3, mySeat: 3, members: [IPMember(seat: 1, playerId: cs, name: "철수"),
                                                  IPMember(seat: 3, playerId: me.id, name: "지우")],
                          hand: hand(turn: 2, deadline: 2, bet: 20, minRaise: 20, pot: 50),
                          seats: [seat(1, "철수", id: cs, put: 30, bet: 20, action: .bet, amount: 20, card: 5),
                                  seat(2, "민지", id: nil, card: 10),
                                  seat(3, "지우", id: me.id, chips: 1_230, card: nil)])
            table.preview(state: s, alert: alert(1, "철수", .bet, 20, ago: 0.8))
        default: // ip-timeout
            // 내가 11초를 넘겨 자동 폴드, 지금은 철수 차례 (시안 S08)
            let s = state(4, mySeat: 4, members: fourP, hand: hand(turn: 1, deadline: 6.6, bet: 30, minRaise: 30, pot: 70),
                          seats: [seat(1, "철수", id: cs, card: 7), seat(2, "민지", id: nil, card: 3),
                                  seat(3, "도윤", id: dy, put: 40, bet: 30, action: .bet, amount: 30, card: 9),
                                  seat(4, "지우", id: me.id, chips: 1_230, folded: true, action: .timeout, amount: 0, card: nil)])
            table.preview(state: s, alert: alert(4, "지우", .timeout))
        }
        return table
    }

    /// 실서버 인디언 포커에 앉아 `seconds` 동안 상태를 찍고 마지막 화면을 저장한다.
    /// 앉은 테이블이 있으면 거기로, 없으면 자리 있는 테이블, 그것도 없으면 봇 2명과 새 테이블.
    /// LOUNGE_E2E_BET=1이면 내 차례에 체크·콜(가끔 레이즈) / fold면 늘 폴드 / idle이면 아무것도 안 함(시간 초과 확인)
    static func renderPokerLive(to path: String, seconds: Int) {
        Task { @MainActor in
            let store = LoungeStore(live: false)
            await store.connect()
            guard let me = store.me else { print("connect failed"); exit(1) }
            print("signed in as \(me.name) · chips \(me.chips)")
            // 닉네임이 없으면 테이블에 못 앉는다 (로컬 테스트 계정)
            if !me.named, await store.rename("지우") != nil { _ = await store.rename("지우\(Int.random(in: 10...99))") }
            let table = store.poker
            table.watching = true
            // LOUNGE_POKER_SEATS=2~4: 새 테이블을 만들 때 최대 인원 (기본 4)
            if let n = ProcessInfo.processInfo.environment["LOUNGE_POKER_SEATS"].flatMap(Int.init) { table.maxSeats = n }
            await table.refreshLobby()
            if !table.seated {
                if let open = table.lobby?.tables.first(where: { !$0.full }) {
                    await table.join(open.id)
                } else {
                    await table.create()
                }
            }
            print("table \(table.tableID.map(String.init) ?? "-") · \(table.message ?? "ok")")
            let play = ProcessInfo.processInfo.environment["LOUNGE_E2E_BET"] ?? ""
            var last = ""
            var acted = ""
            let start = store.chips
            for _ in 0..<(seconds * 4) {
                try? await Task.sleep(for: .milliseconds(250))
                let now = Date()
                if let h = table.hand, let o = table.options(at: now), !play.isEmpty, play != "idle", acted != "\(h.id):\(h.turnNo)",
                   !table.busy {
                    acted = "\(h.id):\(h.turnNo)"
                    try? await Task.sleep(for: .seconds(1))
                    if play == "fold" { await table.act(.fold) }
                    else if o.canRaise, Int.random(in: 0..<4) == 0 {
                        table.openRaise(at: .now)
                        await table.confirmRaise(at: .now)
                    } else { await table.act(o.canCheck ? .check : .call) }
                    print("act → \(table.mySeat?.lastAction?.rawValue ?? "?") \(table.mySeat?.lastAmount ?? 0) · \(table.message ?? "ok")")
                }
                guard let s = table.state, let h = s.hand else { continue }
                let seats = s.seats.map { x in
                    "\(x.seat):\(x.name)\(x.bot ? "(봇)" : "") \(x.card.map(String.init) ?? "?")\(x.folded ? "✕" : "") put \(x.put)\(x.lastAction.map { " " + $0.rawValue } ?? "")\(x.net.map { " net \($0)" } ?? "")"
                }.joined(separator: " | ")
                let line = "#\(h.handNo) \(h.phase.rawValue) turn \(h.turnSeat.map(String.init) ?? "-")/\(h.turnNo) pot \(h.pot) | \(seats)"
                if line != last { print(line); last = line }
                if let a = table.currentAlert(at: now), line.isEmpty { print(a) }
            }
            await store.refreshMe()
            print("chips \(start) → \(store.chips) (\(store.chips - start >= 0 ? "+" : "")\(store.chips - start))")
            write(AnyView(IndianPokerView(table: table, chips: store.chips)), to: path)
            if ProcessInfo.processInfo.environment["LOUNGE_POKER_STAY"] == nil {
                print(await table.leaveAndWait(timeout: 20) ? "left table" : "leave not confirmed")
            }
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    /// 미니 룰렛 가짜 판: 시안과 같은 판 (나 7에 50 · 빨강 50, 철수 홀 100, 영희 9 50 · 빨강 50)
    static func fakeRoulette(store: LoungeStore, me: Player, mode: String) -> RouletteTable {
        let table = RouletteTable(store: store)
        let now = Date()
        let cs = UUID(), yh = UUID()
        func bet(_ id: UUID, _ name: String, _ spot: Roulette.Spot, _ amount: Int64, golden: Bool = false, result: Int? = nil) -> RouletteBet {
            RouletteBet(playerId: id, name: name, spot: spot, amount: amount, golden: golden,
                        payout: result.map { r in golden && r == 0 ? 0 : amount * Int64(spot.multiplier(r)) })
        }
        func crowd(_ mine: [(Roulette.Spot, Int64, Bool)], others: Bool = true, result: Int? = nil) -> [RouletteBet] {
            mine.map { bet(me.id, me.name, $0.0, $0.1, golden: $0.2, result: result) }
                + (others ? [bet(cs, "철수", .odd, 100, result: result), bet(yh, "영희", .number(9), 50, result: result),
                             bet(yh, "영희", .red, 50, result: result)] : [])
        }
        let mine: [(Roulette.Spot, Int64, Bool)] = [(.number(7), 50, false), (.red, 50, false)]
        func round(closesIn: TimeInterval, result: Int? = nil) -> RouletteRound {
            RouletteRound(id: 2, betClosesAt: now.addingTimeInterval(closesIn), result: result)
        }
        switch mode {
        case "roulette-idle":
            // 지난 판(9)에 건 칩이 남아 있어도 칸 위엔 안 보여야 한다
            table.apply(RouletteState(now: now, round: round(closesIn: -20, result: 9), bets: crowd(mine, result: 9), lastResult: 4))
        case "roulette-golden":
            table.useGolden = true
            table.apply(RouletteState(now: now, round: round(closesIn: 8.6), bets: crowd([(.black, 100, true)]), lastResult: 9))
        case "roulette-alone":
            table.apply(RouletteState(now: now, round: round(closesIn: 9.6), bets: crowd([(.red, 50, false)], others: false), lastResult: 9))
        case "roulette-spin":
            table.apply(RouletteState(now: now, round: round(closesIn: -2.4, result: 7), bets: crowd(mine), lastResult: 9))
        case "roulette-closed":
            table.apply(RouletteState(now: now, round: round(closesIn: -1.5, result: 7), bets: crowd([]), lastResult: 9))
            table.preview(closedAt: now.addingTimeInterval(-0.3))
        case "roulette-win":
            table.apply(RouletteState(now: now, round: round(closesIn: -Roulette.spin - 0.8, result: 7), bets: crowd(mine, result: 7), lastResult: 9))
        case "roulette-void":
            table.apply(RouletteState(now: now, round: round(closesIn: -Roulette.spin - 0.8, result: 0), bets: crowd(mine, result: 0), lastResult: 9))
        case "roulette-cut-near", "roulette-cut-edge", "roulette-cut-land":
            // 클로즈업 컷: 결과 6. 나 6에 10 + 빨강 50 (9에서 다음 칸을 기다림 / 칸막이 위 / 6에 멈춤)
            let e: TimeInterval = mode == "roulette-cut-near" ? 5.0 : mode == "roulette-cut-edge" ? 5.8 : 6.3
            table.apply(RouletteState(now: now, round: round(closesIn: -e, result: 6),
                                      bets: crowd([(.number(6), 10, false), (.red, 50, false)], result: 6), lastResult: 9))
        default: // roulette-betting
            table.apply(RouletteState(now: now, round: round(closesIn: 8.6), bets: crowd(mine), lastResult: 9))
        }
        return table
    }

    /// 실서버 룰렛 테이블에 앉아 `seconds` 동안 상태를 찍고 마지막 화면을 저장한다 (Realtime 검증용).
    /// LOUNGE_E2E_BET=golden|chips면 판이 열려 있을 때 한 번 건다 (chips: 빨강 50 + 7에 10, golden: 홀에 황금 칩)
    static func renderRouletteLive(to path: String, seconds: Int) {
        Task { @MainActor in
            let store = LoungeStore(live: false)
            await store.connect()
            guard let me = store.me else {
                print("connect failed: \(store.netError ?? "?")")
                exit(1)
            }
            print("signed in as \(me.name) · chips \(me.chips)")
            await store.refresh() // 토큰 환전 + (LOUNGE_FAKE_429면) 황금 칩
            print("after claim · chips \(store.chips) · golden \(store.golden())")
            let table = RouletteTable(store: store)
            table.enter()
            let mode = ProcessInfo.processInfo.environment["LOUNGE_E2E_BET"]
            var placed = false
            var last = ""
            for _ in 0..<(seconds * 2) {
                try? await Task.sleep(for: .milliseconds(500))
                let phase = table.phase(at: .now)
                if let mode, !placed, table.state != nil, phase == .idle || { if case .betting(let l) = phase { l > 2 } else { false } }() {
                    placed = true
                    if mode == "golden" {
                        table.useGolden = true
                        await table.bet(.odd)
                    } else {
                        table.stake = 50
                        await table.bet(.red)
                        table.stake = 10
                        await table.bet(.number(7))
                    }
                    print("bet → \(table.myBets.map { "\($0.spot.rawValue) \($0.amount)\($0.golden ? " golden" : "")" }) · \(table.message ?? "ok") · chips \(store.chips) · golden \(store.golden())")
                }
                let line = "#\(table.round?.id ?? -1) \(phase) · bets \(table.players().map { "\($0.name) \($0.staked)\($0.net.map { " net \($0)" } ?? "")" })"
                if line != last { print(line); last = line }
            }
            print("chips \(store.chips) · golden \(store.golden())")
            write(AnyView(RouletteView(table: table, chips: store.chips, golden: store.golden())), to: path)
            table.leave()
            exit(0)
        }
        // ImageRenderer는 메인 런루프가 필요하다 (dispatchMain으론 멈춤)
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    /// 실서버 라운지 벽화를 열고 `seconds` 동안 새 칸이 들어올 때마다 찍는다 (Realtime 검증용).
    /// 대체 갱신은 30초라, 지연이 몇 초 안이면 Realtime으로 받은 것
    static func renderWallLive(to path: String, seconds: Int) {
        Task { @MainActor in
            let store = LoungeStore(live: false)
            await store.connect()
            guard let me = store.me else { print("connect failed: \(store.netError ?? "?")"); exit(1) }
            print("signed in as \(me.name)")
            let wall = PixelWall(store: store)
            wall.enter()
            var seen: Date?
            for _ in 0..<(seconds * 4) {
                try? await Task.sleep(for: .milliseconds(250))
                guard let s = wall.state else { continue }
                guard let newest = s.pixels.max(by: { $0.at < $1.at }) else { continue }
                if seen == nil { print("board · \(s.pixels.count)칸 · 내 버킷 \(s.left)/\(s.cap)") }
                if let seen, newest.at <= seen { continue }
                if seen != nil {
                    let lag = Date.now.timeIntervalSince(newest.at.addingTimeInterval(-wall.skew))
                    print(String(format: "+ %@ %d,%d 색%d · 지연 %.1f초 · 총 %d칸", newest.p, newest.x + 1, newest.y + 1, newest.c, lag, s.pixels.count))
                }
                seen = newest.at
            }
            write(AnyView(PixelWallView(wall: wall)), to: path)
            wall.leave()
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    /// 실서버 블랙잭 테이블에 앉아 `seconds` 동안 매초 상태를 찍고 마지막 화면을 저장한다.
    /// LOUNGE_E2E_BET=1이면 앱 계정도 걸고, 내 차례엔 12 미만 히트 · 그 외 스탠드
    static func renderBlackjackLive(to path: String, seconds: Int) {
        Task { @MainActor in
            let store = LoungeStore(live: false)
            await store.connect()
            guard let me = store.me else { print("connect failed"); exit(1) }
            print("signed in as \(me.name) · chips \(me.chips)")
            let table = BlackjackTable(store: store)
            table.enter()
            let play = ProcessInfo.processInfo.environment["LOUNGE_E2E_BET"] != nil
            var last = ""
            for _ in 0..<(seconds * 2) {
                try? await Task.sleep(for: .milliseconds(500))
                let now = Date()
                if play, table.mySeat == nil, !table.busy, table.idle(at: now) || table.round?.phase == .betting {
                    await table.bet()
                    print("bet → seat \(table.mySeat?.seat ?? 0) · \(table.message ?? "ok") · chips \(store.chips)")
                }
                if play, let r = table.round, let mine = table.mySeat, r.phase == .playing, r.turnSeat == mine.seat,
                   mine.state == .playing, !table.busy, now >= table.local(r.betClosesAt).addingTimeInterval(3.5) {
                    let t = BJCard.total(mine.cards.map(BJCard.init)).value
                    await table.act(t < 12 ? .hit : .stand)
                    print("act \(t < 12 ? "hit" : "stand") at \(t) → \(table.message ?? "ok")")
                }
                guard let r = table.round else { continue }
                let seats = table.seats.map { s in
                    "\(s.seat):\(s.name)\(s.bot ? "(AI)" : "") \(BJCard.total(s.cards.map(BJCard.init)).value)/\(s.state.rawValue)\(s.result.map { "=" + $0.rawValue } ?? "")"
                }.joined(separator: " ")
                let line = "#\(r.id) \(r.phase.rawValue) turn \(r.turnSeat.map(String.init) ?? "-") dealer \(BJCard.total(r.dealerCards.map(BJCard.init)).value) | \(seats)"
                if line != last { print(line); last = line }
            }
            print("chips \(store.chips)")
            write(AnyView(BlackjackView(table: table, chips: store.chips, golden: store.golden())), to: path)
            table.leave()
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    /// 실서버 429 드롭에 앉아 `seconds` 동안 상태를 찍고 마지막 화면을 저장한다 (착지 때 지갑이 바뀌는지 확인용).
    /// LOUNGE_E2E_BET=1: 앱 계정도 1.5초마다 한 번 누르고 뗀다(눌림 0.1~1.2초) / auto: AUTO로 / golden: 황금 칩 한 번
    /// 끝나면 떠 있는 공이 다 내려올 때까지 기다린 뒤 서버에 기록된 판 수와 칩을 비교한다
    static func renderPlinkoLive(to path: String, seconds: Int) {
        Task { @MainActor in
            let store = LoungeStore(live: false)
            await store.connect()
            guard let me = store.me else { print("connect failed: \(store.netError ?? "?")"); exit(1) }
            print("signed in as \(me.name) · chips \(me.chips) · golden \(store.golden())")
            let table = PlinkoTable(store: store)
            table.log = { print("  \($0)") }
            table.enter()
            // LOUNGE_PLINKO_WINDOW=1: 실제 창에 띄워 그리면서 잰다 (화면 그리기가 틱을 미는지 확인용)
            if ProcessInfo.processInfo.environment["LOUNGE_PLINKO_WINDOW"] == "1" {
                NSApplication.shared.setActivationPolicy(.accessory)
                let host = NSHostingView(rootView: PlinkoLiveHost(table: table, store: store))
                let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 340, height: 560),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                plinkoWindow = window
                if ProcessInfo.processInfo.environment["LOUNGE_PLINKO_SOUND"] == "1" {
                    let was = GameAudio.shared.enabled
                    GameAudio.shared.enabled = true
                    GameAudio.shared.setVisible(true)
                    GameAudio.shared.enter(.floor)
                    table.onSound = { GameAudio.shared.plinko($0) }
                    GameAudio.shared.warmPlinko()
                    atexit_b { MainActor.assumeIsolated { GameAudio.shared.enabled = was } }
                }
            }
            let mode = ProcessInfo.processInfo.environment["LOUNGE_E2E_BET"]
            table.stake = 50
            let start = store.chips
            var presses = 0
            if mode == "auto" { table.auto = true }
            if mode == "golden", store.golden() > 0 {
                table.useGolden = true
                table.press(at: .now)
                table.release(at: .now.addingTimeInterval(0.9))
                presses += 1
                print("golden drop · 보이는 칩 \(table.shown(chips: store.chips))")
            }
            var last = ""
            for i in 0..<(seconds * 4) {
                try? await Task.sleep(for: .milliseconds(250))
                if mode == "1", i % 6 == 0, !table.charging {
                    let held = Double.random(in: 0.1...1.2)
                    let t0 = Date()
                    table.lane = Int.random(in: -1...1)
                    table.press(at: t0)
                    if table.charging {
                        table.release(at: t0.addingTimeInterval(held))
                        presses += 1
                        print("drop #\(presses) 레인 \(table.lane) 눌림 \(String(format: "%.2f", held))초 → 파워 \(table.lastPower) \(PlinkoGauge.grade(power: table.lastPower).rawValue)")
                    } else {
                        print("drop 막힘 · \(table.blockReason(chips: store.chips, golden: store.golden()) ?? "?") \(table.message ?? "")")
                    }
                }
                let line = "공 \(table.inFlight)/5 fever \(table.feverActive) · 보이는 칩 \(table.shown(chips: store.chips)) / 서버 \(store.chips)\(table.message.map { " · \($0)" } ?? "")"
                if line != last { print(line); last = line }
            }
            table.auto = false
            // 떠 있는 공이 다 닿을 때까지
            for _ in 0..<120 where table.inFlight > 0 || table.feverActive || table.shown(chips: store.chips) != store.chips {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .milliseconds(500))
            print("끝 · 보이는 칩 \(table.shown(chips: store.chips)) / 서버 \(store.chips) · 시작 \(start) → 변화 \(store.chips - start) · 이번 판 \(table.sessionNet)")
            write(AnyView(PlinkoView(table: table, chips: store.chips, golden: store.golden(),
                                     vip: (store.me?.goldenUntil ?? .distantPast) > .now)), to: path)
            table.leave()
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    /// 실서버에서 슬롯을 `spins`번 돌리고 마지막 화면을 찍는다
    static func renderSlotLive(to path: String, spins: Int) {
        Task { @MainActor in
            let store = LoungeStore(live: false)
            await store.connect()
            guard store.me != nil else { print("connect failed"); exit(1) }
            let machine = SlotMachine(store: store)
            machine.stake = 10
            for i in 1...spins {
                let before = store.chips
                await machine.spin()
                let r = machine.result
                print("spin \(i): \(r?.initialReels.joined(separator: " ") ?? "-") → \(r?.reels.joined(separator: " ") ?? "-") glitched \(r?.glitched ?? []) vip \(r?.vip ?? false) ×\(r?.payoutMultiplier ?? -1) payout \(r?.payout ?? -1) · chips \(before) → \(store.chips) \(machine.message ?? "")")
            }
            try? await Task.sleep(for: .seconds(0.4))
            write(AnyView(SlotView(machine: machine, chips: store.chips, golden: store.golden())), to: path)
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    /// 실서버 라운지에 접속해 `seconds`초 동안 회원 목록을 지켜보고 화면을 찍는다
    static func renderLobbyLive(to path: String, seconds: Int) {
        Task { @MainActor in
            let store = LoungeStore(live: false)
            await store.connect()
            guard store.me != nil else { print("connect failed"); exit(1) }
            store.viewing = true
            for i in 1...seconds {
                try? await Task.sleep(for: .seconds(1))
                let c = store.crowd()
                let names = c.others.map { "\($0.name)\($0.viewing ? "👁" : "")\($0.status.map { "·" + $0.rawValue } ?? "")" }
                print("t+\(i)s total \(c.total) viewing \(c.viewing) roulette \(c.roulette) others \(names) events \(c.events.map { "\($0.name) \($0.kind) \($0.amount)" }) dot \(store.tableBusy)")
            }
            await store.loadBoard()
            print("board \(store.board.map { $0.map { "\($0.rank). \($0.name) \($0.net)\($0.me ? " (나)" : "")" } } ?? ["-"])")
            write(AnyView(LoungeView(snapshot: store.snapshot, lastScan: .now, chips: store.chips, online: true,
                                     crowd: store.crowd(), board: store.board, name: store.me?.name)), to: path)
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    private static func write(_ content: AnyView, to path: String) {
        let renderer = ImageRenderer(content: content.padding(8).background(Color(white: 0.3)).environment(\.snapshotting, true))
        renderer.scale = 2
        if let tiff = renderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
    }

    /// mode: slot-idle | slot-spinning | slot-glitch | slot-win | slot-big | slot-jackpot | slot-lose
    private static func fakeWall(store: LoungeStore, mode: String) -> PixelWall {
        let rows = [
            "",
            "..n.n.nnn.nnn.............gg",
            "..n.n...n.n.n............g",
            "..nnn.nnn.nnn............g",
            "....n.n.....n............g",
            "....n.nnn.nnn.............gg",
            "",
            ".......c..............y.........c",
            "",
            "...yyyyyyyyy",
            "....ynnnnny......c.......c",
            ".....ynnny.......cc.....cc",
            "......yny........ccccccccc.nn.nn",
            ".......y.........cckccckcc.nnnnn",
            ".......y.........ccccncccc..nnn",
            ".......y.........ccckckccc...n",
            ".....yyyyy.......ccccccccc",
            "",
            "..c..........................y",
            "",
            "..e.e.e.....mmmmmmmmmm",
            "..eeeee.....mkkkkkkkkm..g",
            "...eee......mkyykccckm",
            "....e.......mkkggkyykm",
            "....e.......mkkkkkkkkm",
            ".ffffff.....mmmmmmmmmm",
            "fffffffff.......mm",
            "fffffffff....mmmmmmmm",
            "",
            "...c.........n.......y.....g",
        ]
        let colors: [Character: Int] = ["c": 0, "n": 1, "g": 2, "y": 3, "e": 4, "f": 5, "m": 6, "k": 7]
        func owner(_ x: Int, _ y: Int) -> String {
            if y <= 5 { return "영희" }
            if (9...16).contains(y) && x <= 12 { return "철수" }
            if (10...16).contains(y) && (17...25).contains(x) { return "민수" }
            if y >= 12 && x >= 26 { return "예린" }
            if (20...27).contains(y) { return "새벽코더" }
            return "우진"
        }
        let now = Date.now
        var pixels: [PixelBoardState.Pixel] = []
        if mode != "wall-empty" {
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let c = colors[ch] else { continue }
                    pixels.append(.init(x: x, y: y, c: c, p: owner(x, y), at: now.addingTimeInterval(-Double((x * 7 + y * 13) % 50) * 60)))
                }
            }
        }
        let counts = Dictionary(grouping: pixels, by: \.p).mapValues(\.count).sorted { $0.value > $1.value }
        let painters = counts.map { PixelBoardState.Painter(name: $0.key, count: $0.value, me: $0.key == "새벽코더") }
        let limited = mode == "wall-limited"
        let left = limited ? 0 : mode == "wall-painted" ? 6 : mode == "wall-empty" ? 10 : 7
        let wall = PixelWall(store: store)
        wall.apply(PixelBoardState(now: now, left: left, nextAt: left == 10 ? nil : now.addingTimeInterval(24),
                                   pixels: pixels, painters: painters))
        switch mode {
        case "wall-painted": wall.preview(response: .created(.init(x: 24, y: 21)), selected: .init(x: 24, y: 21), color: 2)
        case "wall-same": wall.preview(response: .same, selected: .init(x: 20, y: 14), color: 1)
        case "wall-limited": wall.preview(response: .limited, selected: .init(x: 24, y: 21), color: 2)
        case "wall-empty": wall.preview(response: .idle, selected: nil, color: 1)
        default: wall.preview(response: .idle, selected: nil, hover: .init(x: 20, y: 13), color: 1)
        }
        return wall
    }

    /// 429 드롭 가짜 장면: 시드를 고정해 서버 규칙대로 뽑은 한 판을 틱으로 되감아 재생한다
    static func fakePlinko(store: LoungeStore, me: Player, mode: String) -> PlinkoTable {
        let table = PlinkoTable(store: store, seed: 429)
        func drop(_ lane: Int, grade: PlinkoDrop.Grade = .none, amount: Int64 = 100, forceCatch: Bool = false,
                  reels: [String]? = nil, fever: Bool = false, letters: Int = 0, level: Int = 0,
                  matching: (PlinkoBall) -> Bool = { _ in true }) {
            let player = Player(id: me.id, name: me.name, chips: Int64(store.chips), goldenChips: me.goldenChips, goldenUntil: me.goldenUntil)
            table.preview(drop: PlinkoFake.drop(player: player, lane: lane, amount: amount, grade: grade,
                                                forceCatch: forceCatch, reels: reels, fever: fever,
                                                letters: letters, level: level, matching: matching))
        }
        switch mode {
        case "plinko-charging":
            // 앞서 쏜 공 둘: 먼저 것은 한참 내려갔고, 나중 것은 PERFECT라 포켓이 열려 있다
            drop(0) { $0.bucket != nil }
            table.advance(24)
            drop(1, grade: .perfect) { $0.bucket != nil && $0.split == nil }
            table.advance(8)
            table.lane = 1
            table.previewCharging(power: 850)
            table.advance(6)
        case "plinko-flying":
            // 분열: 오른쪽 레인 공이 (10, 8) 분열 핀을 맞고 둘로 갈라진 직후. 다른 공은 왼쪽 레인
            drop(1, grade: .good) { $0.split != nil && $0.clone != nil }
            table.advance(10)
            drop(-1) { $0.bucket != nil && $0.split == nil }
            table.advance(24)
        case "plinko-win":
            drop(0) { $0.bucket == 2 && $0.gold == 0 && $0.split == nil }
            table.advance(43)
        case "plinko-big":
            drop(0, grade: .perfect) { ($0.bucket == 1 || $0.bucket == 11) && $0.split == nil && $0.gold == 0 }
            table.advance(41)
        case "plinko-max":
            drop(0) { $0.bucket == 0 && $0.split == nil }
            table.advance(41)
        case "plinko-pocket":
            drop(0, forceCatch: true) { $0.pocket }
            table.advance(38)
        case "plinko-letters":
            // 포켓 릴이 꽝으로 멈추고 "2"가 켜지며 파란 분열 핀이 생긴 순간
            table.previewLetters(1)
            drop(0, forceCatch: true, reels: ["7", "BAR", "404"], letters: 2, level: 1) { $0.pocket }
            table.advance(46)
        case "plinko-hot":
            // 4·2·9 HOT: 핀이 다 늘어난 보드에서 공 둘이 내려가는 중
            table.previewLetters(3)
            drop(-1, level: 3) { $0.bucket != nil && $0.gold > 0 }
            table.advance(14)
            drop(1, level: 3) { $0.bucket != nil && $0.split != nil }
            table.advance(20)
        case "plinko-fever":
            drop(0, forceCatch: true, fever: true) { $0.pocket }
            table.advance(100)
        case "plinko-fever-end":
            // FEVER가 끝나고 4·2·9가 하나씩 꺼지는 중
            drop(0, forceCatch: true, fever: true) { $0.pocket }
            for _ in 0..<600 where table.fever?.endAt == nil { table.advance(1) }
            table.advance(8)
        case "plinko-vip":
            // VIP HOUR: 포켓 입구가 늘 열려 있다
            table.previewLetters(1)
            drop(0) { $0.bucket != nil && $0.split == nil }
            table.advance(12)
        default: break
        }
        return table
    }

    private static func fakeSlot(store: LoungeStore, me: Player, mode: String) -> SlotMachine {
        let m = SlotMachine(store: store)
        func result(_ reels: [String], _ mult: Int, initial: [String]? = nil, glitched: [Int] = []) -> SlotResult {
            SlotResult(reels: reels, initialReels: initial, glitched: glitched, vip: true,
                       multiplier: mult, payout: 50 * Int64(mult), player: me)
        }
        switch mode {
        case "slot-spinning": m.preview(result: result(["bar", "bar", "bar"], 20), elapsed: 0.75, pending: true)
        case "slot-glitch":
            // 세 릴이 멈추고 500 글리치가 한창인 순간
            m.preview(result: result(["cherry", "bell", "cherry"], 3, initial: ["cherry", "bell", "500"], glitched: [2]),
                      elapsed: 1.6 + 0.25 + 0.25, pending: true)
        case "slot-win": m.preview(result: result(["cherry", "bell", "cherry"], 3), finishedAgo: 0.35)
        case "slot-single-429":
            m.preview(result: SlotResult(reels: ["bell", "429", "blank"], multiplier: 1,
                                         payoutMultiplier: 1.8, payout: 90, player: me), finishedAgo: 0.35)
        case "slot-big": m.preview(result: result(["seven", "seven", "seven"], 50), finishedAgo: 0.9)
        case "slot-jackpot": m.preview(result: result(["429", "429", "429"], 429), finishedAgo: 1.2)
        case "slot-lose": m.preview(result: result(["seven", "blank", "bell"], 0), finishedAgo: 1)
        default: break
        }
        return m
    }

    private static func fakeBoard(_ mode: String) -> [BoardRow]? {
        switch mode {
        case "lobby-board-empty": return []
        case "lobby-board-10", "lobby-board-10-me":
            // 열 명이 꽉 찬 판. -me는 내가 14위 (10위 밖이라 아래에 고정)
            let names = ["지호", "예린", "민수", "서연", "madman", "하루", "도윤", "채원", "리안", "준"]
            var rows = names.enumerated().map { i, n in
                BoardRow(rank: i + 1, name: n, net: Int64(21_450 - i * 2_300), me: mode == "lobby-board-10" && i == 3)
            }
            if mode == "lobby-board-10-me" { rows.append(BoardRow(rank: 14, name: "새벽코더", net: -600, me: true)) }
            return rows
        case "lobby-board-me":
            // 내가 4위 밖
            return [BoardRow(rank: 1, name: "지호", net: 21_450), BoardRow(rank: 2, name: "예린", net: 1_850),
                    BoardRow(rank: 3, name: "민수", net: 320), BoardRow(rank: 7, name: "새벽코더", net: -600, me: true)]
        default:
            return [BoardRow(rank: 1, name: "지호", net: 21_450), BoardRow(rank: 2, name: "새벽코더", net: 1_850, me: true),
                    BoardRow(rank: 3, name: "madman", net: 0)]
        }
    }

    private static func fakeCrowd(me: Player, mode: String) -> LoungeCrowd {
        func m(_ name: String, viewing: Bool = false, place: Member.Place = .lounge, _ status: Member.Status? = nil) -> Member {
            Member(id: UUID(), name: name, viewing: viewing, place: place, status: status)
        }
        let mine = Member(id: me.id, name: "새벽코더", viewing: true)
        let busy = [
            mine,
            m("철수", viewing: true, place: .roulette, .coding), m("영희", viewing: true, place: .roulette),
            m("예린", .vip), m("민수", .coding), m("지호", .coding), m("하준", .coding),
            m("서연", .resting), m("도윤", .resting), m("수아"), m("우진", .coding), m("지은", .resting),
        ]
        let now = Date()
        func r(_ name: String, _ ago: TimeInterval) -> Regular { Regular(id: UUID(), name: name, lastSeenAt: now.addingTimeInterval(-ago)) }
        // 오프라인 명부 회원 (ADR-0011)
        let away = [r("논스탁", 40), r("madman", 12 * 60), r("집산다", 3 * 3600), r("조곽철", 2 * 86_400)]
        switch mode {
        case "lobby-quiet":
            return LoungeCrowd(members: [mine, m("예린", .vip)], roster: away, me: me.id, events: [])
        case "lobby-alone":
            return LoungeCrowd(members: [mine], me: me.id, events: [])
        case "lobby-ticker":
            let events = [
                LoungeEvent(id: 1, kind: "bigwin", game: "slot", name: "민수", amount: 1_000, createdAt: now.addingTimeInterval(-40)),
                LoungeEvent(id: 2, kind: "jackpot", game: "slot", name: "지호", amount: 21_450, createdAt: now.addingTimeInterval(-5)),
            ]
            return LoungeCrowd(members: busy, me: me.id, events: events)
        default:
            return LoungeCrowd(members: busy, roster: away, me: me.id, events: [])
        }
    }
}
