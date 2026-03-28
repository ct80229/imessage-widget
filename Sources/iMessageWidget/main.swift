import AppKit

// Entry point: run the application on the main thread.
// AppDelegate is @MainActor, so we create it via a Task on the main actor.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
