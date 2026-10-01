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
    var reactionStart: Double
    var hover: Bool
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
    var faceMode: Bool
}

struct PetCanvasView: View {
    @ObservedObject var pet: PetStore
    var size: CGFloat
    var mini: Bool = false
    var animate: Bool = true
    @State private var motion = PetMotion()
    @AppStorage(Pref.petStyle) private var petStyle = "body"

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("panel"))
            TimelineView(.animation(minimumInterval: mini ? 1.0 / 20 : 1.0 / 60, paused: !animate)) { timeline in
                let snap = snapshot(frame: frame)
                let m = motion
                Canvas { ctx, canvasSize in
                    m.step(snap)
                    PetRenderer.draw(ctx, size: canvasSize,
                                     t: timeline.date.timeIntervalSinceReferenceDate, s: snap, m: m)
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
        let hover = frame.insetBy(dx: mini ? -30 : -24, dy: mini ? -30 : -24).contains(m)
        let hatch = (Date().timeIntervalSince(p.born) + p.hatchBonus) / PetStore.hatchSeconds
        return PetSnapshot(
            stage: pet.stage, mood: pet.mood, reaction: pet.reaction,
            reactionAge: CACurrentMediaTime() - pet.reactionStart, reactionStart: pet.reactionStart,
            hover: hover, emoji: pet.reactionEmoji,
            poops: p.poops, hygiene: p.hygiene, happiness: p.happiness, asleep: p.isAsleep,
            sick: pet.isSick, thinking: pet.isThinking, expectingFile: pet.expectingFile,
            look: look, hatchProgress: min(1, max(0, hatch)), mini: mini, faceMode: petStyle == "face")
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

    enum EyeStyle { case open, happy, closed, dizzy, annoyed, sad, surprised, sick, wink }
    enum MouthStyle { case smile, bigSmile, frown, open, chew, wavy, flat, yawn }

    static func draw(_ base: GraphicsContext, size: CGSize, t: Double, s: PetSnapshot, m: PetMotion) {
        let S = Double(min(size.width, size.height))
        let cx0 = Double(size.width) / 2
        let ground = Double(size.height) * (s.mini ? 0.94 : 0.88)
        let a = s.reactionAge

        if s.stage == .egg {
            drawEgg(base, S: S, cx: cx0, ground: ground, t: t, s: s)
            return
        }
        if s.mood == .gone {
            drawNote(base, S: S, cx: cx0, ground: ground, t: t)
            return
        }
        if s.faceMode {
            drawFaceMode(base, S: S, cx0: cx0, ground: ground, t: t, s: s, m: m)
            return
        }

        // ---- Motion (from PetMotion) ----
        let scale: Double
        switch s.stage {
        case .egg, .baby: scale = 0.74
        case .kid: scale = 0.84
        case .teen: scale = 0.93
        case .adult: scale = 1.0
        }
        let sc = s.mini ? 1.0 : scale
        let w0 = S * 0.62 * sc, h0 = S * 0.56 * sc
        let w = w0 * m.sx
        let h = h0 * m.sy
        let lift = max(0, m.oy) * S
        let cx = cx0 + m.ox * S
        let baseY = ground - lift
        let centerY = baseY - h * 0.5

        // Soft contact shadow — shrinks and fades as it hops
        if !s.mini {
            let k = max(0.35, 1 - m.oy * 3)
            let sw = w0 * 0.95 * k
            base.fill(Path(ellipseIn: CGRect(x: cx - sw / 2, y: ground - S * 0.025, width: sw, height: S * 0.05)),
                      with: .radialGradient(Gradient(stops: [.init(color: .black.opacity(0.38 * k), location: 0),
                                                             .init(color: .black.opacity(0), location: 1)]),
                                            center: CGPoint(x: cx, y: ground), startRadius: 0, endRadius: sw / 2))
            drawPoops(base, S: S, cx: cx0, ground: ground, w: w0, count: s.poops, t: t)
        }

        var c = base
        c.translateBy(x: cx, y: ground)
        c.rotate(by: .radians(m.tilt))
        c.translateBy(x: -cx, y: -ground)
        if m.roll != 0 {
            c.translateBy(x: cx, y: centerY)
            c.rotate(by: .radians(m.roll))
            c.translateBy(x: -cx, y: -centerY)
        }

        // Project a point on the body's front surface (fx, fy in -1…1, up = +) as if the body
        // were a round 3D shape turned by yaw/pitch. Returns screen point, foreshortening, visibility.
        func proj(_ fx: Double, _ fy: Double) -> (p: CGPoint, kx: Double, ky: Double, vis: Double) {
            let th = asin(max(-0.99, min(0.99, fx))) + m.yaw
            let ph = asin(max(-0.99, min(0.99, fy))) - m.pitch
            let x = cx + sin(th) * cos(ph) * w / 2
            let y = centerY - sin(ph) * h / 2
            return (CGPoint(x: x, y: y), max(0.12, cos(th)), max(0.12, cos(ph)), cos(th) * cos(ph))
        }

        // ---- Colours ----
        let mintTop = RGB(r: 0.66, g: 0.95, b: 0.82), mintBottom = RGB(r: 0.27, g: 0.66, b: 0.53)
        let sickTop = RGB(r: 0.86, g: 0.89, b: 0.6), sickBottom = RGB(r: 0.56, g: 0.62, b: 0.3)
        let k = s.sick ? 0.75 : 0.0
        let top = mintTop.mix(sickTop, k), bottom = mintBottom.mix(sickBottom, k)
        let dark = bottom.mix(RGB(r: 0.08, g: 0.28, b: 0.22), 0.3)
        let limbGrad = Gradient(colors: [top.mix(bottom, 0.55).color, dark.color])

        // ---- Arms (behind body) ----
        var leftRaise = 0.35 + m.arms, rightRaise = 0.35 + m.arms
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
                // Arms slide around the body a little as it turns
                ac.translateBy(x: cx + side * w * 0.40 + sin(m.yaw) * w * 0.07, y: baseY - h * 0.42)
                ac.rotate(by: .radians(-side * raise))
                let aw = w * 0.15, ah = w * 0.27
                let arm = Path(ellipseIn: CGRect(x: -aw / 2, y: -aw * 0.2, width: aw, height: ah))
                ac.fill(arm, with: .linearGradient(limbGrad, startPoint: CGPoint(x: -aw / 2, y: 0),
                                                   endPoint: CGPoint(x: aw / 2, y: ah)))
                ac.fill(Path(ellipseIn: CGRect(x: -aw * 0.28, y: ah * 0.12, width: aw * 0.22, height: ah * 0.35)),
                        with: .color(.white.opacity(0.25)))
            }
        }

        // ---- Glossy body ----
        let body = bodyPath(cx: cx, base: baseY, w: w, h: h)
        // 1. Key light from the upper-left
        c.fill(body, with: .linearGradient(Gradient(colors: [top.color, bottom.color]),
                                           startPoint: CGPoint(x: cx - w * 0.32, y: baseY - h),
                                           endPoint: CGPoint(x: cx + w * 0.3, y: baseY)))
        // 2. Warm bounce light glowing up from the ground (feels squishy / translucent)
        c.fill(body, with: .radialGradient(Gradient(stops: [.init(color: top.color.opacity(0.45), location: 0),
                                                            .init(color: top.color.opacity(0), location: 1)]),
                                           center: CGPoint(x: cx + sin(m.yaw) * w * 0.1, y: baseY + h * 0.05),
                                           startRadius: 0, endRadius: w * 0.42))
        // 3. Tummy patch that turns with the body
        let belly = proj(0, -0.38)
        if belly.vis > 0 {
            var bc = c
            bc.clip(to: body)
            let bw = w * 0.48 * belly.kx, bh = h * 0.38 * belly.ky
            bc.fill(Path(ellipseIn: CGRect(x: belly.p.x - bw / 2, y: belly.p.y - bh / 2, width: bw, height: bh)),
                    with: .radialGradient(Gradient(stops: [.init(color: .white.opacity(0.26), location: 0),
                                                           .init(color: .white.opacity(0.14), location: 0.7),
                                                           .init(color: .white.opacity(0), location: 1)]),
                                          center: belly.p, startRadius: 0, endRadius: max(bw, bh) / 2))
        }
        // 4. Rim shadow: darkens the edges so it reads as round
        c.fill(body, with: .radialGradient(Gradient(stops: [.init(color: .clear, location: 0),
                                                            .init(color: .clear, location: 0.58),
                                                            .init(color: dark.color.opacity(0.28), location: 0.85),
                                                            .init(color: .black.opacity(0.3), location: 1)]),
                                           center: CGPoint(x: cx - w * 0.08, y: centerY - h * 0.08),
                                           startRadius: 0, endRadius: max(w, h) * 0.6))

        // Dirt (moves with the body's turn)
        if s.hygiene < 45 && !s.mini {
            let o = (45 - s.hygiene) / 45 * 0.7
            let mud = Color(red: 0.45, green: 0.32, blue: 0.2).opacity(o)
            var dc = c
            dc.clip(to: body)
            for (px, py, r) in [(-0.4, -0.1, 0.09), (0.38, 0.24, 0.07), (0.12, -0.56, 0.08), (-0.1, 0.4, 0.05)] {
                let q = proj(px, py)
                guard q.vis > 0 else { continue }
                let rr = w * r
                dc.fill(Path(ellipseIn: CGRect(x: q.p.x - rr * q.kx, y: q.p.y - rr * 0.7,
                                               width: rr * 2 * q.kx, height: rr * 1.4)), with: .color(mud))
            }
        }

        // Feet
        let fw = w0 * 0.24, fh = S * 0.075 * sc
        for side in [-1.0, 1.0] {
            let fx = cx + side * w * 0.2 + sin(m.yaw) * w * 0.05
            let foot = Path(ellipseIn: CGRect(x: fx - fw / 2, y: baseY - fh * 0.62, width: fw, height: fh))
            c.fill(foot, with: .linearGradient(limbGrad, startPoint: CGPoint(x: fx, y: baseY - fh * 0.62),
                                               endPoint: CGPoint(x: fx, y: baseY + fh * 0.4)))
            c.fill(Path(ellipseIn: CGRect(x: fx - fw * 0.28, y: baseY - fh * 0.5, width: fw * 0.3, height: fh * 0.22)),
                   with: .color(.white.opacity(0.22)))
        }

        // ---- Face (projected onto the round body so it turns in 3D) ----
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
                if let idle = m.idleEye { eye = idle; if idle == .happy { mouth = .bigSmile } }
            }
        }
        let openable: [EyeStyle] = [.open, .surprised, .sad, .sick, .annoyed]
        if m.open < 0.35 && openable.contains(eye) { eye = .closed }

        var face = c
        face.clip(to: body)
        let rx = S * 0.052 * sc, ry = S * 0.066 * sc
        let eyeFy = 0.28
        let lidColor = top.mix(bottom, 0.3).color
        let pupilLook = CGVector(dx: s.look.dx * 0.4, dy: s.look.dy * 0.4)
        for side in [-1.0, 1.0] {
            let e = proj(side * 0.38, eyeFy)
            guard e.vis > 0.05 else { continue }
            var ec = face
            ec.translateBy(x: e.p.x, y: e.p.y)
            let lidScale = openable.contains(eye) ? max(0.3, m.open) : 1
            ec.scaleBy(x: e.kx * m.es, y: e.ky * m.es * lidScale)
            drawEye(ec, style: eye, x: 0, y: 0, rx: rx, ry: ry, inner: -side, look: pupilLook, t: t, lid: lidColor)
            // Blush cheeks
            if !s.sick {
                let ch = proj(side * 0.5, eyeFy - (ry * 1.25) / (h / 2))
                if ch.vis > 0.05 {
                    let blush = s.reaction == .pat ? 0.75 : 0.22 + s.happiness / 100 * 0.3
                    let cw = rx * 1.6 * ch.kx, chh = ry * 0.62 * ch.ky
                    face.fill(Path(ellipseIn: CGRect(x: ch.p.x - cw / 2, y: ch.p.y - chh / 2, width: cw, height: chh)),
                              with: .radialGradient(Gradient(stops: [
                                    .init(color: Color(red: 1, green: 0.48, blue: 0.6).opacity(blush), location: 0),
                                    .init(color: Color(red: 1, green: 0.48, blue: 0.6).opacity(0), location: 1)]),
                                    center: ch.p, startRadius: 0, endRadius: cw / 2))
                }
            }
        }
        let mo = proj(0, eyeFy - (S * 0.1 * sc) / (h / 2))
        if mo.vis > 0.05 {
            var mc = face
            mc.translateBy(x: mo.p.x, y: mo.p.y)
            mc.scaleBy(x: mo.kx, y: mo.ky)
            drawMouth(mc, style: mouth, x: 0, y: 0, mw: S * 0.08 * sc, a: a, t: t)
        }
        let eyeY = proj(0, eyeFy).p.y

        // 5. Specular shine on top of everything (fixed light, so it stays put while the face turns)
        c.fill(body, with: .radialGradient(Gradient(stops: [.init(color: .white.opacity(0.55), location: 0),
                                                            .init(color: .white.opacity(0.12), location: 0.55),
                                                            .init(color: .white.opacity(0), location: 1)]),
                                           center: CGPoint(x: cx - w * 0.2, y: baseY - h * 0.78),
                                           startRadius: 0, endRadius: w * 0.3))
        var shine = c
        shine.clip(to: body)
        shine.translateBy(x: cx - w * 0.23, y: baseY - h * 0.8)
        shine.rotate(by: .radians(-0.5))
        shine.fill(Path(ellipseIn: CGRect(x: -w * 0.07, y: -h * 0.03, width: w * 0.14, height: h * 0.06)),
                   with: .color(.white.opacity(0.7)))

        // Sprout sits on top of the head and turns with it
        let crown = proj(0, 0.97)
        drawSprout(c, S: S * sc, top: CGPoint(x: crown.p.x, y: baseY - h + h * 0.005), t: t, s: s,
                   lean: m.tilt + sin(m.yaw) * 0.25)

        // Idle love hearts
        if !s.mini {
            let now = CACurrentMediaTime()
            for hrt in m.hearts where now >= hrt.born {
                let ph = (now - hrt.born) / 1.6
                let x = cx + hrt.x * w + sin(ph * 7) * S * 0.02
                let y = baseY - h - ph * S * 0.25
                c.fill(heart(CGPoint(x: x, y: y), S * 0.075 * (1 - ph * 0.3)),
                       with: .color(Color(red: 1, green: 0.42, blue: 0.55).opacity(1 - ph)))
            }
        }

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

    // MARK: - Face mode (just an expressive glowing face)

    static func faceExpression(_ s: PetSnapshot, _ m: PetMotion) -> (EyeStyle, MouthStyle, hearts: Bool) {
        var eye: EyeStyle = .open
        var mouth: MouthStyle = .smile
        var heartEyes = false
        switch s.reaction {
        case .dizzy: eye = .dizzy; mouth = .wavy
        case .poke: eye = .annoyed; mouth = .frown
        case .pat: heartEyes = true; mouth = .bigSmile
        case .happy, .wave, .hatch: eye = .happy; mouth = .bigSmile
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
                case .dirty: eye = .sick; mouth = .flat
                case .sleepy: eye = .sick; mouth = .flat
                case .happy: eye = .open; mouth = .bigSmile
                default: eye = .open; mouth = .smile
                }
                if let idle = m.idleEye { eye = idle; if idle == .happy { mouth = .bigSmile } }
            }
        }
        if m.open < 0.3 && [EyeStyle.open, .surprised, .sad, .sick, .annoyed].contains(eye) { eye = .closed }
        return (eye, mouth, heartEyes)
    }

    static func drawFaceMode(_ base: GraphicsContext, S: Double, cx0: Double, ground: Double, t: Double,
                             s: PetSnapshot, m: PetMotion) {
        let sc: Double
        switch s.stage {
        case .egg, .baby: sc = 0.82
        case .kid: sc = 0.9
        case .teen: sc = 0.96
        case .adult: sc = 1.0
        }
        let k = s.mini ? 1.25 : sc
        let a = s.reactionAge

        // Colours: glowing mint, yellowish when sick, dimmer when asleep
        let mint = RGB(r: 0.55, g: 1.0, b: 0.82)
        let sickC = RGB(r: 0.95, g: 0.92, b: 0.5)
        var eyeRGB = mint.mix(sickC, s.sick ? 0.8 : 0)
        if s.asleep { eyeRGB = eyeRGB.mix(RGB(r: 0.3, g: 0.45, b: 0.45), 0.35) }
        let eyeColor = eyeRGB.color
        let pink = Color(red: 1, green: 0.5, blue: 0.66)

        // Face position: slides toward where it's looking, hops, shuffles
        let fcx = cx0 + m.ox * S + sin(m.yaw) * S * (s.mini ? 0.16 : 0.14)
        let fcy = (s.mini ? ground - S * 0.5 : ground - S * 0.46) - m.oy * S + m.pitch * S * 0.14

        if !s.mini {
            drawPoops(base, S: S, cx: cx0, ground: ground, w: S * 0.62 * sc, count: s.poops, t: t)
        }

        var c = base
        c.translateBy(x: fcx, y: fcy + S * 0.2)
        c.rotate(by: .radians(m.tilt))
        c.translateBy(x: -fcx, y: -(fcy + S * 0.2))
        if m.roll != 0 {
            c.translateBy(x: fcx, y: fcy)
            c.rotate(by: .radians(m.roll))
            c.translateBy(x: -fcx, y: -fcy)
        }

        let (eye, mouth, heartEyes) = faceExpression(s, m)
        let ew = S * 0.13 * k * m.sx * m.es
        let eh = S * 0.2 * k * m.sy * m.es
        let spacing = S * 0.17 * k * (1 - abs(sin(m.yaw)) * 0.22)

        var glow = c
        glow.addFilter(.shadow(color: eyeColor.opacity(s.asleep ? 0.35 : 0.75), radius: S * (s.mini ? 0.05 : 0.035)))

        // ---- Eyes ----
        for side in [-1.0, 1.0] {
            let persp = 1 + side * sin(m.yaw) * 0.14          // near eye a bit bigger as it turns
            let ex = fcx + side * spacing
            var g = glow
            g.translateBy(x: ex, y: fcy)
            g.scaleBy(x: persp, y: persp)
            var lidCtx = c
            lidCtx.translateBy(x: ex, y: fcy)
            lidCtx.scaleBy(x: persp, y: persp)
            if heartEyes {
                let beat = 1 + sin(a * 12) * 0.08
                g.fill(heart(.zero, ew * 1.35 * beat), with: .color(pink))
            } else {
                faceEye(g, lid: lidCtx, style: eye, w: ew, h: eh, open: m.open, side: side, t: t, color: eyeColor)
            }
        }

        // ---- Cheeks ----
        if !s.sick {
            let blush = s.reaction == .pat ? 0.65 : 0.18 + s.happiness / 100 * 0.25
            for side in [-1.0, 1.0] {
                let p = CGPoint(x: fcx + side * spacing * 1.35, y: fcy + eh * 0.62)
                let bw = ew * 1.15, bh = ew * 0.55
                c.fill(Path(ellipseIn: CGRect(x: p.x - bw / 2, y: p.y - bh / 2, width: bw, height: bh)),
                       with: .radialGradient(Gradient(stops: [.init(color: pink.opacity(blush), location: 0),
                                                              .init(color: pink.opacity(0), location: 1)]),
                                             center: p, startRadius: 0, endRadius: bw / 2))
            }
        }

        // ---- Mouth ----
        if !s.mini || mouth == .bigSmile || mouth == .open || mouth == .chew {
            drawMouth(glow, style: mouth, x: fcx, y: fcy + eh * 0.72, mw: S * 0.07 * k, a: a, t: t, color: eyeColor)
        }

        // ---- Sprout antenna (Pip's signature) ----
        drawSprout(c, S: S * (s.mini ? 0.75 : 0.85) * sc, top: CGPoint(x: fcx, y: fcy - eh * 0.62 - S * 0.03),
                   t: t, s: s, lean: m.tilt + sin(m.yaw) * 0.3)

        if s.mini {
            if s.asleep { drawZzz(base, S: S * 1.6, x: fcx + S * 0.28, y: fcy - eh * 0.5, t: t) }
            return
        }

        // ---- Overlays ----
        let topY = fcy - eh * 0.8
        let now = CACurrentMediaTime()
        for hrt in m.hearts where now >= hrt.born {
            let ph = (now - hrt.born) / 1.6
            c.fill(heart(CGPoint(x: fcx + hrt.x * S * 0.5 + sin(ph * 7) * S * 0.02, y: topY - ph * S * 0.22),
                         S * 0.07 * (1 - ph * 0.3)), with: .color(pink.opacity(1 - ph)))
        }
        switch s.reaction {
        case .pat, .happy:
            for i in 0..<3 {
                let ph = (a * 0.9 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let x = fcx + (Double(i) - 1) * spacing * 1.4 + sin(ph * 6) * S * 0.03
                c.fill(heart(CGPoint(x: x, y: topY - ph * S * 0.22), S * 0.075 * (1 - ph * 0.3)),
                       with: .color(pink.opacity(1 - ph)))
            }
        case .eat, .snack, .medicine:
            let dur = s.reaction == .eat ? 2.0 : 1.6
            let left = max(0.15, 1 - a / dur)
            c.draw(Text(s.emoji).font(.system(size: max(4, S * 0.18 * left))),
                   at: CGPoint(x: fcx + spacing * 1.1, y: fcy + eh * 0.85))
        case .bath:
            for i in 0..<10 {
                let ph = (a * 0.8 + Double(i) / 10).truncatingRemainder(dividingBy: 1)
                let x = fcx + sin(Double(i) * 2.3) * S * 0.36 + sin(ph * 8 + Double(i)) * S * 0.02
                let y = fcy + S * 0.3 - ph * S * 0.75
                let r = S * (0.018 + Double(i % 3) * 0.011)
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                c.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.15 * (1 - ph))))
                c.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.8 * (1 - ph))), lineWidth: 1)
            }
        case .dizzy:
            for i in 0..<3 {
                let ang = t * 5 + Double(i) * 2.094
                c.fill(star(CGPoint(x: fcx + cos(ang) * S * 0.3, y: topY + sin(ang) * S * 0.05), S * 0.04),
                       with: .color(Color(red: 1, green: 0.85, blue: 0.3)))
            }
        case .hatch:
            let o = max(0, 1 - max(0, a - 1.2) / 0.8)
            for i in 0..<5 {
                let ang = Double(i) * 1.2566 + 0.3
                let d = S * (0.3 + a * 0.1)
                c.fill(star(CGPoint(x: fcx + cos(ang) * d, y: fcy + sin(ang) * d * 0.6), S * 0.035 * o),
                       with: .color(Color(red: 1, green: 0.9, blue: 0.4).opacity(o)))
            }
        default: break
        }
        if s.sick {
            let dy = (t * 0.6).truncatingRemainder(dividingBy: 1)
            let dx = fcx + spacing * 1.7, y0 = fcy - eh * 0.4 + dy * S * 0.06
            var drop = Path()
            drop.move(to: CGPoint(x: dx, y: y0 - S * 0.035))
            drop.addQuadCurve(to: CGPoint(x: dx, y: y0 + S * 0.025), control: CGPoint(x: dx + S * 0.045, y: y0 + S * 0.02))
            drop.addQuadCurve(to: CGPoint(x: dx, y: y0 - S * 0.035), control: CGPoint(x: dx - S * 0.045, y: y0 + S * 0.02))
            c.fill(drop, with: .color(Color(red: 0.55, green: 0.8, blue: 1).opacity(0.9 - dy * 0.6)))
        }
        if s.hygiene < 45 {
            // Little specks of dirt floating around the face, plus stink lines when really dirty
            let o = (45 - s.hygiene) / 45 * 0.8
            for (px, py) in [(-0.3, 0.12), (0.34, -0.05), (0.18, 0.2), (-0.22, -0.18)] {
                let r = S * 0.012
                c.fill(Path(ellipseIn: CGRect(x: fcx + px * S - r, y: fcy + py * S - r, width: r * 2, height: r * 2)),
                       with: .color(Color(red: 0.6, green: 0.45, blue: 0.3).opacity(o)))
            }
            if s.hygiene < 20 {
                for i in 0..<3 {
                    let ph = (t * 0.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    let x0 = fcx + (Double(i) - 1) * S * 0.2
                    var line = Path()
                    for j in 0...8 {
                        let yy = topY - Double(j) * S * 0.016 - ph * S * 0.08
                        let xx = x0 + sin(Double(j) * 0.9 + t * 3) * S * 0.014
                        if j == 0 { line.move(to: CGPoint(x: xx, y: yy)) } else { line.addLine(to: CGPoint(x: xx, y: yy)) }
                    }
                    c.stroke(line, with: .color(Color(red: 0.6, green: 0.7, blue: 0.4).opacity(0.7 * (1 - ph))), lineWidth: 1.5)
                }
            }
        }
        if s.asleep && s.reaction == .none {
            drawZzz(base, S: S, x: fcx + spacing * 1.6, y: topY, t: t)
        }
        if s.thinking {
            let bx = fcx + spacing * 1.9, by = topY
            for i in 0..<3 {
                let r = S * (0.016 + Double(i) * 0.009)
                let on = Int(t * 3) % 3 == i
                c.fill(Path(ellipseIn: CGRect(x: bx + Double(i) * S * 0.045 - r, y: by - Double(i) * S * 0.04 - r,
                                              width: r * 2, height: r * 2)),
                       with: .color(eyeColor.opacity(on ? 0.95 : 0.4)))
            }
            c.draw(Text("🔎").font(.system(size: S * 0.11)),
                   at: CGPoint(x: bx + S * 0.12, y: by - S * 0.15 + sin(t * 4) * S * 0.01))
        }
    }

    /// One glowing eye centred at (0,0). `lid` is an unglowed context for "eyelid" cut-outs
    /// (drawn in black, which blends with the island's black background).
    static func faceEye(_ g: GraphicsContext, lid: GraphicsContext, style: EyeStyle, w: Double, h: Double,
                        open: Double, side: Double, t: Double, color: Color) {
        let thick = StrokeStyle(lineWidth: max(1.5, w * 0.34), lineCap: .round, lineJoin: .round)
        func pill(_ ww: Double, _ hh: Double) {
            let r = min(ww, hh) / 2
            g.fill(Path(roundedRect: CGRect(x: -ww / 2, y: -hh / 2, width: ww, height: hh), cornerRadius: r),
                   with: .color(color))
            // tiny inner sparkle
            let sp = ww * 0.22
            g.fill(Path(ellipseIn: CGRect(x: -ww * 0.22 - sp / 2, y: -hh * 0.28 - sp / 2, width: sp, height: sp)),
                   with: .color(.white.opacity(0.75)))
        }
        func cutLid(innerY: Double, outerY: Double) {
            let innerX = -side * w * 0.8, outerX = side * w * 0.8
            var p = Path()
            p.move(to: CGPoint(x: innerX, y: innerY))
            p.addLine(to: CGPoint(x: outerX, y: outerY))
            p.addLine(to: CGPoint(x: outerX, y: -h * 1.6))
            p.addLine(to: CGPoint(x: innerX, y: -h * 1.6))
            p.closeSubpath()
            lid.fill(p, with: .color(.black))
        }
        let hh = h * max(0.08, min(1, open))
        switch style {
        case .open:
            pill(w, hh)
        case .surprised:
            pill(w * 1.15, h * 1.08)
        case .happy:
            var p = Path()
            p.move(to: CGPoint(x: -w * 0.55, y: h * 0.12))
            p.addQuadCurve(to: CGPoint(x: w * 0.55, y: h * 0.12), control: CGPoint(x: 0, y: -h * 0.55))
            g.stroke(p, with: .color(color), style: thick)
        case .closed:
            var p = Path()
            p.move(to: CGPoint(x: -w * 0.55, y: 0))
            p.addQuadCurve(to: CGPoint(x: w * 0.55, y: 0), control: CGPoint(x: 0, y: h * 0.3))
            g.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: max(1.5, w * 0.26), lineCap: .round))
        case .sad:
            pill(w, hh * 0.92)
            cutLid(innerY: -h * 0.5, outerY: -h * 0.02)
        case .annoyed:
            pill(w, hh)
            cutLid(innerY: -h * 0.02, outerY: -h * 0.42)
        case .sick:
            pill(w, hh * 0.9)
            cutLid(innerY: -h * 0.08, outerY: -h * 0.08)
        case .dizzy:
            var p = Path()
            for i in 0..<40 {
                let ang = Double(i) * 0.45 + t * 8 * side
                let r = w * 0.62 * Double(i) / 40
                let pt = CGPoint(x: cos(ang) * r, y: sin(ang) * r * h / w * 0.8)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            g.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: max(1.2, w * 0.16), lineCap: .round))
        case .wink:
            if side < 0 {
                var p = Path()
                p.move(to: CGPoint(x: -w * 0.55, y: h * 0.12))
                p.addQuadCurve(to: CGPoint(x: w * 0.55, y: h * 0.12), control: CGPoint(x: 0, y: -h * 0.55))
                g.stroke(p, with: .color(color), style: thick)
            } else {
                pill(w, hh)
            }
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

    static func drawSprout(_ c: GraphicsContext, S: Double, top: CGPoint, t: Double, s: PetSnapshot, lean: Double = 0) {
        let sway = sin(t * 1.6) * S * 0.02 - lean * S * 0.12
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
            let L = S * len
            lc.fill(leaf(L), with: .linearGradient(Gradient(colors: [Color(red: 0.6, green: 0.92, blue: 0.5), leafColor,
                                                                      Color(red: 0.25, green: 0.6, blue: 0.3)]),
                                                     startPoint: CGPoint(x: 0, y: -L * 0.3), endPoint: CGPoint(x: L, y: L * 0.3)))
            var vein = Path()
            vein.move(to: CGPoint(x: L * 0.08, y: 0))
            vein.addQuadCurve(to: CGPoint(x: L * 0.85, y: 0), control: CGPoint(x: L * 0.5, y: -L * 0.06))
            lc.stroke(vein, with: .color(.white.opacity(0.35)), lineWidth: max(0.6, L * 0.05))
            lc.fill(Path(ellipseIn: CGRect(x: L * 0.25, y: -L * 0.2, width: L * 0.25, height: L * 0.08)),
                    with: .color(.white.opacity(0.35)))
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
        case .wink:
            if inner > 0 {
                var p = Path()
                p.move(to: CGPoint(x: x - rx, y: y + ry * 0.35))
                p.addQuadCurve(to: CGPoint(x: x + rx, y: y + ry * 0.35), control: CGPoint(x: x, y: y - ry * 1.1))
                c.stroke(p, with: .color(ink), style: strokeStyle)
            } else {
                openEye()
            }
        }
    }

    static func drawMouth(_ c: GraphicsContext, style: MouthStyle, x: Double, y: Double, mw: Double, a: Double, t: Double, color: Color = ink) {
        let st = StrokeStyle(lineWidth: max(1.2, mw * 0.2), lineCap: .round, lineJoin: .round)
        switch style {
        case .smile:
            var p = Path()
            p.move(to: CGPoint(x: x - mw / 2, y: y))
            p.addQuadCurve(to: CGPoint(x: x + mw / 2, y: y), control: CGPoint(x: x, y: y + mw * 0.6))
            c.stroke(p, with: .color(color), style: st)
        case .bigSmile:
            var p = Path()
            p.move(to: CGPoint(x: x - mw * 0.6, y: y - mw * 0.05))
            p.addQuadCurve(to: CGPoint(x: x + mw * 0.6, y: y - mw * 0.05), control: CGPoint(x: x, y: y + mw * 1.25))
            p.closeSubpath()
            c.fill(p, with: .color(color))
            c.fill(Path(ellipseIn: CGRect(x: x - mw * 0.25, y: y + mw * 0.22, width: mw * 0.5, height: mw * 0.28)),
                   with: .color(Color(red: 1, green: 0.45, blue: 0.5)))
        case .frown:
            var p = Path()
            p.move(to: CGPoint(x: x - mw / 2, y: y + mw * 0.35))
            p.addQuadCurve(to: CGPoint(x: x + mw / 2, y: y + mw * 0.35), control: CGPoint(x: x, y: y - mw * 0.2))
            c.stroke(p, with: .color(color), style: st)
        case .open:
            c.fill(Path(ellipseIn: CGRect(x: x - mw * 0.3, y: y - mw * 0.05, width: mw * 0.6, height: mw * 0.6)),
                   with: .color(color))
        case .chew:
            let hh = mw * (0.12 + 0.45 * abs(sin(a * 14)))
            c.fill(Path(ellipseIn: CGRect(x: x - mw * 0.35, y: y + mw * 0.2 - hh / 2, width: mw * 0.7, height: hh)),
                   with: .color(color))
        case .wavy:
            var p = Path()
            for i in 0...10 {
                let px = x - mw * 0.6 + mw * 1.2 * Double(i) / 10
                let py = y + mw * 0.2 + sin(Double(i) * 1.3 + t * 6) * mw * 0.12
                if i == 0 { p.move(to: CGPoint(x: px, y: py)) } else { p.addLine(to: CGPoint(x: px, y: py)) }
            }
            c.stroke(p, with: .color(color), style: st)
        case .flat:
            var p = Path()
            p.move(to: CGPoint(x: x - mw * 0.3, y: y + mw * 0.2))
            p.addLine(to: CGPoint(x: x + mw * 0.3, y: y + mw * 0.2))
            c.stroke(p, with: .color(color), style: st)
        case .yawn:
            let k = sin(min(a, 1.4) / 1.4 * .pi)
            let hh = mw * (0.2 + k * 0.9)
            c.fill(Path(ellipseIn: CGRect(x: x - mw * 0.35, y: y, width: mw * 0.7, height: hh)), with: .color(color))
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
        // Gloss: rim shadow + shine
        c.fill(egg, with: .radialGradient(Gradient(stops: [.init(color: .clear, location: 0),
                                                           .init(color: .clear, location: 0.6),
                                                           .init(color: Color(red: 0.45, green: 0.35, blue: 0.2).opacity(0.3), location: 1)]),
                                          center: CGPoint(x: cx - w * 0.06, y: ground - h * 0.55),
                                          startRadius: 0, endRadius: h * 0.6))
        c.fill(egg, with: .radialGradient(Gradient(stops: [.init(color: .white.opacity(0.75), location: 0),
                                                           .init(color: .white.opacity(0), location: 1)]),
                                          center: CGPoint(x: cx - w * 0.17, y: ground - h * 0.74),
                                          startRadius: 0, endRadius: w * 0.3))
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
