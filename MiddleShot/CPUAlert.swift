import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "dashboard")

/// An app (or a stray process) that has been busy long enough to mention.
struct CPUHog: Equatable {
    /// Identifies the streak: an app's bundle id, or one process.
    let key: String
    /// What "Ignore" remembers: the bundle id, or the executable name.
    let ignoreKey: String
    let name: String
    let pid: pid_t
    let startTime: UInt64
    let isApp: Bool
    let iconPath: String?
    /// Percent of one core over the last check.
    let cpu: Double
    /// When it crossed the threshold (system uptime).
    let since: TimeInterval
    /// The process doing most of the work, when that isn't the app itself.
    let busiestProcess: String?
    /// Other apps over the threshold at the same time.
    let othersOverThreshold: Int
}

/// Watches every app's CPU in the background and reports the busiest one that
/// has stayed above the threshold for a minute.
///
/// A sustained minute is the point: builds, page loads and launches spike for
/// seconds all the time; a runaway keeps going. Checks run every five seconds
/// on the per-process CPU time since the previous check, so no one-second
/// sampling pause is needed.
final class CPUAlertMonitor {
    static let checkInterval: TimeInterval = 5
    static let sustainedFor: TimeInterval = 60

    /// The hog to show, or nil when nothing (still) qualifies. Main thread.
    var onChange: ((CPUHog?) -> Void)?
    private(set) var current: CPUHog?

    private var timer: Timer?
    private var isReading = false
    private var previous: (readings: [pid_t: ProcessSampler.ProcessReading], time: TimeInterval)?
    private var overSince: [String: TimeInterval] = [:]
    /// Streaks the person closed; forgotten once that app calms down.
    private var dismissed: Set<String> = []

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previous = nil
        overSince.removeAll()
        publish(nil)
    }

    /// ✕: don't bring this streak up again until the app has calmed down.
    func dismissCurrent() {
        if let current { dismissed.insert(current.key) }
        publish(nil)
    }

    /// After Ignore or Force Quit: drop the streak and look again at once.
    func forget(_ hog: CPUHog) {
        overSince[hog.key] = nil
        publish(nil)
    }

    private func check() {
        guard !isReading else { return }
        isReading = true
        DispatchQueue.global(qos: .utility).async {
            let readings = ProcessSampler.readProcesses().processes
            let now = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isReading = false
                guard self.timer != nil else { return }
                self.evaluate(readings, at: now)
            }
        }
    }

    // MARK: - Evaluation (main thread — needs NSWorkspace)

    private struct Group {
        var key: String
        var ignoreKey: String
        var name: String
        var pid: pid_t
        var startTime: UInt64
        var isApp: Bool
        var iconPath: String?
        var cpu = 0.0
        var busiest: (name: String, cpu: Double)?
    }

    private func evaluate(_ readings: [pid_t: ProcessSampler.ProcessReading], at now: TimeInterval) {
        defer { previous = (readings, now) }
        guard let previous, now > previous.time else { return }
        let elapsed = (now - previous.time) * 1_000_000_000

        let myPID = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        // Only a process inside an app's bundle counts toward that app. A node
        // server started from Terminal is its own row — blaming Terminal would
        // make "Force Quit" close every shell.
        let bundles = apps.compactMap { app in app.bundleURL.map { ($0.resolvingSymlinksInPath().path + "/", app) } }
            .sorted { $0.0.count > $1.0.count }

        var groups: [String: Group] = [:]
        for reading in readings.values where reading.pid != myPID {
            guard let before = previous.readings[reading.pid], before.startTime == reading.startTime,
                  reading.cpuNanoseconds >= before.cpuNanoseconds else { continue }
            let cpu = Double(reading.cpuNanoseconds - before.cpuNanoseconds) / elapsed * 100
            guard cpu > 1 else { continue }

            let app = apps.first { $0.processIdentifier == reading.pid }
                ?? bundles.first { reading.path.hasPrefix($0.0) }?.1
            var group: Group
            if let app, app.processIdentifier != myPID {
                let key = "app:" + (app.bundleIdentifier ?? app.bundleURL?.path ?? "\(app.processIdentifier)")
                group = groups[key] ?? Group(key: key, ignoreKey: app.bundleIdentifier ?? app.localizedName ?? key,
                                             name: app.localizedName ?? "App", pid: app.processIdentifier,
                                             startTime: readings[app.processIdentifier]?.startTime ?? 0,
                                             isApp: true, iconPath: app.bundleURL?.path)
            } else if app == nil, !ProcessSampler.systemPathPrefixes.contains(where: { reading.path.hasPrefix($0) }) {
                let key = "process:\(reading.pid):\(reading.startTime)"
                group = groups[key] ?? Group(key: key, ignoreKey: reading.name, name: reading.name, pid: reading.pid,
                                             startTime: reading.startTime, isApp: false,
                                             iconPath: reading.path.isEmpty ? nil : reading.path)
            } else {
                continue
            }
            group.cpu += cpu
            if reading.pid != group.pid, cpu > (group.busiest?.cpu ?? 0) {
                group.busiest = (reading.name, cpu)
            }
            groups[group.key] = group
        }

        let threshold = Settings.cpuAlertThreshold
        let ignored = Set(Settings.cpuAlertIgnored)
        for key in Set(overSince.keys).union(groups.keys) {
            if (groups[key]?.cpu ?? 0) >= threshold {
                overSince[key] = overSince[key] ?? now
            } else {
                overSince[key] = nil
                dismissed.remove(key)
            }
        }

        let qualifying = groups.values.filter { group in
            guard let since = overSince[group.key] else { return false }
            return now - since >= Self.sustainedFor && !dismissed.contains(group.key) && !ignored.contains(group.ignoreKey)
        }.sorted { $0.cpu > $1.cpu }

        guard let top = qualifying.first, let since = overSince[top.key] else {
            publish(nil)
            return
        }
        // Name the busy helper only when it carries most of the load.
        let busiest = top.busiest.flatMap { $0.cpu >= top.cpu * 0.5 ? $0.name : nil }
        publish(CPUHog(key: top.key, ignoreKey: top.ignoreKey, name: top.name, pid: top.pid, startTime: top.startTime,
                       isApp: top.isApp, iconPath: top.iconPath, cpu: top.cpu, since: since,
                       busiestProcess: busiest, othersOverThreshold: qualifying.count - 1))
    }

    private func publish(_ hog: CPUHog?) {
        if hog?.key != current?.key {
            os_log("CPU alert: %{public}@", log: log, type: .info, hog.map { "\($0.name) \(Int($0.cpu))%" } ?? "cleared")
        }
        current = hog
        onChange?(hog)
    }
}

/// The bubble under the menu bar's CPU graph.
final class CPUAlertViewController: NSViewController {
    var onClose: (() -> Void)?
    var onIgnore: (() -> Void)?
    var onForceQuit: (() -> Void)?

    private let iconView = NSImageView()
    private let nameLabel = DashboardStyle.label("", weight: .semibold)
    private let usageLabel = DashboardStyle.label("", size: 12, color: .secondaryLabelColor)
    private let detailLabel = DashboardStyle.label("", size: 11.5, color: .tertiaryLabelColor)
    private let ignoreButton = FirstClickButton(title: "Ignore", target: nil, action: nil)
    private let quitButton = FirstClickButton(title: "Force Quit…", target: nil, action: nil)

    override func loadView() {
        let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                 accessibilityDescription: "Warning") ?? NSImage())
        warning.contentTintColor = .systemOrange
        warning.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 18).isActive = true
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let close = FirstClickButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage(),
                                     target: self, action: #selector(closePressed))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Close — it won't come back until this app calms down"
        let header = NSStackView(views: [warning, iconView, nameLabel, NSView(), close])
        header.spacing = 6

        detailLabel.lineBreakMode = .byTruncatingTail
        ignoreButton.target = self
        ignoreButton.action = #selector(ignorePressed)
        ignoreButton.controlSize = .small
        quitButton.target = self
        quitButton.action = #selector(forceQuitPressed)
        quitButton.controlSize = .small
        quitButton.attributedTitle = NSAttributedString(string: "Force Quit…", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemRed,
        ])
        let buttons = NSStackView(views: [NSView(), ignoreButton, quitButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [header, usageLabel, detailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(10, after: detailLabel)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 10)
        for view in [header, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -22).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 280).isActive = true
        view = stack
    }

    func show(_ hog: CPUHog) {
        _ = view
        iconView.image = hog.iconPath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .unixExecutable)
        nameLabel.stringValue = hog.name
        let minutes = max(1, Int((ProcessInfo.processInfo.systemUptime - hog.since) / 60))
        usageLabel.stringValue = String(format: "%.0f%% CPU for %d minute%@", hog.cpu, minutes, minutes == 1 ? "" : "s")
        var details: [String] = []
        if let busiest = hog.busiestProcess { details.append("Mostly \(busiest)") }
        if hog.othersOverThreshold > 0 {
            details.append("\(hog.othersOverThreshold) more app\(hog.othersOverThreshold == 1 ? "" : "s") also busy")
        }
        detailLabel.stringValue = details.joined(separator: " · ")
        detailLabel.isHidden = details.isEmpty
        ignoreButton.title = "Ignore \(hog.name)"
    }

    @objc private func closePressed() { onClose?() }
    @objc private func ignorePressed() { onIgnore?() }
    @objc private func forceQuitPressed() { onForceQuit?() }
}

/// The bubble appears while you work in another app; a first click should
/// press the button, not just bring MiddleShot forward.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
