import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shelf: ShelfController!
    private var hider: BarHider!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Creation order = right-to-left placement on first launch:
        // [ ...hidden icons... | separator ][ toggle ][ shelf ]
        shelf = ShelfController()
        hider = BarHider()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shelf.store.flush()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
