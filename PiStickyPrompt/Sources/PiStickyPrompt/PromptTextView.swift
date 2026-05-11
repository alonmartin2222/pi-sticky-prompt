import AppKit
import Foundation

/// NSTextView subclass that maps a few keys to higher-level callbacks
/// instead of letting them pass through normal text editing, and
/// rewrites paste-image actions to mirror pi's clipboard-image
/// convention (save to /var/folders/.../T/pi-clipboard-<uuid>.png and
/// insert the path).
final class PromptTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onAbort: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onPickSession: (() -> Void)?
    var onHide: (() -> Void)?

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"
    ]

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
            case "v":
                // Intercept paste. If the clipboard has an image or a file
                // URL, route through our handler that drops a path into the
                // text. Otherwise fall through so NSTextView does its normal
                // text paste.
                NSLog("PiStickyPrompt: keyDown Cmd+V intercepted")
                if handleCustomPaste() { return }
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

    // MARK: - Paste (image + file-URL aware)
    //
    // NSTextView validates `paste:` against the pasteboard's text types. When
    // the clipboard only has image bytes (e.g. a screenshot via
    // Cmd+Ctrl+Shift+4) the action is rejected at validation time and the
    // system beeps. To work around that we intercept Cmd+V directly in
    // keyDown above and call into this helper before anything else runs.

    private static let pngType  = NSPasteboard.PasteboardType("public.png")
    private static let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    private static let tiffType = NSPasteboard.PasteboardType.tiff
    private static let fileURLType = NSPasteboard.PasteboardType.fileURL

    /// Returns true iff we handled the paste ourselves (image or file URL).
    /// Returns false to let the caller fall through to NSTextView's default
    /// text paste behaviour.
    private func handleCustomPaste() -> Bool {
        let pb = NSPasteboard.general
        NSLog("PiStickyPrompt: handleCustomPaste types=\(pb.types?.map { $0.rawValue } ?? [])")

        // 1) File URLs (file copied from Finder, image file, etc.).
        let fileURLOnly: [String] = ["public.file-url"]
        if let urls = pb.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingContentsConformToTypes: fileURLOnly]
             ) as? [URL],
           !urls.isEmpty {
            let paths = urls.map { $0.path }.joined(separator: " ")
            NSLog("PiStickyPrompt: paste -> file URLs \(paths)")
            insertPath(paths)
            return true
        }

        // 2) Raw image bytes (screenshot, image from a browser, etc.).
        if let path = Self.saveClipboardImageFromPasteboard(pb) {
            NSLog("PiStickyPrompt: paste -> wrote temp image \(path)")
            insertPath(path)
            return true
        }

        NSLog("PiStickyPrompt: paste -> no image/file, falling through to text paste")
        return false
    }

    /// Insert a path at the current selection, ensuring it's separated from
    /// surrounding text by whitespace so it can be parsed as an attachment.
    private func insertPath(_ path: String) {
        let sel = self.selectedRange()
        let storage = self.textStorage?.string ?? ""

        let needsLeadingSpace: Bool = {
            guard sel.location > 0, sel.location <= storage.count else { return false }
            let idx = storage.index(storage.startIndex, offsetBy: sel.location - 1)
            let ch = storage[idx]
            return !(ch.isWhitespace || ch.isNewline)
        }()

        let prefix = needsLeadingSpace ? " " : ""
        let inserted = prefix + path + " "
        self.insertText(inserted, replacementRange: sel)
    }

    /// Read raw image bytes from the pasteboard (PNG, TIFF, JPEG, then any
    /// type NSImage understands as a last resort) and persist them as PNG
    /// under $TMPDIR with a pi-clipboard-<uuid>.png filename.
    private static func saveClipboardImageFromPasteboard(_ pb: NSPasteboard) -> String? {
        let pngType  = NSPasteboard.PasteboardType("public.png")
        let tiffType = NSPasteboard.PasteboardType.tiff
        let jpegType = NSPasteboard.PasteboardType("public.jpeg")

        var pngData: Data?

        if let data = pb.data(forType: pngType) {
            pngData = data
        } else if let data = pb.data(forType: tiffType),
                  let rep = NSBitmapImageRep(data: data) {
            pngData = rep.representation(using: .png, properties: [:])
        } else if let data = pb.data(forType: jpegType),
                  let rep = NSBitmapImageRep(data: data) {
            pngData = rep.representation(using: .png, properties: [:])
        } else if pb.canReadObject(forClasses: [NSImage.self], options: nil),
                  let image = NSImage(pasteboard: pb),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) {
            pngData = rep.representation(using: .png, properties: [:])
        }

        guard let data = pngData else { return nil }

        let id = UUID().uuidString.lowercased()
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pi-clipboard-\(id).png")
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            NSLog("PiStickyPrompt: failed to write clipboard image to \(path): \(error)")
            return nil
        }
    }
}
