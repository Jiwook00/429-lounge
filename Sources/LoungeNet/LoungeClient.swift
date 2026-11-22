import Foundation
import Supabase

public struct LoungeConfig: Sendable {
    public var url: URL
    public var key: String

    /// `supabase start`로 띄운 로컬 스택. 키는 모든 로컬 설치에 공통인 공개 개발용 키.
    public static let local = LoungeConfig(
        url: URL(string: "http://127.0.0.1:54321")!,
        key: "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"
    )

    /// 운영 서버 (hi@dwook.co 조직, 서울). publishable 키라 공개돼도 된다. 쓰기는 RPC + RLS로만 열려 있다.
    public static let remote = LoungeConfig(
        url: URL(string: "https://sanozthsmcyxddnqrzkc.supabase.co")!,
        key: "sb_publishable_99CDl77tNy1QLAKJOzfi7A_1tQVjvpC"
    )

    /// 우선순위: LOUNGE_SUPABASE_URL/KEY → LOUNGE_SERVER=remote 환경변수 → Info.plist의 LoungeServer → 로컬.
    /// Finder로 띄운 .app엔 셸 환경변수가 안 넘어가서 배포 빌드는 Info.plist로 정한다.
    public static func load() -> LoungeConfig {
        let env = ProcessInfo.processInfo.environment
        if let url = env["LOUNGE_SUPABASE_URL"].flatMap(URL.init(string:)), let key = env["LOUNGE_SUPABASE_KEY"] {
            return LoungeConfig(url: url, key: key)
        }
        let server = env["LOUNGE_SERVER"] ?? Bundle.main.object(forInfoDictionaryKey: "LoungeServer") as? String
        return server == "remote" ? .remote : .local
    }
}

public enum LoungeError: LocalizedError {
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .server("betting_closed"): "베팅이 마감됐어요"
        case .server("minority_closed"): "이번 판은 마감됐어요"
        case .server("already_picked"): "이번 판엔 이미 골랐어요"
        case .server("not_named"): "이름부터 정해 주세요"
        case .server("already_bet"): "이번 판엔 이미 걸었어요"
        case .server("insufficient_chips"): "칩이 부족해요"
        case .server("invalid_amount"): "베팅 금액이 이상해요"
        case .server("no_golden"): "쓸 수 있는 황금 칩이 없어요"
        case .server("invalid_nickname"): "1~12자로 정해 주세요"
        case .server("nickname_taken"): "누가 벌써 쓰는 이름이에요"
        case .server("table_full"): "자리가 다 찼어요"
        case .server("not_your_turn"): "지금은 내 차례가 아니에요"
        case .server("cannot_double"): "지금은 더블할 수 없어요"
        case .server("not_alone"): "다른 회원도 앉아 있어요"
        case .server("not_seated"): "먼저 걸어 주세요"
        case .server("golden_outside_only"): "황금 칩은 바깥 칸에만 놓여요"
        case .server("invalid_spot"): "걸 수 없는 칸이에요"
        case .server("game_retired"): "홀짝은 문을 닫았어요 · 룰렛으로"
        case .server(let m): m
        }
    }

    static func wrap(_ error: any Error) -> any Error {
        if let e = error as? PostgrestError { return LoungeError.server(e.message) }
        return error
    }
}

public final class LoungeClient: Sendable {
    public let supabase: SupabaseClient

    /// profile: 세션 저장 단위. 앱은 "default", 봇은 각자 다른 이름으로 → 서로 다른 유저.
    public init(config: LoungeConfig = .load(), profile: String = "default") {
        supabase = SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.key,
            options: .init(auth: .init(
                storage: FileAuthStorage(config: config, profile: profile),
                emitLocalSessionAsInitialSession: true
            ))
        )
    }

    public var userID: UUID? { supabase.auth.currentUser?.id }

    /// 익명 로그인(세션이 없거나 만료됐으면) + 플레이어 행 보장.
    /// 처음이면 서버가 "손님 XXXXXX"를 붙인다. name을 주면(봇) 그 이름으로 바꿔 본다.
    public func signIn(name: String? = nil) async throws -> Player {
        if (try? await supabase.auth.session) == nil {
            _ = try await supabase.auth.signInAnonymously()
        }
        var me: Player
        do {
            me = try await ensurePlayer()
        } catch {
            // 로컬 DB를 리셋하면 저장된 세션의 유저가 사라진다 → 새로 가입
            try? await supabase.auth.signOut()
            _ = try await supabase.auth.signInAnonymously()
            me = try await ensurePlayer()
        }
        if let name, me.name != name { me = try await setNickname(name) }
        return me
    }

    private func ensurePlayer() async throws -> Player {
        try await supabase.rpc("ensure_player").execute().value
    }

    /// 닉네임 정하기 / 바꾸기 (1~12자, 라운지 전체에서 하나뿐)
    public func setNickname(_ name: String) async throws -> Player {
        do {
            return try await supabase.rpc("set_nickname", params: ["p_name": name]).execute().value
        } catch { throw LoungeError.wrap(error) }
    }

    public func me() async throws -> Player? {
        guard let id = userID else { return nil }
        return try await supabase.from("players").select().eq("id", value: id).single().execute().value
    }

    public func players(_ ids: [UUID]) async throws -> [Player] {
        guard !ids.isEmpty else { return [] }
        return try await supabase.from("players").select().in("id", values: ids).execute().value
    }

    /// 서버가 요구하는 앱 최소 버전 (ADR-0010). 로그인 전에도 읽힌다
    public func minClientVersion() async throws -> String {
        struct Row: Decodable { let min_version: String }
        let row: Row = try await supabase.from("client_policy").select("min_version").single().execute().value
        return row.min_version
    }

    /// 회원 명부: 닉네임을 정한 회원, 최근에 본 순 (ADR-0011)
    public func roster(limit: Int = 100) async throws -> [Regular] {
        try await supabase.from("players").select("id, name, last_seen_at").eq("named", value: true)
            .order("last_seen_at", ascending: false, nullsFirst: false).limit(limit).execute().value
    }

    /// 앱이 켜져 있다고 알린다 (마지막으로 본 시각). 서버가 1분 안의 중복은 무시한다
    public func touchSeen() async throws {
        try await supabase.rpc("touch_seen").execute()
    }

    /// 이번 주 큰손: 위 `top`명 + (그 밖이면) 내 줄 (ADR-0012)
    public func weeklyBoard(top: Int = 10) async throws -> [BoardRow] {
        try await supabase.rpc("weekly_board", params: ["p_top": top]).execute().value
    }

    /// 지난주 내 순위. 지난주에 안 했으면 nil (ADR-0012)
    public func lastWeekRank() async throws -> Int? {
        let rows: [LastWeekRank] = try await supabase.rpc("last_week_rank").execute().value
        return rows.first?.rank
    }

    /// 소수결: 지난 판 정산 + 지금 판 열기 + 상태 (ADR-0013)
    public func minorityTick() async throws -> MinorityState {
        try await supabase.rpc("minority_tick").execute().value
    }

    /// 소수결: 200칩 걸고 고르기 (0 / 1)
    public func minorityPick(_ choice: Int) async throws -> MinorityState {
        do {
            return try await supabase.rpc("minority_pick", params: ["p_choice": choice]).execute().value
        } catch {
            throw LoungeError.wrap(error)
        }
    }

    // MARK: - 블랙잭 (ADR-0014)

    /// 밀린 단계를 진행하고 지금 판 전부를 받는다
    public func bjTick(room: String) async throws -> BJState {
        try await supabase.rpc("bj_tick", params: ["p_room": room]).execute().value
    }

    /// 자리에 앉아 건다. 판이 없으면 10초 베팅 창이 열린다
    public func bjBet(room: String, amount: Int64, golden: Bool = false) async throws -> BJState {
        struct Params: Encodable { let p_room: String; let p_amount: Int64; let p_golden: Bool }
        do {
            return try await supabase.rpc("bj_bet", params: Params(p_room: room, p_amount: amount, p_golden: golden)).execute().value
        } catch {
            throw LoungeError.wrap(error)
        }
    }

    /// 혼자 앉아 있으면 바로 딜
    public func bjDeal(room: String) async throws -> BJState {
        do {
            return try await supabase.rpc("bj_deal", params: ["p_room": room]).execute().value
        } catch {
            throw LoungeError.wrap(error)
        }
    }

    /// 내 차례: hit | stand | double
    public func bjAction(room: String, _ action: BJSeat.Action) async throws -> BJState {
        do {
            return try await supabase.rpc("bj_action", params: ["p_room": room, "p_action": action.rawValue]).execute().value
        } catch {
            throw LoungeError.wrap(error)
        }
    }

    /// 라운지 타일: 지금 판에 앉은 회원 수 (AI 제외)
    public func bjSeated(room: String) async throws -> Int {
        try await supabase.rpc("bj_seated", params: ["p_room": room]).execute().value
    }

    /// 블랙잭 테이블이 바뀌었다는 신호 (라운드·좌석). 받으면 bjTick으로 다시 읽는다.
    /// 재연결 뒤에도 한 번 보낸다 (그 사이 놓친 변경이 있을 수 있어서)
    public func bjChanges(room: String) -> AsyncStream<Void> {
        changes(channel: "bj:\(room)", tables: ["bj_rounds", "bj_seats"], room: room)
    }

    // MARK: - 미니 룰렛 (ADR-0015)

    /// 마감이 지난 판을 정산하고 지금 판 전부를 받는다
    public func rouletteTick(room: String) async throws -> RouletteState {
        try await supabase.rpc("roulette_tick", params: ["p_room": room]).execute().value
    }

    /// 칸에 칩을 놓는다 (바로 걸림). 판이 없으면 12초 베팅 창이 열린다
    public func rouletteBet(room: String, spot: Roulette.Spot, amount: Int64, golden: Bool = false) async throws -> RouletteState {
        struct Params: Encodable { let p_room: String; let p_spot: String; let p_amount: Int64; let p_golden: Bool }
        do {
            return try await supabase.rpc("roulette_bet", params: Params(p_room: room, p_spot: spot.rawValue, p_amount: amount, p_golden: golden))
                .execute().value
        } catch {
            throw LoungeError.wrap(error)
        }
    }

    /// 혼자 걸었으면 바로 돌린다
    public func rouletteSpin(room: String) async throws -> RouletteState {
        do {
            return try await supabase.rpc("roulette_spin", params: ["p_room": room]).execute().value
        } catch {
            throw LoungeError.wrap(error)
        }
    }

    /// 룰렛 테이블이 바뀌었다는 신호 (라운드·베팅). 받으면 rouletteTick으로 다시 읽는다
    public func rouletteChanges(room: String) -> AsyncStream<Void> {
        changes(channel: "roulette:\(room)", tables: ["roulette_rounds", "roulette_bets"], room: room)
    }

    /// 테이블들의 room_code 변경을 "바뀌었다" 신호 하나로. 재연결 뒤에도 한 번 보낸다 (놓친 변경이 있을 수 있어서)
    private func changes(channel name: String, tables: [String], room: String) -> AsyncStream<Void> {
        let supabase = self.supabase
        return AsyncStream { continuation in
            let task = Task {
                let channel = supabase.channel(name)
                let streams = tables.map { channel.postgresChange(AnyAction.self, table: $0, filter: .eq("room_code", value: room)) }
                let statuses = channel.statusChange
                do {
                    try await channel.subscribeWithError()
                } catch {
                    continuation.finish()
                    return
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { for await _ in statuses.resubscribed() { continuation.yield() } }
                    for stream in streams {
                        group.addTask { for await _ in stream { continuation.yield() } }
                    }
                }
                await supabase.removeChannel(channel)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 칩 경제 (docs/chip-economy.md)

    /// 하루 한 번 출근 도장 (+100, 잔액 100 미만이면 +300)
    public func dailyBonus() async throws -> Grant {
        try await supabase.rpc("daily_bonus").execute().value
    }

    /// 오늘(로컬 날짜) 누적 fresh 토큰을 보내면 아직 안 받은 만큼만 칩으로 받는다
    public func claimTokens(day: Date, fresh: Int) async throws -> Grant {
        struct Params: Encodable { let p_day: String; let p_fresh: Int }
        let d = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let iso = String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
        return try await supabase.rpc("claim_tokens", params: Params(p_day: iso, p_fresh: fresh)).execute().value
    }

    /// 429 한 건당 한 번 황금 칩
    public func claimGolden(resetsAt: Date, type: String) async throws -> Grant {
        struct Params: Encodable { let p_resets_at: String; let p_type: String }
        let params = Params(p_resets_at: resetsAt.formatted(.iso8601), p_type: type)
        return try await supabase.rpc("claim_golden", params: params).execute().value
    }

    // MARK: - 슬롯

    public func spin(amount: Int64, golden: Bool = false) async throws -> SlotResult {
        struct Params: Encodable { let p_amount: Int64; let p_golden: Bool }
        do {
            return try await supabase.rpc("slot_spin", params: Params(p_amount: amount, p_golden: golden)).execute().value
        } catch { throw LoungeError.wrap(error) }
    }

    // MARK: - 라운지 접속 / 전광판 (ADR-0008)

    /// 최근 `within`초 안의 전광판 이벤트 (오래된 것부터)
    public func recentEvents(within seconds: TimeInterval) async throws -> [LoungeEvent] {
        let since = Date().addingTimeInterval(-seconds).formatted(.iso8601)
        let rows: [LoungeEvent] = try await supabase.from("lounge_events").select()
            .gte("created_at", value: since).order("id", ascending: false).limit(10).execute().value
        return rows.reversed()
    }

    /// 라운지 전체 채널에 들어간다. 앱이 켜져 있는 동안 계속 붙어 있고,
    /// 맥이 잠들거나 앱을 끄면 Presence가 알아서 빠진다.
    /// 상태가 바뀌면 `LoungeLink.update`로 다시 알린다.
    public func joinLounge(as me: Member) -> LoungeLink {
        LoungeLink(supabase: supabase, me: me)
    }
}

/// 세션을 키체인 대신 파일로 저장 (ad-hoc 서명 앱의 키체인 프롬프트 회피, 봇 여러 개 분리)
struct FileAuthStorage: AuthLocalStorage {
    let dir: URL

    init(config: LoungeConfig, profile: String) {
        let host = "\(config.url.host ?? "server")-\(config.url.port ?? 443)"
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("429Lounge/sessions/\(host)/\(profile)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ key: String) -> URL {
        dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_"))
    }

    func store(key: String, value: Data) throws {
        try value.write(to: file(key), options: [.atomic, .completeFileProtection])
    }

    func retrieve(key: String) throws -> Data? {
        try? Data(contentsOf: file(key))
    }

    func remove(key: String) throws {
        try? FileManager.default.removeItem(at: file(key))
    }
}

/// 라운지 채널 연결. signals로 회원 목록과 전광판 이벤트를 받고, update로 내 상태를 알린다.
public final class LoungeLink: Sendable {
    public let signals: AsyncStream<LoungeSignal>
    private let channel: RealtimeChannelV2
    private let task: Task<Void, Never>
    private let latest: Latest

    /// 구독이 끝나기 전에 들어온 갱신을 잃지 않게: 마지막 상태를 들고 있다가 구독 직후 보낸다
    private actor Latest {
        var member: Member
        var subscribed = false
        init(_ m: Member) { member = m }
        func set(_ m: Member) -> Bool { member = m; return subscribed }
        func markSubscribed() -> Member { subscribed = true; return member }
        var current: Member { member }
    }

    init(supabase: SupabaseClient, me: Member) {
        let channel = supabase.channel("lounge") { $0.presence.key = me.id.uuidString }
        let latest = Latest(me)
        self.channel = channel
        self.latest = latest
        let presence = channel.presenceChange()
        let statuses = channel.statusChange
        let inserts = channel.postgresChange(InsertAction.self, table: "lounge_events")
        let (stream, continuation) = AsyncStream<LoungeSignal>.makeStream()
        signals = stream

        task = Task {
            do {
                try await channel.subscribeWithError()
                try await channel.track(await latest.markSubscribed())
            } catch {
                continuation.finish()
                return
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    var members: [String: Member] = [:]
                    for await action in presence {
                        // 재연결하면 서버가 전체 목록을 다시 보낸다 → 갈아끼운다 (끊긴 사이 나간 회원이 남지 않게)
                        if action.isFullState { members = [:] }
                        // 상태 갱신은 같은 키로 "나감 + 들어옴"이 함께 온다 → 나감부터 처리
                        for key in action.leaves.keys { members[key] = nil }
                        for (key, p) in action.joins {
                            if let m = try? p.decodeState(as: Member.self) { members[key] = m }
                        }
                        continuation.yield(.members(Array(members.values)))
                    }
                }
                group.addTask {
                    // 맥이 잠들었다 깨는 등으로 소켓이 다시 연결되면 SDK는 채널에 다시 들어가기만 하고
                    // track은 다시 보내지 않는다 → 나는 남들이 보이는데 남들 화면에선 내가 사라진다
                    for await _ in statuses.resubscribed() {
                        try? await channel.track(await latest.current)
                    }
                }
                group.addTask {
                    for await action in inserts {
                        if let e = try? action.decodeRecord(as: LoungeEvent.self, decoder: AnyJSON.decoder) {
                            continuation.yield(.event(e))
                        }
                    }
                }
            }
            await supabase.removeChannel(channel)
            continuation.finish()
        }
    }

    /// 내 상태가 바뀌었을 때 (보는 중, 위치, Claude 상태, 이름)
    public func update(_ me: Member) async {
        if await latest.set(me) { try? await channel.track(me) }
    }

    public func leave() {
        task.cancel()
    }
}

extension PresenceAction {
    /// 구독(재구독) 직후 서버가 보내는 전체 목록인지. 아니면 변화분(diff)
    var isFullState: Bool { rawMessage.event == ChannelEvent.presenceState }
}

extension AsyncStream<RealtimeChannelStatus> {
    /// 처음 구독 이후 다시 구독될 때마다 (소켓 재연결 → SDK가 채널에 다시 들어감).
    /// 구독 전에 만든 스트림이어야 처음 `.subscribed`를 건너뛸 수 있다
    func resubscribed() -> AsyncFilterSequence<AsyncFilterSequence<Self>> {
        var seen = 0
        return filter { $0 == .subscribed }.filter { _ in seen += 1; return seen > 1 }
    }
}
