// Hijack — hold a key to dictate with a voice input method (default WeType) from any input source; the previous input source
// comes back after release. Settings live in ~/.config/hijack/config.json; the menu bar menu edits the common
// ones and the settings window (⌘, or open the app again) all of them.
// Build: ./build.sh (all files in Sources/)
import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

// `hijack <command>` runs the CLI and exits; anything else starts the app.
if let code = runCLI(Array(CommandLine.arguments.dropFirst())) { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
