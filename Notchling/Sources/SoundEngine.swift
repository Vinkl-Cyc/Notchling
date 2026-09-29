import AVFoundation

/// Preloaded short sounds (all synthesized for Notchling — see scripts/make_sounds.py).
@MainActor
final class SoundEngine {
    static let shared = SoundEngine()

    static let names = ["peek", "open", "close", "wave", "poke", "dizzy", "munch", "splash", "purr",
                        "yawn", "gulp", "think", "answer", "alert", "sad", "hatch", "pop"]

    private var players: [String: [AVAudioPlayer]] = [:]

    private init() {
        for name in Self.names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds")
                    ?? Bundle.main.url(forResource: name, withExtension: "wav") else { continue }
            var pool: [AVAudioPlayer] = []
            for _ in 0..<2 {
                if let p = try? AVAudioPlayer(contentsOf: url) {
                    p.prepareToPlay()
                    pool.append(p)
                }
            }
            if !pool.isEmpty { players[name] = pool }
        }
    }

    func play(_ name: String) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Pref.soundOn), let pool = players[name] else { return }
        let player = pool.first { !$0.isPlaying } ?? pool[0]
        player.volume = Float(defaults.double(forKey: Pref.volume))
        player.currentTime = 0
        player.play()
    }
}
