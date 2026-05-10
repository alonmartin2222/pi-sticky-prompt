import AppKit

protocol PromptViewDelegate: AnyObject {
    func promptViewDidSubmit(_ text: String)
    func promptViewDidRequestAbort()
    func promptViewDidRequestMinimizeToggle()
    func promptViewDidRequestSessionPicker()
    func promptViewDidRequestHide()
    func promptViewDidRequestLockToggle()
}

/// Custom NSView containing a status bar and a multi-line text editor styled
/// to vaguely resemble pi's prompt. Implements its own key handling so:
///   Enter        -> submit
///   Shift+Enter  -> newline
///   Escape       -> abort current pi turn, then hide if pressed twice
///   Cmd+M        -> minimize toggle
///   Cmd+L        -> session picker
///   Cmd+W        -> hide
final class PromptView: NSView, NSTextViewDelegate {
    weak var delegate: PromptViewDelegate?

    private let bgLayer = CALayer()
    private let topBar = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let streamingDot = NSView()
    private let modelLabel = NSTextField(labelWithString: "")
    private let modelSeparator = NSBox()
    private let lockButton = NSButton()
    private let minimizeButton = NSButton()
    private let sessionButton = NSButton()
    private let scrollView = NSScrollView()
    private let textView = PromptTextView()
    private let collapsedLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private var lastEscape: Date?

    private static let topBarHeight: CGFloat = 26
    private static let pad: CGFloat = 12

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        bgLayer.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.92).cgColor
        bgLayer.cornerRadius = 14
        layer?.addSublayer(bgLayer)

        // border
        layer?.borderColor = NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.95, alpha: 0.8).cgColor
        layer?.borderWidth = 1

        configureStatus()
        configureTopBar()
        configureEditor()
        configureCollapsed()
        configureError()
        addSubview(topBar)
        addSubview(scrollView)
        addSubview(collapsedLabel)
        addSubview(errorLabel)

        sessionButton.target = self
        sessionButton.action = #selector(sessionButtonClicked)
        minimizeButton.target = self
        minimizeButton.action = #selector(minimizeClicked)
        lockButton.target = self
        lockButton.action = #selector(lockClicked)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    // MARK: - Layout

    override func layout() {
        super.layout()
        bgLayer.frame = bounds

        let pad = PromptView.pad
        let topBarH = PromptView.topBarHeight

        // Toolbar pinned to the BOTTOM of the panel so collapsing leaves
        // the toolbar flush with the screen edge and expanding grows up.
        let toolbarY: CGFloat = pad / 2
        topBar.frame = NSRect(x: pad, y: toolbarY,
                              width: bounds.width - pad * 2,
                              height: topBarH)

        // Editor sits above the toolbar.
        let editorY = toolbarY + topBarH + 6
        let topReserve: CGFloat = errorLabel.stringValue.isEmpty ? 0 : 16
        let editorH = max(0, bounds.height - editorY - pad / 2 - topReserve)
        scrollView.frame = NSRect(x: pad, y: editorY,
                                  width: bounds.width - pad * 2, height: editorH)
        collapsedLabel.frame = scrollView.frame
        errorLabel.frame = NSRect(x: pad, y: bounds.height - 16,
                                  width: bounds.width - pad * 2, height: 14)
    }

    private func configureStatus() {
        // streaming indicator dot — fixed size, vertically centered by stack view
        let dotSize: CGFloat = 8
        streamingDot.wantsLayer = true
        streamingDot.translatesAutoresizingMaskIntoConstraints = false
        streamingDot.widthAnchor.constraint(equalToConstant: dotSize).isActive = true
        streamingDot.heightAnchor.constraint(equalToConstant: dotSize).isActive = true
        streamingDot.layer?.cornerRadius = dotSize / 2
        streamingDot.layer?.backgroundColor = NSColor.systemGreen.cgColor

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        statusLabel.lineBreakMode = .byTruncatingTail
        // Hug content tightly — the spacer view between left/right groups
        // is what stretches now.
        statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        modelLabel.font = .systemFont(ofSize: 11, weight: .regular)
        modelLabel.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        modelLabel.alignment = .left
        modelLabel.lineBreakMode = .byTruncatingTail
        modelLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        modelSeparator.boxType = .custom
        modelSeparator.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.10)
        modelSeparator.fillColor = NSColor(calibratedWhite: 1.0, alpha: 0.10)
        modelSeparator.borderWidth = 0
        modelSeparator.translatesAutoresizingMaskIntoConstraints = false
        modelSeparator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        modelSeparator.heightAnchor.constraint(equalToConstant: 14).isActive = true

        configureIconButton(sessionButton,
                            symbol: "list.bullet",
                            fallback: "≡",
                            tooltip: "Pick session  ⌘L")
        configureIconButton(lockButton,
                            symbol: "lock.fill",
                            fallback: "⌂",
                            tooltip: "Locked — click to free-move/resize")
        configureIconButton(minimizeButton,
                            symbol: "chevron.up",
                            fallback: "▴",
                            tooltip: "Collapse / expand  ⌘M")
    }

    private func configureIconButton(_ b: NSButton,
                                     symbol: String,
                                     fallback: String,
                                     tooltip: String) {
        b.bezelStyle = .inline
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = NSColor(calibratedWhite: 0.65, alpha: 1)
        b.toolTip = tooltip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            b.image = img.withSymbolConfiguration(cfg)
            b.title = ""
        } else {
            b.title = fallback
            b.font = .systemFont(ofSize: 12, weight: .medium)
        }
        // hover effect: brighten on mouse-enter
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: ["button": b])
        b.addTrackingArea(area)
    }

    private func configureTopBar() {
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.distribution = .gravityAreas
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        // We size topBar manually in layout() — keep autoresizing translation
        // ON so its frame width is honoured (otherwise the stack collapses
        // to its intrinsic content width and gravity areas have nothing to
        // distribute).
        topBar.translatesAutoresizingMaskIntoConstraints = true

        // Left gravity — hugs the left edge of the bar.
        topBar.addView(streamingDot,    in: .leading)
        topBar.addView(statusLabel,     in: .leading)
        topBar.addView(modelSeparator,  in: .leading)
        topBar.addView(modelLabel,      in: .leading)
        // Trailing gravity — hugs the right edge of the bar; the gap
        // between leading and trailing groups expands to fill the bar.
        topBar.addView(sessionButton,   in: .trailing)
        topBar.addView(lockButton,      in: .trailing)
        topBar.addView(minimizeButton,  in: .trailing)

        topBar.setCustomSpacing(2, after: streamingDot)
        topBar.setCustomSpacing(8, after: statusLabel)
        topBar.setCustomSpacing(8, after: modelSeparator)
        topBar.setCustomSpacing(4, after: sessionButton)
        topBar.setCustomSpacing(4, after: lockButton)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        if let b = event.trackingArea?.userInfo?["button"] as? NSButton {
            b.contentTintColor = NSColor.white
        }
    }
    override func mouseExited(with event: NSEvent) {
        if let b = event.trackingArea?.userInfo?["button"] as? NSButton {
            b.contentTintColor = NSColor(calibratedWhite: 0.65, alpha: 1)
        }
    }

    private func configureEditor() {
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        textView.insertionPointColor = NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.95, alpha: 1)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        textView.onSubmit = { [weak self] in self?.submit() }
        textView.onAbort = { [weak self] in self?.handleEscape() }
        textView.onMinimize = { [weak self] in self?.delegate?.promptViewDidRequestMinimizeToggle() }
        textView.onPickSession = { [weak self] in self?.delegate?.promptViewDidRequestSessionPicker() }
        textView.onHide = { [weak self] in self?.delegate?.promptViewDidRequestHide() }
    }

    private func configureCollapsed() {
        collapsedLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        collapsedLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)
        collapsedLabel.lineBreakMode = .byTruncatingTail
        collapsedLabel.isHidden = true
    }

    private func configureError() {
        errorLabel.font = .systemFont(ofSize: 10)
        errorLabel.textColor = NSColor.systemRed
        errorLabel.alignment = .left
    }

    // MARK: - State

    func setStatus(connected: Bool, model: String?, sessionLabel: String, streaming: Bool) {
        statusLabel.stringValue = sessionLabel
        modelLabel.stringValue = model ?? ""
        let color: NSColor
        if !connected {
            color = NSColor.systemRed.withAlphaComponent(0.9)
        } else if streaming {
            color = NSColor.systemYellow
        } else {
            color = NSColor.systemGreen
        }
        streamingDot.layer?.backgroundColor = color.cgColor
    }

    func setMinimized(_ minimized: Bool) {
        scrollView.isHidden = minimized
        collapsedLabel.isHidden = !minimized
        // chevron points in the direction expansion will go.
        // collapsed -> show "chevron.up" (clicking opens upward)
        // expanded  -> show "chevron.down" (clicking collapses downward)
        let symbol = minimized ? "chevron.up" : "chevron.down"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            minimizeButton.image = img.withSymbolConfiguration(cfg)
        } else {
            minimizeButton.title = minimized ? "▴" : "▾"
        }
        if minimized {
            collapsedLabel.stringValue = collapsedPreview(of: textView.string)
        } else {
            DispatchQueue.main.async { [weak self] in self?.focusEditor() }
        }
    }

    func setLocked(_ locked: Bool) {
        let symbol = locked ? "lock.fill" : "lock.open.fill"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            lockButton.image = img.withSymbolConfiguration(cfg)
        } else {
            lockButton.title = locked ? "⌂" : "⇳"
        }
        lockButton.toolTip = locked
            ? "Locked — click to free-move/resize"
            : "Unlocked — drag to move, click to re-dock"
        // Unlocked state hints with a warm tint.
        lockButton.contentTintColor = locked
            ? NSColor(calibratedWhite: 0.65, alpha: 1)
            : NSColor.systemOrange
    }

    func clearAfterSend() {
        textView.string = ""
        collapsedLabel.stringValue = ""
    }

    func flashError(_ msg: String) {
        errorLabel.stringValue = msg
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.errorLabel.stringValue = ""
            self?.needsLayout = true
        }
    }

    func focusEditor() {
        window?.makeFirstResponder(textView)
    }

    private func submit() {
        let text = textView.string
        delegate?.promptViewDidSubmit(text)
    }

    private func handleEscape() {
        let now = Date()
        if let prev = lastEscape, now.timeIntervalSince(prev) < 0.6 {
            // double-escape: hide
            delegate?.promptViewDidRequestHide()
            lastEscape = nil
        } else {
            delegate?.promptViewDidRequestAbort()
            lastEscape = now
        }
    }

    private func collapsedPreview(of text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let trimmed = oneLine.count > 90 ? String(oneLine.prefix(87)) + "…" : oneLine
        if lineCount > 1 {
            return "\(trimmed)   [\(lineCount) lines]"
        }
        return trimmed
    }

    @objc private func sessionButtonClicked() { delegate?.promptViewDidRequestSessionPicker() }
    @objc private func minimizeClicked()      { delegate?.promptViewDidRequestMinimizeToggle() }
    @objc private func lockClicked()          { delegate?.promptViewDidRequestLockToggle() }
}
