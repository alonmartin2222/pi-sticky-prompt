import AppKit

/// NSTextView subclass that maps a few keys to higher-level callbacks
/// instead of letting them pass through normal text editing.
final class PromptTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onAbort: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onPickSession: (() -> Void)?
    var onHide: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd  = mods.contains(.command)
        let shift = mods.contains(.shift)

        // Cmd shortcuts.
        if cmd, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "m": onMinimize?(); return
            case "l": onPickSession?(); return
            case "w": onHide?(); return
            default: break
            }
        }

        // Enter / Return without shift -> submit. Shift+Return -> newline.
        if event.keyCode == 36 /* return */ {
            if shift {
                super.keyDown(with: event)
            } else {
                onSubmit?()
            }
            return
        }

        // Escape -> abort
        if event.keyCode == 53 /* esc */ {
            onAbort?()
            return
        }

        super.keyDown(with: event)
    }
}
