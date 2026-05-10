import AppKit

/// Borderless, non-activating NSPanel that still accepts keyboard focus.
///
/// By default, `NSPanel` with `.borderless` + `.nonactivatingPanel` returns
/// `false` from `canBecomeKey`/`canBecomeMain`, which means clicks won't
/// promote it to first responder and the embedded NSTextView never
/// receives keystrokes. Overriding both — together with explicitly
/// activating the app on mouse-down — restores normal text-input behavior
/// while keeping the always-on-top, no-Dock-icon UX.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Promote to key on click without stealing focus from the foreground
        // app's menu bar (we're an accessory app, so this is cheap).
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        super.mouseDown(with: event)
    }
}
