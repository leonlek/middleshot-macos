import Cocoa
import Darwin
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "dashboard")

enum MemoryPressure: Int {
    case normal, warning, critical
}

struct SystemLoad {
    /// Fractions of total CPU capacity (all cores) over the sample.
    let userFraction: Double
    let systemFraction: Double
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    let swapUsed: UInt64
    let pressure: MemoryPressure
}

/// One row in the process table: an app with everything it runs, or a single
/// process.
struct ProcessRow {
    enum Kind {
        case app
        /// Belongs to an app — inside its bundle, or spawned by it.
        case helper
        /// Lives in the OS (`/System`, `/usr`, …) and belongs to no app.
        case system
        case process
        /// MiddleShot itself.
        case current
        /// One editor window's background work (its extension host and what
        /// runs under it). Expandable.
        case window
        /// A Claude Code session with everything it started.
        case session
        /// Processes every window shares (the main process, renderers, GPU);
        /// shown for the numbers, never force quit piecemeal.
        case shared
    }

    let pid: pid_t
    let name: String
    let kind: Kind
    /// Percent of one core, like Activity Monitor — can exceed 100.
    var cpu: Double
    /// Physical footprint in bytes (Activity Monitor's "Memory" column).
    var memory: UInt64
    var processCount: Int
    /// For a helper: the app it belongs to.
    let owner: (pid: pid_t, name: String)?
    /// File whose Finder icon represents this row.
    let iconPath: String?
    /// When the process started (µs since 1970), 0 if unknown. PIDs get reused;
    /// this is what tells "still the same process" apart at Force Quit time.
    var startTime: UInt64 = 0
    /// Second line under the name, when the kind's default doesn't say enough.
    var detail: String?
    /// What the row expands into: an app's windows and sessions, a window's
    /// sessions and busiest processes.
    var children: [ProcessRow] = []
    /// For a group (window, session): every process Force Quit ends, parents
    /// before children, each with its start time. Empty for a single process.
    var targets: [(pid: pid_t, startTime: UInt64)] = []

    /// Why Force Quit is not offered, or nil when it is.
    var protectionReason: String? {
        switch kind {
        case .system: return "Part of macOS — force quitting it can freeze the Mac or log you out"
        case .current:
            return pid == getpid()
                ? "This is MiddleShot — use Quit MiddleShot in the menu bar instead"
                : "Started by MiddleShot — it ends when its task finishes"
        case .shared:
            return "Shared by every window — force quit \(owner?.name ?? "the app") itself to stop it"
        case .app, .helper, .process, .window, .session: return nil
        }
    }
}

struct ProcessSnapshot {
    var apps: [ProcessRow]
    var processes: [ProcessRow]
    /// Processes owned by root or other users. macOS won't report their CPU or
    /// memory to an unprivileged app, so they are left out rather than shown
    /// as zeros.
    let unmeasuredCount: Int
    let load: SystemLoad
    let takenAt: Date
}

/// Takes one CPU / memory snapshot: reads every process, waits a second, reads
/// again, and turns the difference into percentages.
final class ProcessSampler {
    static let sampleInterval: TimeInterval = 1

    private struct RawProcess {
        let pid: pid_t
        let parent: pid_t
        let path: String
        let name: String
        let cpuNanoseconds: UInt64
        let footprint: UInt64
        let startTime: UInt64
    }

    private static let systemPathPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]

    private let wakeUp = DispatchSemaphore(value: 0)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        cancelled.withLock { $0 = true }
        wakeUp.signal()
    }

    /// Samples on a background queue; `completion` arrives on main, with nil
    /// when cancelled.
    func sample(completion: @escaping (ProcessSnapshot?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let start = DispatchTime.now().uptimeNanoseconds
            let before = Self.readProcesses()
            let ticksBefore = SystemStats.cpuTicks()

            // The semaphore doubles as the interval: a cancel signals it and
            // ends the wait early.
            let interrupted = self.wakeUp.wait(timeout: .now() + Self.sampleInterval) == .success
            guard !interrupted else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let after = Self.readProcesses()
            let cpu = SystemStats.cpuTicks().load(since: ticksBefore)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
            let memory = SystemStats.memory()
            let load = SystemLoad(userFraction: cpu.user, systemFraction: cpu.system,
                                  memoryUsed: memory.used, memoryTotal: memory.total,
                                  swapUsed: memory.swapUsed, pressure: memory.pressure)

            DispatchQueue.main.async {
                guard !self.cancelled.withLock({ $0 }) else {
                    completion(nil)
                    return
                }
                completion(Self.snapshot(before: before.processes, after: after.processes,
                                         unmeasured: after.unmeasured, elapsed: elapsed, load: load))
            }
        }
    }

    // MARK: - Grouping (main thread — needs NSWorkspace)

    private static func snapshot(before: [pid_t: RawProcess], after: [pid_t: RawProcess],
                                 unmeasured: Int, elapsed: Double, load: SystemLoad) -> ProcessSnapshot {
        let myPID = getpid()
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
        let appsByPID = Dictionary(runningApps.map { ($0.processIdentifier, $0) },
                                   uniquingKeysWith: { first, _ in first })
        // Longest bundle path first, so an app nested inside another app's
        // bundle claims its own processes.
        let bundlePrefixes: [(prefix: String, pid: pid_t)] = runningApps
            .compactMap { app in
                app.bundleURL.map { ($0.resolvingSymlinksInPath().path + "/", app.processIdentifier) }
            }
            .sorted { $0.prefix.count > $1.prefix.count }

        func owningApp(of process: RawProcess) -> pid_t? {
            if appsByPID[process.pid] != nil { return process.pid }
            if let match = bundlePrefixes.first(where: { process.path.hasPrefix($0.prefix) }) {
                return match.pid
            }
            // Work spawned by an app (a build under Xcode, a language server
            // under an editor) counts toward that app.
            var cursor = process.parent
            for _ in 0..<64 where cursor > 1 {
                if appsByPID[cursor] != nil { return cursor }
                guard let parent = after[cursor] else { break }
                cursor = parent.parent
            }
            return nil
        }

        var appRows: [pid_t: ProcessRow] = [:]
        for app in runningApps {
            let pid = app.processIdentifier
            appRows[pid] = ProcessRow(pid: pid, name: app.localizedName ?? "App",
                                      kind: pid == myPID ? .current : .app,
                                      cpu: 0, memory: 0, processCount: 0, owner: nil,
                                      iconPath: app.bundleURL?.path)
        }

        var processRows: [ProcessRow] = []
        processRows.reserveCapacity(after.count)
        var ownerOf: [pid_t: pid_t] = [:]
        for process in after.values {
            var cpu = 0.0
            if let earlier = before[process.pid], process.cpuNanoseconds >= earlier.cpuNanoseconds {
                cpu = Double(process.cpuNanoseconds - earlier.cpuNanoseconds) / elapsed * 100
            }
            let ownerPID = owningApp(of: process)
            if let ownerPID {
                ownerOf[process.pid] = ownerPID
                appRows[ownerPID]?.cpu += cpu
                appRows[ownerPID]?.memory += process.footprint
                appRows[ownerPID]?.processCount += 1
            }

            let kind: ProcessRow.Kind
            // MiddleShot's own children (a simctl deletion it is running) are
            // as untouchable from here as MiddleShot itself.
            if process.pid == myPID || ownerPID == myPID {
                kind = .current
            } else if appsByPID[process.pid] != nil {
                kind = .app
            } else if ownerPID != nil {
                kind = .helper
            } else if systemPathPrefixes.contains(where: { process.path.hasPrefix($0) }) {
                kind = .system
            } else {
                kind = .process
            }
            let owner = ownerPID.flatMap { pid in appRows[pid].map { (pid: pid, name: $0.name) } }
            let isClaudeCode = isClaudeCodeSession(process)
            processRows.append(ProcessRow(
                pid: process.pid,
                name: kind == .app ? (appsByPID[process.pid]?.localizedName ?? process.name)
                    : isClaudeCode ? "Claude Code" : process.name,
                kind: kind, cpu: cpu, memory: process.footprint, processCount: 1,
                owner: kind == .helper ? owner : nil,
                iconPath: owner.flatMap { appRows[$0.pid]?.iconPath } ?? (process.path.isEmpty ? nil : process.path),
                startTime: process.startTime,
                detail: isClaudeCode ? workFolder(of: process.pid).map { "Claude Code session in \(($0 as NSString).lastPathComponent)" } : nil
            ))
            if appRows[process.pid] != nil {
                appRows[process.pid]?.startTime = process.startTime
            }
        }

        var childrenOf: [pid_t: [pid_t]] = [:]
        for process in after.values {
            childrenOf[process.parent, default: []].append(process.pid)
        }
        for (pid, row) in appRows where row.kind == .app && row.processCount > 1 {
            let members = processRows.filter { ownerOf[$0.pid] == pid }
            appRows[pid]?.children = breakdown(of: row, members: members, after: after, childrenOf: childrenOf)
        }

        return ProcessSnapshot(apps: appRows.values.filter { $0.processCount > 0 },
                               processes: processRows, unmeasuredCount: unmeasured,
                               load: load, takenAt: Date())
    }

    // MARK: - Windows and sessions

    /// What an app's row expands into.
    ///
    /// Editors built on VS Code (VS Code, Cursor, VSCodium, …) give every window
    /// its own extension host — a `… Helper (Plugin)` child of the main process
    /// — and Claude Code sessions, language servers and the like run under it.
    /// The host carries no window id, so a window is named after the folder its
    /// work runs in, and terminal programs whose working folder lies inside that
    /// folder join it. What's left (main process, renderers, GPU) is "shared".
    /// Apps without that shape simply list their busiest processes.
    private static func breakdown(of app: ProcessRow, members: [ProcessRow], after: [pid_t: RawProcess],
                                  childrenOf: [pid_t: [pid_t]]) -> [ProcessRow] {
        let rowsByPID = Dictionary(members.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let owner = (pid: app.pid, name: app.name)
        func subtree(_ root: pid_t) -> [pid_t] {
            var result = [root]
            var index = 0
            while index < result.count {
                result += (childrenOf[result[index]] ?? []).filter { rowsByPID[$0] != nil }
                index += 1
            }
            return result
        }
        func group(_ pids: [pid_t], pid: pid_t, name: String, kind: ProcessRow.Kind, detail: String,
                   children: [ProcessRow]) -> ProcessRow {
            let rows = pids.compactMap { rowsByPID[$0] }
            return ProcessRow(pid: pid, name: name, kind: kind, cpu: rows.reduce(0) { $0 + $1.cpu },
                              memory: rows.reduce(0) { $0 + $1.memory }, processCount: rows.count, owner: owner,
                              iconPath: app.iconPath, startTime: rowsByPID[pid]?.startTime ?? 0, detail: detail,
                              children: children, targets: rows.map { ($0.pid, $0.startTime) })
        }

        let hosts = members.filter { $0.name.hasSuffix("Helper (Plugin)") && after[$0.pid]?.parent == app.pid }
        var windows: [(folder: String, host: pid_t, pids: [pid_t])] = []
        var assigned = Set<pid_t>()
        for host in hosts {
            let pids = subtree(host.pid)
            let folders = pids.dropFirst().compactMap(workFolder(of:))
            guard let folder = Dictionary(grouping: folders, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key else {
                continue
            }
            windows.append((folder, host.pid, pids))
            assigned.formUnion(pids)
        }
        guard !windows.isEmpty else {
            return members.sorted { $0.cpu > $1.cpu }.prefix(12).map { row in
                var row = row
                if row.pid == app.pid { row.detail = "Main process" }
                return row
            }
        }

        // Terminal programs and dev servers started inside a window's folder.
        for member in members where !assigned.contains(member.pid) && member.pid != app.pid {
            guard let folder = workFolder(of: member.pid),
                  let index = windows.firstIndex(where: { folder == $0.folder || folder.hasPrefix($0.folder + "/") }) else {
                continue
            }
            let pids = subtree(member.pid).filter { !assigned.contains($0) }
            windows[index].pids += pids
            assigned.formUnion(pids)
        }

        var rows: [ProcessRow] = windows.map { window in
            let folderName = (window.folder as NSString).lastPathComponent
            var inSessions = Set<pid_t>()
            let sessions: [ProcessRow] = window.pids.compactMap { pid in
                guard let process = after[pid], isClaudeCodeSession(process) else { return nil }
                let pids = subtree(pid).filter { window.pids.contains($0) }
                inSessions.formUnion(pids)
                // Its own folder can differ from the window's (a session opened
                // on a neighbouring project).
                let sessionFolder = workFolder(of: pid).map { ($0 as NSString).lastPathComponent } ?? folderName
                return group(pids, pid: pid, name: "Claude Code", kind: .session,
                             detail: "Session in \(sessionFolder) · \(pids.count) process\(pids.count == 1 ? "" : "es")",
                             children: [])
            }
            let others = window.pids.filter { !inSessions.contains($0) }.compactMap { pid -> ProcessRow? in
                guard var row = rowsByPID[pid] else { return nil }
                if pid == window.host {
                    row.detail = "Extension host"
                }
                return row
            }
            let sessionCount = sessions.count
            let detail = "Window · \(window.pids.count) processes"
                + (sessionCount == 0 ? "" : " · \(sessionCount) Claude Code session\(sessionCount == 1 ? "" : "s")")
            return group(window.pids, pid: window.host, name: folderName, kind: .window, detail: detail,
                         children: sessions + others.sorted { $0.cpu > $1.cpu }.prefix(8))
        }

        let shared = members.map(\.pid).filter { !assigned.contains($0) }
        if !shared.isEmpty {
            let sharedRows = shared.compactMap { rowsByPID[$0] }.map { row -> ProcessRow in
                var row = row
                row = ProcessRow(pid: row.pid, name: row.name, kind: .shared, cpu: row.cpu, memory: row.memory,
                                 processCount: 1, owner: owner, iconPath: row.iconPath, startTime: row.startTime,
                                 detail: row.pid == app.pid ? "Main process" : "Shared")
                return row
            }
            rows.append(group(shared, pid: app.pid, name: "Shared by all windows", kind: .shared,
                              detail: "Main process, window renderers, GPU · \(shared.count) processes",
                              children: Array(sharedRows.sorted { $0.cpu > $1.cpu }.prefix(8))))
        }
        return rows
    }

    /// The Claude Code CLI: the native binary is named `claude`; an npm install
    /// runs from a `claude-code` package folder.
    private static func isClaudeCodeSession(_ process: RawProcess) -> Bool {
        process.name == "claude" || process.path.contains("/claude-code/")
    }

    /// The project folder a process works in, judged by its current directory —
    /// or nil when that says nothing about a project (/, the home folder,
    /// ~/Library, app bundles, system folders).
    private static func workFolder(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { buffer in
            String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !path.isEmpty, path != "/", path != home, !path.hasPrefix(home + "/Library"), !path.hasPrefix(home + "/."),
              !["/System", "/Applications", "/Library", "/private", "/usr", "/opt"].contains(where: { path.hasPrefix($0) }) else {
            return nil
        }
        return path
    }

    // MARK: - Kernel readings (any thread)

    private static func readProcesses() -> (processes: [pid_t: RawProcess], unmeasured: Int) {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return ([:], 0) }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let myUID = getuid()
        var processes: [pid_t: RawProcess] = [:]
        var unmeasured = 0
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var nameBuffer = [CChar](repeating: 0, count: 256)

        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            var info = proc_bsdshortinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, infoSize) == infoSize else {
                continue  // exited between the listing and now
            }
            guard info.pbsi_uid == myUID, let started = Self.startTime(of: pid) else {
                unmeasured += 1
                continue
            }
            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard status == 0 else {
                unmeasured += 1
                continue
            }

            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathLength > 0 ? String(cString: pathBuffer) : ""
            let name: String
            if !path.isEmpty {
                name = (path as NSString).lastPathComponent
            } else if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 {
                name = String(cString: nameBuffer)
            } else {
                name = "Process \(pid)"
            }
            // rusage times are Mach absolute-time units, not nanoseconds, on
            // Apple silicon (timebase 125/3).
            let ticks = usage.ri_user_time + usage.ri_system_time
            processes[pid] = RawProcess(
                pid: pid, parent: pid_t(info.pbsi_ppid), path: path, name: name,
                cpuNanoseconds: ticks * UInt64(timebase.numer) / UInt64(timebase.denom),
                footprint: usage.ri_phys_footprint,
                startTime: started
            )
        }
        return (processes, unmeasured)
    }

    // MARK: - Force quit

    /// Ends a window's or session's processes, children first so none gets a
    /// chance to respawn another. Each PID is checked against the start time it
    /// had in the snapshot; one that no longer matches is someone else now and
    /// is left alone.
    private static func forceQuitGroup(_ row: ProcessRow) -> Result<Void, Error> {
        guard let lead = row.targets.first, lead.startTime != 0, startTime(of: lead.pid) == lead.startTime else {
            return .failure(CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "“\(row.name)” has already quit, so nothing was force quit — press Refresh for a new snapshot.",
            ]))
        }
        for target in row.targets.reversed() where target.startTime != 0 && startTime(of: target.pid) == target.startTime {
            if kill(target.pid, SIGKILL) != 0 {
                os_log("SIGKILL %d failed: errno %d", log: log, type: .error, target.pid, errno)
            }
        }
        return .success(())
    }

    /// Apps go through NSRunningApplication so macOS treats it like the Force
    /// Quit window; anything else gets SIGKILL.
    /// A process's start time in microseconds, or nil once it has exited (or
    /// belongs to another user).
    static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    static func forceQuit(_ row: ProcessRow) -> Result<Void, Error> {
        precondition(row.protectionReason == nil, "Force quit offered for a protected row")
        if !row.targets.isEmpty {
            return forceQuitGroup(row)
        }
        // The snapshot can be minutes old. If the process has exited, its PID
        // may now belong to something else — never signal a stranger.
        guard row.startTime != 0, let current = startTime(of: row.pid) else {
            return .failure(CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "“\(row.name)” has already quit, so nothing was force quit.",
            ]))
        }
        guard current == row.startTime else {
            return .failure(CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "“\(row.name)” has already quit, and another process now has its ID. Nothing was force quit — press Refresh for a new snapshot.",
            ]))
        }
        if row.kind == .app, let app = NSRunningApplication(processIdentifier: row.pid) {
            guard app.forceTerminate() else {
                return .failure(CocoaError(.featureUnsupported, userInfo: [
                    NSLocalizedDescriptionKey: "macOS refused to force quit “\(row.name)”.",
                ]))
            }
            return .success(())
        }
        guard kill(row.pid, SIGKILL) == 0 else {
            return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM))
        }
        return .success(())
    }
}
