import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

// What has keyboard focus right now (app + control role) — for diagnosing focus changes in the logs.
func focusDesc() -> String {
    let sys = AXUIElementCreateSystemWide()
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success, let ref else {
        return "focus=none(\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))"
    }
    let el = ref as! AXUIElement
    var pid: pid_t = 0; AXUIElementGetPid(el, &pid)
    var role: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
    let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid\(pid)"
    return "focus=\(app):\((role as? String) ?? "?")"
}
