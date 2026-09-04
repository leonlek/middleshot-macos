import Foundation

/// User-facing preferences, backed by UserDefaults so they survive relaunch.
///
/// Kept as a plain namespace rather than an observable object: there is exactly
/// one reader (ActionHandler, on main) and one writer (the status bar menu, on
/// main), so nothing needs to observe anything.
enum Settings {
    private static let showsScreenshotThumbnailKey = "showsScreenshotThumbnail"
    private static let copiesScreenshotToClipboardKey = "copiesScreenshotToClipboard"

    /// Whether an area screenshot presents the floating thumbnail (`-u`) or
    /// saves straight to the screenshot folder with no UI.
    ///
    /// Defaults to **false** — a silent save is the point of the app for most
    /// captures, and the thumbnail's only real advantage (drag it into a text
    /// field) costs a few seconds of waiting for it to fade otherwise. An
    /// unset key reads as false, so no `register(defaults:)` is needed.
    static var showsScreenshotThumbnail: Bool {
        get { UserDefaults.standard.bool(forKey: showsScreenshotThumbnailKey) }
        set { UserDefaults.standard.set(newValue, forKey: showsScreenshotThumbnailKey) }
    }

    /// Whether a silent capture also lands on the clipboard, ready to paste.
    ///
    /// Defaults to **true**, so an unset key has to be told apart from a stored
    /// `false` — `bool(forKey:)` alone would read both as off.
    ///
    /// Has no effect in thumbnail mode: there the file's location is
    /// screencapture's secret, and the thumbnail can be dragged instead.
    static var copiesScreenshotToClipboard: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: copiesScreenshotToClipboardKey) != nil else {
                return true
            }
            return defaults.bool(forKey: copiesScreenshotToClipboardKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: copiesScreenshotToClipboardKey) }
    }
}
