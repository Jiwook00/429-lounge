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
        case .server("already_bet"): "이번 판엔 이미 걸었어요"
        case .server("insufficient_chips"): "칩이 부족해요"
        case .server("invalid_amount"): "베팅 금액이 이상해요"
        case .server("no_golden"): "쓸 수 있는 황금 칩이 없어요"
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

    /// 익명 로그인(세션이 없거나 만료됐으면) + 플레이어 행 보장
    public func signIn(name: String) async throws -> Player {
        if (try? await supabase.auth.session) == nil {
            _ = try await supabase.auth.signInAnonymously()
        }
        do {
            return try await ensurePlayer(name)
        } catch {
            // 로컬 DB를 리셋하면 저장된 세션의 유저가 사라진다 → 새로 가입
            try? await supabase.auth.signOut()
            _ = try await supabase.auth.signInAnonymously()
            return try await ensurePlayer(name)
        }
    }

    private func ensurePlayer(_ name: String) async throws -> Player {
        try await supabase.rpc("ensure_player", params: ["p_name": name]).execute().value
    }

    public func me() async throws -> Player? {
        guard let id = userID else { return nil }
        return try await supabase.from("players").select().eq("id", value: id).single().execute().value
    }

    public func players(_ ids: [UUID]) async throws -> [Player] {
        guard !ids.isEmpty else { return [] }
        return try await supabase.from("players").select().in("id", values: ids).execute().value
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

    // MARK: - 홀짝

    public func tick(room: String) async throws -> Round {
        do {
            return try await supabase.rpc("oddeven_tick", params: ["p_room": room]).execute().value
        } catch { throw LoungeError.wrap(error) }
    }

    public func bet(room: String, side: Side, amount: Int64, golden: Bool = false) async throws -> Bet {
        struct Params: Encodable { let p_room: String; let p_side: String; let p_amount: Int64; let p_golden: Bool }
        do {
            return try await supabase
                .rpc("oddeven_bet", params: Params(p_room: room, p_side: side.rawValue, p_amount: amount, p_golden: golden))
                .execute().value
        } catch { throw LoungeError.wrap(error) }
    }

    public func bets(roundID: Int64) async throws -> [Bet] {
        try await supabase.from("oddeven_bets").select().eq("round_id", value: Int(roundID))
            .order("created_at").execute().value
    }

    /// 방의 가장 최근 정산된 라운드
    public func lastSettled(room: String) async throws -> Round? {
        let rows: [Round] = try await supabase.from("oddeven_rounds").select()
            .eq("room_code", value: room).not("settled_at", operator: .is, value: "null")
            .order("id", ascending: false).limit(1).execute().value
        return rows.first
    }

    /// 테이블 실시간 이벤트: 라운드/베팅 변경, 칩 변동, 착석자(Presence).
    /// 스트림을 끝내면(구독 Task 취소) 채널도 정리된다.
    public func tableEvents(room: String, seat: Seat) -> AsyncStream<TableEvent> {
        let supabase = self.supabase
        return AsyncStream { continuation in
            let task = Task {
                let channel = supabase.channel("oddeven:\(room)") { $0.presence.key = seat.id.uuidString }
                let rounds = channel.postgresChange(AnyAction.self, table: "oddeven_rounds", filter: .eq("room_code", value: room))
                let bets = channel.postgresChange(AnyAction.self, table: "oddeven_bets", filter: .eq("room_code", value: room))
                let players = channel.postgresChange(UpdateAction.self, table: "players")
                let presence = channel.presenceChange()

                do {
                    try await channel.subscribeWithError()
                    try await channel.track(seat)
                } catch {
                    continuation.finish()
                    return
                }

                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await action in rounds {
                            if let r: Round = action.decoded() { continuation.yield(.round(r)) }
                        }
                    }
                    group.addTask {
                        for await action in bets {
                            if let b: Bet = action.decoded() { continuation.yield(.bet(b)) }
                        }
                    }
                    group.addTask {
                        for await action in players {
                            if let p = try? action.decodeRecord(as: Player.self, decoder: AnyJSON.decoder) {
                                continuation.yield(.player(p))
                            }
                        }
                    }
                    group.addTask {
                        var seats: [String: Seat] = [:]
                        for await action in presence {
                            for (key, p) in action.joins {
                                if let s = try? p.decodeState(as: Seat.self) { seats[key] = s }
                            }
                            for key in action.leaves.keys { seats[key] = nil }
                            continuation.yield(.seats(seats.values.sorted { $0.name < $1.name }))
                        }
                    }
                }
                await supabase.removeChannel(channel)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension AnyAction {
    func decoded<T: Decodable>() -> T? {
        switch self {
        case .insert(let a): try? a.decodeRecord(as: T.self, decoder: AnyJSON.decoder)
        case .update(let a): try? a.decodeRecord(as: T.self, decoder: AnyJSON.decoder)
        case .delete: nil
        }
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
