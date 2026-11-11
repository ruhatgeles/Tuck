import Foundation

/// App-wide preferences shared by several components.
enum Settings {
    /// Close the popover / clipboard panel / info popover when clicking outside Tuck. Default: on.
    static var closeOnOutsideClick: Bool {
        get { UserDefaults.standard.object(forKey: "closeOnOutsideClick") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "closeOnOutsideClick") }
    }
}
