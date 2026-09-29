import SwiftUI
import QuartzCore

/// Mouse position in the island panel's coordinate space (top-left origin), updated by IslandController.
enum MouseTracker {
    static var point: CGPoint = CGPoint(x: -9999, y: -9999)
    /// Frame of the big pet in the expanded island (panel coords), used to detect petting strokes.
    static var petFrame: CGRect = .zero
}

struct PetSnapshot {
    var stage: PetStage
    var mood: Mood
    var reaction: Reaction
    var reactionAge: Double
    var emoji: String
    var poops: Int
    var hygiene: Double
    var happiness: Double
    var asleep: Bool
    var sick: Bool
    var thinking: Bool
    var expectingFile: Bool
    var look: CGVector
    var hatchProgress: Double
    var mini: Bool
}

struct PetCanvasView: View {
    @ObservedObject var pet: PetStore
    var size: CGFloat
    var mini: Bool = false
    var animate: Bool = true

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("panel"))
            TimelineView(.animation(minimumInterval: mini ? 1.0 / 20 : 1.0 / 60, paused: !animate)) { timeline in
                let snap = snapshot(frame: frame)
                Canvas { ctx, canvasSize in
                    PetRenderer.draw(ctx, size: canvasSize,
                                     t: timeline.date.timeIntervalSinceReferenceDate, s: snap)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func snapshot(frame: CGRect) -> PetSnapshot {
        if !mini { MouseTracker.petFrame = frame }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let m = MouseTracker.point
        let dx = m.x - center.x, dy = m.y - center.y
        let dist = max(1, hypot(dx, dy))
        let pull = min(1, dist / 220)
        var look = CGVector(dx: dx / dist * pull, dy: dy / dist * pull)
        if pet.isThinking { look = CGVector(dx: 0.7, dy: -0.7) }
        let p = pet.pet
        let hatch = (Date().timeIntervalSince(p.born) + p.hatchBonus) / PetStore.hatchSeconds
        return PetSnapshot(
            stage: pet.stage, mood: pet.mood, reaction: pet.reaction,
            reactionAge: CACurrentMediaTime() - pet.reactionStart, emoji: pet.reactionEmoji,
            poops: p.poops, hygiene: p.hygiene, happiness: p.happiness, asleep: p.isAsleep,
            sick: pet.isSick, thinking: pet.isThinking, expectingFile: pet.expectingFile,
            look: look, hatchProgress: min(1, max(0, hatch)), mini: mini)
    }
}

// MARK: - Renderer

enum PetRenderer {
    static let ink = Color(red: 0.12, green: 0.15, blue: 0.18)

    struct RGB {
        var r, g, b: Double
        func mix(_ o: RGB, _ k: Double) -> RGB { RGB(r: r + (o.r - r) * k, g: g + (o.g - g) * k, b: b + (o.b - b) * k) }
        var color: Color { Color(red: r, green: g, blue: b) }
    }

    enum EyeStyle { case open, happy, closed, dizzy, annoyed, sad, surprised, sick }
    enum MouthStyle { case smile, bigSmile, frown, open, chew, wavy, flat, yawn }

    static func draw(_ base: GraphicsContext, size: CGSize, t: Double, s: PetSnapshot) {
        let S = Double(min(size.width, size.height))
        let cx = Double(size.width) / 2
        let ground = Double(size.height) * (s.mini ? 0.94 : 0.88)
        let a = s.reactionAge

        if s.stage == .egg {
            drawEgg(base, S: S, cx: cx, ground: ground, t: t, s: s)
            return
        }
        if s.mood == .gone {
            drawNote(base, S: S, cx: cx, ground: ground, t: t)
            return
        }

        // ---- Motion ----
        let scale: Double
        switch s.stage {
        case .egg, .baby: scale = 0.74
        case .kid: scale = 0.84
        case .teen: scale = 0.93
        case .adult: scale = 1.0
        }
        let sc = s.mini ? 1.0 : scale
        var sy = 1.0 + sin(t * 2.2) * 0.022
        var hop = 0.0
        var tilt = 0.0
        switch s.reaction {
        case .poke: sy -= 0.2 * exp(-a * 5) * cos(a * 16)
        case .happy, .pat, .wave, .hatch: hop = abs(sin(a * 7)) * S * 0.07 * max(0, 1 - a / 1.8)
        case .eat, .snack, .medicine: sy += sin(a * 16) * 0.035
        case .dizzy: tilt = sin(t * 9) * 0.14
        case .refuse: tilt = sin(a * 22) * 0.09 * max(0, 1 - a)
        case .sad: sy -= 0.05
        case .yawn: sy += sin(min(a, 1.2) / 1.2 * .pi) * 0.08
        case .bath: tilt = sin(a * 10) * 0.05
        case .none:
            if s.asleep { sy = 0.96 + sin(t * 1.2) * 0.03 }
            else if s.mood == .happy && !s.mini { hop = pow(max(0, sin(t * 2.4)), 10) * S * 0.035 }
        }
        let sx = 1 + (1 - sy) * 0.7
        let w = S * 0.62 * sc * sx
        let h = S * 0.56 * sc * sy
        let baseY = ground - hop

        // Shadow
        if !s.mini {
            let sw = w * 0.85 * (1 - hop / S)
            base.fill(Path(ellipseIn: CGRect(x: cx - sw / 2, y: ground - S * 0.02, width: sw, height: S * 0.045)),
                      with: .color(.black.opacity(0.28)))
            drawPoops(base, S: S, cx: cx, ground: ground, w: S * 0.62 * sc, count: s.poops, t: t)
        }

        var c = base
        c.translateBy(x: cx, y: ground)
        c.rotate(by: .radians(tilt))
        c.translateBy(x: -cx, y: -ground)

        // ---- Colours ----
        let mintTop = RGB(r: 0.62, g: 0.92, b: 0.78), mintBottom = RGB(r: 0.33, g: 0.72, b: 0.58)
        let sickTop = RGB(r: 0.84, g: 0.87, b: 0.58), sickBottom = RGB(r: 0.60, g: 0.66, b: 0.34)
        let k = s.sick ? 0.75 : 0.0
        let top = mintTop.mix(sickTop, k), bottom = mintBottom.mix(sickBottom, k)
        let dark = bottom.mix(RGB(r: 0.1, g: 0.3, b: 0.25), 0.25)

        // ---- Arms (behind body) ----
        var leftRaise = 0.35, rightRaise = 0.35
        switch s.reaction {
        case .wave, .hatch: rightRaise = 2.3 + sin(a * 14) * 0.4
        case .bath: leftRaise = 2.5 + sin(a * 18) * 0.3; rightRaise = 2.5 - sin(a * 18) * 0.3
        case .pat, .happy: leftRaise = 0.9 + sin(a * 10) * 0.2; rightRaise = 0.9 - sin(a * 10) * 0.2
        case .dizzy: leftRaise = 0.8 + sin(t * 11) * 0.6; rightRaise = 0.8 + cos(t * 11) * 0.6
        case .refuse: leftRaise = 1.2; rightRaise = 1.2
        case .eat, .snack, .medicine: rightRaise = 1.6
        default: if s.asleep { leftRaise = 0.15; rightRaise = 0.15 }
        }
        if !s.mini {
            for (side, raise) in [(-1.0, leftRaise), (1.0, rightRaise)] {
                var ac = c
                ac.translateBy(x: cx + side * w * 0.40, y: baseY - h * 0.42)
                ac.rotate(by: .radians(-side * raise))
                let aw = w * 0.15, ah = w * 0.27
                ac.fill(Path(ellipseIn: CGRect(x: -aw / 2, y: -aw * 0.2, width: aw, height: ah)), with: .color(dark.color))
            }
        }

        // ---- Body ----
        let body = bodyPath(cx: cx, base: baseY, w: w, h: h)
        c.fill(body, with: .linearGradient(Gradient(colors: [top.color, bottom.color]),
                                           startPoint: CGPoint(x: cx, y: baseY - h),
                                           endPoint: CGPoint(x: cx, y: baseY)))
        c.fill(Path(ellipseIn: CGRect(x: cx - w * 0.25, y: baseY - h * 0.46, width: w * 0.5, height: h * 0.40)),
               with: .color(.white.opacity(0.26)))

        // Dirt
        if s.hygiene < 45 && !s.mini {
            let o = (45 - s.hygiene) / 45 * 0.7
            let mud = Color(red: 0.45, green: 0.32, blue: 0.2).opacity(o)
            for (px, py, r) in [(-0.2, 0.55, 0.09), (0.19, 0.38, 0.07), (0.06, 0.78, 0.08), (-0.05, 0.3, 0.05)] {
                let rr = w * r
                c.fill(Path(ellipseIn: CGRect(x: cx + w * px - rr, y: baseY - h * (1 - py) - rr * 0.7,
                                              width: rr * 2, height: rr * 1.4)), with: .color(mud))
            }
        }

        // Feet
        let fw = w * 0.24, fh = S * 0.075 * sc
        for side in [-1.0, 1.0] {
            c.fill(Path(ellipseIn: CGRect(x: cx + side * w * 0.2 - fw / 2, y: baseY - fh * 0.62, width: fw, height: fh)),
                   with: .color(dark.color))
        }

        // Sprout
        drawSprout(c, S: S * sc, top: CGPoint(x: cx, y: baseY - h), t: t, s: s)

        // ---- Face ----
        var eye: EyeStyle = .open
        var mouth: MouthStyle = .smile
        switch s.reaction {
        case .dizzy: eye = .dizzy; mouth = .wavy
        case .poke: eye = .annoyed; mouth = .frown
        case .pat, .happy, .wave, .hatch: eye = .happy; mouth = .bigSmile
        case .eat, .snack: eye = .happy; mouth = .chew
        case .medicine: eye = .closed; mouth = .chew
        case .bath: eye = .happy; mouth = .open
        case .refuse: eye = .annoyed; mouth = .flat
        case .sad: eye = .sad; mouth = .frown
        case .yawn: eye = .closed; mouth = .yawn
        case .none:
            if s.asleep { eye = .closed; mouth = .flat }
            else if s.thinking { eye = .open; mouth = .flat }
            else if s.expectingFile { eye = .surprised; mouth = .open }
            else {
                switch s.mood {
                case .sick: eye = .sick; mouth = .wavy
                case .hungry, .sad: eye = .sad; mouth = .frown
                case .dirty: eye = .open; mouth = .flat
                case .sleepy: eye = .sick; mouth = .flat
                case .happy: eye = .open; mouth = .bigSmile
                default: eye = .open; mouth = .smile
                }
            }
        }
        let blinking = (t + 0.7).truncatingRemainder(dividingBy: 4.3) < 0.13
        if blinking && [EyeStyle.open, .surprised, .sad].contains(eye) { eye = .closed }

        let eyeY = baseY - h * 0.64
        let rx = S * 0.052 * sc, ry = S * 0.066 * sc
        let lidColor = top.mix(bottom, 0.3).color
        for side in [-1.0, 1.0] {
            let ex = cx + side * w * 0.19
            drawEye(c, style: eye, x: ex, y: eyeY, rx: rx, ry: ry, inner: -side, look: s.look, t: t, lid: lidColor)
            // Cheeks
            if !s.sick && !s.mini {
                let blush = s.reaction == .pat ? 0.7 : 0.18 + s.happiness / 100 * 0.3
                c.fill(Path(ellipseIn: CGRect(x: ex + side * rx * 0.55 - rx * 0.75, y: eyeY + ry * 0.95,
                                              width: rx * 1.5, height: ry * 0.6)),
                       with: .color(Color(red: 1, green: 0.5, blue: 0.6).opacity(blush)))
            }
        }
        drawMouth(c, style: mouth, x: cx, y: eyeY + S * 0.1 * sc, mw: S * 0.08 * sc, a: a, t: t)

        if s.mini {
            if s.asleep { drawZzz(base, S: S * 1.6, x: cx + S * 0.25, y: baseY - h, t: t) }
            return
        }

        // ---- Overlays ----
        if s.sick {
            let dy = (t * 0.6).truncatingRemainder(dividingBy: 1)
            let dx = cx + w * 0.42, dy0 = baseY - h * 0.85 + dy * S * 0.06
            var drop = Path()
            drop.move(to: CGPoint(x: dx, y: dy0 - S * 0.04))
            drop.addQuadCurve(to: CGPoint(x: dx, y: dy0 + S * 0.03), control: CGPoint(x: dx + S * 0.05, y: dy0 + S * 0.02))
            drop.addQuadCurve(to: CGPoint(x: dx, y: dy0 - S * 0.04), control: CGPoint(x: dx - S * 0.05, y: dy0 + S * 0.02))
            c.fill(drop, with: .color(Color(red: 0.55, green: 0.8, blue: 1).opacity(0.9 - dy * 0.6)))
        }
        if s.hygiene < 20 {
            for i in 0..<3 {
                let ph = (t * 0.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let x0 = cx + (Double(i) - 1) * w * 0.35
                var line = Path()
                for j in 0...8 {
                    let yy = baseY - h - S * 0.02 - Double(j) * S * 0.018 - ph * S * 0.08
                    let xx = x0 + sin(Double(j) * 0.9 + t * 3) * S * 0.015
                    if j == 0 { line.move(to: CGPoint(x: xx, y: yy)) } else { line.addLine(to: CGPoint(x: xx, y: yy)) }
                }
                c.stroke(line, with: .color(Color(red: 0.6, green: 0.7, blue: 0.4).opacity(0.7 * (1 - ph))), lineWidth: 1.5)
            }
        }

        switch s.reaction {
        case .pat, .happy:
            for i in 0..<3 {
                let ph = (a * 0.9 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let x = cx + (Double(i) - 1) * w * 0.38 + sin(ph * 6) * S * 0.03
                let y = baseY - h - S * 0.04 - ph * S * 0.22
                c.fill(heart(CGPoint(x: x, y: y), S * 0.085 * (1 - ph * 0.3)),
                       with: .color(Color(red: 1, green: 0.42, blue: 0.55).opacity(1 - ph)))
            }
        case .eat, .snack, .medicine:
            let dur = s.reaction == .eat ? 2.0 : 1.6
            let left = max(0.15, 1 - a / dur)
            let fs = S * 0.2 * left
            c.draw(Text(s.emoji).font(.system(size: max(4, fs))),
                   at: CGPoint(x: cx + w * 0.3, y: eyeY + S * 0.12 * sc))
            for i in 0..<4 {
                let ph = (a * 1.5 + Double(i) * 0.25).truncatingRemainder(dividingBy: 1)
                c.fill(Path(ellipseIn: CGRect(x: cx + w * 0.15 + Double(i) * S * 0.02, y: eyeY + S * 0.15 + ph * S * 0.2,
                                              width: S * 0.015, height: S * 0.015)),
                       with: .color(Color(red: 0.95, green: 0.8, blue: 0.5).opacity(1 - ph)))
            }
        case .bath:
            for i in 0..<9 {
                let ph = (a * 0.8 + Double(i) / 9).truncatingRemainder(dividingBy: 1)
                let x = cx + sin(Double(i) * 2.3) * w * 0.6 + sin(ph * 8 + Double(i)) * S * 0.02
                let y = baseY - ph * S * 0.8
                let r = S * (0.02 + Double(i % 3) * 0.012)
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                c.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.18 * (1 - ph))))
                c.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.85 * (1 - ph))), lineWidth: 1)
            }
            for i in 0..<5 {
                let r = S * 0.045
                let x = cx + (Double(i) - 2) * r * 1.2, y = baseY - h - r * 0.3 + (i % 2 == 0 ? 0 : -r * 0.6)
                c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.9)))
            }
        case .dizzy:
            for i in 0..<3 {
                let ang = t * 5 + Double(i) * 2.094
                let p = CGPoint(x: cx + cos(ang) * w * 0.48, y: baseY - h * 1.02 + sin(ang) * h * 0.09)
                c.fill(star(p, S * 0.04), with: .color(Color(red: 1, green: 0.85, blue: 0.3)))
            }
        case .hatch:
            let o = max(0, 1 - max(0, a - 1.2) / 0.8)
            c.fill(shellCup(cx: cx, ground: ground, S: S), with: .color(Color(red: 0.98, green: 0.94, blue: 0.84).opacity(o)))
            var cap = base
            cap.opacity = max(0, 1 - a / 1.3)
            cap.translateBy(x: cx + a * S * 0.35, y: ground - S * 0.6 - a * S * 0.3 + a * a * S * 0.3)
            cap.rotate(by: .radians(a * 3))
            var capPath = Path()
            capPath.move(to: CGPoint(x: -S * 0.2, y: 0))
            capPath.addQuadCurve(to: CGPoint(x: S * 0.2, y: 0), control: CGPoint(x: 0, y: -S * 0.3))
            capPath.addLine(to: CGPoint(x: S * 0.1, y: S * 0.04))
            capPath.addLine(to: CGPoint(x: 0, y: -S * 0.01))
            capPath.addLine(to: CGPoint(x: -S * 0.1, y: S * 0.04))
            capPath.closeSubpath()
            cap.fill(capPath, with: .color(Color(red: 0.98, green: 0.94, blue: 0.84)))
            for i in 0..<4 {
                let ang = Double(i) * 1.57 + 0.4
                let d = S * (0.35 + a * 0.1)
                c.fill(star(CGPoint(x: cx + cos(ang) * d, y: baseY - h * 0.5 + sin(ang) * d * 0.6), S * 0.035 * o),
                       with: .color(Color(red: 1, green: 0.9, blue: 0.4).opacity(o)))
            }
        default: break
        }

        if s.asleep && s.reaction == .none {
            drawZzz(base, S: S, x: cx + w * 0.4, y: baseY - h * 0.95, t: t)
        }
        if s.thinking {
            let bx = cx + w * 0.55, by = baseY - h * 1.05
            for i in 0..<3 {
                let r = S * (0.018 + Double(i) * 0.01)
                let on = Int(t * 3) % 3 == i
                c.fill(Path(ellipseIn: CGRect(x: bx + Double(i) * S * 0.05 - r, y: by - Double(i) * S * 0.045 - r,
                                              width: r * 2, height: r * 2)),
                       with: .color(.white.opacity(on ? 0.95 : 0.45)))
            }
            c.draw(Text("🔎").font(.system(size: S * 0.12)),
                   at: CGPoint(x: bx + S * 0.13, y: by - S * 0.17 + sin(t * 4) * S * 0.01))
        }
    }

    // MARK: Parts

    static func bodyPath(cx: Double, base: Double, w: Double, h: Double) -> Path {
        var p = Path()
        let top = CGPoint(x: cx, y: base - h)
        p.move(to: top)
        p.addCurve(to: CGPoint(x: cx + w / 2, y: base - h * 0.38),
                   control1: CGPoint(x: cx + w * 0.30, y: base - h),
                   control2: CGPoint(x: cx + w / 2, y: base - h * 0.72))
        p.addCurve(to: CGPoint(x: cx, y: base),
                   control1: CGPoint(x: cx + w / 2, y: base - h * 0.06),
                   control2: CGPoint(x: cx + w * 0.30, y: base))
        p.addCurve(to: CGPoint(x: cx - w / 2, y: base - h * 0.38),
                   control1: CGPoint(x: cx - w * 0.30, y: base),
                   control2: CGPoint(x: cx - w / 2, y: base - h * 0.06))
        p.addCurve(to: top,
                   control1: CGPoint(x: cx - w / 2, y: base - h * 0.72),
                   control2: CGPoint(x: cx - w * 0.30, y: base - h))
        p.closeSubpath()
        return p
    }

    static func leaf(_ len: Double) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: len, y: 0), control: CGPoint(x: len * 0.5, y: -len * 0.5))
        p.addQuadCurve(to: .zero, control: CGPoint(x: len * 0.5, y: len * 0.5))
        p.closeSubpath()
        return p
    }

    static func drawSprout(_ c: GraphicsContext, S: Double, top: CGPoint, t: Double, s: PetSnapshot) {
        let sway = sin(t * 1.6) * S * 0.02
        let stemLen = S * (s.mini ? 0.14 : 0.11)
        let tip = CGPoint(x: top.x + sway, y: top.y - stemLen)
        var stem = Path()
        stem.move(to: CGPoint(x: top.x, y: top.y + S * 0.01))
        stem.addQuadCurve(to: tip, control: CGPoint(x: top.x - S * 0.02, y: top.y - stemLen * 0.5))
        let green = Color(red: 0.28, green: 0.62, blue: 0.3)
        c.stroke(stem, with: .color(green), style: StrokeStyle(lineWidth: max(1.2, S * 0.022), lineCap: .round))

        let droop = (s.asleep || s.sick || s.mood == .sad || s.mood == .hungry) ? 0.55 : 0.0
        let flutter = sin(t * 2.1) * 0.12
        let leafColor = Color(red: 0.42, green: 0.8, blue: 0.4)
        var leaves: [(Double, Double)] = []  // (angle, length)
        switch s.stage {
        case .egg, .baby: leaves = [(-0.55, 0.13)]
        case .kid: leaves = [(-0.5, 0.12), (.pi + 0.5, 0.11)]
        case .teen, .adult: leaves = [(-0.5, 0.16), (.pi + 0.5, 0.15)]
        }
        if s.mini { leaves = [(-0.55, 0.2)] }
        for (ang, len) in leaves {
            var lc = c
            lc.translateBy(x: tip.x, y: tip.y)
            let dir = ang < 1 ? 1.0 : -1.0
            lc.rotate(by: .radians(ang + flutter + droop * dir))
            lc.fill(leaf(S * len), with: .color(leafColor))
        }
        if s.stage == .adult && !s.mini {
            let fc = CGPoint(x: tip.x, y: tip.y - S * 0.035)
            for i in 0..<5 {
                let ang = Double(i) * 1.2566 + t * 0.3
                let r = S * 0.022
                c.fill(Path(ellipseIn: CGRect(x: fc.x + cos(ang) * r * 1.1 - r, y: fc.y + sin(ang) * r * 1.1 - r,
                                              width: r * 2, height: r * 2)),
                       with: .color(Color(red: 1, green: 0.62, blue: 0.75)))
            }
            c.fill(Path(ellipseIn: CGRect(x: fc.x - S * 0.016, y: fc.y - S * 0.016, width: S * 0.032, height: S * 0.032)),
                   with: .color(Color(red: 1, green: 0.85, blue: 0.3)))
        }
    }

    static func drawEye(_ c: GraphicsContext, style: EyeStyle, x: Double, y: Double, rx: Double, ry: Double,
                        inner: Double, look: CGVector, t: Double, lid: Color) {
        let lineW = max(1.2, rx * 0.42)
        let strokeStyle = StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round)
        func openEye(scale: Double = 1) {
            let ex = x + look.dx * rx * 0.45, ey = y + look.dy * ry * 0.35
            let w = rx * 2 * scale, h = ry * 2 * scale
            c.fill(Path(ellipseIn: CGRect(x: ex - w / 2, y: ey - h / 2, width: w, height: h)), with: .color(ink))
            let hr = rx * 0.34 * scale
            c.fill(Path(ellipseIn: CGRect(x: ex - rx * 0.32 - hr, y: ey - ry * 0.38 - hr, width: hr * 2, height: hr * 2)),
                   with: .color(.white))
            let hr2 = hr * 0.45
            c.fill(Path(ellipseIn: CGRect(x: ex + rx * 0.3 - hr2, y: ey + ry * 0.35 - hr2, width: hr2 * 2, height: hr2 * 2)),
                   with: .color(.white.opacity(0.8)))
        }
        func brow(outerY: Double, innerY: Double) {
            var p = Path()
            p.move(to: CGPoint(x: x - inner * rx * 1.05, y: y + outerY))
            p.addLine(to: CGPoint(x: x + inner * rx * 0.95, y: y + innerY))
            c.stroke(p, with: .color(ink), style: strokeStyle)
        }
        func lidOver(_ fraction: Double) {
            c.fill(Path(CGRect(x: x - rx * 1.4, y: y - ry * 1.5, width: rx * 2.8, height: ry * (0.5 + fraction * 2))),
                   with: .color(lid))
        }

        switch style {
        case .open: openEye()
        case .surprised: openEye(scale: 1.18)
        case .happy:
            var p = Path()
            p.move(to: CGPoint(x: x - rx, y: y + ry * 0.35))
            p.addQuadCurve(to: CGPoint(x: x + rx, y: y + ry * 0.35), control: CGPoint(x: x, y: y - ry * 1.1))
            c.stroke(p, with: .color(ink), style: strokeStyle)
        case .closed:
            var p = Path()
            p.move(to: CGPoint(x: x - rx, y: y))
            p.addQuadCurve(to: CGPoint(x: x + rx, y: y), control: CGPoint(x: x, y: y + ry * 0.7))
            c.stroke(p, with: .color(ink), style: strokeStyle)
        case .dizzy:
            var p = Path()
            for i in 0..<36 {
                let ang = Double(i) * 0.5 + t * 8 * (inner > 0 ? 1 : -1)
                let r = rx * 1.05 * Double(i) / 36
                let pt = CGPoint(x: x + cos(ang) * r, y: y + sin(ang) * r * ry / rx)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            c.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: max(1, rx * 0.28), lineCap: .round))
        case .annoyed:
            openEye()
            lidOver(0.35)
            brow(outerY: -ry * 1.35, innerY: -ry * 0.85)
        case .sad:
            openEye(scale: 0.92)
            brow(outerY: -ry * 1.0, innerY: -ry * 1.5)
        case .sick:
            openEye(scale: 0.9)
            lidOver(0.5)
        }
    }

    static func drawMouth(_ c: GraphicsContext, style: MouthStyle, x: Double, y: Double, mw: Double, a: Double, t: Double) {
        let st = StrokeStyle(lineWidth: max(1.2, mw * 0.2), lineCap: .round, lineJoin: .round)
        switch style {
        case .smile:
            var p = Path()
            p.move(to: CGPoint(x: x - mw / 2, y: y))
            p.addQuadCurve(to: CGPoint(x: x + mw / 2, y: y), control: CGPoint(x: x, y: y + mw * 0.6))
            c.stroke(p, with: .color(ink), style: st)
        case .bigSmile:
            var p = Path()
            p.move(to: CGPoint(x: x - mw * 0.6, y: y - mw * 0.05))
            p.addQuadCurve(to: CGPoint(x: x + mw * 0.6, y: y - mw * 0.05), control: CGPoint(x: x, y: y + mw * 1.25))
            p.closeSubpath()
            c.fill(p, with: .color(ink))
            c.fill(Path(ellipseIn: CGRect(x: x - mw * 0.25, y: y + mw * 0.22, width: mw * 0.5, height: mw * 0.28)),
                   with: .color(Color(red: 1, green: 0.45, blue: 0.5)))
        case .frown:
            var p = Path()
            p.move(to: CGPoint(x: x - mw / 2, y: y + mw * 0.35))
            p.addQuadCurve(to: CGPoint(x: x + mw / 2, y: y + mw * 0.35), control: CGPoint(x: x, y: y - mw * 0.2))
            c.stroke(p, with: .color(ink), style: st)
        case .open:
            c.fill(Path(ellipseIn: CGRect(x: x - mw * 0.3, y: y - mw * 0.05, width: mw * 0.6, height: mw * 0.6)),
                   with: .color(ink))
        case .chew:
            let hh = mw * (0.12 + 0.45 * abs(sin(a * 14)))
            c.fill(Path(ellipseIn: CGRect(x: x - mw * 0.35, y: y + mw * 0.2 - hh / 2, width: mw * 0.7, height: hh)),
                   with: .color(ink))
        case .wavy:
            var p = Path()
            for i in 0...10 {
                let px = x - mw * 0.6 + mw * 1.2 * Double(i) / 10
                let py = y + mw * 0.2 + sin(Double(i) * 1.3 + t * 6) * mw * 0.12
                if i == 0 { p.move(to: CGPoint(x: px, y: py)) } else { p.addLine(to: CGPoint(x: px, y: py)) }
            }
            c.stroke(p, with: .color(ink), style: st)
        case .flat:
            var p = Path()
            p.move(to: CGPoint(x: x - mw * 0.3, y: y + mw * 0.2))
            p.addLine(to: CGPoint(x: x + mw * 0.3, y: y + mw * 0.2))
            c.stroke(p, with: .color(ink), style: st)
        case .yawn:
            let k = sin(min(a, 1.4) / 1.4 * .pi)
            let hh = mw * (0.2 + k * 0.9)
            c.fill(Path(ellipseIn: CGRect(x: x - mw * 0.35, y: y, width: mw * 0.7, height: hh)), with: .color(ink))
        }
    }

    static func drawZzz(_ c: GraphicsContext, S: Double, x: Double, y: Double, t: Double) {
        for i in 0..<3 {
            let ph = (t * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let fs = S * (0.06 + ph * 0.06)
            c.draw(Text("z").font(.system(size: max(4, fs), weight: .heavy, design: .rounded))
                    .foregroundColor(Color(red: 0.75, green: 0.85, blue: 1).opacity(1 - ph)),
                   at: CGPoint(x: x + ph * S * 0.12 + sin(ph * 6) * S * 0.015, y: y - ph * S * 0.25))
        }
    }

    static func drawPoops(_ c: GraphicsContext, S: Double, cx: Double, ground: Double, w: Double, count: Int, t: Double) {
        let slots = [cx + w * 0.78, cx - w * 0.78, cx + w * 1.02]
        let brown = Color(red: 0.5, green: 0.33, blue: 0.2)
        for i in 0..<min(count, 3) {
            let x = slots[i]
            let sizes: [(Double, Double)] = [(0.13, 0), (0.095, 0.045), (0.06, 0.085)]
            for (sw, up) in sizes {
                let ww = S * sw
                c.fill(Path(ellipseIn: CGRect(x: x - ww / 2, y: ground - S * up - ww * 0.42, width: ww, height: ww * 0.55)),
                       with: .color(brown))
            }
            let wob = sin(t * 3 + Double(i)) * S * 0.01
            var fume = Path()
            fume.move(to: CGPoint(x: x - S * 0.02, y: ground - S * 0.13))
            fume.addQuadCurve(to: CGPoint(x: x + S * 0.01, y: ground - S * 0.2), control: CGPoint(x: x + wob + S * 0.02, y: ground - S * 0.16))
            c.stroke(fume, with: .color(Color(red: 0.6, green: 0.7, blue: 0.4).opacity(0.7)), lineWidth: 1)
        }
    }

    static func eggPath(cx: Double, base: Double, w: Double, h: Double) -> Path {
        var p = Path()
        let top = CGPoint(x: cx, y: base - h)
        p.move(to: top)
        p.addCurve(to: CGPoint(x: cx + w / 2, y: base - h * 0.42),
                   control1: CGPoint(x: cx + w * 0.36, y: base - h), control2: CGPoint(x: cx + w / 2, y: base - h * 0.75))
        p.addCurve(to: CGPoint(x: cx, y: base),
                   control1: CGPoint(x: cx + w / 2, y: base - h * 0.1), control2: CGPoint(x: cx + w * 0.33, y: base))
        p.addCurve(to: CGPoint(x: cx - w / 2, y: base - h * 0.42),
                   control1: CGPoint(x: cx - w * 0.33, y: base), control2: CGPoint(x: cx - w / 2, y: base - h * 0.1))
        p.addCurve(to: top,
                   control1: CGPoint(x: cx - w / 2, y: base - h * 0.75), control2: CGPoint(x: cx - w * 0.36, y: base - h))
        p.closeSubpath()
        return p
    }

    static func drawEgg(_ base: GraphicsContext, S: Double, cx: Double, ground: Double, t: Double, s: PetSnapshot) {
        let p = s.hatchProgress
        let w = S * 0.5, h = S * 0.64
        if !s.mini {
            base.fill(Path(ellipseIn: CGRect(x: cx - w * 0.45, y: ground - S * 0.02, width: w * 0.9, height: S * 0.045)),
                      with: .color(.black.opacity(0.28)))
        }
        var c = base
        var wob = sin(t * (2.5 + p * 7)) * (0.03 + p * 0.12)
        if s.reaction == .pat || s.reaction == .poke { wob += sin(s.reactionAge * 25) * 0.15 * max(0, 1 - s.reactionAge) }
        c.translateBy(x: cx, y: ground)
        c.rotate(by: .radians(wob))
        c.translateBy(x: -cx, y: -ground)
        let egg = eggPath(cx: cx, base: ground, w: w, h: h)
        c.fill(egg, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.98, blue: 0.9),
                                                            Color(red: 0.92, green: 0.85, blue: 0.7)]),
                                          startPoint: CGPoint(x: cx, y: ground - h), endPoint: CGPoint(x: cx, y: ground)))
        for (px, py, r) in [(-0.18, 0.3, 0.07), (0.15, 0.5, 0.09), (-0.1, 0.72, 0.06), (0.2, 0.22, 0.05)] {
            let rr = w * r
            c.fill(Path(ellipseIn: CGRect(x: cx + w * px - rr, y: ground - h * py - rr, width: rr * 2, height: rr * 2)),
                   with: .color(Color(red: 0.5, green: 0.85, blue: 0.68).opacity(0.8)))
        }
        if p > 0.5 {
            let k = min(1, (p - 0.5) / 0.4)
            var crack = Path()
            let y0 = ground - h * 0.55
            crack.move(to: CGPoint(x: cx - w * 0.4 * k, y: y0))
            var x = cx - w * 0.4 * k
            var up = true
            while x < cx + w * 0.4 * k {
                x += w * 0.1
                crack.addLine(to: CGPoint(x: x, y: y0 + (up ? -h * 0.05 : h * 0.03)))
                up.toggle()
            }
            c.stroke(crack, with: .color(Color(red: 0.45, green: 0.38, blue: 0.3)), lineWidth: max(1, S * 0.012))
        }
        if !s.mini && s.reaction == .pat {
            let ph = min(1, s.reactionAge)
            c.fill(heart(CGPoint(x: cx + w * 0.5, y: ground - h - ph * S * 0.1), S * 0.08),
                   with: .color(Color(red: 1, green: 0.42, blue: 0.55).opacity(1 - ph)))
        }
    }

    static func shellCup(cx: Double, ground: Double, S: Double) -> Path {
        let w = S * 0.5, h = S * 0.3
        var p = Path()
        p.move(to: CGPoint(x: cx - w / 2, y: ground - h))
        var x = cx - w / 2
        var up = false
        while x < cx + w / 2 {
            x = min(cx + w / 2, x + w / 8)
            p.addLine(to: CGPoint(x: x, y: ground - h + (up ? -S * 0.04 : S * 0.02)))
            up.toggle()
        }
        p.addCurve(to: CGPoint(x: cx, y: ground), control1: CGPoint(x: cx + w / 2, y: ground - h * 0.3),
                   control2: CGPoint(x: cx + w * 0.3, y: ground))
        p.addCurve(to: CGPoint(x: cx - w / 2, y: ground - h), control1: CGPoint(x: cx - w * 0.3, y: ground),
                   control2: CGPoint(x: cx - w / 2, y: ground - h * 0.3))
        p.closeSubpath()
        return p
    }

    static func drawNote(_ c: GraphicsContext, S: Double, cx: Double, ground: Double, t: Double) {
        let w = S * 0.46, h = S * 0.34
        var cc = c
        cc.translateBy(x: cx, y: ground - h * 0.8)
        cc.rotate(by: .radians(sin(t * 1.5) * 0.06))
        cc.fill(Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: S * 0.02),
                with: .color(Color(red: 1, green: 0.97, blue: 0.9)))
        for i in 0..<3 {
            var l = Path()
            let y = -h * 0.2 + Double(i) * h * 0.2
            l.move(to: CGPoint(x: -w * 0.35, y: y))
            l.addLine(to: CGPoint(x: w * (i == 2 ? 0.1 : 0.35), y: y))
            cc.stroke(l, with: .color(.gray.opacity(0.6)), lineWidth: 1.5)
        }
        cc.fill(heart(CGPoint(x: w * 0.28, y: h * 0.25), S * 0.07), with: .color(Color(red: 1, green: 0.45, blue: 0.55)))
    }

    static func heart(_ c: CGPoint, _ s: Double) -> Path {
        var p = Path()
        let bottom = CGPoint(x: c.x, y: c.y + s * 0.45)
        p.move(to: bottom)
        p.addCurve(to: CGPoint(x: c.x, y: c.y - s * 0.18),
                   control1: CGPoint(x: c.x - s * 0.8, y: c.y - s * 0.05),
                   control2: CGPoint(x: c.x - s * 0.35, y: c.y - s * 0.65))
        p.addCurve(to: bottom,
                   control1: CGPoint(x: c.x + s * 0.35, y: c.y - s * 0.65),
                   control2: CGPoint(x: c.x + s * 0.8, y: c.y - s * 0.05))
        p.closeSubpath()
        return p
    }

    static func star(_ c: CGPoint, _ r: Double) -> Path {
        var p = Path()
        for i in 0..<8 {
            let ang = Double(i) * .pi / 4 - .pi / 2
            let rr = i % 2 == 0 ? r : r * 0.38
            let pt = CGPoint(x: c.x + cos(ang) * rr, y: c.y + sin(ang) * rr)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}
