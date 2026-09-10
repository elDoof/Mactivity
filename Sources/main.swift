import AppKit

// A menu bar app has no windows of its own, so it uses a plain AppKit entry
// point. Using SwiftUI's `App` protocol would require returning some Scene,
// and the usual `Settings { EmptyView() }` placeholder registers a real
// (blank) settings window that macOS opens whenever the app is reopened.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement in Info.plist already implies this; setting it explicitly keeps
// `swift run` (which has no bundle) behaving the same way.
app.setActivationPolicy(.accessory)
app.run()
