import Foundation

/// User-facing preferences, backed by UserDefaults so they survive relaunch.
///
/// Kept as a plain namespace rather than an observable object: there is exactly
/// one reader (ActionHandler, on main) and one writer (the status bar menu, on
/// main), so nothing needs to observe anything.
enum Settings {
    private static let showsScreenshotThumbnailKey = "showsScreenshotThumbnail"

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
}
