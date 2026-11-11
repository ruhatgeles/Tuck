import AppKit
import ServiceManagement

/// Hides menu bar icons by widening the "│" separator so items to its left no longer fit.
/// User arranges icons with ⌘-drag: anything left of the separator gets hidden.
///
/// macOS 27 (MenuBarAgent) note: the old "length = 10_000" trick no longer works —
/// an item wider than ~half the menu bar is simply dropped and nothing gets pushed.
/// Measured on a 1470pt notched screen (right-of-notch area 645pt):
///   <=170 fits · 200–480 left items go to the system "«" overflow ·
///   500–700 left items vanish (wanted) · >=800 separator dropped, nothing hidden.
/// So the collapsed width is ~90% of the area right of the notch (or half the screen).
final class BarHider: NSObject {
    // Two status items whose *roles* follow their position: the right one is always the
    // arrow (toggle), the left one the "│" separator. If the user ⌘-drags them past each
    // other while arranging icons, the roles simply swap instead of hiding breaking.
    private let itemA = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let itemB = NSStatusBar.system.statusItem(withLength: 12)
    private var swapped: Bool {
        get { UserDefaults.standard.bool(forKey: "hiderSwapped") }
        set { UserDefaults.standard.set(newValue, forKey: "hiderSwapped") }
    }
    private var toggle: NSStatusItem { swapped ? itemB : itemA }
    private var separator: NSStatusItem { swapped ? itemA : itemB }

    private let expandedLength: CGFloat = 12

    private var collapsedLength: CGFloat {
        if let custom = UserDefaults.standard.object(forKey: "collapsedLength") as? Double, custom > 0 {
            return CGFloat(custom)
        }
        let screen = separator.button?.window?.screen ?? NSScreen.main
        let area = screen?.auxiliaryTopRightArea?.width ?? (screen?.frame.width ?? 1440) / 2
        return (area * 0.9).rounded()
    }
    private let autoCollapseDelay: TimeInterval = 15

    private var isCollapsed = false
    private var autoCollapseTimer: Timer?

    private var autoCollapse: Bool {
        get { UserDefaults.standard.object(forKey: "autoCollapse") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoCollapse") }
    }

    override init() {
        super.init()
        itemA.autosaveName = "tuck.toggle"
        itemB.autosaveName = "tuck.separator"
        for item in [itemA, itemB] {
            item.button?.target = self
            item.button?.action = #selector(toggleClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        applyRoles()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.collapse() }
        // Debug aid: `Tuck --toggle-test` flips hide/show 12× and logs how long each takes.
        if CommandLine.arguments.contains("--toggle-test") { runToggleTest(remaining: 12) }
    }

    private func runToggleTest(remaining: Int) {
        guard remaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let t0 = DispatchTime.now().uptimeNanoseconds
            self.isCollapsed ? self.expand() : self.collapse()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            FileHandle.standardError.write(Data(String(format: "toggle collapsed=%d took %.2f ms\n", self.isCollapsed ? 1 : 0, ms).utf8))
            self.runToggleTest(remaining: remaining - 1)
        }
    }

    /// Gives the right-hand item the arrow and the left-hand one the separator look.
    private func applyRoles() {
        separator.length = isCollapsed ? collapsedLength : expandedLength
        toggle.length = NSStatusItem.variableLength
        if let b = separator.button {
            b.image = Self.separatorImage
            b.toolTip = "⌘ basılı tutup gizlenecek ikonları bu çizginin soluna sürükle"
        }
        toggle.button?.toolTip = "Gizli ikonları göster / gizle (sağ tık: ayarlar)"
        updateIcon()
    }

    /// Re-checks which of our two items is on the right. Only meaningful while expanded
    /// (when collapsed the separator is huge and its frame is not a useful position).
    private func normalizeRoles() {
        guard !isCollapsed,
              let tX = toggle.button?.window?.frame.minX,
              let sX = separator.button?.window?.frame.minX,
              tX < sX else { return }
        swapped.toggle()
        applyRoles()
    }

    // MARK: - Actions

    @objc private func toggleClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            isCollapsed ? expand() : collapse()
        }
    }

    private func collapse() {
        normalizeRoles()
        // Only collapse if the separator really sits left of the toggle,
        // otherwise we would push our own toggle off-screen.
        guard let sepX = separator.button?.window?.frame.minX,
              let togX = toggle.button?.window?.frame.minX,
              sepX < togX else { return }
        autoCollapseTimer?.invalidate()
        separator.length = collapsedLength
        isCollapsed = true
        updateIcon()
    }

    private func expand() {
        separator.length = expandedLength
        isCollapsed = false
        updateIcon()
        autoCollapseTimer?.invalidate()
        guard autoCollapse else { return }
        scheduleAutoCollapse(after: autoCollapseDelay)
    }

    /// Never collapse while a mouse button is held: the user may be ⌘-dragging icons,
    /// and resizing the separator mid-drag makes the whole menu bar re-layout (stutter).
    private func scheduleAutoCollapse(after delay: TimeInterval) {
        autoCollapseTimer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, !self.isCollapsed else { return }
            if NSEvent.pressedMouseButtons != 0 { self.scheduleAutoCollapse(after: 2); return }
            self.collapse()
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        autoCollapseTimer = t
    }

    private func updateIcon() {
        let name = isCollapsed ? "chevron.left" : "chevron.right"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: isCollapsed ? "Göster" : "Gizle")
        img?.isTemplate = true
        toggle.button?.image = img
    }

    // MARK: - Menu

    private func showMenu() {
        let menu = NSMenu()
        let hint = NSMenuItem(title: "⌘ basılı tutup simgeleri │ çizgisinin soluna sürükle", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let auto = NSMenuItem(title: "15 sn sonra otomatik gizle", action: #selector(toggleAutoCollapse), keyEquivalent: "")
        auto.target = self
        auto.state = autoCollapse ? .on : .off
        menu.addItem(auto)

        let login = NSMenuItem(title: "Girişte başlat", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        toggle.menu = menu
        toggle.button?.performClick(nil)
        toggle.menu = nil
    }

    @objc private func toggleAutoCollapse() {
        autoCollapse.toggle()
        if !autoCollapse { autoCollapseTimer?.invalidate() }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("Tuck: launch at login failed: \(error)")
        }
    }

    private static let separatorImage: NSImage = {
        let img = NSImage(size: NSSize(width: 4, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1.25, y: 1, width: 1.5, height: 14), xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}
