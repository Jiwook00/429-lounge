import AVFAudio
import SwiftUI

@MainActor @Observable
final class GameAudio {
    static let shared = GameAudio()
    var enabled = UserDefaults.standard.bool(forKey: "gameEffectsEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "gameEffectsEnabled")
            refreshPlayback()
        }
    }
    var backgroundEnabled = UserDefaults.standard.object(forKey: "gameAmbienceEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(backgroundEnabled, forKey: "gameAmbienceEnabled")
            updateAmbience()
        }
    }

    var musicVolume = min(1, max(0, UserDefaults.standard.object(forKey: "loungeMusicVolume") as? Double ?? 1)) {
        didSet {
            UserDefaults.standard.set(musicVolume, forKey: "loungeMusicVolume")
            guard enabled, visible, backgroundEnabled else { return }
            players[musicName]?.setVolume(musicLevel, fadeDuration: 0.04)
        }
    }

    private var musicName: String { "bgm" + track.rawValue }
    private var musicLevel: Float { Float(musicVolume) * (room == .lounge ? 1 : 0.75) }

    enum Track: String, CaseIterable {
        case veranda = "21", pixel = "24", pending = "27", lowball = "22"

        var title: String {
            switch self {
            case .veranda: "Neon Veranda"
            case .pixel: "One Pixel to Midnight"
            case .pending: "Build Pending"
            case .lowball: "Ice in the Lowball"
            }
        }
    }

    var track = Track(rawValue: UserDefaults.standard.string(forKey: "loungeMusicTrack") ?? "") ?? .veranda {
        didSet {
            UserDefaults.standard.set(track.rawValue, forKey: "loungeMusicTrack")
            updateAmbience()
        }
    }

    enum Room: String {
        case lounge, floor = "slotRoom", felt = "cardRoom", marbles = "marbleRoom", ballot = "ballotRoom"
    }
    enum Effect: String, CaseIterable { case rouletteTick, rouletteLand, rouletteClose, rouletteReject, betChip, yourTurn, lever, reel, card, win, bigWin, jackpot, hit, stand, chips, bust, natural, collect, push }

    private var visible = false
    private var room = Room.lounge
    private var since = Date()
    private var reelsTurning = 0
    private var players: [String: AVAudioPlayer] = [:]
    /// 한꺼번에 여러 번 겹쳐 울려야 하는 소리(429 드롭의 핀·착지): 이름마다 플레이어 4개를 돌려 쓴다
    private var pools: [String: (players: [AVAudioPlayer], next: Int)] = [:]
    private static let poolSize = 4
    private var fadeTask: Task<Void, Never>?

    func enter(_ next: Room) {
        since = .now
        stopEffects()
        room = next
        updateAmbience()
    }

    func setVisible(_ value: Bool) {
        visible = value
        refreshPlayback()
    }

    private func refreshPlayback() {
        since = .now
        if !enabled || !visible {
            fadeTask?.cancel()
            for player in players.values { player.stop() }
            stopPools()
        }
        updateAmbience()
        updateMotor()
    }

    private func stopEffects() {
        for effect in Effect.allCases { players[effect.rawValue]?.stop() }
        stopPools()
        players["dropCharge"]?.stop()
        setReelsTurning(0)
    }

    private func player(_ name: String, extension ext: String = "wav") -> AVAudioPlayer? {
        if let existing = players[name] { return existing }
        guard let url = LoungeResources.bundle.url(forResource: name, withExtension: ext, subdirectory: "Sounds"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        players[name] = player
        return player
    }

    private func updateAmbience() {
        fadeTask?.cancel()
        let audible = enabled && visible && backgroundEnabled
        var levels: [String: Float] = [:]
        if audible {
            levels[musicName] = musicLevel
            if room != .lounge { levels[room.rawValue] = 1 }
        }
        let retiring = players.filter { name, sound in
            sound.numberOfLoops == -1 && name != "motor" && levels[name] == nil && sound.isPlaying
        }.map(\.value)
        for old in retiring {
            if audible { old.setVolume(0, fadeDuration: 0.35) } else { old.stop() }
        }
        for (name, level) in levels {
            guard let loop = player(name, extension: "m4a") else { continue }
            if !loop.isPlaying {
                loop.currentTime = 0
                loop.numberOfLoops = -1
                loop.volume = 0
                loop.play()
            }
            loop.setVolume(level, fadeDuration: 0.35)
        }
        guard audible, !retiring.isEmpty else { return }
        fadeTask = Task {
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            for old in retiring { old.stop() }
        }
    }

    func setReelsTurning(_ count: Int) {
        reelsTurning = count
        updateMotor()
    }

    private func updateMotor() {
        guard enabled, visible, room == .floor, reelsTurning > 0 else {
            players["motor"]?.stop()
            return
        }
        guard let motor = player("motor") else { return }
        if !motor.isPlaying {
            motor.currentTime = 0
            motor.numberOfLoops = -1
            motor.volume = 0
            motor.play()
        }
        motor.setVolume(Float(reelsTurning) / 3, fadeDuration: 0.09)
    }

    private func stopPools() {
        for pool in pools.values { for p in pool.players { p.stop() } }
        players["dropCharge"]?.stop()
    }

    /// 풀에서 다음 플레이어를 꺼낸다 (처음엔 4개까지 만든다). 뒤늦게 쓰는 플레이어가 앞 소리를 끊는다
    private func pooled(_ name: String) -> AVAudioPlayer? {
        var pool = pools[name] ?? ([], 0)
        let player: AVAudioPlayer
        if pool.players.count < Self.poolSize {
            guard let url = LoungeResources.bundle.url(forResource: name, withExtension: "wav", subdirectory: "Sounds"),
                  let made = try? AVAudioPlayer(contentsOf: url) else { return nil }
            made.enableRate = true
            made.prepareToPlay()
            pool.players.append(made)
            player = made
        } else {
            player = pool.players[pool.next % Self.poolSize]
        }
        pool.next = (pool.next + 1) % Self.poolSize
        pools[name] = pool
        return player
    }

    private func fire(_ name: String, volume: Float = 1, pan: Float = 0, rate: Float = 1) {
        guard let sound = pooled(name) else { return }
        sound.stop()
        sound.currentTime = 0
        sound.pan = pan
        sound.volume = volume
        sound.rate = rate
        sound.play()
    }

    /// 429 드롭 소리. 소리 끄기·창 닫기면 아무것도 안 낸다 (충전음 루프는 `refreshPlayback`이 끊는다)
    func plinko(_ sound: PlinkoSound) {
        guard enabled, visible else { return }
        func pan(_ x: Int) -> Float { Float(max(-1, min(1, Double(x - PlinkoTable.cx) / Double(PlinkoTable.cx)))) }
        switch sound {
        case .chargeStart:
            guard let loop = chargeLoop() else { return }
            loop.currentTime = 0
            loop.rate = 0.45
            loop.volume = 0.8
            loop.numberOfLoops = -1
            loop.play()
        case .chargeLevel(let power):
            players["dropCharge"]?.rate = Float(0.45 + 1.55 * Double(power) / 1000)
        case .chargeStop: players["dropCharge"]?.stop()
        case .launch: fire("dropLaunch")
        case .good: fire("dropGood")
        case .perfect: fire("dropPerfect")
        case .pin(let row, let x): fire("dropPin\(min(11, max(0, row)))", pan: pan(x))
        case .gold(let x): fire("dropGold", pan: pan(x))
        case .split: fire("dropSplit")
        case .lose(let x): fire("dropLand", pan: pan(x))
        case .win(let mult, let x): fire("win", pan: pan(x), rate: mult >= 1.8 ? 1.26 : mult >= 1.3 ? 1.12 : 1)
        case .big: fire("bigWin")
        case .max: fire("dropMax")
        case .pocket: fire("dropPocket")
        case .reelTick: break
        case .reelStop: fire("reel")
        case .reach: fire("dropReach")
        case .fever: fire("dropFever")
        case .refund: fire("push")
        }
    }

    private func chargeLoop() -> AVAudioPlayer? {
        if let existing = players["dropCharge"] { return existing }
        guard let url = LoungeResources.bundle.url(forResource: "dropCharge", withExtension: "wav", subdirectory: "Sounds"),
              let made = try? AVAudioPlayer(contentsOf: url) else { return nil }
        made.enableRate = true
        made.prepareToPlay()
        players["dropCharge"] = made
        return made
    }

    func play(_ effect: Effect, at time: Date?, volume: Float = 1, pan: Float = 0) {
        guard enabled, visible, let time, time >= since,
              Date().timeIntervalSince(time) < 0.2, let sound = player(effect.rawValue) else { return }
        sound.currentTime = 0
        sound.pan = pan
        sound.volume = volume
        sound.play()
    }
}

struct GameSoundButton: View {
    private let audio = GameAudio.shared
    var body: some View {
        Button { audio.enabled.toggle() } label: {
            Image(systemName: audio.enabled ? "speaker.wave.2" : "speaker.slash")
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(audio.enabled ? Theme.cream : Theme.muted)
        .accessibilityLabel(audio.enabled ? "게임 소리 끄기" : "게임 소리 켜기")
        .help(audio.enabled ? "게임 소리 끄기" : "게임 소리 켜기")
    }
}
