import AppKit

/// Best-effort detection of which NSScreen is currently hosting a terminal
/// window (Ghostty / Terminal.app / iTerm2 / Alacritty / WezTerm / kitty /
/// Warp). Used to pin the prompt bar to the bottom of that screen.
///
/// Implementation note: `CGWindowListCopyWindowInfo` returns window bounds
/// and owner PID without requiring Screen Recording permission; we only
/// read those, never window names or pixels.
enum TerminalScreen {
    private static let terminalBundles: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "co.zeit.hyper",
        "io.alacritty",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable",
    ]

    /// Returns the screen containing the frontmost terminal window, or
    /// `nil` if no terminal app currently has a visible window.
    static func find() -> NSScreen? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else {
            return nil
        }

        for info in raw {
            // Layer 0 = normal window stratum; skip menu bar, dock, etc.
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid),
                  let bundle = app.bundleIdentifier,
                  terminalBundles.contains(bundle),
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }

            let cgRect = NSRect(x: bounds["X"] ?? 0,
                                y: bounds["Y"] ?? 0,
                                width: bounds["Width"] ?? 0,
                                height: bounds["Height"] ?? 0)
            // Discard tiny windows (system overlays, hidden tabs, etc.)
            if cgRect.width < 200 || cgRect.height < 100 { continue }

            // CGWindowList uses top-left origin; NSScreen uses bottom-left.
            // Flip relative to primary screen height to match NSScreen coords.
            let flipped = NSRect(x: cgRect.minX,
                                 y: primary.frame.height - cgRect.maxY,
                                 width: cgRect.width,
                                 height: cgRect.height)
            let center = NSPoint(x: flipped.midX, y: flipped.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return screen
            }
        }
        return nil
    }
}
