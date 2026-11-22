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
    enum Effect: String, CaseIterable { case lever, reel, card, win, bigWin, jackpot, hit, stand, chips, bust, natural, collect, push }

    private var visible = false
    private var room = Room.lounge
    private var since = Date()
    private var reelsTurning = 0
    private var players: [String: AVAudioPlayer] = [:]
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
        }
        updateAmbience()
        updateMotor()
    }

    private func stopEffects() {
        for effect in Effect.allCases { players[effect.rawValue]?.stop() }
        setReelsTurning(0)
    }

    private func player(_ name: String, extension ext: String = "wav") -> AVAudioPlayer? {
        if let existing = players[name] { return existing }
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Sounds"),
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

    func play(_ effect: Effect, at time: Date?, volume: Float = 1) {
        guard enabled, visible, let time, time >= since,
              Date().timeIntervalSince(time) < 0.2, let sound = player(effect.rawValue) else { return }
        sound.currentTime = 0
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
