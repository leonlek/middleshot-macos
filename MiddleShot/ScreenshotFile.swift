import Foundation

/// Builds the destination for a silent capture — the file `screencapture -p`
/// would have written if we could still afford to pass `-p`.
///
/// We cannot: `-p` means "use the default settings", and those settings include
/// the floating thumbnail, so the only way to suppress the thumbnail is to name
/// the file ourselves. That hands us the rest of `-p`'s job as well, so the
/// three preferences that decide the path are read back out of the very domain
/// the Screenshot app writes: folder, name prefix and image format. They are
/// read per capture rather than cached, so changing them in the Screenshot app
/// takes effect on the next gesture with no relaunch.
enum ScreenshotFile {
    private static let domain = "com.apple.screencapture"

    static func nextURL() -> URL {
        let defaults = UserDefaults(suiteName: domain)
        let prefix = defaults?.string(forKey: "name") ?? "Screenshot"
        let type = defaults?.string(forKey: "type") ?? "png"
        let directory = captureDirectory(defaults)
        let stamp = timestamp.string(from: Date())

        // Two captures inside the same second would otherwise collide and the
        // second would overwrite the first.
        var url = directory.appendingPathComponent("\(prefix) \(stamp).\(type)")
        var duplicate = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory
                .appendingPathComponent("\(prefix) \(stamp) (\(duplicate)).\(type)")
            duplicate += 1
        }
        return url
    }

    /// `Screenshot 2569-09-05 at 00.03.09.png` — the era comes from the user's
    /// locale, which is what makes this match the system's own naming rather
    /// than the Gregorian stamp a fixed-locale formatter would produce.
    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    /// The `location` preference, or the Desktop. A location that has since been
    /// deleted or renamed falls back rather than handing screencapture a path it
    /// will fail to write — the capture would be lost with no visible error.
    private static func captureDirectory(_ defaults: UserDefaults?) -> URL {
        if let configured = defaults?.string(forKey: "location") {
            let expanded = (configured as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded,
                                              isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true)
    }
}
