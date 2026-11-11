import AppKit
import QuickLookThumbnailing

final class ShelfViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let store: ShelfStore
    let table = ShelfTable()
    private let emptyLabel = NSTextField(labelWithString: "Dosya, metin, görsel veya bağlantıyı\nraf simgesine ya da buraya bırak")
    private let countLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: "Tümünü Sil", target: nil, action: nil)
    private let pasteButton = NSButton()
    private let thumbs = NSCache<NSString, NSImage>()

    init(store: ShelfStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = DropView(frame: NSRect(x: 0, y: 0, width: 340, height: 420))
        root.accepts = { [weak self] info in
            guard let self else { return false }
            return (info.draggingSource as AnyObject?) !== self.table
        }
        root.onDrop = { [weak self] info in self?.store.ingest(info.draggingPasteboard) ?? false }

        // Header
        let title = NSTextField(labelWithString: "Raf")
        title.font = .boldSystemFont(ofSize: 13)
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 11)
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearAll)
        pasteButton.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Panodan ekle")
        pasteButton.isBordered = false
        pasteButton.contentTintColor = .secondaryLabelColor
        pasteButton.toolTip = "Panodakini rafa ekle (⌘V)"
        pasteButton.target = self
        pasteButton.action = #selector(pasteClipboard)
        let header = NSStackView(views: [title, countLabel, NSView(), pasteButton, clearButton])
        header.orientation = .horizontal
        header.spacing = 6

        // Table
        let column = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 42
        table.style = .inset
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.onDelete = { [weak self] in self?.deleteSelected() }
        table.onPaste = { [weak self] in self?.pasteClipboard() }
        table.onCopy = { [weak self] in self?.copyClicked() }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        // Footer
        let footer = NSTextField(labelWithString: "30 gün sonra silinir (sabitler hariç) · Dışarı sürükle · ⌘V ekle")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        footer.alignment = .center

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)

        for v in [header, scroll, footer, emptyLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = root
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(table) // so ⌘V / ⌘C / ⌫ work right away
    }

    func reload() {
        guard isViewLoaded else { return }
        table.reloadData()
        let n = store.items.count
        emptyLabel.isHidden = n > 0
        clearButton.isHidden = n == 0
        let bytes = store.totalSize
        countLabel.stringValue = n == 0 ? "" :
            bytes > 0 ? "\(n) öğe · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" : "\(n) öğe"
    }

    // MARK: - Data source

    func numberOfRows(in tableView: NSTableView) -> Int { store.items.count }

    /// Subtitle text, prefixed with a small monochrome pin for pinned items.
    private static func subtitle(_ text: String, pinned: Bool, color: NSColor) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: color]
        let out = NSMutableAttributedString()
        if pinned, let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Sabit")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold).applying(.init(paletteColors: [color]))) {
            let a = NSTextAttachment()
            a.image = pin
            a.bounds = NSRect(x: 0, y: -1, width: pin.size.width, height: pin.size.height)
            out.append(NSAttributedString(attachment: a))
            out.append(NSAttributedString(string: " ", attributes: attrs))
        }
        out.append(NSAttributedString(string: text, attributes: attrs))
        return out
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ShelfCell.id, owner: nil) as? ShelfCell) ?? ShelfCell()
        let item = store.items[row]
        cell.titleField.stringValue = item.name
        let kind: String
        switch item.kind {
        case .file: kind = "Dosya"
        case .text: kind = "Metin"
        case .link: kind = "Bağlantı"
        }
        var parts = [kind]
        if let size = item.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        else if item.kind == .file { parts.append("Klasör") }
        if item.isPinned {
            parts.append("Sabit")
            cell.subtitleField.textColor = .secondaryLabelColor
        } else {
            let days = store.daysLeft(item)
            parts.append("\(days) gün kaldı")
            cell.subtitleField.textColor = days <= 3 ? .systemOrange : .secondaryLabelColor
        }
        cell.subtitleField.attributedStringValue = Self.subtitle(parts.joined(separator: " · "),
                                                                 pinned: item.isPinned,
                                                                 color: cell.subtitleField.textColor ?? .secondaryLabelColor)
        let url = store.url(for: item)
        let key = item.id.uuidString as NSString
        cell.itemID = item.id
        cell.iconView.image = thumbs.object(forKey: key) ?? NSWorkspace.shared.icon(forFile: url.path)
        if thumbs.object(forKey: key) == nil, item.kind == .file {
            loadThumbnail(url: url, key: key, cell: cell, id: item.id)
        }
        cell.deleteButton.target = self
        cell.deleteButton.action = #selector(deleteRow(_:))
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = store.items[row]
        let url = store.url(for: item)
        guard item.kind == .text, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return url as NSURL
        }
        // Text: provide both the .txt file (Finder) and the plain string (editors).
        let pbItem = NSPasteboardItem()
        pbItem.setString(text, forType: .string)
        pbItem.setString(url.absoluteString, forType: .fileURL)
        return pbItem
    }

    /// Real previews (images, PDFs, videos…) via QuickLook; falls back to the file icon.
    private func loadThumbnail(url: URL, key: NSString, cell: ShelfCell, id: UUID) {
        let scale = view.window?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 30, height: 30),
                                               scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self, weak cell] rep, _ in
            guard let rep else { return }
            DispatchQueue.main.async {
                self?.thumbs.setObject(rep.nsImage, forKey: key)
                if cell?.itemID == id { cell?.iconView.image = rep.nsImage }
            }
        }
    }

    // MARK: - Actions

    @objc private func pasteClipboard() { store.addFromClipboard() }

    @objc private func pinClicked() {
        for item in items(at: targetRows) { store.togglePin(item.id) }
    }

    private var targetRows: IndexSet {
        let clicked = table.clickedRow
        if clicked >= 0 && !table.selectedRowIndexes.contains(clicked) { return IndexSet(integer: clicked) }
        return table.selectedRowIndexes
    }

    private func items(at rows: IndexSet) -> [ShelfItem] {
        rows.filter { $0 < store.items.count }.map { store.items[$0] }
    }

    @objc private func openClicked() {
        for item in items(at: targetRows) { NSWorkspace.shared.open(store.url(for: item)) }
    }

    @objc private func revealClicked() {
        NSWorkspace.shared.activateFileViewerSelecting(items(at: targetRows).map(store.url(for:)))
    }

    @objc private func copyClicked() {
        if let item = items(at: targetRows).first { store.copyToPasteboard(item) }
    }

    @objc private func deleteClicked() {
        store.remove(Set(items(at: targetRows).map(\.id)))
    }

    @objc private func deleteRow(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0, row < store.items.count else { return }
        store.remove([store.items[row].id])
    }

    private func deleteSelected() {
        store.remove(Set(items(at: table.selectedRowIndexes).map(\.id)))
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Raftaki tüm öğeler silinsin mi?"
        alert.informativeText = "Sabitlenmiş öğeler kalır. Bu işlem geri alınamaz; orijinal dosyalarınız etkilenmez."
        alert.addButton(withTitle: "Sil")
        alert.addButton(withTitle: "Vazgeç")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { store.removeAll() }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0 else { return }
        let pinned = items(at: targetRows).allSatisfy(\.isPinned)
        let entries: [(String, Selector)] = [
            ("Aç", #selector(openClicked)),
            ("Finder'da Göster", #selector(revealClicked)),
            ("Kopyala", #selector(copyClicked)),
            (pinned ? "Sabitlemeyi kaldır" : "Sabitle (silinmesin)", #selector(pinClicked)),
        ]
        for (title, sel) in entries {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            if sel == #selector(pinClicked) {
                mi.image = NSImage(systemSymbolName: pinned ? "pin.slash" : "pin", accessibilityDescription: nil)
            }
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let del = NSMenuItem(title: "Sil", action: #selector(deleteClicked), keyEquivalent: "")
        del.target = self
        menu.addItem(del)
    }
}

// MARK: - Views

final class ShelfTable: NSTableView {
    var onDelete: (() -> Void)?
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch (event.keyCode, cmd) {
        case (51, _), (117, _): onDelete?()
        case (9, true): onPaste?()   // ⌘V
        case (8, true): onCopy?()    // ⌘C
        default: super.keyDown(with: event)
        }
    }
}

final class ShelfCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ShelfCell")
    var itemID: UUID?
    let iconView = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    let subtitleField = NSTextField(labelWithString: "")
    let deleteButton = NSButton()

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.font = .systemFont(ofSize: 12)
        subtitleField.font = .systemFont(ofSize: 10)
        deleteButton.isBordered = false
        deleteButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Sil")
        deleteButton.contentTintColor = .tertiaryLabelColor
        deleteButton.toolTip = "Sil"

        let texts = NSStackView(views: [titleField, subtitleField])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        for v in [iconView, texts, deleteButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            texts.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -6),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Popover root that accepts drops and shows an accent border while targeted.
final class DropView: NSView {
    var onDrop: ((NSDraggingInfo) -> Bool)?
    var accepts: ((NSDraggingInfo) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        registerForDraggedTypes(ShelfStore.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setTargeted(_ on: Bool) {
        layer?.borderWidth = on ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts?(sender) ?? true else { return [] }
        setTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        (accepts?(sender) ?? true) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setTargeted(false)
        return onDrop?(sender) ?? false
    }
}
