import AppKit

/// Watches for drags started in any app and slides a drop box down from the menu bar,
/// right under the shelf icon.
///
/// Cost: only mouse-*down* events are observed permanently. A drag monitor is attached
/// for a moment after a press (max 3 s / until the drag is recognised or the button is
/// released), so Tuck does not wake for every pixel of every drag. Presses in the menu
/// bar (⌘-dragging icons around) are ignored entirely.
final class DropZoneController: NSObject {
    private let store: ShelfStore
    private let anchor: () -> NSView?
    private var downMonitor: Any?
    private var dragMonitor: Any?
    private var armedAt: TimeInterval = 0
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var panel: NSPanel?
    private var zone: DropZoneView?
    private var watchTimer: Timer?
    private lazy var lastDragChange = dragPasteboard.changeCount
    private var lastCheck: TimeInterval = 0
    private var isHiding = false
    /// Uptime until which the box stays open even with the mouse button up
    /// (menu preview, or showing the "added" confirmation). Never indefinite.
    private var holdUntil: TimeInterval = 0

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static let size = NSSize(width: 280, height: 132)

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "dropZone") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dropZone"); newValue ? start() : stop() }
    }

    init(store: ShelfStore, anchor: @escaping () -> NSView?) {
        self.store = store
        self.anchor = anchor
        super.init()
        if enabled { start() }
    }

    private func start() {
        guard downMonitor == nil else { return }
        _ = lastDragChange
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            self?.mouseDown(e)
        }
    }

    private func stop() {
        if let downMonitor { NSEvent.removeMonitor(downMonitor) }
        downMonitor = nil
        disarm()
    }

    private func mouseDown(_ event: NSEvent) {
        guard panel == nil, !Self.isInMenuBar(NSEvent.mouseLocation)
        else { return }
        armedAt = now
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] e in
            self?.armedEvent(e)
        }
    }

    private func disarm() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
    }

    private func armedEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp || now - armedAt > 3 || panel != nil { disarm(); return }
        guard now - lastCheck > 0.1 else { return }
        lastCheck = now
        let count = dragPasteboard.changeCount
        guard count != lastDragChange else { return }
        lastDragChange = count
        disarm()
        guard let types = dragPasteboard.types, !Set(types).isDisjoint(with: ShelfStore.acceptedTypes) else { return }
        show()
    }

    /// Presses in the menu bar strip (⌘-dragging icons). Uses the physical bar height so it
    /// also works when the menu bar auto-hides (visibleFrame then reaches the top).
    private static func isInMenuBar(_ p: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return false }
        let barHeight = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top, 24) + 4
        return p.y >= screen.frame.maxY - barHeight
    }

    // MARK: - Panel

    /// - Parameter holdFor: seconds to stay open even if no drag is in progress (preview).
    func show(holdFor: TimeInterval = 0) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        isHiding = false
        holdUntil = now + holdFor
        zone?.reset(count: store.items.count)

        let target = targetFrame()
        var start = target
        start.origin.y += 24
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        startWatching()
    }

    func hide(after delay: TimeInterval = 0) {
        guard let panel, panel.isVisible, !isHiding else { return }
        isHiding = true
        watchTimer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isHiding else { return }
            var up = panel.frame
            up.origin.y += 24
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                panel.animator().setFrame(up, display: true)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // Always finish closing once the fade started, so a half-hidden,
                // invisible panel can never block future drags.
                panel.orderOut(nil)
                guard let self, self.panel === panel else { return }
                // Free the window entirely; it is rebuilt on the next drag.
                self.panel = nil
                self.zone = nil
                self.isHiding = false
            })
        }
    }

    /// While shown, poll the mouse button: once it is released (dropped anywhere or
    /// cancelled) and no hold is active, close. This cannot get stuck open.
    private func startWatching() {
        watchTimer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if NSEvent.pressedMouseButtons & 1 == 0 && self.now >= self.holdUntil {
                self.hide(after: 0.3)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
    }

    private func targetFrame() -> NSRect {
        let size = Self.size
        let anchorFrame = anchor()?.window?.frame
        let screen = anchor()?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var x = (anchorFrame?.midX ?? visible.maxX - size.width / 2 - 12) - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        return NSRect(x: x, y: visible.maxY - size.height - 6, width: size.width, height: size.height)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        effect.autoresizingMask = [.width, .height]

        let zone = DropZoneView(frame: effect.bounds.insetBy(dx: 10, dy: 10))
        zone.autoresizingMask = [.width, .height]
        zone.onClick = { [weak self] in self?.hide() }
        zone.onDrop = { [weak self] info in
            guard let self else { return false }
            let ok = self.store.ingest(info.draggingPasteboard)
            if ok {
                // Show the confirmation briefly; the watch timer closes it afterwards.
                self.holdUntil = self.now + 0.9
                self.isHiding = false
                self.zone?.showDone()
                if self.watchTimer?.isValid != true { self.startWatching() }
            }
            return ok
        }
        effect.addSubview(zone)
        p.contentView = effect
        self.zone = zone
        return p
    }
}

/// Dashed drop target with icon + label; turns accent-colored while targeted.
final class DropZoneView: NSView {
    var onClick: (() -> Void)?
    var onDrop: ((NSDraggingInfo) -> Bool)?

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "Rafa bırak")
    private let subtitle = NSTextField(labelWithString: "")
    private var targeted = false { didSet { needsDisplay = true; updateColors() } }
    private var done = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(ShelfStore.acceptedTypes)

        icon.symbolConfiguration = .init(pointSize: 28, weight: .medium)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [icon, title, subtitle])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        reset(count: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    func reset(count: Int) {
        done = false
        targeted = false
        icon.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
        title.stringValue = "Rafa bırak"
        subtitle.stringValue = count > 0 ? "Rafta \(count) öğe · 30 gün saklanır" : "30 gün saklanır"
        updateColors()
    }

    func showDone() {
        done = true
        targeted = false
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        title.stringValue = "Rafa eklendi"
        subtitle.stringValue = "Üst bardaki raf simgesinden ulaşabilirsin"
        updateColors()
    }

    private func updateColors() {
        let c: NSColor = done ? .systemGreen : (targeted ? .controlAccentColor : .secondaryLabelColor)
        icon.contentTintColor = c
        title.textColor = done || targeted ? c : .labelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 11, yRadius: 11)
        if targeted {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            path.fill()
        }
        path.lineWidth = targeted ? 2 : 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        (targeted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        targeted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        targeted = false
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        targeted = false
        return onDrop?(sender) ?? false
    }
}
