import AppKit

Theme.registerFonts()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// No Dock icon and no menu bar: the app is only its floating panel.
app.setActivationPolicy(.accessory)
app.run()
