import Cocoa
import Security
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "app")

/// Finds newer builds that `dist.sh` dropped into Dropbox and installs one on
/// request. No server: Dropbox already syncs every zip to the other Macs.
///
/// A zip is only installed when its app passes our own designated requirement
/// (same bundle id, signed by the same certificate) — anything else landing in
/// that folder is refused. The same requirement is what lets the privacy
/// grants carry over, so a build that passes keeps every permission.
final class Updater {
    struct Release {
        let build: Int
        let version: String
        let zip: URL
    }

    /// Set when a newer build than ours is sitting in Dropbox.
    private(set) var available: Release?
    var onChange: () -> Void = {}
    private var timer: Timer?

    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    /// Lists the folders and remembers the newest build above ours. Reads
    /// directory entries only — never a zip — so a Dropbox placeholder isn't
    /// downloaded just to be looked at.
    @discardableResult
    func check() -> Release? {
        let newest = Self.publishFolders()
            .flatMap { folder in
                ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                    .compactMap(Self.release)
            }
            .max { $0.build < $1.build }
        let found = newest.flatMap { $0.build > Self.currentBuild ? $0 : nil }
        if found?.build != available?.build {
            available = found
            if let found {
                os_log("Update available: build %d at %{public}@", log: log, type: .info, found.build, found.zip.path)
            }
            onChange()
        }
        return found
    }

    /// `~/Dropbox/Apps`, plus the File Provider location newer Dropbox clients
    /// use (`~/Library/CloudStorage/Dropbox…/Apps`) — the other Macs may have
    /// either.
    private static func publishFolders() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var folders = [home.appendingPathComponent("Dropbox/Apps")]
        let cloud = home.appendingPathComponent("Library/CloudStorage")
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: cloud.path)) ?? []
        where entry.hasPrefix("Dropbox") {
            folders.append(cloud.appendingPathComponent(entry).appendingPathComponent("Apps"))
        }
        return folders
    }

    /// "MiddleShot-0.2.0-b39.zip" → build 39.
    private static func release(from url: URL) -> Release? {
        let name = url.lastPathComponent
        guard name.hasPrefix("MiddleShot-"), name.hasSuffix(".zip"),
              let marker = name.range(of: "-b", options: .backwards) else { return nil }
        let version = String(name[name.index(name.startIndex, offsetBy: 11)..<marker.lowerBound])
        guard let build = Int(name[marker.upperBound..<name.index(name.endIndex, offsetBy: -4)]) else { return nil }
        return Release(build: build, version: version, zip: url)
    }

    enum Failure: LocalizedError {
        case unzip(String), noApp, untrusted(String), notNewer(Int), helper(String)
        var errorDescription: String? {
            switch self {
            case .unzip(let detail): return "The zip couldn't be opened. \(detail)"
            case .noApp: return "The zip has no MiddleShot.app inside."
            case .untrusted(let detail): return "The app in the zip isn't signed like this one, so it wasn't installed. \(detail)"
            case .notNewer(let build): return "The zip holds build \(build), which isn't newer than this one."
            case .helper(let detail): return "The installer couldn't start. \(detail)"
            }
        }
    }

    /// Unpacks and verifies off main, then quits; a shell outlives us, swaps the
    /// bundle in place and opens it. If the swap fails it puts the old bundle
    /// back and opens that, so the app never just disappears.
    func install(_ release: Release, completion: @escaping (Failure?) -> Void) {
        let target = Bundle.main.bundleURL
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.prepare(release) }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    os_log("Update failed: %{public}@", log: log, type: .error, "\(error)")
                    completion(error as? Failure ?? .unzip(error.localizedDescription))
                case .success(let newApp):
                    do {
                        try Self.launchSwap(newApp: newApp.app, target: target, work: newApp.work)
                        os_log("Installing build %d over %{public}@", log: log, type: .info, release.build, target.path)
                        NSApp.terminate(nil)
                    } catch {
                        completion(.helper(error.localizedDescription))
                    }
                }
            }
        }
    }

    /// Returns the verified app and the scratch folder it sits in.
    private static func prepare(_ release: Release) throws -> (app: URL, work: URL) {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiddleShot-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // ditto reads through a Dropbox placeholder, downloading it if needed.
        // Thrown out on any failure below; on success the swap script removes it.
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: work) } }
        let unzip = try run("/usr/bin/ditto", ["-x", "-k", release.zip.path, work.path])
        guard unzip.status == 0 else { throw Failure.unzip(unzip.output) }

        let enumerator = FileManager.default.enumerator(at: work, includingPropertiesForKeys: nil)
        var found: URL?
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "MiddleShot.app" { found = url; break }
        }
        guard let app = found else { throw Failure.noApp }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

        try verify(app)
        let build = Int(Bundle(url: app)?.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
        guard build > currentBuild else { throw Failure.notNewer(build) }
        succeeded = true
        return (app, work)
    }

    /// The new bundle must satisfy the running app's own designated
    /// requirement: same identifier, same signing certificate.
    private static func verify(_ app: URL) throws {
        var me: SecCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyDesignatedRequirement(unsafeBitCast(me, to: SecStaticCode.self), [], &requirement) == errSecSuccess,
              let requirement else {
            throw Failure.untrusted("This copy's own signature couldn't be read.")
        }
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw Failure.untrusted("No signature.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(candidate, flags, requirement)
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw Failure.untrusted(message)
        }
    }

    /// Waits for us to exit, moves the old bundle aside, moves the new one in,
    /// opens it. Any failure restores the old bundle and opens that instead.
    private static func launchSwap(newApp: URL, target: URL, work: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        old="$1.old-$$"
        if /bin/mv "$1" "$old" && /bin/mv "$2" "$1"; then
            /bin/rm -rf "$old"
        else
            [ -d "$old" ] && [ ! -d "$1" ] && /bin/mv "$old" "$1"
        fi
        /bin/rm -rf "$3"
        /usr/bin/open "$1"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "sh", target.path, newApp.path, work.path]
        try task.run()
    }

    private static func run(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
