import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "dashboard")

/// One thing in the Safe to Clean list.
struct CleanupItem {
    enum Action {
        /// Every URL goes to the Trash together (an Android emulator is a
        /// folder plus its .ini).
        case trash([URL])
        /// `simctl delete` — CoreSimulator keeps its own device registry, so
        /// the folder can't just be moved away.
        case deleteSimulator(udid: String)
        /// `simctl runtime delete` — runtimes live in system-owned storage.
        case deleteRuntime(identifier: String)
        /// Safe to remove, but not by MiddleShot: root-owned or locked by SIP.
        /// The row explains how instead of offering a button that would fail.
        case manual(ManualRemoval)
    }

    struct ManualRemoval {
        let location: URL
        /// What to do, in Thai like the group guides.
        let steps: String
        /// A Terminal command to copy, when one works (`sudo rm` can't touch
        /// anything SIP protects, so those get none).
        let command: String?
    }

    let id: String
    let title: String
    let detail: String
    let size: Int64
    let action: Action
    /// Why this is worth removing now, or nil when it's merely safe.
    let recommendation: String?
    /// Why no button is offered (a simulator that is running).
    let blockedReason: String?
    /// File whose Finder icon represents the item; `symbol` is used otherwise.
    let iconPath: String?
    let symbol: String

    var revealURL: URL? {
        switch action {
        case .trash(let urls): return urls.first
        case .manual(let removal): return removal.location
        default: return nil
        }
    }

    /// Simulator and runtime deletions skip the Trash.
    var isPermanent: Bool {
        if case .trash = action { return false }
        return true
    }

    var manualRemoval: ManualRemoval? {
        if case .manual(let removal) = action { return removal }
        return nil
    }
}

struct CleanupGroup {
    enum Kind: String, CaseIterable {
        case runtimes, simulators, derivedData, deviceSupport, xcodeCaches
        case projectBuilds, packageCaches, appCaches, androidEmulators, logs
        case installers, needsAdmin, editorExtensions
    }

    let kind: Kind
    var items: [CleanupItem]

    var size: Int64 { items.reduce(0) { $0 + $1.size } }
    var cleanableItems: [CleanupItem] { items.filter { $0.blockedReason == nil && $0.manualRemoval == nil } }
    /// What MiddleShot itself can free — leaves out the rows it can only explain.
    var removableSize: Int64 { items.filter { $0.manualRemoval == nil }.reduce(0) { $0 + $1.size } }
    var recommendedItems: [CleanupItem] { cleanableItems.filter { $0.recommendation != nil } }

    var title: String {
        switch kind {
        case .runtimes: return "Simulator Runtimes"
        case .simulators: return "Simulators"
        case .derivedData: return "Xcode Build Data"
        case .deviceSupport: return "Device Support Files"
        case .xcodeCaches: return "Xcode & Simulator Caches"
        case .projectBuilds: return "Project Dependencies & Build Output"
        case .packageCaches: return "Package Manager Caches"
        case .appCaches: return "App Caches"
        case .androidEmulators: return "Android Emulators"
        case .logs: return "Logs"
        case .installers: return "macOS Installers"
        case .editorExtensions: return "Old Editor Extensions"
        case .needsAdmin: return "Needs Xcode or Terminal"
        }
    }

    var explanation: String {
        switch kind {
        case .runtimes: return "Whole OS versions for the Simulator. Xcode › Settings › Components downloads them again."
        case .simulators: return "Each simulator with its apps and data. Xcode creates new ones on demand."
        case .derivedData: return "DerivedData — intermediate build files per project. Rebuilt on the next build."
        case .deviceSupport: return "Debug symbols copied from devices you connected. Copied again on the next connection."
        case .xcodeCaches: return "SwiftUI preview simulators and shared Simulator caches. Recreated when needed."
        case .projectBuilds: return "node_modules, Pods, build folders and the like in your projects. Reinstall or rebuild to restore."
        case .packageCaches: return "Downloads kept by Gradle, npm, Homebrew, CocoaPods and others. Downloaded again when needed."
        case .appCaches: return "Files apps keep to load faster. Apps rebuild them."
        case .androidEmulators: return "Virtual devices with their data. Recreate them in Android Studio › Device Manager."
        case .logs: return "Log files apps have written. Nothing needs them to keep working."
        case .installers: return "Full macOS installers left in Applications. The App Store downloads them again."
        case .editorExtensions: return "Extension versions VS Code-family editors replaced but never removed."
        case .needsAdmin: return "Safe to remove, but macOS won't let MiddleShot do it. Each row says how."
        }
    }

    /// The longer story behind the ⓘ on a group's row: what it is, what
    /// deleting it costs, and when it's worth deleting. In Thai, at the
    /// user's request (2026-09-25) — the rest of the UI stays English.
    var guide: (what: String, cost: String, when: String) {
        switch kind {
        case .runtimes:
            return ("ระบบ iOS (หรือ watchOS, tvOS, visionOS) ทั้งชุดที่ Simulator ใช้รัน ตกเวอร์ชันละประมาณ 8–10 GB และ Xcode เก็บไว้ทุกเวอร์ชันที่เคยดาวน์โหลด",
                    "Simulator ทุกเครื่องที่ใช้เวอร์ชันนั้นจะเปิดไม่ได้ จนกว่าจะดาวน์โหลดใหม่ใน Xcode › Settings › Components ซึ่งมีขนาดหลาย GB และจะลบถาวร ไม่ได้ย้ายไปถังขยะ",
                    "เวอร์ชันที่ไม่ได้ใช้ทดสอบแล้ว ส่วนใหญ่เป็นเวอร์ชันเก่าหลังอัปเดต Xcode ให้เก็บเวอร์ชันที่ Simulator ใช้อยู่ไว้")
        case .simulators:
            return ("เครื่องจำลองแต่ละเครื่อง (iPhone, iPad, Watch…) พร้อมทุกอย่างที่อยู่ข้างใน ทั้งแอปที่ลงไว้ทดสอบ ข้อมูลของแอป การตั้งค่า และรูปภาพ",
                    "เครื่องและข้อมูลทั้งหมดในนั้นจะหายถาวร ไม่ได้ย้ายไปถังขยะ ถ้าเลือกรุ่นนั้นอีก Xcode จะสร้างเครื่องใหม่ให้ แต่ข้อมูลทดสอบที่เคยตั้งไว้จะหายไป",
                    "เครื่องที่ไม่ได้เปิดมาหลายเดือน หรือเครื่องที่ค้างมาจาก Xcode รุ่นเก่า รายการที่ขึ้น Recommended คือเครื่องที่ไม่ได้ใช้มานานแล้ว")
        case .derivedData:
            return ("ไฟล์ระหว่างการ build ของ Xcode ได้แก่โค้ดที่ compile แล้ว index และ preview แยกโฟลเดอร์ตามทุกโปรเจกต์ที่เคย build",
                    "ไม่เสียอะไร แค่ build ครั้งถัดไปของโปรเจกต์นั้นจะเริ่มจากศูนย์ จึงช้ากว่าปกติหนึ่งครั้ง และต้องทำ index ใหม่",
                    "ลบได้ทุกเมื่อ เป็นรายการใหญ่ที่ลบได้ปลอดภัยที่สุด โฟลเดอร์ของโปรเจกต์ที่ไม่ได้เปิดแล้วเสียพื้นที่เปล่าๆ และการลบยังช่วยแก้ error แปลกๆ ตอน build ได้หลายอย่าง")
        case .deviceSupport:
            return ("debug symbols ที่ Xcode คัดลอกมาจาก iPhone หรือ iPad ตอนรันแอปบนเครื่องนั้นครั้งแรก แยกโฟลเดอร์ตามรุ่นเครื่องและเวอร์ชัน iOS แต่ละโฟลเดอร์มักมีขนาดหลาย GB",
                    "ครั้งหน้าที่เสียบเครื่องนั้น Xcode จะคัดลอกใหม่ ต้องรอขึ้น “Copying shared cache symbols” อยู่หลายนาทีกว่าจะ debug ได้",
                    "โฟลเดอร์ของ iOS เวอร์ชันที่เครื่องไม่ได้ใช้แล้ว เพราะทุกครั้งที่อัปเดต iOS จะมีโฟลเดอร์ใหม่เพิ่มมา และโฟลเดอร์เก่าจะค้างอยู่ ให้เก็บโฟลเดอร์ของเครื่องที่กำลัง debug อยู่ไว้")
        case .xcodeCaches:
            return ("ข้อมูลชั่วคราวของ SwiftUI preview และ cache ที่ Simulator ใช้ร่วมกันทุกเครื่อง",
                    "Preview และ Simulator จะสร้างใหม่เอง แค่ preview หรือการเปิดครั้งแรกหลังลบจะช้ากว่าปกติ ควรปิด Xcode และ Simulator ก่อนลบ",
                    "เมื่อ preview มีปัญหา หรือเมื่อต้องการพื้นที่ ในนี้ไม่มีไฟล์ของคุณเก็บอยู่")
        case .projectBuilds:
            return ("dependency และผลการ build ที่อยู่ในโปรเจกต์ เช่น node_modules, Pods, build, .build, .gradle… จะนับเฉพาะเมื่อมีไฟล์ที่ใช้สร้างขึ้นมาใหม่ได้ (package.json, Podfile, build.gradle…) อยู่ข้างๆ สำหรับโปรเจกต์ React Native หรือ Expo ใน node_modules ยังมีผลการ build Android ของ native module อยู่ด้วย จึงใหญ่ได้ถึง 10 GB ขึ้นไป",
                    "โปรเจกต์จะ build หรือรันไม่ได้ จนกว่าจะติดตั้งใหม่ (npm install, pnpm install, pod install) หรือ build ใหม่ แต่โค้ดที่คุณเขียนไม่ถูกแตะเลย",
                    "โปรเจกต์ที่ไม่ได้ทำอยู่ตอนนี้ เมื่อกลับมาทำค่อยติดตั้งใหม่ ใช้เวลาไม่กี่นาที รายการที่ขึ้น Recommended คือโปรเจกต์ที่ไม่ได้แตะมานานแล้ว")
        case .packageCaches:
            return ("ไฟล์ที่ package manager ดาวน์โหลดเก็บไว้เพื่อไม่ต้องโหลดของเดิมซ้ำ เช่น Gradle, npm, pnpm, Homebrew, CocoaPods และอื่นๆ",
                    "ไม่มีอะไรเสีย แค่การติดตั้งหรือ build ครั้งถัดไปจะดาวน์โหลดสิ่งที่ต้องใช้ใหม่ เสียเวลาและเน็ตเพิ่ม",
                    "เมื่อต้องการพื้นที่ โดยเฉพาะ cache ของ Gradle และ Homebrew ที่สะสมเพิ่มไปเรื่อยๆ เป็นปี แต่ถ้าเน็ตช้าหรือจำกัดปริมาณ ควรเก็บไว้")
        case .appCaches:
            return ("ไฟล์ที่แอปเก็บไว้เพื่อให้เปิดและโหลดเร็วขึ้น เช่นรูปย่อและข้อมูลเว็บที่ดาวน์โหลดไว้ เอกสารและการตั้งค่าของคุณไม่ได้อยู่ในนี้",
                    "แอปจะสร้าง cache ใหม่ การเปิดครั้งแรกหลังลบจึงอาจช้ากว่าปกติ ควรปิดแอปก่อนลบ",
                    "แอปที่มี cache ใหญ่ผิดปกติ หรือแอปที่แทบไม่ได้ใช้")
        case .androidEmulators:
            return ("เครื่อง Android จำลองจาก Android Studio แต่ละเครื่องมีข้อมูลระบบ แอปที่ติดตั้ง และการตั้งค่าของตัวเอง",
                    "เครื่องจำลองและข้อมูลทั้งหมดในนั้นจะหายไป ถ้าต้องการใช้อีก สร้างใหม่ได้ใน Android Studio › Device Manager",
                    "เครื่องจำลองที่ไม่ได้เปิดใช้แล้ว")
        case .installers:
            return ("ตัวติดตั้ง macOS ทั้งชุด (Install macOS ….app) ที่ค้างอยู่ใน Applications ขนาดตัวละ 12–15 GB หลังอัปเดตเสร็จแล้วไม่ได้ใช้อีก",
                    "ไม่มีอะไรเสีย ถ้าต้องการติดตั้งใหม่หรือทำ USB ติดตั้ง ดาวน์โหลดใหม่ได้จาก App Store",
                    "ลบได้ทุกเมื่อ ยกเว้นกำลังจะใช้ทำ USB ติดตั้งหรือติดตั้งเครื่องอื่น")
        case .editorExtensions:
            return ("extension เวอร์ชันเก่าของ VS Code (รวมถึง Cursor, Windsurf, VS Code Insiders) ที่ถูกแทนที่ด้วยเวอร์ชันใหม่แล้ว ตัวแก้โค้ดบันทึกไว้ในไฟล์ .obsolete ว่ารอลบ แต่จะลบจริงตอนเปิดโปรแกรมใหม่เท่านั้น ถ้าเปิดค้างไว้นานจะสะสมเรื่อยๆ เช่น ChatGPT extension ที่อัปเดตวันละหลายรอบ ตัวละเกือบ 1 GB",
                    "ไม่มีอะไรเสีย extension ที่ใช้อยู่ไม่ถูกแตะ ลบเฉพาะโฟลเดอร์ที่ตัวแก้โค้ดเองบอกว่าเลิกใช้แล้ว",
                    "ต้องปิดตัวแก้โค้ดก่อน (⌘Q) เพราะหน้าต่างที่เปิดค้างอาจยังใช้เวอร์ชันเก่าอยู่ หรือแค่ปิดแล้วเปิดใหม่ โปรแกรมจะลบให้เองก็ได้")
        case .needsAdmin:
            return ("ไฟล์ที่ลบได้ปลอดภัย แต่ macOS ไม่ให้ MiddleShot ลบเอง เพราะเป็นของ root หรือถูกล็อกด้วย SIP (System Integrity Protection) เช่น Simulator Runtime ที่ Xcode ไม่ใช้แล้วแต่ไฟล์ยังค้าง",
                    "แล้วแต่รายการ กด How to Remove… ในแต่ละแถวเพื่อดูวิธี บางอันลบด้วยคำสั่ง sudo ใน Terminal ได้ บางอันต้องลบผ่าน Xcode",
                    "เมื่อต้องการพื้นที่คืน ไฟล์พวกนี้ไม่มีอะไรใช้แล้ว แค่ macOS ไม่ลบให้เอง")
        case .logs:
            return ("ไฟล์ log ที่แอปและเครื่องมือต่างๆ เขียนสะสมไว้",
                    "ไม่มีอะไรหยุดทำงาน แอปจะเริ่มเขียน log ใหม่ สิ่งที่หายไปคือประวัติเก่า ซึ่งจำเป็นเฉพาะตอนต้องไล่หาสาเหตุปัญหาเก่า",
                    "ลบได้ทุกเมื่อ")
        }
    }

    /// What removing items from this group costs — said in the confirmation.
    var consequence: String {
        switch kind {
        case .runtimes: return "Simulators that use a deleted runtime stop working until you download it again in Xcode › Settings › Components."
        case .simulators: return "Each simulator is deleted with every app and file on it. Xcode can create a new one any time."
        case .derivedData: return "Xcode rebuilds this data the next time you build, so that first build is slower."
        case .deviceSupport: return "Xcode copies these symbols again the next time the device connects."
        case .xcodeCaches: return "Quit Xcode and Simulator first — they recreate these caches when needed."
        case .projectBuilds: return "Reinstall dependencies or rebuild the project to bring these back."
        case .packageCaches: return "Package managers download these again the next time a project needs them."
        case .appCaches: return "Quit the app first. It rebuilds its cache and may be slower the first time it opens."
        case .androidEmulators: return "Each emulator is deleted with its apps and data. Recreate it in Android Studio › Device Manager."
        case .logs: return "Apps start new logs as needed."
        case .installers: return "Download the installer again from the App Store if you need it."
        case .editorExtensions: return "Only versions the editor itself marked as replaced — the ones in use stay."
        case .needsAdmin: return "MiddleShot doesn't remove these — follow the steps on each row."
        case .editorExtensions: return "The extensions you have installed now aren't touched."
        }
    }

    var symbol: String {
        switch kind {
        case .runtimes: return "shippingbox"
        case .simulators: return "iphone"
        case .derivedData: return "hammer"
        case .deviceSupport: return "cable.connector"
        case .xcodeCaches: return "square.stack.3d.up"
        case .projectBuilds: return "folder.badge.gearshape"
        case .packageCaches: return "arrow.down.circle"
        case .appCaches: return "internaldrive"
        case .androidEmulators: return "iphone.gen1"
        case .logs: return "doc.text"
        case .installers: return "arrow.down.app"
        case .editorExtensions: return "puzzlepiece.extension"
        case .needsAdmin: return "lock.shield"
        }
    }
}

/// What the scan measured, in the shape the finder asks about. Built by
/// DiskScanner from its tree for exactly the folders listed in
/// `CleanupFinder.watchedFolders`.
struct MeasuredFolders {
    /// Size by absolute path.
    let sizes: [String: Int64]
    /// Measured direct children (folders, and files of 50 MB or more) by the
    /// parent's absolute path.
    let children: [String: [(url: URL, size: Int64)]]
    /// Folders named like build output or dependencies, anywhere in the scan.
    let projectFolders: [(url: URL, size: Int64)]
}

/// Turns a finished scan into the Safe to Clean groups.
///
/// Only locations whose contents a tool recreates on its own are listed.
/// Everything else — documents, app data, archives with dSYMs — stays in the
/// Largest Items view, where the person decides.
enum CleanupFinder {
    private static let minimumSize: Int64 = 1 << 20
    private static let minimumListedCacheSize: Int64 = 10 << 20

    private static let packageCaches: [(path: String, title: String)] = [
        (".gradle/caches", "Gradle caches"),
        (".gradle/wrapper/dists", "Gradle distributions"),
        (".gradle/daemon", "Gradle daemon logs"),
        (".npm/_cacache", "npm cache"),
        ("Library/Caches/Yarn", "Yarn cache"),
        ("Library/pnpm/store", "pnpm store"),
        ("Library/Caches/Homebrew", "Homebrew downloads"),
        ("Library/Caches/CocoaPods", "CocoaPods cache"),
        (".cocoapods/repos", "CocoaPods spec repos"),
        ("Library/Caches/pip", "pip cache"),
        (".cargo/registry", "Cargo registry"),
        (".bun/install/cache", "Bun cache"),
        ("Library/Caches/ms-playwright", "Playwright browsers"),
        (".android/cache", "Android SDK cache"),
    ]

    private static let xcodeCaches: [(path: String, title: String)] = [
        ("Library/Developer/Xcode/UserData/Previews", "SwiftUI preview simulators"),
        ("Library/Developer/CoreSimulator/Caches", "Simulator caches"),
        ("Library/Caches/com.apple.dt.Xcode", "Xcode cache"),
        ("Library/Developer/Xcode/DocumentationCache", "Documentation cache"),
    ]

    private static let derivedData = "Library/Developer/Xcode/DerivedData"
    private static let simulatorDevices = "Library/Developer/CoreSimulator/Devices"
    private static let deviceSupport = ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport",
                                        "visionOS DeviceSupport"].map { "Library/Developer/Xcode/" + $0 }
    private static let caches = "Library/Caches"
    private static let logs = "Library/Logs"
    private static let androidAVDs = ".android/avd"

    /// Folders (relative to home) whose size or children the scan must report.
    static let watchedFolders: [String] = [derivedData, simulatorDevices, caches, logs, androidAVDs]
        + deviceSupport + packageCaches.map(\.path) + xcodeCaches.map(\.path)

    /// A folder with this name counts as removable project output only when
    /// one of the marker files sits next to it — proof it belongs to a project.
    static let projectFolderMarkers: [String: [String]] = [
        "node_modules": ["package.json"],
        "Pods": ["Podfile"],
        ".build": ["Package.swift"],
        "build": ["build.gradle", "build.gradle.kts", "pubspec.yaml"],
        ".next": ["package.json"],
        "target": ["Cargo.toml"],
        ".dart_tool": ["pubspec.yaml"],
        ".gradle": ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"],
    ]

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    static func groups(from measured: MeasuredFolders, simulators: SimulatorInventory?) -> [CleanupGroup] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }
        func children(_ relative: String) -> [(url: URL, size: Int64)] {
            (measured.children[url(relative).path] ?? []).filter { $0.size >= minimumSize }
        }

        var groups: [CleanupGroup] = []
        func add(_ kind: CleanupGroup.Kind, _ items: [CleanupItem]) {
            guard !items.isEmpty else { return }
            groups.append(CleanupGroup(kind: kind, items: items.sorted { $0.size > $1.size }))
        }

        if let simulators {
            add(.runtimes, runtimeItems(simulators))
            add(.simulators, simulatorItems(children(simulatorDevices), simulators))
        }
        add(.derivedData, children(derivedData).map(derivedDataItem))
        add(.deviceSupport, deviceSupport.flatMap { folder in
            children(folder).map { child in
                let platform = folder.components(separatedBy: "/").last?.replacingOccurrences(of: " DeviceSupport", with: "") ?? ""
                let age = modificationAge(of: child.url)
                return trashItem(child, title: child.url.lastPathComponent,
                                 detail: [platform, age.map { "added \($0.text)" }].compactMap { $0 }.joined(separator: " · "),
                                 recommendation: age.flatMap { $0.days >= 90 ? "Not used in \($0.days) days" : nil },
                                 symbol: "cable.connector")
            }
        })
        add(.xcodeCaches, xcodeCaches.compactMap { entry in
            measured.sizes[url(entry.path).path].flatMap { size in
                size >= minimumListedCacheSize
                    ? trashItem((url(entry.path), size), title: entry.title,
                                detail: (url(entry.path).path as NSString).abbreviatingWithTildeInPath,
                                recommendation: nil, symbol: "square.stack.3d.up")
                    : nil
            }
        } + (simulators.map { deadAppCopyItems($0, home: home) } ?? []))
        add(.projectBuilds, projectItems(measured.projectFolders, home: home))
        add(.packageCaches, packageCaches.compactMap { entry in
            measured.sizes[url(entry.path).path].flatMap { size in
                size >= minimumSize
                    ? trashItem((url(entry.path), size), title: entry.title,
                                detail: (url(entry.path).path as NSString).abbreviatingWithTildeInPath,
                                recommendation: nil, symbol: "arrow.down.circle")
                    : nil
            }
        })
        let claimedCaches = Set((packageCaches + xcodeCaches).map { url($0.path).path })
        add(.appCaches, children(caches)
            .filter { $0.size >= minimumListedCacheSize && !claimedCaches.contains($0.url.path) && !isSystemCache($0.url) }
            .map(appCacheItem))
        add(.androidEmulators, children(androidAVDs).filter { $0.url.pathExtension == "avd" }.map { avd in
            let name = avd.url.deletingPathExtension().lastPathComponent
            let ini = avd.url.deletingPathExtension().appendingPathExtension("ini")
            let age = modificationAge(of: avd.url)
            return CleanupItem(
                id: avd.url.path, title: name.replacingOccurrences(of: "_", with: " "),
                detail: age.map { "Last changed \($0.text)" } ?? "Android Virtual Device",
                size: avd.size,
                action: .trash(FileManager.default.fileExists(atPath: ini.path) ? [avd.url, ini] : [avd.url]),
                recommendation: age.flatMap { $0.days >= 60 ? "Not used in \($0.days) days" : nil },
                blockedReason: nil, iconPath: nil, symbol: "iphone.gen1")
        })
        add(.logs, children(logs)
            .filter { $0.size >= minimumListedCacheSize && $0.url.lastPathComponent != "DiagnosticReports" }
            .map { trashItem($0, title: $0.url.lastPathComponent,
                             detail: ($0.url.path as NSString).abbreviatingWithTildeInPath,
                             recommendation: nil, symbol: "doc.text") })

        add(.installers, installerItems())
        add(.editorExtensions, editorExtensionItems(home: home))
        add(.needsAdmin, (simulators.map(orphanedRuntimeItems) ?? []))

        return groups.sorted { $0.size > $1.size }
    }

    // MARK: - Leftovers inside simulators and editors

    /// Old app bundles a simulator's containermanagerd moved aside to delete
    /// and never did: every reinstall (each `xcodebuild test`) adds one to
    /// data/Library/Caches/com.apple.containermanagerd/Dead. Seen at 266
    /// copies, 28.7 GB, in one test simulator (2026-10-22). Clearing it costs
    /// nothing — the installed app and its data live elsewhere.
    private static func deadAppCopyItems(_ inventory: SimulatorInventory, home: URL) -> [CleanupItem] {
        inventory.devices.compactMap { udid, device -> CleanupItem? in
            let dead = home.appendingPathComponent(simulatorDevices).appendingPathComponent(udid)
                .appendingPathComponent("data/Library/Caches/com.apple.containermanagerd/Dead")
            let copies = ((try? FileManager.default.contentsOfDirectory(atPath: dead.path)) ?? [])
                .filter { $0.hasPrefix("temp.") }
            guard !copies.isEmpty else { return nil }
            let size = allocatedSize(of: dead)
            guard size >= minimumSize else { return nil }
            return CleanupItem(
                id: dead.path, title: "Leftover app copies · \(device.name)",
                detail: "\(copies.count) old installs the Simulator never removed · \(device.runtimeName)",
                size: size, action: .trash(copies.map { dead.appendingPathComponent($0) }),
                recommendation: device.isBooted ? nil : "Nothing uses them",
                blockedReason: device.isBooted ? "Running — shut the simulator down first" : nil,
                iconPath: nil, symbol: "iphone")
        }
    }

    /// Editors built on VS Code keep each replaced extension version until
    /// they next start, listing it in extensions/.obsolete. A window left open
    /// for weeks piles them up — 70 versions, 11.3 GB here (2026-10-22), most
    /// of it the ChatGPT extension at ~0.8 GB a release. Only folders the
    /// editor itself marked obsolete and no longer lists as installed count.
    private static func editorExtensionItems(home: URL) -> [CleanupItem] {
        let editors: [(folder: String, name: String, bundleIDs: [String])] = [
            (".vscode", "VS Code", ["com.microsoft.VSCode"]),
            (".vscode-insiders", "VS Code Insiders", ["com.microsoft.VSCodeInsiders"]),
            (".cursor", "Cursor", ["com.todesktop.230313mzl4w4u92"]),
            (".windsurf", "Windsurf", ["com.exafunction.windsurf"]),
        ]
        return editors.compactMap { editor -> CleanupItem? in
            let root = home.appendingPathComponent(editor.folder).appendingPathComponent("extensions")
            guard let obsoleteData = FileManager.default.contents(atPath: root.appendingPathComponent(".obsolete").path),
                  let obsolete = (try? JSONSerialization.jsonObject(with: obsoleteData)) as? [String: Any] else { return nil }
            let installed = Set(installedExtensionFolders(in: root))
            // Can't tell what's installed → offer nothing rather than guess.
            guard !installed.isEmpty else { return nil }
            let stale = obsolete.keys.filter { !installed.contains($0) }.sorted()
                .map { root.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !stale.isEmpty else { return nil }
            let size = stale.reduce(Int64(0)) { $0 + allocatedSize(of: $1) }
            guard size >= minimumSize else { return nil }
            let running = NSWorkspace.shared.runningApplications.contains {
                editor.bundleIDs.contains($0.bundleIdentifier ?? "")
            }
            return CleanupItem(
                id: root.path, title: "\(editor.name) · old extension versions",
                detail: "\(stale.count) replaced versions · \((root.path as NSString).abbreviatingWithTildeInPath)",
                size: size, action: .trash(stale),
                recommendation: running ? nil : "\(editor.name) marked them as replaced",
                blockedReason: running ? "\(editor.name) is open — quit it first (⌘Q); reopening also clears these itself" : nil,
                iconPath: NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleIDs[0])?.path,
                symbol: "puzzlepiece.extension")
        }
    }

    /// Folder names extensions.json lists as installed — never removed, even
    /// if a stale .obsolete still names one.
    private static func installedExtensionFolders(in root: URL) -> [String] {
        guard let data = FileManager.default.contents(atPath: root.appendingPathComponent("extensions.json").path),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            (entry["relativeLocation"] as? String)
                ?? ((entry["location"] as? [String: Any])?["path"] as? String).map { ($0 as NSString).lastPathComponent }
        }
    }

    // MARK: - Installers and orphans

    /// "Install macOS Sequoia.app" in /Applications. Measured here — a Home
    /// Folder scan never walks /Applications — and only when one exists.
    private static func installerItems() -> [CleanupItem] {
        let applications = URL(fileURLWithPath: "/Applications")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []
        return names.filter { $0.hasPrefix("Install macOS") && $0.hasSuffix(".app") }.map { name in
            let url = applications.appendingPathComponent(name)
            let age = modificationAge(of: url)
            return CleanupItem(id: url.path, title: (name as NSString).deletingPathExtension,
                               detail: age.map { "Downloaded \($0.text)" } ?? "macOS installer",
                               size: allocatedSize(of: url), action: .trash([url]),
                               recommendation: "The App Store can download it again", blockedReason: nil,
                               iconPath: url.path, symbol: "arrow.down.app")
        }
    }

    /// Simulator runtimes Xcode has forgotten but whose files stayed behind:
    /// MobileAsset downloads in /System/Library/AssetsV2 (marked NeverCollected,
    /// so macOS never purges them — and SIP-locked, so not even sudo can), and
    /// disk images in /Library/Developer/CoreSimulator/Images that simctl no
    /// longer lists (root-owned; sudo can).
    private static func orphanedRuntimeItems(_ inventory: SimulatorInventory) -> [CleanupItem] {
        // No runtimes at all more likely means simctl answered badly than that
        // every one is orphaned — the same caution as for simulators.
        guard !inventory.runtimes.isEmpty else { return [] }
        let knownBuilds = Set(inventory.runtimes.map(\.build))
        let knownPaths = Set(inventory.runtimes.compactMap(\.path))
        var items: [CleanupItem] = []

        let assets = URL(fileURLWithPath: "/System/Library/AssetsV2")
        let families = ((try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? [])
            .filter { $0.hasPrefix("com_apple_MobileAsset_") && $0.hasSuffix("SimulatorRuntime") }
        for family in families {
            let folder = assets.appendingPathComponent(family)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".asset") {
                let asset = folder.appendingPathComponent(name)
                guard let info = NSDictionary(contentsOf: asset.appendingPathComponent("Info.plist")),
                      let properties = info["MobileAssetProperties"] as? [String: Any],
                      let build = properties["Build"] as? String, !knownBuilds.contains(build) else { continue }
                let platform = family.replacingOccurrences(of: "com_apple_MobileAsset_", with: "")
                    .replacingOccurrences(of: "SimulatorRuntime", with: "")
                    .replacingOccurrences(of: "xrOS", with: "visionOS")
                let version = properties["SimulatorVersion"] as? String ?? "?"
                items.append(CleanupItem(
                    id: asset.path, title: "\(platform) \(version) Simulator Runtime",
                    detail: "Build \(build) · Xcode no longer uses it",
                    size: allocatedSize(of: asset),
                    action: .manual(.init(location: asset, steps: """
                        Runtime นี้ Xcode ไม่ได้ใช้แล้ว แต่ไฟล์ยังค้างอยู่ และ macOS จะไม่ลบให้เอง

                        ไฟล์ถูกล็อกด้วย SIP แม้ใช้ sudo ใน Terminal ก็ลบไม่ได้ (Operation not permitted)

                        วิธีลบ: เปิด Xcode › Settings › Components ถ้ามี \(platform) \(version) อยู่ในรายการ ให้กดลบจากตรงนั้น

                        ถ้า Xcode ไม่แสดง ทางเดียวคือปิด SIP ชั่วคราวผ่าน Recovery ซึ่งไม่แนะนำ ปล่อยไว้ก็ไม่เป็นอันตราย แค่เสียพื้นที่
                        """, command: nil)),
                    recommendation: nil, blockedReason: nil, iconPath: nil, symbol: "shippingbox"))
            }
        }

        let images = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Images")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? [] where name.hasSuffix(".dmg") {
            let image = images.appendingPathComponent(name)
            guard !knownPaths.contains(image.path) else { continue }
            items.append(CleanupItem(
                id: image.path, title: name, detail: "Simulator disk image · Xcode no longer lists it",
                size: allocatedSize(of: image),
                action: .manual(.init(location: image, steps: """
                    ไฟล์ image ของ Simulator ที่ Xcode ไม่ได้ลงทะเบียนไว้แล้ว เป็นของ root แอปจึงลบเองไม่ได้

                    วิธีลบ: กด Copy Command แล้ววางใน Terminal จะถามรหัสผ่านเครื่อง
                    """, command: "sudo rm \"\(image.path)\"")),
                recommendation: nil, blockedReason: nil, iconPath: nil, symbol: "opticaldiscdrive"))
        }
        return items
    }

    private static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let child = enumerator?.nextObject() as? URL {
            total += Int64((try? child.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Simulators

    private static func runtimeItems(_ inventory: SimulatorInventory) -> [CleanupItem] {
        let inUse = Set(inventory.devices.values.map(\.runtimeIdentifier))
        let newestPerPlatform = Dictionary(grouping: inventory.runtimes, by: \.platform)
            .compactMapValues { $0.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }?.identifier }
        return inventory.runtimes.filter(\.deletable).map { runtime in
            let used = runtime.lastUsedAt.map { "last used \(relativeFormatter.localizedString(for: $0, relativeTo: Date()))" }
                ?? "never used"
            let isNewest = newestPerPlatform[runtime.platform] == runtime.identifier
            let recommendation = !inUse.contains(runtime.runtimeIdentifier) && !isNewest
                ? "No simulator uses it" : nil
            return CleanupItem(id: runtime.identifier, title: runtime.name,
                               detail: "Build \(runtime.build) · \(used)", size: runtime.size,
                               action: .deleteRuntime(identifier: runtime.identifier),
                               recommendation: recommendation, blockedReason: nil, iconPath: nil,
                               symbol: "shippingbox")
        }
    }

    private static func simulatorItems(_ folders: [(url: URL, size: Int64)],
                                       _ inventory: SimulatorInventory) -> [CleanupItem] {
        // An empty device list more likely means simctl answered badly (say,
        // right after an Xcode update) than that every simulator is orphaned.
        guard !inventory.devices.isEmpty else { return [] }
        return folders.compactMap { folder -> CleanupItem? in
            let udid = folder.url.lastPathComponent
            guard UUID(uuidString: udid) != nil else { return nil }
            guard let device = inventory.devices[udid] else {
                // Offered, never recommended: "unknown" can be a simctl hiccup.
                return CleanupItem(id: folder.url.path, title: "Unknown simulator", detail: "\(udid) · not listed by Xcode",
                                   size: folder.size, action: .trash([folder.url]),
                                   recommendation: nil, blockedReason: nil, iconPath: nil, symbol: "iphone")
            }
            var recommendation: String?
            let opened: String
            // lastBootedAt is only recorded when Simulator.app boots a device;
            // one booted by `xcodebuild test` has none even while it runs. So
            // fall back to when its data last changed before calling it unused.
            let lastUsed = device.lastBootedAt
                ?? (try? folder.url.appendingPathComponent("data")
                        .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            if device.isBooted {
                opened = "running now"
            } else if let lastUsed {
                let days = Int(Date().timeIntervalSince(lastUsed) / 86_400)
                opened = "used \(relativeFormatter.localizedString(for: lastUsed, relativeTo: Date()))"
                if days >= 30 { recommendation = "Not used in \(days) days" }
            } else {
                opened = "never used"
                recommendation = "Never used"
            }
            if !device.isAvailable {
                recommendation = "Its runtime is no longer installed"
            }
            return CleanupItem(id: udid, title: device.name, detail: "\(device.runtimeName) · \(opened)",
                               size: folder.size, action: .deleteSimulator(udid: udid),
                               recommendation: device.isBooted ? nil : recommendation,
                               blockedReason: device.isBooted ? "Running — shut it down in Simulator first" : nil,
                               iconPath: nil, symbol: "iphone")
        }
    }

    // MARK: - Folders

    private static func derivedDataItem(_ folder: (url: URL, size: Int64)) -> CleanupItem {
        let name = folder.url.lastPathComponent
        let special = ["ModuleCache.noindex": "Module cache", "SymbolCache.noindex": "Symbol cache",
                       "CompilationCache.noindex": "Compilation cache"]
        if let title = special[name] {
            return trashItem(folder, title: title, detail: "Shared by every project", recommendation: nil, symbol: "hammer")
        }
        // "MyApp-bxjqhmdkcdfpzagxwcxlqqxlnnmk": Xcode appends a 28-letter hash.
        var title = name
        if let dash = name.lastIndex(of: "-"), name.distance(from: dash, to: name.endIndex) == 29 {
            title = String(name[..<dash])
        }
        let info = NSDictionary(contentsOf: folder.url.appendingPathComponent("info.plist"))
        let workspace = (info?["WorkspacePath"] as? String).map { ($0 as NSString).abbreviatingWithTildeInPath }
        let lastAccess = info?["LastAccessedDate"] as? Date
        var detail = [workspace]
        var recommendation: String?
        if let lastAccess {
            let days = Int(Date().timeIntervalSince(lastAccess) / 86_400)
            detail.append("opened \(relativeFormatter.localizedString(for: lastAccess, relativeTo: Date()))")
            if days >= 30 { recommendation = "Not opened in Xcode for \(days) days" }
        }
        if let workspace = info?["WorkspacePath"] as? String, !FileManager.default.fileExists(atPath: workspace) {
            recommendation = "The project no longer exists"
        }
        return trashItem(folder, title: title, detail: detail.compactMap { $0 }.joined(separator: " · "),
                         recommendation: recommendation, symbol: "hammer")
    }

    private static func projectItems(_ folders: [(url: URL, size: Int64)], home: URL) -> [CleanupItem] {
        let homePath = home.path + "/"
        var accepted: [(url: URL, size: Int64)] = []
        for folder in folders.sorted(by: { $0.url.path < $1.url.path }) {
            let path = folder.url.path
            guard path.hasPrefix(homePath), folder.size >= minimumListedCacheSize else { continue }
            // Project folders live in plain, visible places: never under
            // ~/Library or a dot-folder like ~/.vscode, where a node_modules is
            // part of an installed tool rather than a checkout.
            let components = path.dropFirst(homePath.count).split(separator: "/").dropLast()
            // A marker folder straight in the home folder (~/.gradle, ~/build)
            // belongs to the account, not to a checkout.
            guard !components.isEmpty, components.first != "Library",
                  !components.contains(where: { $0.hasPrefix(".") }) else { continue }
            let parent = folder.url.deletingLastPathComponent()
            let markers = projectFolderMarkers[folder.url.lastPathComponent] ?? []
            guard markers.contains(where: { FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path) }) else {
                continue
            }
            // Sorted by path, so an enclosing folder is always seen first.
            if let last = accepted.last, path.hasPrefix(last.url.path + "/") { continue }
            accepted.append(folder)
        }
        return accepted.sorted { $0.size > $1.size }.prefix(100).map { folder in
            let parent = folder.url.deletingLastPathComponent()
            let marker = (projectFolderMarkers[folder.url.lastPathComponent] ?? [])
                .map { parent.appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            let age = marker.flatMap(modificationAge)
            return trashItem(folder, title: "\(parent.lastPathComponent) › \(folder.url.lastPathComponent)",
                             detail: (parent.path as NSString).abbreviatingWithTildeInPath,
                             recommendation: age.flatMap { $0.days >= 90 ? "Project untouched for \($0.days) days" : nil },
                             symbol: "folder.badge.gearshape")
        }
    }

    private static func appCacheItem(_ folder: (url: URL, size: Int64)) -> CleanupItem {
        let name = folder.url.lastPathComponent
        var title = name
        var iconPath: String?
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            title = FileManager.default.displayName(atPath: app.path)
            iconPath = app.path
        }
        return CleanupItem(id: folder.url.path, title: title,
                           detail: (folder.url.path as NSString).abbreviatingWithTildeInPath,
                           size: folder.size, action: .trash([folder.url]), recommendation: nil,
                           blockedReason: nil, iconPath: iconPath, symbol: "internaldrive")
    }

    /// Caches macOS itself manages (iCloud, Siri, Maps, …) and background
    /// agents' queues. Clearing them buys little and can make those services
    /// re-sync or lose pending work.
    private static func isSystemCache(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let systemNames: Set<String> = ["CloudKit", "GeoServices", "FamilyCircle", "PassKit", "SiriTTS", "GameKit",
                                        "Animoji", "EnergyKit", "TemporaryItems", "AMSDataMigratorTool"]
        if name.hasPrefix("com.apple.") || systemNames.contains(name) { return true }
        // Daemons and agents name their caches after themselves: familycircled,
        // icloudmailagent, askpermissiond.
        let isDaemonName = name.range(of: "^[a-z0-9]+(d|agent)$", options: .regularExpression) != nil
        return isDaemonName || name.lowercased().contains("crashreporter")
    }

    private static func trashItem(_ folder: (url: URL, size: Int64), title: String, detail: String,
                                  recommendation: String?, symbol: String) -> CleanupItem {
        CleanupItem(id: folder.url.path, title: title, detail: detail, size: folder.size,
                    action: .trash([folder.url]), recommendation: recommendation, blockedReason: nil,
                    iconPath: nil, symbol: symbol)
    }

    private static func modificationAge(of url: URL) -> (days: Int, text: String)? {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return nil
        }
        return (Int(Date().timeIntervalSince(date) / 86_400),
                relativeFormatter.localizedString(for: date, relativeTo: Date()))
    }
}

/// Simulators and runtimes as CoreSimulator reports them.
struct SimulatorInventory {
    struct Device {
        let name: String
        let runtimeIdentifier: String
        let runtimeName: String
        let isBooted: Bool
        let isAvailable: Bool
        let lastBootedAt: Date?
    }

    struct Runtime {
        let identifier: String
        let runtimeIdentifier: String
        let platform: String
        let version: String
        let build: String
        let size: Int64
        let lastUsedAt: Date?
        let deletable: Bool
        /// The disk image it's served from, when it is one.
        let path: String?

        var name: String { "\(platform) \(version)" }
    }

    let devices: [String: Device]
    let runtimes: [Runtime]

    /// Nil when the Simulator has never been used here — running `xcrun`
    /// without developer tools would pop the "install tools" dialog.
    static func load() -> SimulatorInventory? {
        let simulatorFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator")
        guard FileManager.default.fileExists(atPath: simulatorFolder.path),
              let deviceJSON = try? runSimctl(["list", "devices", "-j"]).get(),
              let devicesByRuntime = (try? JSONSerialization.jsonObject(with: deviceJSON) as? [String: Any])?["devices"]
                as? [String: [[String: Any]]] else {
            return nil
        }
        let dates = ISO8601DateFormatter()

        var devices: [String: Device] = [:]
        for (runtime, entries) in devicesByRuntime {
            for entry in entries {
                guard let udid = entry["udid"] as? String else { continue }
                devices[udid] = Device(name: entry["name"] as? String ?? udid,
                                       runtimeIdentifier: runtime,
                                       runtimeName: displayName(ofRuntime: runtime),
                                       isBooted: entry["state"] as? String == "Booted",
                                       isAvailable: entry["isAvailable"] as? Bool ?? true,
                                       lastBootedAt: (entry["lastBootedAt"] as? String).flatMap(dates.date(from:)))
            }
        }

        var runtimes: [Runtime] = []
        if let runtimeJSON = try? runSimctl(["runtime", "list", "-j"]).get(),
           let entries = try? JSONSerialization.jsonObject(with: runtimeJSON) as? [String: [String: Any]] {
            for (identifier, entry) in entries {
                let runtimeIdentifier = entry["runtimeIdentifier"] as? String ?? ""
                runtimes.append(Runtime(
                    identifier: identifier,
                    runtimeIdentifier: runtimeIdentifier,
                    platform: platformName(entry["platformIdentifier"] as? String ?? ""),
                    version: entry["version"] as? String ?? "?",
                    build: entry["build"] as? String ?? "?",
                    size: (entry["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                    lastUsedAt: (entry["lastUsedAt"] as? String).flatMap(dates.date(from:)),
                    deletable: entry["deletable"] as? Bool ?? false,
                    path: entry["path"] as? String
                ))
            }
        }
        return SimulatorInventory(devices: devices, runtimes: runtimes)
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → "iOS 26.5"
    private static func displayName(ofRuntime identifier: String) -> String {
        guard let tail = identifier.components(separatedBy: "SimRuntime.").last else { return identifier }
        let parts = tail.split(separator: "-")
        guard let platform = parts.first else { return tail }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }

    private static func platformName(_ identifier: String) -> String {
        switch identifier {
        case "com.apple.platform.iphonesimulator": return "iOS"
        case "com.apple.platform.watchsimulator": return "watchOS"
        case "com.apple.platform.appletvsimulator": return "tvOS"
        case "com.apple.platform.xrsimulator": return "visionOS"
        default: return identifier.components(separatedBy: ".").last ?? identifier
        }
    }

    /// Runs `xcrun simctl …` synchronously and returns stdout, or stderr as the
    /// error. Call off the main thread — runtime deletion can take a while.
    static func runSimctl(_ arguments: [String]) -> Result<Data, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failure(error)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            os_log("simctl %{public}@ failed: %{public}@", log: log, type: .error,
                   arguments.joined(separator: " "), message ?? "")
            let description = message.flatMap { $0.isEmpty ? nil : $0 }
                ?? "simctl exited with status \(process.terminationStatus)."
            return .failure(CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: description]))
        }
        return .success(data)
    }
}
