import AppKit

/// Small popover with details about one clipboard item: where and when it was copied,
/// what kind of data it is, size, formats, and a preview.
final class ClipInfoViewController: NSViewController {
    private let entry: ClipEntry
    private let store: ClipboardStore

    static func show(for entry: ClipEntry, store: ClipboardStore, relativeTo view: NSView) {
        let p = NSPopover()
        p.behavior = Settings.closeOnOutsideClick ? .transient : .semitransient
        p.animates = false
        p.contentViewController = ClipInfoViewController(entry: entry, store: store)
        p.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
    }

    init(entry: ClipEntry, store: ClipboardStore) {
        self.entry = entry
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let formatNames: [String: String] = [
        "public.utf8-plain-text": "Düz metin", "public.utf16-plain-text": "Düz metin (UTF-16)",
        "public.utf16-external-plain-text": "Düz metin (UTF-16)", "NSStringPboardType": "Metin (eski biçim)",
        "public.rtf": "Biçimli metin (RTF)", "com.apple.flat-rtfd": "Biçimli metin + ekler (RTFD)",
        "public.html": "Web (HTML)", "public.png": "PNG görsel", "public.tiff": "TIFF görsel",
        "public.jpeg": "JPEG görsel", "public.heic": "HEIC görsel", "public.file-url": "Dosya konumu",
        "public.url": "Bağlantı", "public.url-name": "Bağlantı adı",
    ]

    override func loadView() {
        let payload = store.payload(for: entry)
        let text = payload.flatMap(ClipboardStore.plainText)

        // Header: source app icon + name, and what kind of item this is.
        let icon = NSImageView()
        icon.image = ClipboardController.appIcon(entry.app)
            ?? NSImage(systemSymbolName: entry.origin == "drop" ? "hand.draw" : "doc.on.clipboard",
                       accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let source: String
        if entry.origin == "drop" { source = "Sürükle-bırak ile eklendi" }
        else if let app = entry.app { source = ClipboardController.appName(app) }
        else { source = "Bilinmeyen uygulama" }
        let title = NSTextField(labelWithString: source)
        title.font = .boldSystemFont(ofSize: 13)
        let kind = NSTextField(labelWithString: kindDescription(payload))
        kind.font = .systemFont(ofSize: 11)
        kind.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [title, kind])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        let header = NSStackView(views: [icon, titles])
        header.spacing = 8

        // Detail rows.
        var rows: [(String, String)] = []
        if entry.origin == "drop" { rows.append(("Nasıl", "Tuck'a sürüklenip bırakıldı")) }
        else if entry.app != nil { rows.append(("Nasıl", "Kopyalandı (⌘C / Kopyala)")) }
        if let app = entry.app { rows.append(("Uygulama kimliği", app)) }
        rows.append(("İlk kopyalama", Self.dateFormatter.string(from: entry.firstCopied)))
        if entry.copies > 1 {
            rows.append(("Son kopyalama", Self.dateFormatter.string(from: entry.lastCopied)))
        }
        rows.append(("Kaç kez", "\(entry.copies)"))
        rows.append(("Boyut", ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file)))

        switch entry.kind {
        case .text, .link:
            if let t = text {
                let words = t.split { $0.isWhitespace || $0.isNewline }.count
                let lines = t.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
                rows.append(("İçerik", "\(t.count) karakter · \(words) kelime · \(lines) satır"))
                if entry.kind == .link, let host = URL(string: t.trimmingCharacters(in: .whitespacesAndNewlines))?.host {
                    rows.append(("Site", host))
                }
            }
        case .image:
            if let img = store.image(for: entry), let rep = img.representations.first {
                rows.append(("Çözünürlük", "\(rep.pixelsWide) × \(rep.pixelsHigh) px"))
            }
        case .file:
            let urls = payload?.compactMap { $0["public.file-url"].flatMap { URL(dataRepresentation: $0, relativeTo: nil) } } ?? []
            let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }.count
            rows.append(("Dosyalar", "\(urls.count)" + (missing > 0 ? " (\(missing) tanesi artık yok)" : "")))
        }
        rows.append(("Durum", entry.pinned ? "Sabitlenmiş — silinmez" : "Geçmişte"))
        if let formats = entry.formats, !formats.isEmpty {
            let known = formats.compactMap { Self.formatNames[$0] }
            let unique = Array(NSOrderedSet(array: known)) as? [String] ?? known
            let extra = formats.count - known.count
            rows.append(("Biçimler", (unique.isEmpty ? "" : unique.joined(separator: ", "))
                         + (extra > 0 ? (unique.isEmpty ? "" : " + ") + "\(extra) uygulamaya özel" : "")))
        }

        let grid = NSGridView(views: rows.map { key, value in
            let k = NSTextField(labelWithString: key)
            k.font = .systemFont(ofSize: 11)
            k.textColor = .secondaryLabelColor
            k.alignment = .right
            let v = NSTextField(wrappingLabelWithString: value)
            v.font = .systemFont(ofSize: 11)
            v.isSelectable = true
            v.preferredMaxLayoutWidth = 230
            return [k, v]
        })
        grid.rowSpacing = 4
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing

        var views: [NSView] = [header, grid]
        if let preview = makePreview(text: text) { views.append(preview) }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 340),
        ])
        view = root
    }

    private func kindDescription(_ payload: [[String: Data]]?) -> String {
        let first = payload?.first ?? [:]
        switch entry.kind {
        case .link: return "Bağlantı"
        case .image: return "Görsel"
        case .file: return "Dosya"
        case .text:
            if first["public.html"] != nil || first["public.rtf"] != nil || first["com.apple.flat-rtfd"] != nil {
                return "Biçimli metin"
            }
            return "Düz metin"
        }
    }

    private func makePreview(text: String?) -> NSView? {
        if entry.kind == .image, let img = store.image(for: entry) {
            let iv = NSImageView(image: img)
            iv.imageScaling = .scaleProportionallyDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 6
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 316).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 150).isActive = true
            return iv
        }
        guard let text, !text.isEmpty else { return nil }
        let tv = NSTextView()
        tv.string = String(text.prefix(4000)) + (text.count > 4000 ? "\n…" : "")
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 316).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: min(150, CGFloat(20 + 14 * min(text.split(whereSeparator: \.isNewline).count, 10)))).isActive = true
        return scroll
    }
}
