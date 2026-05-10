import AppKit
import Darwin

/// Walks up the BSD process tree starting from a pi session's PID and
/// finds the terminal application that ultimately spawned it. Used to
/// hand keyboard focus back to the terminal after the user sends a
/// prompt from the HUD.
enum TerminalLocator {
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

    /// Returns the parent PID of `pid`, or nil if it cannot be determined.
    /// Uses sysctl(KERN_PROC_PID) — no extra permissions required.
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { bp -> Int32 in
            sysctl(bp.baseAddress, UInt32(bp.count), &info, &size, nil, 0)
        }
        if rc != 0 || size == 0 { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// Walks up from `pid` until it finds a running app with a known
    /// terminal bundle identifier. Caps the walk at 12 hops to avoid
    /// pathological loops.
    static func findTerminalApp(forPID pid: pid_t) -> NSRunningApplication? {
        var current: pid_t? = pid
        var hops = 0
        while let p = current, hops < 12 {
            if let app = NSRunningApplication(processIdentifier: p),
               let bundle = app.bundleIdentifier,
               terminalBundles.contains(bundle) {
                return app
            }
            current = parentPID(of: p)
            hops += 1
        }
        return nil
    }

    /// Convenience: activate the terminal app hosting the given pi PID.
    /// Returns true on a best-effort activation, false if no terminal
    /// ancestor was found.
    @discardableResult
    static func activateTerminal(forPiPID pid: pid_t) -> Bool {
        guard let app = findTerminalApp(forPID: pid) else { return false }
        app.activate(options: [.activateIgnoringOtherApps])
        return true
    }
}
