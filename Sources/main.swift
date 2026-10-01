// Hijack — hold a key to dictate with a voice input method (default WeType) from any input source; the previous input source
// comes back after release. Settings live in ~/.config/hijack/config.json; the menu (menu bar icon, or
// open the app again) edits the common ones.
// Build: ./build.sh (all files in Sources/)
import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
