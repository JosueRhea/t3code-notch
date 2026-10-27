import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement

/// Non-activating: it can take keyboard focus (for the shortcut and the reply field)
/// without pulling the user's current app out of the foreground.
final class NotchPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

private let forceExpanded = ProcessInfo.processInfo.environment["T3NOTCH_FORCE_EXPANDED"] != nil

/// One notch window pinned to the top-center of a single display.
@MainActor
final class NotchController {
    let screen: NSScreen
    private let panel: NotchPanel
    private let model: NotchModel
    private var collapseWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var resignObserver: NSObjectProtocol?
    private var lastRenderKey: [AnyHashable] = []
    private let root: NotchRootView
    private let store: ThreadStore

    /// Window is sized for the largest state; the visible notch is drawn inside it.
    private static let canvas = CGSize(width: 600, height: 560)

    /// While the settings menu is open the cursor leaves the notch; don't collapse under it.
    var holdOpen = false

    init(screen: NSScreen, store: ThreadStore, onSettings: @escaping () -> Void) {
        self.screen = screen
        self.store = store
        model = NotchModel(notchSize: Self.notchSize(on: screen), hardwareNotch: screen.safeAreaInsets.top > 0, store: store)
        model.onSettings = onSettings

        let canvas = Self.canvas
        let f = screen.frame
        panel = NotchPanel(
            contentRect: .init(x: f.midX - canvas.width / 2, y: f.maxY - canvas.height,
                               width: canvas.width, height: canvas.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false // ARC owns it; AppKit's extra release would over-free
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        // Hover rows / collapse on exit need mouse moves *inside* the panel too. SwiftUI used to
        // turn this on implicitly via its tracking areas; plain AppKit windows default to off.
        panel.acceptsMouseMovedEvents = true
        // Invisible to screen sharing, recordings and screenshots, so thread titles, commands and
        // agent messages never leak into a Zoom/Meet share. It stays visible on your own display.
        panel.sharingType = Settings.hideFromCapture ? .none : .readOnly // see applyCaptureSetting()
        root = NotchRootView(model: model, store: store)
        panel.contentView = root
        panel.orderFrontRegardless()

        // Re-render when store changes so `model.mode` (derived) is re-evaluated.
        // objectWillChange fires *before* the change; compare after it lands, and only redraw
        // a collapsed notch when what it shows actually changed.
        store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            guard let self else { return }
            if self.root.isInteractive {
                self.root.refresh() // open: update the list / card (you're looking at it)
                return
            }
            let key = self.model.renderKey
            if key != self.lastRenderKey {
                self.lastRenderKey = key
                self.root.refresh() // collapsed: only when something visible changed
            }
        }.store(in: &cancellables)
        // Hover, keyboard, reply, mode: reshape (spring) and mount/unmount the list or card.
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            self?.root.refresh()
        }.store(in: &cancellables)
        // Reply field opened by mouse: the panel needs focus for typing.
        model.$replyingTo.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.syncFocus()
            if !self.model.focused { self.handBackFocus() } // reply sent / cancelled
        }.store(in: &cancellables)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.unfocus(restoreFocus: false) } // clicked elsewhere
        }
        if forceExpanded { model.hovering = true }
    }

    var isFocused: Bool { model.focused }
    /// Pointer is somewhere this notch could care about (or it still thinks it's hovered).
    func cares(about p: CGPoint) -> Bool {
        model.hovering || model.hoveredRow != nil || panel.frame.insetBy(dx: -8, dy: -8).contains(p)
    }
    var peekRow: String? { model.peekRow }

    /// Keyboard mode (shortcut): expand, select the most urgent thread, take focus.
    func focus() {
        model.selection = (store.stickyEvent ?? store.needsYou.first ?? store.threads.first)?.id
        model.keyboard = true
        syncFocus()
    }

    /// App that was frontmost before we took focus; it gets focus back when we close.
    private var previousApp: NSRunningApplication?

    func unfocus(restoreFocus: Bool = true) {
        guard model.focused else { return }
        model.keyboard = false
        model.replyingTo = nil
        model.draft = ""
        model.hovering = false
        syncFocus()
        if restoreFocus { handBackFocus() }
        previousApp = nil
    }

    private func handBackFocus() {
        previousApp?.activate()
        previousApp = nil
    }

    private func syncFocus() {
        if model.focused {
            panel.allowsKey = true
            panel.ignoresMouseEvents = false
            // Keys only reach an *active* app, so take focus like Spotlight does.
            if !NSApp.isActive {
                previousApp = NSWorkspace.shared.frontmostApplication
                NSApp.activate()
            }
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.allowsKey = false
            if panel.isKeyWindow { panel.resignKey() }
            panel.orderFrontRegardless()
        }
    }

    /// Returns true when the key was handled (and shouldn't reach the text field).
    func handleKey(_ event: NSEvent) -> Bool {
        guard model.focused else { return false }
        let key = Int(event.keyCode)
        if key == kVK_Escape {
            if model.replyingTo != nil && model.keyboard {
                model.replyingTo = nil // back to the list
            } else {
                unfocus()
            }
            return true
        }
        guard model.replyingTo == nil else { return false } // typing: let the field have it
        guard let thread = model.selectedThread else { return false }

        switch key {
        case kVK_UpArrow: model.moveSelection(-1)
        case kVK_DownArrow: model.moveSelection(1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            unfocus(restoreFocus: false) // T3 Code comes to the front instead
            store.open(thread)
        default:
            let char = event.charactersIgnoringModifiers?.lowercased() ?? ""
            switch (char, thread.request?.kind) {
            case ("r", _):
                model.startReply(thread)
            case ("a", .approval(_, _, let options)?):
                if let option = options.first(where: \.isAccept) { store.approve(thread, option) }
            case ("d", .approval(_, _, let options)?):
                if let option = options.first(where: { !$0.isAccept }) { store.approve(thread, option) }
            case (let c, _) where Int(c).map { (1...9).contains($0) } == true:
                let i = Int(c)! - 1
                if case .approval(_, _, let options)? = thread.request?.kind, options.indices.contains(i) {
                    store.approve(thread, options[i])
                } else if let q = thread.request?.quickQuestion, q.options.indices.contains(i) {
                    store.answer(thread, q, q.options[i])
                }
            default:
                return false
            }
        }
        return true
    }

    func collapse() {
        holdOpen = false
        model.hovering = false
    }

    /// Display changes rebuild every notch; tear this one down completely.
    /// Invisible to screen sharing / recordings / screenshots, or not (menu: Visible in Screen Sharing).
    /// Takes effect immediately; the window server re-evaluates the window on the next capture.
    func applyCaptureSetting() {
        panel.sharingType = Settings.hideFromCapture ? .none : .readOnly
    }

    func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        collapseWork?.cancel()
        cancellables.removeAll()
        panel.contentView = nil
        panel.orderOut(nil)
        panel.close()
    }

    /// Screen-space rect of the currently visible notch shape.
    private func visibleRect() -> CGRect {
        let s = model.size
        let f = panel.frame
        return .init(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
    }

    func updateHover(_ p: CGPoint) {
        if forceExpanded { return }
        // Slight slop so slamming the cursor into the top edge opens it.
        let rect = visibleRect()
        let inside = rect.insetBy(dx: -4, dy: -4).contains(p)
        let row = inside ? model.rowId(atY: rect.maxY - p.y) : nil
        if model.hoveredRow != row { model.hoveredRow = row }
        if model.focused { return } // keyboard / reply mode: stays open until Esc or click-away
        panel.ignoresMouseEvents = !inside

        if inside {
            collapseWork?.cancel()
            collapseWork = nil
            if !model.hovering { model.hovering = true }
        } else if model.hovering, collapseWork == nil, !holdOpen {
            let work = DispatchWorkItem { [weak self] in
                self?.model.hovering = false
                self?.collapseWork = nil
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    static func notchSize(on screen: NSScreen) -> CGSize {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else {
            // No hardware notch: fake one hanging from the menu bar.
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            return .init(width: 190, height: max(menuBar, 24))
        }
        return .init(width: screen.frame.width - left.width - right.width + 4,
                     height: screen.safeAreaInsets.top)
    }
}

/// Which display(s) get a notch. Persisted as a string in UserDefaults.
enum DisplayChoice: Equatable {
    case all, builtIn, named(String)

    private static let key = "displayChoice"

    static var saved: DisplayChoice {
        get {
            switch UserDefaults.standard.string(forKey: key) {
            case nil, "all": .all
            case "builtin": .builtIn
            case let name?: .named(String(name.dropFirst("name:".count)))
            }
        }
        set {
            let raw = switch newValue {
            case .all: "all"
            case .builtIn: "builtin"
            case .named(let n): "name:\(n)"
            }
            UserDefaults.standard.set(raw, forKey: key)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var isBuiltIn: Bool { CGDisplayIsBuiltin(displayID) != 0 }

    static var builtIn: NSScreen {
        screens.first(where: \.isBuiltIn) ?? screens.first { $0.safeAreaInsets.top > 0 } ?? main ?? screens[0]
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ThreadStore()
    private var controllers: [NotchController] = []
    private var monitors: [Any] = []
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                           accessibilityDescription: "T3 Notch")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        rebuildPanels()

        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                let p = NSEvent.mouseLocation
                // Most mouse moves are nowhere near a notch: skip all work for those.
                guard let self, self.controllers.contains(where: { $0.cares(about: p) }) else { return }
                self.controllers.forEach { $0.updateHover(p) }
                self.syncOutputWatch()
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { e in handler(e); return e }) {
            monitors.append(m)
        }
        // Displays plugged/unplugged or rearranged.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }

        // Keyboard mode: keys go to whichever notch has focus.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated {
                let handled = self?.controllers.first(where: \.isFocused)?.handleKey(event) ?? false
                self?.syncOutputWatch() // selection may have moved
                return handled
            }
            return handled ? nil : event
        }) {
            monitors.append(m)
        }
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.toggleKeyboardMode()
        }

        // New command started (or finished) under the cursor: follow it.
        store.$threads.receive(on: RunLoop.main).sink { [weak self] _ in self?.syncOutputWatch() }
            .store(in: &cancellables)

        store.start()
    }

    private var hotKey: HotKey?
    private var cancellables: Set<AnyCancellable> = []

    /// One live command-output stream, for whichever notch is peeking at a running row.
    private func syncOutputWatch() {
        store.watchOutput(of: controllers.lazy.compactMap(\.peekRow).first)
    }

    /// ⌘⇧Space: open the notch under the mouse (or the first one), or close it.
    private func toggleKeyboardMode() {
        if let focused = controllers.first(where: \.isFocused) {
            focused.unfocus()
            return
        }
        let mouse = NSEvent.mouseLocation
        let target = controllers.first { $0.screen.frame.contains(mouse) } ?? controllers.first
        target?.focus()
    }

    /// Chosen display, falling back to the built-in (laptop) screen when it isn't connected.
    private func targetScreens() -> [NSScreen] {
        switch DisplayChoice.saved {
        case .all: NSScreen.screens
        case .builtIn: [NSScreen.builtIn]
        case .named(let name): [NSScreen.screens.first { $0.localizedName == name } ?? NSScreen.builtIn]
        }
    }

    private func rebuildPanels() {
        controllers.forEach { $0.close() }
        controllers = targetScreens().map { screen in
            NotchController(screen: screen, store: store) { [weak self] in self?.showSettings(from: screen) }
        }
    }

    // MARK: Settings menu (status item + gear in the notch)

    private func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        if let problem = store.incompatible {
            let warn = NSMenuItem(title: "⚠︎ Needs an update: \(problem)", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            menu.addItem(.separator())
        }
        let header = NSMenuItem(title: "Show notch on", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let current = DisplayChoice.saved
        func add(_ title: String, _ choice: DisplayChoice) {
            let item = NSMenuItem(title: title, action: #selector(pickDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice
            item.state = current == choice ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }
        add("All displays", .all)
        add("Built-in display", .builtIn)
        for screen in NSScreen.screens where !screen.isBuiltIn {
            add(screen.localizedName, .named(screen.localizedName))
        }
        // Remembered monitor that is currently unplugged.
        if case .named(let name) = current, !NSScreen.screens.contains(where: { $0.localizedName == name }) {
            add("\(name) (disconnected, using built-in)", current)
        }

        menu.addItem(.separator())
        let sounds = NSMenuItem(title: "Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        sounds.state = Chime.enabled ? .on : .off
        menu.addItem(sounds)

        let capture = NSMenuItem(title: "Visible in Screen Sharing & Screenshots", action: #selector(toggleCapture), keyEquivalent: "")
        capture.target = self
        capture.state = Settings.hideFromCapture ? .off : .on
        capture.toolTip = "Off (default): the notch never appears in Zoom/Meet shares, recordings or screenshots."
        menu.addItem(capture)

        let showModel = NSMenuItem(title: "Show Model", action: #selector(toggleShowModel), keyEquivalent: "")
        showModel.target = self
        showModel.state = Settings.showModel ? .on : .off
        menu.addItem(showModel)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed // allowed in System Settings yet?
        default: login.state = .off
        }
        menu.addItem(login)

        let shortcut = NSMenuItem(title: "Open with ⌘⇧Space", action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        menu.addItem(shortcut)

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open T3 Code", action: #selector(openT3), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Quit T3 Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func showSettings(from screen: NSScreen) {
        let menu = NSMenu()
        buildMenu(menu)
        controllers.forEach { $0.holdOpen = true }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        // popUp blocks until the menu closes.
        controllers.forEach { $0.collapse() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { buildMenu(menu) }

    @objc private func pickDisplay(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? DisplayChoice else { return }
        DisplayChoice.saved = choice
        // Defer so we don't tear down the panel whose menu is still unwinding.
        DispatchQueue.main.async { self.rebuildPanels() }
    }

    @objc private func toggleSounds() {
        Chime.enabled.toggle()
        if Chime.enabled { Chime.shared.play(.done) } // a little preview
    }

    @objc private func toggleCapture() {
        Settings.hideFromCapture.toggle()
        controllers.forEach { $0.applyCaptureSetting() }
    }

    @objc private func toggleShowModel() {
        Settings.showModel.toggle()
        rebuildPanels() // rows re-render with / without the model
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openT3() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
