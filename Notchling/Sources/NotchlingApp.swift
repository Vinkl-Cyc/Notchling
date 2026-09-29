import SwiftUI
import AppKit

@main
struct NotchlingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { SettingsView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    private(set) var island: IslandController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var sleepItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Pref.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        _ = SoundEngine.shared
        _ = ChatService.shared

        PetStore.shared.start()
        island = IslandController()
        setupMenuBar()

        // Say hello on launch.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self.island?.greet()
            if !ChatService.shared.isReady {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.openSettings()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PetStore.shared.save()
    }

    // MARK: Menu bar

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "Notchling")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(makeItem("Open Notchling", #selector(openIsland), "o"))
        menu.addItem(makeItem("Ask a question…", #selector(openAsk), "k"))
        menu.addItem(.separator())
        menu.addItem(makeItem("🍙 Feed a meal", #selector(feed), ""))
        menu.addItem(makeItem("🍪 Give a snack", #selector(snack), ""))
        menu.addItem(makeItem("🛁 Bath time", #selector(bath), ""))
        menu.addItem(makeItem("🤚 Pat", #selector(pat), ""))
        let sleep = makeItem("🌙 Bedtime", #selector(toggleSleep), "")
        menu.addItem(sleep)
        sleepItem = sleep
        menu.addItem(.separator())
        menu.addItem(makeItem("Settings…", #selector(openSettings), ","))
        menu.addItem(makeItem("Quit Notchling", #selector(quit), "q"))
        item.menu = menu
        statusItem = item
    }

    private func makeItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        sleepItem?.title = PetStore.shared.pet.isAsleep ? "☀️ Wake up" : "🌙 Bedtime"
    }

    @objc func openIsland() { island?.open(tab: .care) }
    @objc func openAsk() { island?.open(tab: .ask) }
    @objc func feed() { island?.peek(); PetStore.shared.feedMeal() }
    @objc func snack() { island?.peek(); PetStore.shared.feedSnack() }
    @objc func bath() { island?.peek(); PetStore.shared.bath() }
    @objc func pat() { island?.peek(); PetStore.shared.pat() }
    @objc func toggleSleep() { island?.peek(); PetStore.shared.toggleSleep() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func openSettings() {
        island?.collapse()
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Notchling Settings"
        win.contentView = NSHostingView(rootView: SettingsView())
        win.center()
        win.isReleasedWhenClosed = false
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
