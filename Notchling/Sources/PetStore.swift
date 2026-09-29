import Foundation
import SwiftUI
import QuartzCore

// MARK: - Types

enum PetStage: String {
    case egg, baby, kid, teen, adult

    var label: String {
        switch self {
        case .egg: return "Egg"
        case .baby: return "Baby"
        case .kid: return "Kid"
        case .teen: return "Teen"
        case .adult: return "Grown-up"
        }
    }
}

enum Reaction: String {
    case none, eat, snack, bath, pat, poke, dizzy, happy, hatch, wave, medicine, sad, yawn, refuse
}

enum Mood: String {
    case egg, asleep, sick, hungry, dirty, sleepy, sad, happy, content, gone

    var summary: String {
        switch self {
        case .egg: return "still inside the egg"
        case .asleep: return "sleeping"
        case .sick: return "feeling sick"
        case .hungry: return "very hungry"
        case .dirty: return "feeling grubby and wants a bath"
        case .sleepy: return "very sleepy"
        case .sad: return "a bit lonely and sad"
        case .happy: return "happy and bouncy"
        case .content: return "content"
        case .gone: return "gone"
        }
    }

    var icon: String {
        switch self {
        case .egg: return "🥚"
        case .asleep: return "💤"
        case .sick: return "🤒"
        case .hungry: return "🍙"
        case .dirty: return "🛁"
        case .sleepy: return "🥱"
        case .sad: return "🥺"
        case .happy: return "💚"
        case .content: return "🌱"
        case .gone: return "💌"
        }
    }
}

// MARK: - Saved data

struct PetData: Codable {
    var name: String = "Pip"
    var born: Date = Date()
    var hatchedAt: Date? = nil
    var fullness: Double = 70
    var hygiene: Double = 95
    var happiness: Double = 75
    var energy: Double = 85
    var health: Double = 100
    var isAsleep: Bool = false
    var poops: Int = 0
    var nextPoopAt: Date? = nil
    var lastUpdate: Date = Date()
    var questionsAnswered: Int = 0
    var ranAway: Bool = false
    var generation: Int = 1
    var hatchBonus: Double = 0   // seconds shaved off hatching by warming the egg

    init() {}

    // Tolerant decoding so adding fields in future versions never wipes the pet.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PetData.fresh
        name = (try? c.decode(String.self, forKey: .name)) ?? d.name
        born = (try? c.decode(Date.self, forKey: .born)) ?? d.born
        hatchedAt = try? c.decode(Date.self, forKey: .hatchedAt)
        fullness = (try? c.decode(Double.self, forKey: .fullness)) ?? d.fullness
        hygiene = (try? c.decode(Double.self, forKey: .hygiene)) ?? d.hygiene
        happiness = (try? c.decode(Double.self, forKey: .happiness)) ?? d.happiness
        energy = (try? c.decode(Double.self, forKey: .energy)) ?? d.energy
        health = (try? c.decode(Double.self, forKey: .health)) ?? d.health
        isAsleep = (try? c.decode(Bool.self, forKey: .isAsleep)) ?? false
        poops = (try? c.decode(Int.self, forKey: .poops)) ?? 0
        nextPoopAt = try? c.decode(Date.self, forKey: .nextPoopAt)
        lastUpdate = (try? c.decode(Date.self, forKey: .lastUpdate)) ?? Date()
        questionsAnswered = (try? c.decode(Int.self, forKey: .questionsAnswered)) ?? 0
        ranAway = (try? c.decode(Bool.self, forKey: .ranAway)) ?? false
        generation = (try? c.decode(Int.self, forKey: .generation)) ?? 1
        hatchBonus = (try? c.decode(Double.self, forKey: .hatchBonus)) ?? 0
    }

    static var fresh: PetData { PetData() }
}

// MARK: - Pet store

@MainActor
final class PetStore: ObservableObject {
    static let shared = PetStore()

    @Published var pet: PetData
    @Published private(set) var reaction: Reaction = .none
    @Published private(set) var reactionEmoji: String = ""
    @Published private(set) var speech: String? = nil
    @Published var isThinking = false
    @Published var expectingFile = false

    /// CACurrentMediaTime() when the current reaction started.
    private(set) var reactionStart: Double = 0
    private(set) var speechUntil: Date = .distantPast

    /// Called when the pet wants attention (controller peeks out of the notch).
    var onAlert: (() -> Void)?

    static let hatchSeconds: Double = 45

    private var tickTimer: Timer?
    private var reactionClear: Task<Void, Never>?
    private var speechClear: Task<Void, Never>?
    private var lastAlert: [String: Date] = [:]
    private var snackTimes: [Date] = []
    private var pokeTimes: [Double] = []
    private var lastPat: Double = 0

    private static var saveURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Notchling", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pet.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.saveURL),
           let saved = try? JSONDecoder().decode(PetData.self, from: data) {
            pet = saved
        } else {
            pet = PetData()
        }
    }

    // MARK: Lifecycle

    func start() {
        // Catch up on time passed while the app was closed (gentler than live decay).
        let hours = min(24, max(0, Date().timeIntervalSince(pet.lastUpdate) / 3600))
        if hours > 0.02 { applyDecay(hours: hours, offline: true) }
        pet.lastUpdate = Date()
        save()

        let timer = Timer(timeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { PetStore.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        tick()
    }

    func save() {
        if let data = try? JSONEncoder().encode(pet) {
            try? data.write(to: Self.saveURL, options: .atomic)
        }
    }

    // MARK: Derived state

    var stage: PetStage {
        guard let hatched = pet.hatchedAt else { return .egg }
        let days = Date().timeIntervalSince(hatched) / 86_400
        if days < 1 { return .baby }
        if days < 3 { return .kid }
        if days < 7 { return .teen }
        return .adult
    }

    var isSick: Bool { pet.health < 40 }

    var mood: Mood {
        if pet.ranAway { return .gone }
        if stage == .egg { return .egg }
        if pet.isAsleep { return .asleep }
        if isSick { return .sick }
        if pet.fullness < 25 { return .hungry }
        if pet.hygiene < 25 || pet.poops >= 2 { return .dirty }
        if pet.energy < 20 { return .sleepy }
        if pet.happiness < 30 { return .sad }
        if pet.happiness > 70 && pet.fullness > 50 { return .happy }
        return .content
    }

    var ageText: String {
        guard let hatched = pet.hatchedAt else {
            let left = max(0, Self.hatchSeconds - pet.hatchBonus - Date().timeIntervalSince(pet.born))
            return left > 0 ? "hatching in \(Int(left))s" : "hatching…"
        }
        let s = Date().timeIntervalSince(hatched)
        if s < 3600 { return "\(max(1, Int(s / 60)))m old" }
        if s < 86_400 { return "\(Int(s / 3600))h old" }
        return "\(Int(s / 86_400))d old"
    }

    var statusLine: String {
        if let speech { return speech }
        switch mood {
        case .egg: return "Something is wiggling inside…"
        case .gone: return "\(pet.name) left a note."
        default: return "\(pet.name) is \(mood.summary)."
        }
    }

    /// Short description used to give the chat its personality.
    var personaForChat: String {
        let voice: String
        switch stage {
        case .egg, .baby: voice = "You're a newly hatched baby: sweet, simple words, the odd happy \"pip!\"."
        case .kid: voice = "You're a curious kid pet: playful and enthusiastic."
        case .teen: voice = "You're a teenage pet: witty, a little sassy, still kind."
        case .adult: voice = "You're a grown-up pet: warm, calm and articulate."
        }
        var needs: [String] = []
        if pet.fullness < 30 { needs.append("hungry") }
        if pet.hygiene < 30 { needs.append("in need of a bath") }
        if pet.energy < 25 { needs.append("sleepy") }
        if isSick { needs.append("a little sick") }
        let needText = needs.isEmpty ? "" : " Right now you're \(needs.joined(separator: ", ")) — you may mention it briefly and cutely, once."
        return "Your name is \(pet.name). You are \(mood.summary). \(voice)\(needText)"
    }

    // MARK: Tick & decay

    func tick() {
        let now = Date()
        let hours = now.timeIntervalSince(pet.lastUpdate) / 3600
        pet.lastUpdate = now

        if pet.ranAway { return }

        if pet.hatchedAt == nil {
            if now.timeIntervalSince(pet.born) + pet.hatchBonus >= Self.hatchSeconds { hatch() }
            save()
            return
        }

        applyDecay(hours: hours, offline: false)

        // Poop
        if let due = pet.nextPoopAt, now >= due {
            pet.nextPoopAt = nil
            if pet.poops < 3 {
                pet.poops += 1
                say("Oops… 💩", seconds: 5)
                alertOnce("poop", minutes: 30)
            }
        }

        // Auto sleep / wake
        if !pet.isAsleep && pet.energy < 8 {
            pet.isAsleep = true
            say("So… sleepy… 💤", seconds: 5)
        } else if pet.isAsleep && pet.energy >= 100 {
            pet.isAsleep = false
            react(.wave, seconds: 1.6)
            say("Good morning! ☀️", seconds: 5)
            SoundEngine.shared.play("wave")
            alertOnce("wake", minutes: 60)
        }

        // Needs
        if !pet.isAsleep {
            if pet.fullness < 20 { alertOnce("food", minutes: 45, saying: "I'm so hungry… 🍙") }
            else if pet.hygiene < 20 { alertOnce("bath", minutes: 60, saying: "I feel grubby… bath? 🛁") }
            else if isSick { alertOnce("sick", minutes: 45, saying: "I don't feel so good… 💊") }
            else if pet.happiness < 20 { alertOnce("love", minutes: 60, saying: "Pat me? I'm lonely 🥺") }
        }

        if pet.health <= 0 {
            pet.ranAway = true
            pet.isAsleep = false
            SoundEngine.shared.play("sad")
            speech = nil
            alertOnce("gone", minutes: 600)
        }
        save()
    }

    private func applyDecay(hours: Double, offline: Bool) {
        guard hours > 0, pet.hatchedAt != nil, !pet.ranAway else { return }
        let k = offline ? 0.5 : 1.0
        var p = pet
        if p.isAsleep {
            p.fullness -= 2.5 * hours * k
            p.hygiene -= 1.5 * hours * k
            p.energy += 20 * hours
        } else {
            p.fullness -= 5 * hours * k
            p.hygiene -= (3 + Double(p.poops) * 4) * hours * k
            p.happiness -= (4 + Double(p.poops) * 2) * hours * k
            p.energy -= 4 * hours * k
        }
        var healthDelta = 0.0
        if p.fullness < 15 { healthDelta -= 6 }
        if p.hygiene < 15 { healthDelta -= 4 }
        if p.happiness < 10 { healthDelta -= 3 }
        if healthDelta == 0 && p.fullness > 50 && p.hygiene > 50 { healthDelta = 3 }
        p.health += healthDelta * hours * k

        p.fullness = clamp(p.fullness); p.hygiene = clamp(p.hygiene)
        p.happiness = clamp(p.happiness); p.energy = clamp(p.energy)
        // The pet never runs away while the Mac was off.
        p.health = offline ? max(15, clamp(p.health)) : clamp(p.health)
        pet = p
    }

    private func clamp(_ v: Double) -> Double { min(100, max(0, v)) }

    private func alertOnce(_ key: String, minutes: Double, saying text: String? = nil) {
        let now = Date()
        if let last = lastAlert[key], now.timeIntervalSince(last) < minutes * 60 { return }
        lastAlert[key] = now
        if let text { say(text, seconds: 6) }
        SoundEngine.shared.play("alert")
        onAlert?()
    }

    // MARK: Reactions & speech

    func react(_ r: Reaction, emoji: String = "", seconds: Double = 1.4) {
        reaction = r
        reactionEmoji = emoji
        reactionStart = CACurrentMediaTime()
        reactionClear?.cancel()
        reactionClear = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self.reaction = .none; self.reactionEmoji = "" }
        }
    }

    func say(_ text: String, seconds: Double = 4) {
        speech = text
        speechUntil = Date().addingTimeInterval(seconds)
        speechClear?.cancel()
        speechClear = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self.speech = nil }
        }
    }

    // MARK: Care actions

    private func guardAwake(_ action: String) -> Bool {
        if pet.ranAway || stage == .egg { return false }
        if pet.isAsleep {
            say("Shhh… \(pet.name) is asleep. Wake them first to \(action).")
            return false
        }
        return true
    }

    func feedMeal() {
        guard guardAwake("eat") else { return }
        if pet.fullness > 92 {
            react(.refuse); say("I'm stuffed! 🙅"); SoundEngine.shared.play("poke"); return
        }
        pet.fullness = clamp(pet.fullness + 35)
        pet.energy = clamp(pet.energy + 5)
        pet.happiness = clamp(pet.happiness + 4)
        if pet.nextPoopAt == nil { pet.nextPoopAt = Date().addingTimeInterval(.random(in: 7_200...14_400)) }
        react(.eat, emoji: ["🍙", "🥕", "🍜", "🥞"].randomElement()!, seconds: 2.2)
        SoundEngine.shared.play("munch")
        say("Nom nom nom!", seconds: 2.5)
        save()
    }

    func feedSnack() {
        guard guardAwake("snack") else { return }
        let now = Date()
        snackTimes = snackTimes.filter { now.timeIntervalSince($0) < 3600 } + [now]
        pet.fullness = clamp(pet.fullness + 10)
        pet.happiness = clamp(pet.happiness + 14)
        react(.snack, emoji: ["🍪", "🍓", "🍩", "🧁"].randomElement()!, seconds: 1.8)
        SoundEngine.shared.play("munch")
        if snackTimes.count > 3 {
            pet.health = clamp(pet.health - 6)
            say("Too many treats… tummy ache 😖", seconds: 4)
        } else {
            say("Yum! A treat! ✨", seconds: 2.5)
        }
        save()
    }

    func bath() {
        guard guardAwake("take a bath") else { return }
        pet.hygiene = 100
        pet.poops = 0
        pet.happiness = clamp(pet.happiness + 5)
        react(.bath, seconds: 2.6)
        SoundEngine.shared.play("splash")
        say("Splish splash! Squeaky clean 🫧", seconds: 3)
        save()
    }

    /// `stroke` = true when the user petted the pet with the mouse instead of the button.
    func pat(stroke: Bool = false) {
        let now = CACurrentMediaTime()
        if stroke && now - lastPat < 2.5 { return }
        lastPat = now
        if pet.ranAway { return }
        if stage == .egg {
            pet.hatchBonus += 8
            react(.pat, seconds: 1.0)
            SoundEngine.shared.play("purr")
            say("The egg feels warm… it wiggled!", seconds: 2.5)
            save()
            return
        }
        if pet.isAsleep {
            react(.pat, seconds: 1.2)
            say("(happy sleepy mumble)", seconds: 2)
            SoundEngine.shared.play("purr")
            return
        }
        pet.happiness = clamp(pet.happiness + 12)
        react(.pat, seconds: 1.8)
        SoundEngine.shared.play("purr")
        say(["Hehe, that tickles!", "More pats please 💚", "Pip pip! ♥︎", "Mmm, cozy."].randomElement()!, seconds: 2.2)
        save()
    }

    func toggleSleep() {
        if pet.ranAway || stage == .egg { return }
        if pet.isAsleep {
            pet.isAsleep = false
            if pet.energy < 50 { pet.happiness = clamp(pet.happiness - 5); say("Five more minutes… 😪") }
            else { say("I'm up! ☀️") }
            react(.wave, seconds: 1.4)
            SoundEngine.shared.play("wave")
        } else {
            if pet.energy > 90 {
                react(.refuse); say("I'm not tired at all!"); SoundEngine.shared.play("poke"); return
            }
            react(.yawn, seconds: 1.6)
            SoundEngine.shared.play("yawn")
            say("Goodnight… 🌙", seconds: 2.5)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                self.pet.isAsleep = true
                self.save()
            }
        }
        save()
    }

    func giveMedicine() {
        guard guardAwake("take medicine") else { return }
        if isSick {
            pet.health = clamp(pet.health + 45)
            react(.medicine, emoji: "💊", seconds: 2.0)
            SoundEngine.shared.play("gulp")
            say("Bleh… but I feel better!", seconds: 3)
        } else {
            pet.happiness = clamp(pet.happiness - 3)
            react(.refuse)
            SoundEngine.shared.play("poke")
            say("I'm not sick! Yuck!", seconds: 2.5)
        }
        save()
    }

    /// Clicking the pet. Three quick clicks = dizzy.
    func poke() {
        guard !pet.ranAway else { return }
        let now = CACurrentMediaTime()
        pokeTimes = pokeTimes.filter { now - $0 < 1.2 } + [now]
        if stage == .egg { pat(); return }
        if pokeTimes.count >= 3 {
            pokeTimes.removeAll()
            pet.happiness = clamp(pet.happiness - 3)
            react(.dizzy, seconds: 3.0)
            SoundEngine.shared.play("dizzy")
            say("Whoaaa… the room is spinning 😵‍💫", seconds: 3)
        } else {
            react(.poke, seconds: 0.9)
            SoundEngine.shared.play("poke")
            if pet.isAsleep { say("Hmph… trying to sleep here.", seconds: 2) }
        }
    }

    func greet() {
        if pet.ranAway { return }
        if stage == .egg { say("Something's in the egg… keep it warm!", seconds: 5); return }
        react(.wave, seconds: 1.8)
        SoundEngine.shared.play("wave")
        say(pet.isAsleep ? "(\(pet.name) is snoozing 💤)" : "Hi! It's me, \(pet.name) 👋", seconds: 4)
    }

    func eatFile(named name: String) {
        guard !pet.ranAway else { return }
        pet.fullness = clamp(pet.fullness + 3)
        react(.eat, emoji: "📄", seconds: 1.8)
        SoundEngine.shared.play("gulp")
        say("Gulp! Ask me anything about \(name).", seconds: 4)
        save()
    }

    func rename(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        pet.name = String(clean.prefix(20))
        save()
    }

    func newEgg() {
        let name = pet.name
        let generation = pet.generation + 1
        pet = PetData()
        pet.name = name
        pet.generation = generation
        speech = nil
        save()
        SoundEngine.shared.play("pop")
        say("A new egg appeared! 🥚", seconds: 4)
    }

    private func hatch() {
        pet.hatchedAt = Date()
        pet.lastUpdate = Date()
        react(.hatch, seconds: 2.4)
        SoundEngine.shared.play("hatch")
        say("Pip! Hello world! I'm \(pet.name)! 🐣", seconds: 5)
        onAlert?()
    }

    // MARK: Chat hooks

    func beginThinking() {
        isThinking = true
        if pet.isAsleep {
            pet.isAsleep = false
            pet.happiness = clamp(pet.happiness - 4)
            say("*yawn* …okay, okay, I'm looking it up.", seconds: 3)
        }
        pet.energy = clamp(pet.energy - 2)
        SoundEngine.shared.play("think")
    }

    func finishedAnswer(success: Bool) {
        isThinking = false
        if success {
            pet.questionsAnswered += 1
            pet.happiness = clamp(pet.happiness + 3)
            react(.happy, seconds: 1.4)
            SoundEngine.shared.play("answer")
        } else {
            react(.sad, seconds: 2.0)
            SoundEngine.shared.play("sad")
        }
        save()
    }
}
