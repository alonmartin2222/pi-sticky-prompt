import AppKit

/// Owns the floating NSPanel, the embedded prompt view, and the connection
/// to whichever pi session is currently picked.
final class HUDController: NSObject, NSWindowDelegate, PromptViewDelegate {
    private let panel: HUDPanel
    private let promptView: PromptView
    private let client = BridgeClient()

    private var minimized = false
    private var locked = true
    private let normalHeight: CGFloat = 180
    private let minimizedHeight: CGFloat = 38
    private let dockedBottomMargin: CGFloat = 0
    private var pickerWindow: NSWindow?
    private var rescanTimer: Timer?
    private var unlockedFrame: NSRect?  // remembered when user unlocks/moves

    private var preferredPID: Int32? {
        get { (UserDefaults.standard.object(forKey: "pi.preferredPID") as? NSNumber)?.int32Value }
        set {
            if let v = newValue { UserDefaults.standard.set(NSNumber(value: v), forKey: "pi.preferredPID") }
            else { UserDefaults.standard.removeObject(forKey: "pi.preferredPID") }
        }
    }

    override init() {
        // Initial frame: full-width docked at the bottom of the terminal
        // screen (or main screen if no terminal window is found yet).
        let frame = HUDController.dockedFrame(height: 180,
                                              screen: TerminalScreen.find() ?? NSScreen.main)
        panel = HUDPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false  // locked by default
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        promptView = PromptView()
        panel.contentView = promptView

        super.init()
        panel.delegate = self
        promptView.delegate = self
        promptView.setLocked(locked)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)

        client.onHello = { [weak self] s in self?.applyState(s) }
        client.onState = { [weak self] s in self?.applyState(s) }
        client.onAck   = { [weak self] ok, cmd, err in self?.handleAck(ok: ok, command: cmd, error: err) }
        client.onClose = { [weak self] in self?.handleDisconnect() }

        attachToBestSession()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshSessionsTick()
        }
    }

    // MARK: - Visibility

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if locked { repositionToTerminalScreen() }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        panel.makeKeyAndOrderFront(nil)
        promptView.focusEditor()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    // MARK: - Layout

    /// Full-width frame docked along the bottom edge of the given screen's
    /// visible area (above the Dock).
    private static func dockedFrame(height: CGFloat, screen: NSScreen?) -> NSRect {
        let s = screen ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = s.visibleFrame
        return NSRect(x: visible.minX,
                      y: visible.minY,
                      width: visible.width,
                      height: height)
    }

    private func resize(toHeight h: CGFloat) {
        var f = panel.frame
        // Keep bottom edge fixed so the toolbar stays glued to the dock
        // and the editor opens upward.
        f.size.height = h
        if locked {
            // Stay flush with the bottom of the terminal's screen.
            let screen = TerminalScreen.find() ?? panel.screen ?? NSScreen.main
            f.origin.y = (screen?.visibleFrame.minY ?? f.origin.y)
        }
        panel.setFrame(f, display: true, animate: true)
    }

    private func repositionToTerminalScreen() {
        let screen = TerminalScreen.find() ?? panel.screen ?? NSScreen.main
        let h = panel.frame.height
        panel.setFrame(HUDController.dockedFrame(height: h, screen: screen),
                       display: true, animate: false)
    }

    @objc private func screenParametersChanged() {
        if locked { repositionToTerminalScreen() }
    }

    // MARK: - Session attachment

    private func attachToBestSession() {
        let sessions = SessionDiscovery.list()
        if sessions.isEmpty {
            promptView.setStatus(connected: false,
                                 model: nil, sessionLabel: "no pi sessions found",
                                 streaming: false)
            return
        }
        let pick: PiSession =
            sessions.first(where: { $0.pid == preferredPID }) ?? sessions[0]
        connect(to: pick)
    }

    private func connect(to s: PiSession) {
        client.disconnect()
        if client.connect(toSocket: s.socket) {
            preferredPID = s.pid
            promptView.setStatus(
                connected: true,
                model: s.model,
                sessionLabel: s.label,
                streaming: s.streaming
            )
        } else {
            promptView.setStatus(connected: false,
                                 model: nil, sessionLabel: "connect failed",
                                 streaming: false)
        }
    }

    private func applyState(_ s: BridgeClient.State) {
        let label: String
        if let pid = preferredPID {
            let match = SessionDiscovery.list().first(where: { $0.pid == pid })
            label = match?.label ?? "pid \(pid)"
        } else {
            label = "pi"
        }
        promptView.setStatus(
            connected: client.isConnected,
            model: s.model,
            sessionLabel: s.sessionName.flatMap { $0.isEmpty ? nil : $0 } ?? label,
            streaming: s.streaming
        )
    }

    private func handleAck(ok: Bool, command: String, error: String?) {
        if !ok {
            promptView.flashError("ack \(command) failed: \(error ?? "?")")
        } else if command == "prompt" {
            promptView.clearAfterSend()
            // Hand focus back to the terminal that owns the pi session.
            if let pid = preferredPID {
                TerminalLocator.activateTerminal(forPiPID: pid)
            }
        }
    }

    private func handleDisconnect() {
        promptView.setStatus(connected: false,
                             model: nil, sessionLabel: "disconnected",
                             streaming: false)
        // Try to rebind on next tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.attachToBestSession()
        }
    }

    private func refreshSessionsTick() {
        if !client.isConnected {
            attachToBestSession()
        }
    }

    // MARK: - PromptViewDelegate

    func promptViewDidSubmit(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !client.isConnected {
            promptView.flashError("not connected")
            return
        }
        client.sendPrompt(text)
    }

    func promptViewDidRequestAbort() {
        client.sendAbort()
    }

    func promptViewDidRequestMinimizeToggle() {
        minimized.toggle()
        promptView.setMinimized(minimized)
        resize(toHeight: minimized ? minimizedHeight : normalHeight)
    }

    func promptViewDidRequestSessionPicker() {
        openSessionPicker()
    }

    func promptViewDidRequestHide() {
        hide()
    }

    func promptViewDidRequestLockToggle() {
        locked.toggle()
        promptView.setLocked(locked)
        if locked {
            // Snap back to terminal-screen bottom dock and disable dragging.
            unlockedFrame = panel.frame
            panel.styleMask.remove(.resizable)
            panel.isMovable = false
            panel.isMovableByWindowBackground = false
            repositionToTerminalScreen()
        } else {
            // Free movement + resizing; restore last unlocked frame if any.
            panel.styleMask.insert(.resizable)
            panel.isMovable = true
            panel.isMovableByWindowBackground = true
            if let f = unlockedFrame {
                panel.setFrame(f, display: true, animate: true)
            }
        }
    }

    // MARK: - Session picker

    func openSessionPicker() {
        let sessions = SessionDiscovery.list()
        let menu = NSMenu()
        if sessions.isEmpty {
            let item = menu.addItem(withTitle: "No pi sessions running",
                                    action: nil, keyEquivalent: "")
            item.isEnabled = false
        } else {
            for s in sessions {
                let item = NSMenuItem(title: s.label,
                                      action: #selector(pickSessionAction(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = s
                if preferredPID == s.pid { item.state = .on }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let refresh = menu.addItem(withTitle: "Refresh",
                                   action: #selector(refreshAction),
                                   keyEquivalent: "r")
        refresh.target = self

        let location = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: location, in: nil)
    }

    @objc private func pickSessionAction(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? PiSession else { return }
        connect(to: s)
    }

    @objc private func refreshAction() {
        attachToBestSession()
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) { /* keep visible */ }
}
