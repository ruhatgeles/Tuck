import Foundation

/// Debug-only main-thread stall detector. Pings the main queue every 0.5 s from a
/// background timer and logs any reply slower than 100 ms to ~/Library/Logs/Tuck/clipboard.log.
/// Enabled only with `defaults write io.github.ruhatgeles.Tuck clipDebug -bool true`.
final class Watchdog {
    private let timer: DispatchSourceTimer

    init?() {
        guard UserDefaults.standard.bool(forKey: "clipDebug") else { return nil }
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler {
            let sent = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
                if ms > 100 { ClipboardController.debugLog(String(format: "STALL main thread blocked %.0f ms", ms)) }
            }
        }
        timer.resume()
    }

    deinit { timer.cancel() }
}
