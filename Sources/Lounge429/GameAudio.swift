import AppKit
import SwiftUI

@MainActor @Observable
final class GameAudio {
    static let shared = GameAudio()
    var enabled = UserDefaults.standard.bool(forKey: "gameEffectsEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "gameEffectsEnabled")
            reset()
        }
    }
    private var visible = false
    private var since = Date()
    private var sounds: [Effect: NSSound] = [:]

    enum Effect: String { case reel, card, win, jackpot }

    func setVisible(_ value: Bool) {
        visible = value
        reset()
    }

    func reset() {
        since = .now
        for sound in sounds.values { sound.stop() }
    }

    func play(_ effect: Effect, at time: Date?) {
        guard enabled, visible, let time, time >= since,
              Date().timeIntervalSince(time) < 0.15 else { return }
        if sounds[effect] == nil,
           let url = Bundle.module.url(forResource: effect.rawValue, withExtension: "wav", subdirectory: "Sounds") {
            sounds[effect] = NSSound(contentsOf: url, byReference: false)
        }
        sounds[effect]?.stop()
        sounds[effect]?.play()
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
        .accessibilityLabel(audio.enabled ? "효과음 끄기" : "효과음 켜기")
        .help(audio.enabled ? "효과음 끄기" : "효과음 켜기")
    }
}
