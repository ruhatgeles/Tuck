import AppKit
import CryptoKit

struct ClipEntry: Codable, Equatable {
    enum Kind: String, Codable { case text, link, image, file }
    let id: UUID
    var kind: Kind
    var title: String        // one-line preview
    var search: String       // folded text used for searching
    var hash: String         // content hash, used to de-duplicate
    var firstCopied: Date
    var lastCopied: Date
    var copies: Int
    var app: String?         // bundle id of the app it was copied from
    var pinned: Bool
    var bytes: Int
}

/// Clipboard history. Metadata lives in memory + index.json; the actual pasteboard
/// payloads are stored one binary plist per entry and only loaded when needed.
final class ClipboardStore {
    /// Types we keep. Everything else (private app formats) is dropped to stay small.
    static let keptTypes: Set<String> = [
        "public.utf8-plain-text", "public.rtf", "com.apple.flat-rtfd", "public.html",
        "public.png", "public.tiff", "public.jpeg", "public.file-url", "public.url", "public.url-name",
    ]
    static let maxEntryBytes = 25 * 1024 * 1024

    let root: URL
    private let dataDir: URL
    private let indexURL: URL
    private(set) var entries: [ClipEntry] = []
    var onChange: (() -> Void)?

    private let fm = FileManager.default
    private let io = DispatchQueue(label: "tuck.clip.io", qos: .utility)

    var limit: Int {
        get { let v = UserDefaults.standard.integer(forKey: "clipLimit"); return v > 0 ? v : 200 }
        set { UserDefaults.standard.set(newValue, forKey: "clipLimit"); enforceLimit(); save(); onChange?() }
    }

    init(root custom: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = custom ?? base.appendingPathComponent("Tuck/Clipboard", isDirectory: true)
        dataDir = root.appendingPathComponent("data", isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")
        // Clipboard history can contain private data: keep it readable only by the user.
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        load()
    }

    // MARK: - Capture

    /// Stores the pasteboard contents. Returns true if something was added or bumped.
    @discardableResult
    func capture(_ pb: NSPasteboard, app: String?) -> Bool {
        guard let items = pb.pasteboardItems, !items.isEmpty else { return false }
        var payload: [[String: Data]] = []
        for item in items {
            var dict: [String: Data] = [:]
            for t in item.types where Self.keptTypes.contains(t.rawValue) {
                if let d = item.data(forType: t) { dict[t.rawValue] = d }
            }
            // Keep one image representation: PNG is far smaller than TIFF.
            if let tiff = dict["public.tiff"] {
                if dict["public.png"] == nil, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    dict["public.png"] = png
                }
                if dict["public.png"] != nil { dict["public.tiff"] = nil }
            }
            if !dict.isEmpty { payload.append(dict) }
        }
        guard !payload.isEmpty else { return false }
        let bytes = payload.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
        guard bytes <= Self.maxEntryBytes else { return false }

        guard let info = Self.describe(payload) else { return false }
        let now = Date()

        if let i = entries.firstIndex(where: { $0.hash == info.hash }) {
            entries[i].lastCopied = now
            entries[i].copies += 1
            entries[i].app = app ?? entries[i].app
            let id = entries[i].id
            writePayload(payload, id: id) // latest formatting wins
            sortEntries()
            save()
            onChange?()
            return true
        }

        let entry = ClipEntry(id: UUID(), kind: info.kind, title: info.title, search: info.search,
                              hash: info.hash, firstCopied: now, lastCopied: now, copies: 1,
                              app: app, pinned: false, bytes: bytes)
        writePayload(payload, id: entry.id)
        entries.append(entry)
        sortEntries()
        enforceLimit()
        save()
        onChange?()
        return true
    }

    private struct Info { let kind: ClipEntry.Kind; let title: String; let search: String; let hash: String }

    private static func describe(_ payload: [[String: Data]]) -> Info? {
        let files = payload.compactMap { $0["public.file-url"].flatMap { URL(dataRepresentation: $0, relativeTo: nil) } }
        if !files.isEmpty {
            let names = files.map(\.lastPathComponent)
            let title = names.count == 1 ? names[0] : "\(names.count) dosya: " + names.joined(separator: ", ")
            return Info(kind: .file, title: title, search: fold(files.map(\.path).joined(separator: " ")),
                        hash: sha(Data(files.map(\.path).joined(separator: "\n").utf8)))
        }
        if let png = payload.first?["public.png"] ?? payload.first?["public.jpeg"] {
            var title = "Görsel"
            if let rep = NSBitmapImageRep(data: png) { title += " \(rep.pixelsWide)×\(rep.pixelsHigh)" }
            return Info(kind: .image, title: title, search: fold(title), hash: sha(png))
        }
        guard let text = plainText(payload), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLink = !trimmed.contains(where: \.isWhitespace)
            && (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
        let oneLine = trimmed.prefix(300).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ⏎ ")
        return Info(kind: isLink ? .link : .text, title: oneLine,
                    search: fold(String(text.prefix(5000))), hash: sha(Data(text.utf8)))
    }

    static func plainText(_ payload: [[String: Data]]) -> String? {
        let parts = payload.compactMap { dict -> String? in
            if let d = dict["public.utf8-plain-text"], let s = String(data: d, encoding: .utf8) { return s }
            if let d = dict["public.rtf"], let a = NSAttributedString(rtf: d, documentAttributes: nil) { return a.string }
            if let d = dict["public.url"], let s = String(data: d, encoding: .utf8) { return s }
            if let d = dict["public.file-url"], let u = URL(dataRepresentation: d, relativeTo: nil) { return u.path }
            return nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // MARK: - Use

    func payload(for entry: ClipEntry) -> [[String: Data]]? {
        guard let data = try? Data(contentsOf: dataURL(entry.id)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Data]]
    }

    func text(for entry: ClipEntry) -> String? { payload(for: entry).flatMap(Self.plainText) }

    func image(for entry: ClipEntry) -> NSImage? {
        guard entry.kind == .image, let p = payload(for: entry)?.first,
              let d = p["public.png"] ?? p["public.jpeg"] ?? p["public.tiff"] else { return nil }
        return NSImage(data: d)
    }

    /// Puts the entry back on a pasteboard. `plain` strips all formatting.
    @discardableResult
    func write(_ entry: ClipEntry, to pb: NSPasteboard, plain: Bool = false) -> Bool {
        guard let payload = payload(for: entry) else { return false }
        pb.clearContents()
        if plain, entry.kind != .image, let s = Self.plainText(payload) {
            return pb.setString(s, forType: .string)
        }
        let items: [NSPasteboardItem] = payload.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        return pb.writeObjects(items)
    }

    /// Marks as just used: moves to the top (below pins) and counts the copy.
    func touch(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].lastCopied = Date()
        entries[i].copies += 1
        sortEntries()
        save()
        onChange?()
    }

    // MARK: - Edit

    func togglePin(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].pinned.toggle()
        sortEntries()
        enforceLimit()
        save()
        onChange?()
    }

    func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        let urls = ids.map(dataURL)
        io.async { [fm] in urls.forEach { try? fm.removeItem(at: $0) } }
        save()
        onChange?()
    }

    /// Clears history. Pinned items are kept unless `includingPinned`.
    func clear(includingPinned: Bool = false) {
        remove(Set(entries.filter { includingPinned || !$0.pinned }.map(\.id)))
    }

    func filtered(_ query: String) -> [ClipEntry] {
        let words = Self.fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { e in words.allSatisfy { e.search.contains($0) } }
    }

    var totalBytes: Int { entries.reduce(0) { $0 + $1.bytes } }

    func flush() { io.sync {} }

    // MARK: - Internals

    private func dataURL(_ id: UUID) -> URL { dataDir.appendingPathComponent(id.uuidString + ".plist") }

    private func writePayload(_ payload: [[String: Data]], id: UUID) {
        let url = dataURL(id)
        io.async {
            guard let data = try? PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
            else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// Pinned first, then most recently copied.
    private func sortEntries() {
        entries.sort { a, b in a.pinned != b.pinned ? a.pinned : a.lastCopied > b.lastCopied }
    }

    private func enforceLimit() {
        let unpinned = entries.filter { !$0.pinned }
        guard unpinned.count > limit else { return }
        let drop = unpinned.sorted { $0.lastCopied > $1.lastCopied }.dropFirst(limit)
        let ids = Set(drop.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        let urls = ids.map(dataURL)
        io.async { [fm] in urls.forEach { try? fm.removeItem(at: $0) } }
    }

    private func load() {
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? Self.decoder.decode([ClipEntry].self, from: data) {
            entries = decoded.filter { fm.fileExists(atPath: dataURL($0.id).path) }
        }
        sortEntries()
        // Remove payload files that are no longer referenced.
        let known = Set(entries.map { $0.id.uuidString + ".plist" })
        for f in (try? fm.contentsOfDirectory(atPath: dataDir.path)) ?? [] where !known.contains(f) {
            try? fm.removeItem(at: dataDir.appendingPathComponent(f))
        }
    }

    private func save() {
        guard let data = try? Self.encoder.encode(entries) else { return }
        let target = indexURL
        io.async { try? data.write(to: target, options: [.atomic]) }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// Search normalisation: case-, accent- and Turkish-i-insensitive
    /// ("istanbul" finds "İstanbul", "cicek" finds "çiçek").
    static func fold(_ s: String) -> String {
        s.lowercased(with: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func sha(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
}
