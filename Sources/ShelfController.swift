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
    private let clipboard: ClipboardController
    private var tabs: PopoverTabsViewController?
    private var outsideClickMonitor: Any?

    init(clipboard: ClipboardController) {
        self.clipboard = clipboard
        super.init()
        clipboard.shelf = store
        clipboard.closePopover = { [weak self] in self?.popover?.performClose(nil) }
        clipboard.openPopoverTab = { [weak self] index in self?.openPopover(tab: index) }
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

        // Debug aid: `Tuck --show-popover` opens the menu bar popover at launch.
        if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openPopover(tab: nil) }
        }
        // Debug aid: `Tuck --show-dropzone` shows the drop box once at launch.
        if CommandLine.arguments.contains("--show-dropzone") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.dropZone.show(holdFor: 3) }
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
        let clipTitle = clipboard.hotKeyTitle.map { "Pano geçmişini aç (\($0))" } ?? "Pano geçmişini aç"
        add(clipTitle, #selector(openClipboard))
        let clipSettings = NSMenuItem(title: "Pano ayarları", action: nil, keyEquivalent: "")
        clipSettings.submenu = clipboard.settingsMenu()
        menu.addItem(clipSettings)
        menu.addItem(.separator())
        add("Panodakini rafa ekle", #selector(pasteClipboard))
        add("Raf klasörünü Finder'da aç", #selector(openFolder))
        menu.addItem(.separator())
        add("Dışarı tıklanınca kapat", #selector(toggleCloseOutside), state: Settings.closeOnOutsideClick)
        add("Sürüklerken kutuyu göster", #selector(toggleDropZone), state: dropZone.enabled)
        add("Kutuyu şimdi göster", #selector(previewDropZone))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openClipboard() { openPopover(tab: 1) }
    @objc private func pasteClipboard() { if store.addFromClipboard() { flash() } }
    @objc private func openFolder() { NSWorkspace.shared.open(store.root) }
    @objc private func toggleCloseOutside() { Settings.closeOnOutsideClick.toggle() }
    @objc private func toggleDropZone() { dropZone.enabled.toggle() }
    @objc private func previewDropZone() {
        dropZone.show(holdFor: 3)
    }

    // MARK: - Popover

    private func togglePopover() {
        if let p = popover, p.isShown { p.performClose(nil); return }
        openPopover(tab: nil)
    }

    /// - Parameter tab: 0 = shelf, 1 = clipboard, nil = last used.
    func openPopover(tab: Int?) {
        if let tab, let tabs, popover?.isShown == true { tabs.select(tab); return }
        guard let button = item.button else { return }
        store.purgeExpired()
        // Remember where the user was, so a chosen clipboard item is pasted there.
        let front = NSWorkspace.shared.frontmostApplication
        clipboard.previousApp = front == NSRunningApplication.current ? nil : front

        let shelfVC = ShelfViewController(store: store)
        let clipVC = ClipboardViewController(controller: clipboard, inPanel: false)
        let tabsVC = PopoverTabsViewController(shelf: shelfVC, clipboard: clipVC)
        if let tab { tabsVC.select(tab) }
        let p = NSPopover()
        // .transient alone is not reliable for an accessory app (e.g. with a nested info
        // popover open), so outside clicks are also caught explicitly below.
        p.behavior = Settings.closeOnOutsideClick ? .transient : .applicationDefined
        p.animates = false
        p.contentViewController = tabsVC
        p.delegate = self
        viewController = shelfVC
        tabs = tabsVC
        clipboard.popoverVC = clipVC
        popover = p
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if Settings.closeOnOutsideClick {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] _ in self?.popover?.performClose(nil)
            }
        }
    }

    // MARK: - Drop on the menu bar icon

    private func isOwnDrag(_ info: NSDraggingInfo) -> Bool {
        guard let src = info.draggingSource as AnyObject?, let table = viewController?.table else { return false }
        return src === table
    }

    /// Only real content drags count; e.g. ⌘-dragging menu bar icons over the tray is ignored.
    private func isContentDrag(_ info: NSDraggingInfo) -> Bool {
        guard !isOwnDrag(info), let types = info.draggingPasteboard.types else { return false }
        return !Set(types).isDisjoint(with: ShelfStore.acceptedTypes)
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isContentDrag(sender) else { return [] }
        item.button?.highlight(true)
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isContentDrag(sender) ? .copy : []
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        item.button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        item.button?.highlight(false)
        guard isContentDrag(sender), store.ingest(sender.draggingPasteboard) else { return false }
        flash()
        dropZone.hide()
        return true
    }
}

extension ShelfController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        popover = nil
        viewController = nil
        tabs = nil
    }
}
