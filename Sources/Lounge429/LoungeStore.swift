import Foundation
import LoungeCore
import LoungeNet
import Observation

@MainActor @Observable
final class LoungeStore {
    struct Toast: Equatable {
        let text: String
        let golden: Bool
        let at: Date
    }

    private(set) var snapshot = UsageSnapshot()
    private(set) var lastScan: Date?
    /// 서버 지갑. 연결 전/오프라인이면 nil.
    private(set) var me: Player?
    private(set) var netError: String?
    /// 칩이 들어왔을 때 잠깐 보여주는 알림
    private(set) var toast: Toast?

    let net = LoungeClient()
    private let scanner = UsageScanner()

    /// 개발용: LOUNGE_FAKE_429=1 이면 가짜 429 상태. 실제 로그처럼 리셋 시각이 고정돼야
    /// 재실행해도 황금 칩이 중복 지급되지 않으므로 "2시간 뒤 정각"으로 맞춘다.
    private static let fakeLock: RateLimitHit? = {
        guard ProcessInfo.processInfo.environment["LOUNGE_FAKE_429"] != nil else { return nil }
        let hour: TimeInterval = 3600
        let reset = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 / hour).rounded(.down) * hour + 2 * hour)
        return RateLimitHit(hitAt: .now, resetsAt: reset, type: "five_hour")
    }()

    init(live: Bool = true) {
        guard live else { return }
        Task {
            await connect()
            await poll()
        }
    }

    var chips: Int { Int(me?.chips ?? 0) }
    func golden(at now: Date = .now) -> Int { me?.golden(at: now) ?? 0 }

    func refresh() async {
        let scanner = self.scanner
        var s = await Task.detached(priority: .utility) { scanner.scan() }.value
        if let fake = Self.fakeLock { s.lastLimitHit = fake }
        snapshot = s
        lastScan = .now
        await claim()
    }

    func connect() async {
        do {
            me = try await net.signIn()
            netError = nil
        } catch {
            netError = "라운지 서버에 연결할 수 없어요"
            return
        }
        if let g = try? await net.dailyBonus() {
            apply(g, g.granted >= 300 ? "파산 구제 +\(g.granted)칩" : "출근 도장 +\(g.granted)칩")
        }
        await claim()
    }

    /// 로그에서 읽은 토큰/429를 서버에 보내서 칩으로 받는다 (서버가 차액만 지급하므로 자주 불러도 안전)
    private func claim() async {
        guard me != nil else { return }
        let s = snapshot
        if lastScan != nil, let g = try? await net.claimTokens(day: .now, fresh: s.today.fresh) {
            apply(g, "토큰 환전 +\(g.granted.formatted(.number))칩")
        }
        if let lock = s.activeLock(), let g = try? await net.claimGolden(resetsAt: lock.resetsAt, type: lock.type) {
            apply(g, "429! 황금 칩 +\(g.granted)", golden: true)
        }
    }

    private func apply(_ grant: Grant, _ message: String, golden: Bool = false) {
        me = grant.player
        guard grant.granted > 0 else { return }
        let t = Toast(text: message, golden: golden, at: .now)
        toast = t
        Task {
            try? await Task.sleep(for: .seconds(5))
            if toast == t { toast = nil }
        }
    }

    /// 닉네임 저장. 실패하면 보여줄 문구
    func rename(_ name: String) async -> String? {
        do {
            me = try await net.setNickname(name)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshMe() async {
        guard me != nil, let fresh = try? await net.me() else { return }
        me = fresh
    }

    func update(_ player: Player) {
        if player.id == me?.id { me = player }
    }

    /// 스냅샷/프리뷰용
    func preview(me: Player, snapshot: UsageSnapshot, toast: String? = nil) {
        self.me = me
        self.snapshot = snapshot
        self.toast = toast.map { Toast(text: $0, golden: snapshot.activeLock() != nil, at: .now) }
    }

    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(30))
        }
    }
}
