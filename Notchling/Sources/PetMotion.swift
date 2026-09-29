import Foundation
import QuartzCore

// Animation engine: tweens + smoothed targets, head turning, blinks, squash & stretch and
// idle behaviours. The tween/easing approach is adapted from Coucou's BotEngine (MIT License,
// see LICENSE-coucou-MIT.txt); the behaviours and character are Notchling's own.

enum Ease {
    static func out(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static func inOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func back(_ t: Double) -> Double { let c1 = 1.7, c3 = c1 + 1; return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2) }
    static func lin(_ t: Double) -> Double { t }
}

struct Key {
    let to: Double
    let ms: Double
    let ease: (Double) -> Double
    init(_ to: Double, _ ms: Double, _ ease: @escaping (Double) -> Double = Ease.inOut) {
        self.to = to; self.ms = ms; self.ease = ease
    }
}

final class PetMotion {
    enum Prop: Hashable { case yaw, pitch, tilt, roll, sx, sy, oy, ox, open, es, arms }

    // Live values
    var yaw = 0.0      // head turn left/right (radians-ish; features wrap around the body)
    var pitch = 0.0    // head nod (positive = looking down)
    var tilt = 0.0     // whole-body lean
    var roll = 0.0     // full spins
    var sx = 1.0, sy = 1.0   // squash & stretch
    var oy = 0.0       // hop height (fraction of size, positive = up)
    var ox = 0.0       // sideways shuffle (fraction of size)
    var open = 1.0     // eyelids
    var es = 1.0       // eye size (bigger when you hover)
    var arms = 0.0     // extra arm raise for idle waves

    /// Temporary eye expression for idle moves (wink, happy squint…)
    var idleEye: PetRenderer.EyeStyle? = nil
    var idleEyeUntil = 0.0
    var hearts: [(born: Double, x: Double)] = []

    private struct Tween { var keys: [Key]; var index = 0; var from: Double; var start: Double }
    private var tweens: [Prop: Tween] = [:]

    private var last = CACurrentMediaTime()
    private let t0 = CACurrentMediaTime() - Double.random(in: 0...5)
    private var nextBlink = CACurrentMediaTime() + 1.5
    private var nextIdle = CACurrentMediaTime() + 3
    private var lastReactionStart = -1.0
    private var glance: (x: Double, y: Double, until: Double)? = nil
    private var wander = (x: 0.0, y: 0.0, next: 0.0)

    // MARK: Frame update

    func step(_ s: PetSnapshot) {
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0.001, now - last))
        last = now
        let t = now - t0

        if s.reactionStart != lastReactionStart {
            if lastReactionStart >= 0 && s.reaction != .none { trigger(s.reaction, s: s) }
            lastReactionStart = s.reactionStart
        }

        runTweens(now)

        // ---- Where to look ----
        var lx = Double(s.look.dx), ly = Double(s.look.dy)
        if s.mini && !s.hover {
            if now > wander.next {
                wander = (Double.random(in: -0.8...0.8), Double.random(in: -0.4...0.4), now + Double.random(in: 0.8...2.5))
            }
            lx = wander.x; ly = wander.y
        }
        if let g = glance, now < g.until { lx = g.x; ly = g.y } else { glance = nil }

        var tgYaw = lx * 0.62
        var tgPitch = ly * 0.42
        if s.thinking { tgYaw = sin(t * 2.6) * 0.6; tgPitch = -0.08 }        // scanning while searching
        if s.asleep { tgYaw = 0; tgPitch = 0.16 }
        if s.reaction == .dizzy { tgYaw = sin(t * 9) * 0.3 }
        if s.mood == .sad || s.mood == .hungry || s.mood == .sick { tgPitch += 0.1 }

        // ---- Body targets ----
        var tgTilt = 0.0
        var tgSx = 1.0, tgSy = 1.0
        if s.asleep {
            tgSy = 0.97 + sin(t * 1.5) * 0.035; tgSx = 1 - sin(t * 1.5) * 0.02
        } else {
            let breathe = s.mood == .happy ? 0.028 : 0.02
            tgSy = 1 + sin(t * 2.2) * breathe; tgSx = 1 - sin(t * 2.2) * breathe * 0.55
        }
        if s.hover && !s.asleep { tgTilt = lx * 0.07 }                         // leans toward your cursor
        if s.reaction == .pat { tgTilt = sin(t * 5) * 0.08 }                   // happy sway while patted
        if s.reaction == .wave || s.reaction == .hatch { tgTilt = -0.05 + sin(t * 7.5) * 0.07 }
        if s.reaction == .dizzy { tgTilt = sin(t * 6) * 0.12 }
        let tgEs = (s.hover && !s.asleep) || s.reaction == .pat ? 1.1 : (s.expectingFile ? 1.18 : 1.0)
        let thinkingBob = s.thinking ? abs(sin(t * 4)) * 0.012 : 0

        let kLook = 1 - pow(0.0025, dt)
        let kGen = 1 - pow(0.0008, dt)
        ease(.yaw, &yaw, tgYaw, kLook)
        ease(.pitch, &pitch, tgPitch, kLook)
        ease(.tilt, &tilt, tgTilt, kGen)
        ease(.sx, &sx, tgSx, kGen)
        ease(.sy, &sy, tgSy, kGen)
        ease(.es, &es, tgEs, kGen)
        ease(.oy, &oy, thinkingBob, kGen)
        ease(.ox, &ox, 0, kGen)
        ease(.arms, &arms, 0, kGen)

        // ---- Blinking ----
        if now > nextBlink {
            if !s.asleep && s.reaction != .dizzy {
                blink()
                if Double.random(in: 0...1) < 0.22 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.23) { [weak self] in self?.blink() }
                }
            }
            nextBlink = now + 2.2 + Double.random(in: 0...3.2)
        }
        if idleEye != nil && now > idleEyeUntil { idleEye = nil }
        hearts.removeAll { now - $0.born > 1.6 }

        // ---- Idle behaviours: so it never just stands there ----
        if now > nextIdle {
            if s.reaction == .none && !s.asleep && !s.thinking && s.stage != .egg && s.mood != .gone {
                idleBehaviour(s, now: now)
            }
            let calm = s.mood == .sad || s.mood == .sick || s.mood == .sleepy || s.mood == .hungry
            nextIdle = now + (calm ? 5.5 : 3.0) + Double.random(in: 0...(s.mini ? 4 : 3))
        }
    }

    private func ease(_ p: Prop, _ v: inout Double, _ target: Double, _ k: Double) {
        guard tweens[p] == nil else { return }
        v += (target - v) * k
    }

    // MARK: Tweens

    func anim(_ p: Prop, _ keys: [Key]) {
        tweens[p] = Tween(keys: keys, from: get(p), start: CACurrentMediaTime())
    }

    private func runTweens(_ now: Double) {
        for (p, var tw) in tweens {
            let k = tw.keys[tw.index]
            let prog = min(1, max(0, (now - tw.start) * 1000 / k.ms))
            set(p, tw.from + (k.to - tw.from) * k.ease(prog))
            if prog >= 1 {
                tw.from = k.to
                tw.index += 1
                tw.start = now
                if tw.index >= tw.keys.count {
                    tweens[p] = nil
                    if p == .roll { roll = 0 }
                    continue
                }
            }
            tweens[p] = tw
        }
    }

    private func get(_ p: Prop) -> Double {
        switch p {
        case .yaw: return yaw
        case .pitch: return pitch
        case .tilt: return tilt
        case .roll: return roll
        case .sx: return sx
        case .sy: return sy
        case .oy: return oy
        case .ox: return ox
        case .open: return open
        case .es: return es
        case .arms: return arms
        }
    }

    private func set(_ p: Prop, _ v: Double) {
        switch p {
        case .yaw: yaw = v
        case .pitch: pitch = v
        case .tilt: tilt = v
        case .roll: roll = v
        case .sx: sx = v
        case .sy: sy = v
        case .oy: oy = v
        case .ox: ox = v
        case .open: open = v
        case .es: es = v
        case .arms: arms = v
        }
    }

    // MARK: Moves

    func blink() {
        guard tweens[.open] == nil else { return }
        anim(.open, [Key(0.06, 70), Key(1, 130, Ease.out)])
    }

    func squash() {
        anim(.sy, [Key(0.78, 70, Ease.out), Key(1.1, 130, Ease.out), Key(1, 170)])
        anim(.sx, [Key(1.16, 70, Ease.out), Key(0.95, 130, Ease.out), Key(1, 170)])
    }

    func hop(height: Double = 0.1) {
        anim(.oy, [Key(0, 60), Key(height, 170, Ease.out), Key(0, 190, Ease.inOut), Key(0, 1)])
        anim(.sy, [Key(0.84, 70, Ease.out), Key(1.16, 130, Ease.out), Key(0.9, 190), Key(1, 200, Ease.back)])
        anim(.sx, [Key(1.12, 70, Ease.out), Key(0.9, 130, Ease.out), Key(1.07, 190), Key(1, 200, Ease.back)])
    }

    func headShake(_ amount: Double = 0.6) {
        anim(.yaw, [Key(-amount, 50, Ease.out), Key(amount, 90), Key(-amount * 0.75, 80),
                    Key(amount * 0.6, 75), Key(-amount * 0.3, 70), Key(0, 140, Ease.out)])
    }

    func spin(turns: Double = 1, ms: Double = 900) {
        roll = 0
        anim(.roll, [Key(.pi * 2 * turns, ms)])
    }

    func gulp() {
        anim(.sy, [Key(0.78, 80, Ease.out), Key(1.18, 130, Ease.out), Key(1, 220, Ease.back)])
        anim(.sx, [Key(1.28, 80, Ease.out), Key(0.92, 130, Ease.out), Key(1, 220, Ease.back)])
        blink()
    }

    func stretch() {
        anim(.sy, [Key(1.16, 380, Ease.out), Key(1.16, 250, Ease.lin), Key(0.92, 160), Key(1, 260, Ease.back)])
        anim(.sx, [Key(0.9, 380, Ease.out), Key(0.9, 250, Ease.lin), Key(1.06, 160), Key(1, 260, Ease.back)])
        anim(.arms, [Key(1.8, 380, Ease.out), Key(1.8, 250, Ease.lin), Key(0, 300)])
    }

    private func trigger(_ r: Reaction, s: PetSnapshot) {
        switch r {
        case .poke:
            squash()
            anim(.tilt, [Key(0.12, 60, Ease.out), Key(-0.06, 120), Key(0, 160)])
        case .dizzy:
            spin(turns: 1, ms: 850)
            squash()
        case .happy:
            hop(height: 0.12)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.hop(height: 0.07) }
        case .pat:
            anim(.sy, [Key(0.9, 150, Ease.out), Key(1.04, 220), Key(1, 200, Ease.back)])
            anim(.sx, [Key(1.08, 150, Ease.out), Key(0.98, 220), Key(1, 200, Ease.back)])
        case .wave, .hatch:
            anim(.oy, [Key(0.05, 220, Ease.out), Key(0, 220, Ease.back)])
            anim(.sy, [Key(0.95, 100, Ease.out), Key(1, 260, Ease.back)])
            anim(.sx, [Key(1.04, 100, Ease.out), Key(1, 260, Ease.back)])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in self?.blink() }
        case .eat, .snack, .medicine:
            gulp()
        case .refuse:
            headShake(0.65)
        case .sad:
            anim(.sy, [Key(0.9, 300, Ease.out), Key(0.95, 600)])
        case .yawn:
            stretch()
        case .bath:
            anim(.tilt, [Key(0.1, 120), Key(-0.1, 200), Key(0.08, 180), Key(-0.06, 160), Key(0, 200)])
            hop(height: 0.05)
        case .none:
            break
        }
    }

    private func idleBehaviour(_ s: PetSnapshot, now: Double) {
        let happy = s.mood == .happy || s.mood == .content
        var options: [Int] = [0, 1, 2, 3]     // glance, tilt, wiggle, double-blink
        if happy { options += [4, 4, 5, 6, 7] } // hop, shuffle, wink, love
        if s.mood == .sleepy { options += [8, 8] }
        if happy && Double.random(in: 0...1) < 0.06 { options = [9] } // rare happy spin
        if s.mini { options.removeAll { $0 == 5 } }

        switch options.randomElement() ?? 0 {
        case 0: // look around
            let side = Bool.random() ? 1.0 : -1.0
            glance = (side * Double.random(in: 0.6...1), Double.random(in: -0.5...0.2), now + Double.random(in: 0.7...1.4))
        case 1: // curious head tilt
            let d = Bool.random() ? 0.14 : -0.14
            anim(.tilt, [Key(d, 180, Ease.out), Key(d, 500, Ease.lin), Key(0, 260)])
        case 2: // wiggle
            anim(.tilt, [Key(0.07, 90), Key(-0.07, 140), Key(0.05, 120), Key(0, 140)])
        case 3:
            blink()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in self?.blink() }
        case 4:
            hop(height: s.mini ? 0.14 : 0.08)
        case 5: // little shuffle side to side
            anim(.ox, [Key(0.04, 180, Ease.out), Key(-0.04, 300), Key(0, 220)])
            anim(.tilt, [Key(-0.06, 180, Ease.out), Key(0.06, 300), Key(0, 220)])
        case 6: // wink
            idleEye = .wink; idleEyeUntil = now + 0.55
            anim(.tilt, [Key(0.12, 100, Ease.out), Key(0.12, 320, Ease.lin), Key(0, 200)])
        case 7: // little burst of love
            hearts.append((now, -0.2)); hearts.append((now + 0.15, 0.25))
            idleEye = .happy; idleEyeUntil = now + 0.9
            anim(.tilt, [Key(-0.1, 180, Ease.out), Key(0.1, 340), Key(0, 220)])
        case 8:
            stretch()
        default:
            hop(height: 0.1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.spin(turns: 1, ms: 700) }
        }
    }
}
