import AppKit

/// Menu bar tray icon: drop target, opens the shelf popover, owns the drag-triggered drop box.
final class ShelfController: NSObject, NSWindowDelegate, NSDraggingDestination {
    let store = ShelfStore()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var popover: NSPopover?           // created lazily, released on close
    private var viewController: ShelfViewController?
    private var dropZone: DropZoneController!
    private var purgeTimer: Timer?
    private var flashing = false

    override init() {
        super.init()
        item.autosaveName = "tuck.shelf"
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        store.onChange = { [weak self] in self?.refresh() }
        dropZone = DropZoneController(store: store, anchor: { [weak self] in self?.item.button })
        refresh()
        registerDrop()
        DispatchQueue.main.async { [weak self] in self?.registerDrop() }

        // Expiry check every 6h, loose tolerance so the system can coalesce wakeups.
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.store.purgeExpired() }
        t.tolerance = 3600
        RunLoop.main.add(t, forMode: .common)
        purgeTimer = t

        // Debug aid: `Tuck --show-dropzone` shows the drop box once at launch.
        if CommandLine.arguments.contains("--show-dropzone") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.dropZone.show(hold: true) }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(registerDrop),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func registerDrop() {
        guard let window = item.button?.window else { return }
        window.registerForDraggedTypes(ShelfStore.acceptedTypes)
        window.delegate = self
    }

    private func refresh() {
        if !flashing { setIcon(store.items.isEmpty ? "tray" : "tray.full") }
        item.button?.toolTip = store.items.isEmpty ? "Raf boş" : "Raf: \(store.items.count) öğe"
        viewController?.reload()
    }

    private func setIcon(_ symbol: String) {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Raf")
        img?.isTemplate = true
        item.button?.image = img
    }

    private func flash() {
        flashing = true
        setIcon("tray.and.arrow.down.fill")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.flashing = false
            self?.refresh()
        }
    }

    // MARK: - Clicks

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector, key: String = "", state: Bool? = nil) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            mi.target = self
            if let state { mi.state = state ? .on : .off }
            menu.addItem(mi)
        }
        add("Panodakini rafa ekle", #selector(pasteClipboard))
        add("Raf klasörünü Finder'da aç", #selector(openFolder))
        menu.addItem(.separator())
        add("Sürüklerken kutuyu göster", #selector(toggleDropZone), state: dropZone.enabled)
        add("Kutuyu şimdi göster", #selector(previewDropZone))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func pasteClipboard() { if store.addFromClipboard() { flash() } }
    @objc private func openFolder() { NSWorkspace.shared.open(store.root) }
    @objc private func toggleDropZone() { dropZone.enabled.toggle() }
    @objc private func previewDropZone() {
        dropZone.show(hold: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.dropZone.hide() }
    }

    // MARK: - Popover

    private func togglePopover() {
        if let p = popover, p.isShown { p.performClose(nil); return }
        guard let button = item.button else { return }
        store.purgeExpired()
        let vc = ShelfViewController(store: store)
        let p = NSPopover()
        p.behavior = .transient
        p.animates = false
        p.contentViewController = vc
        p.delegate = self
        viewController = vc
        popover = p
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: - Drop on the menu bar icon

    private func isOwnDrag(_ info: NSDraggingInfo) -> Bool {
        guard let src = info.draggingSource as AnyObject?, let table = viewController?.table else { return false }
        return src === table
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isOwnDrag(sender) { return [] }
        item.button?.highlight(true)
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isOwnDrag(sender) ? [] : .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        item.button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        item.button?.highlight(false)
        guard !isOwnDrag(sender), store.ingest(sender.draggingPasteboard) else { return false }
        flash()
        dropZone.hide()
        return true
    }
}

extension ShelfController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popover = nil
        viewController = nil
    }
}
