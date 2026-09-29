import AppKit
import SwiftUI

// MARK: - Shared island state

@MainActor
final class IslandModel: ObservableObject {
    static let shared = IslandModel()

    enum Mode { case hidden, compact, expanded }
    enum Tab: String { case care = "Care", ask = "Ask" }

    @Published var mode: Mode = .hidden
    @Published var tab: Tab = .care
    @Published var dropHover = false

    var notchWidth: CGFloat = 190
    var notchHeight: CGFloat = 32
    var hasNotch = true
    var textFieldFocused = false

    static let expandedSize = CGSize(width: 620, height: 290)

    /// Size of the black island for a given mode (panel coords, glued to the top edge).
    func islandSize(mode: Mode? = nil) -> CGSize {
        let m = mode ?? self.mode
        switch m {
        case .hidden:
            return hasNotch ? CGSize(width: notchWidth, height: notchHeight) : CGSize(width: 90, height: 6)
        case .compact:
            let speaking = PetStore.shared.speech != nil
            return CGSize(width: max(notchWidth + 150, speaking ? 380 : 0),
                          height: notchHeight + (speaking ? 26 : 0))
        case .expanded:
            return CGSize(width: Self.expandedSize.width, height: notchHeight + Self.expandedSize.height)
        }
    }
}

// MARK: - Panel

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - Controller

@MainActor
final class IslandController {
    let panel: IslandPanel
    private let model = IslandModel.shared
    private let pet = PetStore.shared
    private let chat = ChatService.shared

    private var timer: Timer?
    private var wasInside = false
    private var lastInside = Date()
    private var lastStrokePoint: CGPoint? = nil
    private var strokeDistance: CGFloat = 0
    private var monitors: [Any] = []

    private static let panelSize = CGSize(width: 700, height: 400)

    init() {
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isMovable = false

        let container = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        container.autoresizingMask = [.width, .height]
        let hosting = NSHostingView(rootView: IslandRootView(model: model, pet: pet, chat: chat))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        let drop = FileDropView(frame: container.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.onEnter = { [weak self] in MainActor.assumeIsolated { self?.dragEntered() } }
        drop.onExit = { [weak self] in MainActor.assumeIsolated { self?.dragExited() } }
        drop.onDrop = { [weak self] urls in MainActor.assumeIsolated { self?.dropped(urls) } }
        container.addSubview(hosting)
        container.addSubview(drop)
        panel.contentView = container

        positionOnScreen()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionOnScreen() }
        }

        pet.onAlert = { [weak self] in self?.peek() }
        chat.onAnswer = { [weak self] in
            guard let self else { return }
            if self.model.mode != .expanded {
                self.pet.say("I have a reply for you! Click me 💡", seconds: 8)
                self.peek()
            }
        }
        startTimer()
        startMonitors()
    }

    // MARK: Screen placement

    private func targetScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func positionOnScreen() {
        let screen = targetScreen()
        let notchH = screen.safeAreaInsets.top
        if notchH > 0 {
            let aux = (screen.auxiliaryTopLeftArea?.width ?? 0) + (screen.auxiliaryTopRightArea?.width ?? 0)
            let w = screen.frame.width - aux
            model.notchWidth = w > 60 ? w : 190
            model.notchHeight = notchH
            model.hasNotch = true
        } else {
            model.notchWidth = 190
            model.notchHeight = max(24, NSStatusBar.system.thickness)
            model.hasNotch = false
        }
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - Self.panelSize.width / 2, y: f.maxY - Self.panelSize.height,
                              width: Self.panelSize.width, height: Self.panelSize.height), display: true)
        model.objectWillChange.send()
    }

    // MARK: Polling (hover detection & eye tracking)

    private func startTimer() {
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func islandRect() -> CGRect {
        // AppKit coords inside the panel (origin bottom-left).
        let size = model.islandSize()
        let pf = panel.frame
        return CGRect(x: (pf.width - size.width) / 2, y: pf.height - size.height,
                      width: size.width, height: size.height)
    }

    private func poll() {
        let mouse = NSEvent.mouseLocation
        let pf = panel.frame
        let local = CGPoint(x: mouse.x - pf.minX, y: mouse.y - pf.minY)
        MouseTracker.point = CGPoint(x: local.x, y: pf.height - local.y)

        var hover = islandRect()
        if model.mode == .hidden {
            // Generous hover zone so the pet is easy to summon.
            hover = hover.insetBy(dx: -20, dy: 0)
            hover.size.height = max(hover.height, model.notchHeight) + 6
            hover.origin.y = pf.height - hover.height
        }
        let inside = hover.insetBy(dx: -6, dy: -6).contains(local)

        // A drag that was cancelled or released elsewhere: forget the hover state.
        if model.dropHover && NSEvent.pressedMouseButtons == 0 { dragExited() }

        let accept = inside || model.dropHover
        if panel.ignoresMouseEvents == accept { panel.ignoresMouseEvents = !accept }

        if inside {
            lastInside = Date()
            if !wasInside && model.mode == .hidden { setMode(.compact); SoundEngine.shared.play("peek") }
        }
        wasInside = inside

        // Stroking the pet with the cursor counts as a pat.
        let p = MouseTracker.point
        if model.mode == .expanded && MouseTracker.petFrame.insetBy(dx: 20, dy: 20).contains(p) {
            if let last = lastStrokePoint { strokeDistance += hypot(p.x - last.x, p.y - last.y) }
            lastStrokePoint = p
            if strokeDistance > 320 { strokeDistance = 0; pet.pat(stroke: true) }
        } else {
            lastStrokePoint = nil
            strokeDistance = max(0, strokeDistance - 10)
        }

        // Auto-hide timers
        let idle = Date().timeIntervalSince(lastInside)
        switch model.mode {
        case .compact:
            if !inside && pet.speech == nil && idle > 3 { setMode(.hidden) }
        case .expanded:
            let keepOpen = chat.isThinking || model.textFieldFocused || model.dropHover
            if !inside && !keepOpen && idle > 12 { collapse() }
        case .hidden:
            break
        }
    }

    // MARK: Mouse & keyboard monitors

    private func startMonitors() {
        // Clicks on the island (local = inside our panel)
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.panel else { return }
                if self.model.mode != .expanded { self.open(tab: nil) }
            }
            return event
        }) { monitors.append(m) }

        // Clicks anywhere else close the island
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.mode == .expanded, !self.model.dropHover else { return }
                self.collapse()
            }
        }) { monitors.append(m) }

        // Escape closes
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let handled: Bool = MainActor.assumeIsolated {
                guard let self, event.window === self.panel, self.model.mode == .expanded else { return false }
                self.collapse()
                return true
            }
            return handled ? nil : event
        }) { monitors.append(m) }
    }

    // MARK: Mode changes

    func setMode(_ mode: IslandModel.Mode) {
        guard model.mode != mode else { return }
        let growing = mode == .expanded || (mode == .compact && model.mode == .hidden)
        if mode == .expanded { SoundEngine.shared.play("open") }
        if model.mode == .expanded { SoundEngine.shared.play("close") }
        withAnimation(growing ? .spring(response: 0.45, dampingFraction: 0.74)
                              : .timingCurve(0.45, 0, 0.2, 1, duration: 0.32)) {
            model.mode = mode
        }
        if mode != .expanded {
            model.textFieldFocused = false
            panel.resignKey()
        }
    }

    func open(tab: IslandModel.Tab?) {
        if let tab { model.tab = tab }
        lastInside = Date()
        setMode(.expanded)
        if model.tab == .ask { focusPanel() }
    }

    func focusPanel() {
        panel.makeKey()
    }

    func collapse() {
        guard model.mode == .expanded else { return }
        lastInside = Date()
        setMode(.compact)
    }

    /// Pop out of the notch briefly (alerts, answers).
    func peek() {
        lastInside = Date()
        if model.mode == .hidden { setMode(.compact); SoundEngine.shared.play("peek") }
    }

    func greet() {
        peek()
        pet.greet()
    }

    // MARK: File drop

    private func dragEntered() {
        model.dropHover = true
        panel.ignoresMouseEvents = false
        pet.expectingFile = true
        open(tab: .ask)
    }

    private func dragExited() {
        model.dropHover = false
        pet.expectingFile = false
    }

    private func dropped(_ urls: [URL]) {
        model.dropHover = false
        pet.expectingFile = false
        guard let url = urls.first else { return }
        if let problem = chat.attach(url) {
            pet.react(.refuse)
            pet.say(problem, seconds: 5)
            SoundEngine.shared.play("poke")
            return
        }
        pet.eatFile(named: url.lastPathComponent)
        open(tab: .ask)
    }
}

// MARK: - Drag destination (transparent to mouse clicks)

final class FileDropView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onEnter?()
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onExit?() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { onExit?(); return false }
        onDrop?(urls)
        return true
    }
}
