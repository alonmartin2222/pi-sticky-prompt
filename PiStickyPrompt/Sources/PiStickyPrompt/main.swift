import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement-style: no Dock icon, no menu bar focus stealing.
app.setActivationPolicy(.accessory)
app.run()
