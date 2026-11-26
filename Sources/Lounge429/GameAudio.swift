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
    /// 429 드롭 소리 (핀·착지가 틱마다 여러 번 겹쳐 울린다)
    private let drop = DropAudio()
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
            drop.stopAll()
        }
        updateAmbience()
        updateMotor()
    }

    private func stopEffects() {
        for effect in Effect.allCases { players[effect.rawValue]?.stop() }
        drop.stopAll()
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

    /// 429 드롭 화면에 들어갈 때: 오디오 엔진을 켜고 소리 파일을 미리 읽는다 (첫 소리에 화면이 멈칫하지 않게)
    func warmPlinko() {
        guard enabled, visible else { return }
        drop.warm(["dropCharge", "dropLaunch", "dropGood", "dropPerfect", "dropGold", "dropSplit", "dropLand", "win", "bigWin",
                   "dropMax", "dropPocket", "reel", "dropReach", "dropFever", "push"] + (0..<12).map { "dropPin\($0)" })
    }

    /// 429 드롭 소리. 소리 끄기·창 닫기면 아무것도 안 낸다 (충전음 루프는 `refreshPlayback`이 끊는다)
    func plinko(_ sound: PlinkoSound) {
        guard enabled, visible else { return }
        func pan(_ x: Int) -> Float { Float(max(-1, min(1, Double(x - PlinkoTable.cx) / Double(PlinkoTable.cx)))) }
        switch sound {
        case .chargeStart: drop.chargeStart()
        case .chargeLevel(let power): drop.chargeRate(Float(0.45 + 1.55 * Double(power) / 1000))
        case .chargeStop: drop.chargeStop()
        case .launch: drop.play("dropLaunch")
        case .good: drop.play("dropGood")
        case .perfect: drop.play("dropPerfect")
        case .pin(let row, let x): drop.play("dropPin\(min(11, max(0, row)))", pan: pan(x))
        case .gold(let x): drop.play("dropGold", pan: pan(x))
        case .split: drop.play("dropSplit")
        case .lose(let x): drop.play("dropLand", pan: pan(x))
        case .win(_, let x): drop.play("win", pan: pan(x))
        case .big: drop.play("bigWin")
        case .max: drop.play("dropMax")
        case .pocket: drop.play("dropPocket")
        case .reelTick: break
        case .reelStop: drop.play("reel")
        case .reach: drop.play("dropReach")
        case .fever: drop.play("dropFever")
        case .refund: drop.play("push")
        }
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

/// 429 드롭 소리: `AVAudioEngine` 한 대에 미리 읽어 둔 버퍼를 목소리 8개로 돌려 쓴다.
/// `AVAudioPlayer`의 stop·play는 부를 때마다 메인 스레드를 수 ms씩 막아서, 틱(60ms)마다 핀 소리가 여러 번 나면
/// 틱이 100ms 넘게 밀려 공이 버벅였다. 플레이어 노드에 버퍼를 예약하는 건 거의 막지 않는다.
@MainActor
final class DropAudio {
    private static let voiceCount = 8
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private let engine = AVAudioEngine()
    private var voices: [AVAudioPlayerNode] = []
    private var next = 0
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private let chargeNode = AVAudioPlayerNode()
    private let chargeSpeed = AVAudioUnitVarispeed()
    private var built = false

    private func ready() -> Bool {
        if !built {
            built = true
            for _ in 0..<Self.voiceCount {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: Self.format)
                voices.append(node)
            }
            engine.attach(chargeNode)
            engine.attach(chargeSpeed)
            engine.connect(chargeNode, to: chargeSpeed, format: Self.format)
            engine.connect(chargeSpeed, to: engine.mainMixerNode, format: Self.format)
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        // 노드는 늘 재생 중으로 둔다. 버퍼가 없으면 무음이고, 새 버퍼는 `.interrupts`로 바로 끼워 넣는다
        // (`stop()`은 오디오 스레드를 기다리느라 부를 때마다 수 ms씩 막는다)
        for v in voices where !v.isPlaying { v.play() }
        if !chargeNode.isPlaying { chargeNode.play() }
        return true
    }

    /// wav를 한 번 읽어 엔진 형식(44.1kHz 모노 float)으로 바꿔 둔다
    private func buffer(_ name: String) -> AVAudioPCMBuffer? {
        if let b = buffers[name] { return b }
        guard let url = LoungeResources.bundle.url(forResource: name, withExtension: "wav", subdirectory: "Sounds"),
              let file = try? AVAudioFile(forReading: url),
              let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: raw)) != nil else { return nil }
        let out: AVAudioPCMBuffer
        if raw.format == Self.format {
            out = raw
        } else {
            guard let converter = AVAudioConverter(from: raw.format, to: Self.format),
                  let converted = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(
                      Double(raw.frameLength) * Self.format.sampleRate / raw.format.sampleRate) + 64) else { return nil }
            let feed = Feed(raw)
            converter.convert(to: converted, error: nil) { _, status in
                if feed.done { status.pointee = .endOfStream; return nil }
                feed.done = true
                status.pointee = .haveData
                return feed.buffer
            }
            out = converted
        }
        buffers[name] = out
        return out
    }

    /// 변환기에 원본 버퍼를 한 번만 넘기기 위한 상자 (변환은 그 자리에서 동기로 끝난다)
    private final class Feed: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var done = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    func warm(_ names: [String]) {
        guard ready() else { return }
        for n in names { _ = buffer(n) }
    }

    func play(_ name: String, volume: Float = 1, pan: Float = 0) {
        guard ready(), let b = buffer(name) else { return }
        let node = voices[next]
        next = (next + 1) % voices.count
        node.volume = volume
        node.pan = pan
        node.scheduleBuffer(b, at: nil, options: .interrupts)
    }

    func chargeStart() {
        guard ready(), let b = buffer("dropCharge") else { return }
        chargeNode.volume = 0.8
        chargeSpeed.rate = 0.45
        chargeNode.scheduleBuffer(b, at: nil, options: [.loops, .interrupts])
    }

    func chargeRate(_ rate: Float) {
        guard built else { return }
        chargeSpeed.rate = max(0.25, min(4, rate))
    }

    /// 루프를 멈춘다: 볼륨을 끄고 무음 버퍼로 바꿔 끼운다 (`stop()` 대신)
    func chargeStop() {
        guard built else { return }
        chargeNode.volume = 0
        if let silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 1) {
            silence.frameLength = 1
            chargeNode.scheduleBuffer(silence, at: nil, options: .interrupts)
        }
    }

    /// 소리 끄기·창 닫기: 드물게 불리니 확실히 멈춘다
    func stopAll() {
        guard built else { return }
        for v in voices { v.stop() }
        chargeNode.stop()
        engine.pause()
    }
}
