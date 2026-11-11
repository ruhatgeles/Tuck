import AppKit

struct ShelfItem: Codable, Equatable {
    enum Kind: String, Codable { case file, text, link }
    let id: UUID
    var name: String
    var file: String // path relative to store root
    var added: Date
    var kind: Kind
    var pinned: Bool? = nil   // pinned items never expire
    var size: Int64? = nil    // bytes; nil for folders

    var isPinned: Bool { pinned ?? false }
}

/// Persists dropped things under ~/Library/Application Support/Tuck/Shelf.
/// Each drop gets its own folder; items expire 30 days after being added.
final class ShelfStore {
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    static let acceptedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .png, .tiff, .string] +
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    let root: URL
    private let indexURL: URL
    private(set) var items: [ShelfItem] = []
    var onChange: (() -> Void)?

    private let fm = FileManager.default
    private let io = DispatchQueue(label: "tuck.io", qos: .utility)
    private lazy var promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .utility
        return q
    }()

    /// - Parameter root: storage folder; defaults to ~/Library/Application Support/Tuck/Shelf.
    init(root custom: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = custom ?? base.appendingPathComponent("Tuck/Shelf", isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        load()
        removeOrphans()
        purgeExpired()
    }

    func url(for item: ShelfItem) -> URL { root.appendingPathComponent(item.file) }

    var totalSize: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }

    func daysLeft(_ item: ShelfItem) -> Int {
        let left = item.added.addingTimeInterval(Self.lifetime).timeIntervalSinceNow
        return max(0, Int(ceil(left / 86_400)))
    }

    // MARK: - Ingest

    @discardableResult
    func ingest(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            urls.forEach(addFile)
            return true
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            promises.forEach(addPromise)
            return true
        }
        if let png = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap(Self.pngData) {
            addData(png, name: "Görsel \(Self.stamp()).png", kind: .file)
            return true
        }
        if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first,
           let scheme = url.scheme, scheme.hasPrefix("http") {
            let plist = (try? PropertyListSerialization.data(
                fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)) ?? Data()
            addData(plist, name: Self.sanitize(url.host ?? "Bağlantı") + ".webloc", kind: .link)
            return true
        }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let firstLine = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            var name = Self.sanitize(String(firstLine.prefix(40)))
            if name.isEmpty { name = "Metin" }
            addData(Data(s.utf8), name: name + ".txt", kind: .text)
            return true
        }
        return false
    }

    private func addFile(_ src: URL) {
        let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let name = src.lastPathComponent
        io.async { [fm] in
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                // On APFS this is a cheap clone, not a full copy.
                let dest = dir.appendingPathComponent(name)
                try fm.copyItem(at: src, to: dest)
                let size = Self.fileSize(dest)
                DispatchQueue.main.async {
                    self.append(ShelfItem(id: id, name: name, file: "\(id.uuidString)/\(name)", added: Date(),
                                          kind: .file, size: size))
                }
            } catch {
                try? fm.removeItem(at: dir)
                NSLog("Tuck: copy failed: \(error)")
            }
        }
    }

    private func addPromise(_ receiver: NSFilePromiseReceiver) {
        let folder = UUID().uuidString
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: promiseQueue) { url, error in
            DispatchQueue.main.async {
                if let error { NSLog("Tuck: promise failed: \(error)"); return }
                let name = url.lastPathComponent
                self.append(ShelfItem(id: UUID(), name: name, file: "\(folder)/\(name)", added: Date(),
                                      kind: .file, size: Self.fileSize(url)))
            }
        }
    }

    private func addData(_ data: Data, name: String, kind: ShelfItem.Kind) {
        let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            append(ShelfItem(id: id, name: name, file: "\(id.uuidString)/\(name)", added: Date(),
                             kind: kind, size: Int64(data.count)))
        } catch {
            NSLog("Tuck: write failed: \(error)")
        }
    }

    private func append(_ item: ShelfItem) {
        items.insert(item, at: 0)
        save()
        onChange?()
    }

    // MARK: - Remove

    func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let gone = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        let urls = gone.map(url(for:))
        io.async { [fm] in
            for u in urls {
                try? fm.removeItem(at: u)
                let dir = u.deletingLastPathComponent()
                if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? false {
                    try? fm.removeItem(at: dir)
                }
            }
        }
        save()
        onChange?()
    }

    /// Removes everything except pinned items.
    func removeAll() { remove(Set(items.filter { !$0.isPinned }.map(\.id))) }

    func purgeExpired() {
        let cutoff = Date().addingTimeInterval(-Self.lifetime)
        remove(Set(items.filter { !$0.isPinned && $0.added < cutoff }.map(\.id)))
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned = !items[i].isPinned
        if !items[i].isPinned { items[i].added = Date() } // unpinning restarts the 30-day clock
        save()
        onChange?()
    }

    /// Blocks until pending disk writes finish (call before quitting).
    func flush() { io.sync {} }

    /// Adds whatever is currently on the clipboard.
    @discardableResult
    func addFromClipboard() -> Bool { ingest(.general) }

    // MARK: - Clipboard

    func copyToPasteboard(_ item: ShelfItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let u = url(for: item)
        switch item.kind {
        case .text:
            if let s = try? String(contentsOf: u, encoding: .utf8) { pb.setString(s, forType: .string) }
        case .link:
            if let data = try? Data(contentsOf: u),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let s = dict["URL"] as? String {
                pb.setString(s, forType: .string)
            }
        case .file:
            pb.writeObjects([u as NSURL])
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? Self.decoder.decode([ShelfItem].self, from: data) else { return }
        items = decoded.filter { fm.fileExists(atPath: url(for: $0).path) }
    }

    private func save() {
        guard let data = try? Self.encoder.encode(items) else { return }
        let target = indexURL
        io.async { try? data.write(to: target, options: .atomic) }
    }

    /// Clean folders left behind by interrupted copies.
    private func removeOrphans() {
        let used = Set(items.map { String($0.file.split(separator: "/").first ?? "") })
        let dirs = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for d in dirs where UUID(uuidString: d) != nil && !used.contains(d) {
            try? fm.removeItem(at: root.appendingPathComponent(d))
        }
    }

    // MARK: - Helpers

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    static func fileSize(_ url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if v?.isDirectory == true { return nil }
        return v?.fileSize.map(Int64.init)
    }

    private static func pngData(_ tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }
}
