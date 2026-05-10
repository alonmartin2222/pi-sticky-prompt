import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hud: HUDController!
    private var hotkey: GlobalHotkey!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        hud = HUDController()
        hud.show()  // start visible

        // Cmd+Opt+P (key 35 = 'p')
        hotkey = GlobalHotkey(keyCode: 35, modifiers: [.command, .option]) { [weak self] in
            self?.hud.toggle()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "π▸"
            button.toolTip = "Pi Sticky Prompt (⌘⌥P to toggle)"
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Prompt Bar  ⌘⌥P", action: #selector(toggleFromMenu), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Pick Session…", action: #selector(pickSessionFromMenu), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pi Sticky Prompt", action: #selector(quitApp), keyEquivalent: "q")
            .target = self
        statusItem.menu = menu
    }

    @objc private func toggleFromMenu() { hud.toggle() }
    @objc private func pickSessionFromMenu() { hud.openSessionPicker() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
