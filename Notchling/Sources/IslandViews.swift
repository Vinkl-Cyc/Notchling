import SwiftUI
import AppKit

// MARK: - Shape (notch-style: flared top "ears", rounded bottom)

struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var earRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, earRadius) }
        set { bottomRadius = newValue.first; earRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let e = min(earRadius, rect.width / 4, rect.height / 2)
        let b = max(0, min(bottomRadius, rect.height - e, (rect.width - 2 * e) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + e, y: rect.minY + e), control: CGPoint(x: rect.minX + e, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + e, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + e + b, y: rect.maxY), control: CGPoint(x: rect.minX + e, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - e - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - e, y: rect.maxY - b), control: CGPoint(x: rect.maxX - e, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - e, y: rect.minY + e))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - e, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var pet: PetStore
    @ObservedObject var chat: ChatService

    var body: some View {
        let size = model.islandSize()
        let expanded = model.mode == .expanded
        let shape = IslandShape(bottomRadius: expanded ? 26 : (model.mode == .hidden ? 8 : 12),
                                earRadius: model.mode == .hidden && !model.hasNotch ? 0 : (expanded ? 12 : 7))
        ZStack(alignment: .top) {
            Color.clear
            ZStack(alignment: .top) {
                shape.fill(model.mode == .hidden && !model.hasNotch ? Color.white.opacity(0.22) : Color.black)
                Group {
                    switch model.mode {
                    case .hidden: EmptyView()
                    case .compact: CompactView(model: model, pet: pet, chat: chat, size: size)
                    case .expanded: ExpandedView(model: model, pet: pet, chat: chat)
                    }
                }
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: pet.speech != nil)
            .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 16, y: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "panel")
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Compact (peeking out of the notch)

struct CompactView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var pet: PetStore
    @ObservedObject var chat: ChatService
    let size: CGSize

    var body: some View {
        let side = max(40, (size.width - model.notchWidth) / 2)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PetCanvasView(pet: pet, size: model.notchHeight - 4, mini: true)
                    .frame(width: side)
                if model.hasNotch {
                    Spacer(minLength: model.notchWidth)
                } else {
                    Text(pet.pet.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(maxWidth: .infinity)
                }
                HStack(spacing: 3) {
                    if chat.isThinking { Text("🔎") }
                    if pet.pet.poops > 0 { Text("💩") }
                    Text(pet.mood.icon)
                }
                .font(.system(size: 13))
                .frame(width: side)
            }
            .frame(height: model.notchHeight)

            if let speech = pet.speech {
                Text(speech)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 16)
                    .frame(height: 24)
            }
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var pet: PetStore
    @ObservedObject var chat: ChatService

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 16) {
                petColumn
                VStack(spacing: 8) {
                    StatsRow(pet: pet.pet)
                    Picker("", selection: $model.tab) {
                        Text("🧺 Care").tag(IslandModel.Tab.care)
                        Text("💬 Ask").tag(IslandModel.Tab.ask)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if model.tab == .care {
                        CareView(pet: pet)
                    } else {
                        AskView(model: model, pet: pet, chat: chat)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .foregroundColor(.white)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(pet.pet.name).font(.system(size: 13, weight: .bold, design: .rounded))
            Text("\(pet.stage.label) · \(pet.ageText)")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: model.hasNotch ? model.notchWidth : 20)
            if model.tab == .ask && !chat.messages.isEmpty {
                IconButton(symbol: "arrow.counterclockwise", help: "Start a new chat") { chat.clear() }
            }
            IconButton(symbol: "gearshape.fill", help: "Settings") { AppDelegate.shared?.openSettings() }
            IconButton(symbol: "chevron.up", help: "Close (Esc)") { AppDelegate.shared?.island?.collapse() }
        }
        .padding(.horizontal, 24)
        .frame(height: model.notchHeight)
    }

    private var petColumn: some View {
        VStack(spacing: 4) {
            PetCanvasView(pet: pet, size: 160)
                .contentShape(Rectangle())
                .onTapGesture { pet.poke() }
                .help("Click to poke · stroke with the cursor to pat · drop a file to feed it")
            Text(pet.statusLine)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(height: 44, alignment: .top)
        }
        .frame(width: 170)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hover ? 0.18 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Stats

struct StatsRow: View {
    let pet: PetData

    var body: some View {
        HStack(spacing: 10) {
            StatBar(symbol: "fork.knife", label: "Food", value: pet.fullness)
            StatBar(symbol: "drop.fill", label: "Clean", value: pet.hygiene)
            StatBar(symbol: "heart.fill", label: "Joy", value: pet.happiness)
            StatBar(symbol: "bolt.fill", label: "Energy", value: pet.energy)
            StatBar(symbol: "cross.case.fill", label: "Health", value: pet.health)
        }
    }
}

struct StatBar: View {
    let symbol: String
    let label: String
    let value: Double

    var body: some View {
        let color: Color = value > 50 ? Color(red: 0.4, green: 0.85, blue: 0.55)
            : value > 25 ? Color(red: 1, green: 0.78, blue: 0.3) : Color(red: 1, green: 0.4, blue: 0.4)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 8))
                Text(label).font(.system(size: 9, weight: .medium, design: .rounded))
            }
            .foregroundColor(.white.opacity(0.7))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(color).frame(width: max(3, g.size.width * value / 100))
                }
            }
            .frame(height: 5)
        }
        .help("\(label): \(Int(value.rounded()))%")
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

// MARK: - Care tab

struct CareView: View {
    @ObservedObject var pet: PetStore

    var body: some View {
        if pet.pet.ranAway {
            VStack(spacing: 10) {
                Text("\(pet.pet.name) packed a tiny bag and went off to find more snacks and cuddles. 🥲\nThe note says: “thanks for the questions!”")
                    .font(.system(size: 12, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.85))
                Button("🥚  Hatch a new egg") { pet.newEgg() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.3, green: 0.7, blue: 0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let egg = pet.stage == .egg
            let asleep = pet.pet.isAsleep
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                CareButton(emoji: "🍙", title: "Meal", disabled: egg) { pet.feedMeal() }
                CareButton(emoji: "🍪", title: "Snack", disabled: egg) { pet.feedSnack() }
                CareButton(emoji: "🛁", title: "Bath", disabled: egg) { pet.bath() }
                CareButton(emoji: egg ? "🔥" : "🤚", title: egg ? "Warm egg" : "Pat") { pet.pat() }
                CareButton(emoji: asleep ? "☀️" : "🌙", title: asleep ? "Wake up" : "Bedtime", disabled: egg) { pet.toggleSleep() }
                CareButton(emoji: "💊", title: "Medicine", disabled: egg, highlight: pet.isSick) { pet.giveMedicine() }
            }
            Spacer(minLength: 0)
        }
    }
}

struct CareButton: View {
    let emoji: String
    let title: String
    var disabled = false
    var highlight = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(emoji).font(.system(size: 22))
                Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(highlight ? Color.red.opacity(0.28) : Color.white.opacity(hover && !disabled ? 0.16 : 0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { hover = $0 }
        .scaleEffect(hover && !disabled ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

// MARK: - Ask tab

struct AskView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var pet: PetStore
    @ObservedObject var chat: ChatService
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if !chat.isReady {
                            MessageBubble(message: ChatMessage(role: .pet,
                                text: chat.setupHint,
                                isError: true))
                        } else if chat.messages.isEmpty {
                            Text(pet.stage == .egg ? "The egg can't talk yet… keep it warm! 🥚"
                                 : "Ask \(pet.pet.name) anything — I'll search the web if I need to. You can also drop a file on the notch.")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(.white.opacity(0.55))
                                .padding(.top, 8)
                        }
                        ForEach(chat.messages) { msg in
                            MessageBubble(message: msg).id(msg.id)
                        }
                        if chat.isThinking {
                            Text("\(pet.pet.name) is thinking & searching…")
                                .font(.system(size: 11, design: .rounded).italic())
                                .foregroundColor(.white.opacity(0.6))
                                .id("thinking")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    if let last = chat.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: chat.isThinking) { _, thinking in
                    if thinking {
                        withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                    } else {
                        focused = true
                    }
                }
            }

            HStack(spacing: 6) {
                if let att = chat.attachment {
                    HStack(spacing: 3) {
                        Text("📄 " + att.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Button { chat.attachment = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .frame(maxWidth: 130)
                }
                TextField("Ask \(pet.pet.name) anything…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit(send)
                    .disabled(chat.isThinking)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                        .foregroundColor(Color(red: 0.45, green: 0.88, blue: 0.62))
                }
                .buttonStyle(.plain)
                .disabled(chat.isThinking || (draft.trimmingCharacters(in: .whitespaces).isEmpty && chat.attachment == nil))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.09)))
        }
        .onAppear {
            AppDelegate.shared?.island?.focusPanel()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 80_000_000)
                focused = true
            }
        }
        .onChange(of: focused) { _, isFocused in model.textFieldFocused = isFocused }
        .onDisappear { model.textFieldFocused = false }
    }

    private func send() {
        let text = draft
        guard !chat.isThinking else { return }
        draft = ""
        chat.send(text)
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        let mine = message.role == .user
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                if let name = message.attachmentName {
                    Text("📄 \(name)").font(.system(size: 10, weight: .semibold)).opacity(0.8)
                }
                Text(Self.rich(message.text))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.sources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(message.sources.prefix(6)) { src in
                                Link(destination: src.url) {
                                    Text("🔗 " + (src.url.host ?? src.title).replacingOccurrences(of: "www.", with: ""))
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.white.opacity(0.12)))
                                }
                                .help(src.title)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(mine ? Color(red: 0.25, green: 0.55, blue: 0.42)
                          : (message.isError ? Color.red.opacity(0.25) : Color.white.opacity(0.1)))
            )
            if !mine { Spacer(minLength: 24) }
        }
    }

    static func rich(_ text: String) -> AttributedString {
        if let a = try? AttributedString(markdown: text,
                                         options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return a
        }
        return AttributedString(text)
    }
}
