import AppKit
import ImageIO

/// Searchable clipboard history list. Used both in the shortcut panel and the menu bar popover.
final class ClipboardViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                     NSSearchFieldDelegate, NSMenuDelegate {
    private let controller: ClipboardController
    private var store: ClipboardStore { controller.store }
    private let inPanel: Bool

    private let search = NSSearchField()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let permissionButton = NSButton()
    private let gearButton = NSButton()
    private var rows: [ClipEntry] = []
    private var keyMonitor: Any?
    private let thumbs = NSCache<NSString, NSImage>()

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.unitsStyle = .abbreviated
        return f
    }()

    init(controller: ClipboardController, inPanel: Bool) {
        self.controller = controller
        self.inPanel = inPanel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    // MARK: - Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 470))

        search.placeholderString = "Ara…"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.focusRingType = .none

        let column = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.toolTip = "↩ yapıştır · ⇧↩ düz metin yapıştır · ⌘↩ sadece kopyala · ⌘1…9 hızlı seç\n⌥P sabitle · ⌥⌫ sil · ⌥⌘⌫ geçmişi temizle (📌 hariç) · esc kapat"
        hintLabel.stringValue = "↩ yapıştır · ⇧↩ düz · ⌥P sabitle · ⌥⌫ sil"

        gearButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Ayarlar")
        gearButton.isBordered = false
        gearButton.contentTintColor = .secondaryLabelColor
        gearButton.target = self
        gearButton.action = #selector(showSettings)
        gearButton.toolTip = "Pano ayarları"

        permissionButton.title = "Otomatik yapıştırma için izin ver"
        permissionButton.bezelStyle = .accessoryBarAction
        permissionButton.controlSize = .small
        permissionButton.contentTintColor = .systemOrange
        permissionButton.target = self
        permissionButton.action = #selector(grantPermission)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)

        let footer = NSStackView(views: [hintLabel, NSView(), gearButton])
        footer.orientation = .horizontal
        footer.spacing = 6

        for v in [search, scroll, permissionButton, footer, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: permissionButton.topAnchor, constant: -4),

            permissionButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            permissionButton.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = root
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installKeyMonitor()
        focusSearch()
        reload()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func focusSearch() {
        view.window?.makeFirstResponder(search)
    }

    // MARK: - Data

    func reload() {
        guard isViewLoaded else { return }
        let selectedID = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].id : nil
        rows = store.filtered(search.stringValue)
        table.reloadData()
        let keep = selectedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        if !rows.isEmpty { table.selectRowIndexes([keep], byExtendingSelection: false); table.scrollRowToVisible(keep) }

        let total = store.entries.count
        search.placeholderString = total > 0 ? "Ara (\(total) öğe)…" : "Ara…"
        if controller.paused {
            emptyLabel.stringValue = "Kayıt duraklatıldı\n⚙︎ menüsünden yeniden başlat"
        } else if total == 0 {
            let key = controller.hotKeyTitle.map { "\n\($0) ile her yerden aç" } ?? ""
            emptyLabel.stringValue = "Henüz kopyalanan bir şey yok\(key)"
        } else {
            emptyLabel.stringValue = "Sonuç yok"
        }
        emptyLabel.isHidden = !rows.isEmpty && !controller.paused
        permissionButton.isHidden = !(controller.autoPaste && !AXIsProcessTrusted())
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row].kind == .image ? 56 : 38
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ClipCell.id, owner: nil) as? ClipCell) ?? ClipCell()
        let e = rows[row]
        cell.entryID = e.id
        cell.titleField.stringValue = e.title
        cell.titleField.maximumNumberOfLines = 1

        var parts: [String] = []
        if let app = e.app { parts.append(ClipboardController.appName(app)) }
        parts.append(Self.relative.localizedString(for: e.lastCopied, relativeTo: Date()))
        if e.copies > 1 { parts.append("×\(e.copies)") }
        cell.subtitleField.stringValue = (e.pinned ? "📌 " : "") + parts.joined(separator: " · ")
        cell.shortcutField.stringValue = row < 9 ? "⌘\(row + 1)" : ""
        cell.toolTip = e.kind == .image ? nil : e.title.replacingOccurrences(of: " ⏎ ", with: "\n")

        let big = e.kind == .image
        cell.setIconSize(big ? 44 : 22)
        switch e.kind {
        case .image:
            if let t = thumbs.object(forKey: e.id.uuidString as NSString) {
                cell.iconView.image = t
            } else {
                cell.iconView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
                loadThumbnail(e, cell: cell)
            }
        case .file:
            cell.iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        case .link:
            cell.iconView.image = ClipboardController.appIcon(e.app)
                ?? NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        case .text:
            cell.iconView.image = ClipboardController.appIcon(e.app)
                ?? NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)
        }
        return cell
    }

    /// Small, cheap thumbnail decoded off the main thread with ImageIO.
    private func loadThumbnail(_ e: ClipEntry, cell: ClipCell) {
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak cell] in
            guard let p = store.payload(for: e)?.first,
                  let data = p["public.png"] ?? p["public.jpeg"] ?? p["public.tiff"],
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 160,
                  ] as CFDictionary) else { return }
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            DispatchQueue.main.async {
                self?.thumbs.setObject(img, forKey: e.id.uuidString as NSString)
                if cell?.entryID == e.id { cell?.iconView.image = img }
            }
        }
    }

    // MARK: - Actions

    private var selected: ClipEntry? {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return rows.indices.contains(r) ? rows[r] : nil
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0, rows.indices.contains(table.clickedRow) else { return }
        let flags = NSEvent.modifierFlags
        controller.use(rows[table.clickedRow], plain: flags.contains(.shift), paste: !flags.contains(.command))
    }

    private func useSelected(plain: Bool, paste: Bool) {
        guard let e = selected else { NSSound.beep(); return }
        controller.use(e, plain: plain, paste: paste)
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let r = min(max((table.selectedRow < 0 ? -1 : table.selectedRow) + delta, 0), rows.count - 1)
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    @objc private func showSettings() {
        let menu = controller.settingsMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: gearButton.bounds.height + 4), in: gearButton)
        reload()
    }

    @objc private func grantPermission() { controller.requestAccessibility() }

    @objc private func pinSelected() { if let e = selected { controller.store.togglePin(e.id); reload() } }
    @objc private func deleteSelected() {
        guard let e = selected else { return }
        let r = table.selectedRow
        controller.store.remove([e.id])
        reload()
        if !rows.isEmpty { table.selectRowIndexes([min(r, rows.count - 1)], byExtendingSelection: false) }
    }
    @objc private func pasteSelected() { useSelected(plain: false, paste: true) }
    @objc private func pastePlainSelected() { useSelected(plain: true, paste: true) }
    @objc private func copySelected() { useSelected(plain: false, paste: false) }
    @objc private func shelfSelected() { if let e = selected { controller.addToShelf(e) } }
    @objc private func ignoreAppSelected() { if let app = selected?.app { controller.ignoreApp(app) } }

    // MARK: - Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): moveSelection(-8)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): moveSelection(8)
        case #selector(NSResponder.insertNewline(_:)):
            let f = NSApp.currentEvent?.modifierFlags ?? []
            useSelected(plain: f.contains(.shift), paste: !f.contains(.command))
        case #selector(NSResponder.cancelOperation(_:)):
            if !search.stringValue.isEmpty { search.stringValue = ""; reload() } else { close() }
        default: return false
        }
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        rows = store.filtered(search.stringValue)
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0) }
        emptyLabel.stringValue = "Sonuç yok"
        emptyLabel.isHidden = !rows.isEmpty
    }

    /// Shortcuts the search field doesn't handle itself (⌘1…9, ⌥P, ⌥⌫, ⌥⌘⌫, ⌘↩, ⇧↩).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.view.window else { return event }
            let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers ?? ""
            switch (event.keyCode, f) {
            case (35, .option): self.pinSelected(); return nil                            // ⌥P
            case (51, .option): self.deleteSelected(); return nil                         // ⌥⌫
            case (51, [.option, .command]): self.controller.clearHistory(); self.reload(); return nil
            case (36, .command), (76, .command): self.useSelected(plain: false, paste: false); return nil
            case (36, .shift), (36, [.shift, .option]): self.useSelected(plain: true, paste: true); return nil
            case (36, .option): self.useSelected(plain: false, paste: true); return nil
            default: break
            }
            if f == .command || f == .option, let n = Int(chars), (1...9).contains(n), n <= self.rows.count {
                self.controller.use(self.rows[n - 1], plain: false, paste: true)
                return nil
            }
            return event
        }
    }

    private func close() {
        if inPanel { controller.closePanel() } else { controller.closePopover?() }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0, rows.indices.contains(table.clickedRow) else { return }
        let e = rows[table.clickedRow]
        func add(_ title: String, _ sel: Selector) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        add("Yapıştır", #selector(pasteSelected))
        if e.kind != .image { add("Düz metin olarak yapıştır", #selector(pastePlainSelected)) }
        add("Sadece kopyala", #selector(copySelected))
        menu.addItem(.separator())
        add(e.pinned ? "Sabitlemeyi kaldır" : "Sabitle 📌", #selector(pinSelected))
        add("Rafa ekle (dosya olarak sakla)", #selector(shelfSelected))
        if let app = e.app {
            add("\(ClipboardController.appName(app)) kopyalarını yok say", #selector(ignoreAppSelected))
        }
        menu.addItem(.separator())
        add("Sil", #selector(deleteSelected))
    }
}

// MARK: - Cell

final class ClipCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ClipCell")
    var entryID: UUID?
    let iconView = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    let subtitleField = NSTextField(labelWithString: "")
    let shortcutField = NSTextField(labelWithString: "")
    private var iconW: NSLayoutConstraint!
    private var iconH: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .secondaryLabelColor
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 4
        iconView.layer?.masksToBounds = true
        titleField.font = .systemFont(ofSize: 12.5)
        titleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = .systemFont(ofSize: 10)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail
        shortcutField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        shortcutField.textColor = .tertiaryLabelColor

        let texts = NSStackView(views: [titleField, subtitleField])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        for v in [iconView, texts, shortcutField] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcutField.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconW = iconView.widthAnchor.constraint(equalToConstant: 22)
        iconH = iconView.heightAnchor.constraint(equalToConstant: 22)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconW, iconH,
            texts.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: shortcutField.leadingAnchor, constant: -6),
            shortcutField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            shortcutField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setIconSize(_ s: CGFloat) {
        iconW.constant = s
        iconH.constant = s
    }
}
