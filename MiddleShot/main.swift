import Cocoa

// Explicit entry point. `@main` on an NSApplicationDelegate-conforming class
// starts the process but does not call NSApplicationMain, so the run loop
// never starts and applicationDidFinishLaunching never fires.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // matches LSUIElement — menu-bar only, no Dock
app.run()
