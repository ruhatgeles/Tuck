import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var clipboard: ClipboardController!
    private var shelf: ShelfController!
    private var watchdog: Watchdog?
    private var hider: BarHider!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Creation order = right-to-left placement on first launch:
        // [ ...hidden icons... | separator ][ toggle ][ shelf ]
        clipboard = ClipboardController()
        shelf = ShelfController(clipboard: clipboard)
        watchdog = Watchdog()
        hider = BarHider()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shelf.store.flush()
        clipboard.applicationWillTerminate()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
