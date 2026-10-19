// Prints every event tap in the login session, in the order the window server keeps them: the chain
// a key event walks. A tap earlier in the list sees the event first; a filtering tap (options 0) can
// drop it for everyone after it. Run: swift scripts/taps.swift  (or `hijack doctor`, which prints the same).
import CoreGraphics
import Foundation

func processName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return "gone" }
    return URL(fileURLWithPath: String(cString: buf)).lastPathComponent
}
func location(_ p: CGEventTapLocation) -> String {
    switch p { case .cghidEventTap: return "hid"; case .cgSessionEventTap: return "session"; case .cgAnnotatedSessionEventTap: return "annotated"; @unknown default: return "?" }
}
let keyMask: CGEventMask = 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue | 1 << CGEventType.flagsChanged.rawValue
var count: UInt32 = 0
var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: 128)
let r = CGGetEventTapList(128, &taps, &count)
print("CGGetEventTapList: \(r == .success ? "ok" : "error \(r.rawValue)"), \(count) taps, pid of this process \(getpid())")
print("order | id | location | filter/listen | key events | enabled | pid process | latency min/avg/max ms")
for (i, t) in taps.prefix(Int(count)).enumerated() {
    let keys = t.eventsOfInterest & keyMask != 0 ? "keys" : "    "
    let kind = t.options == .defaultTap ? "filter" : "listen"
    print(String(format: "%2d | %4u | %-9@ | %@ | %@ | %@ | %6d %@ | %.1f/%.1f/%.1f", i, t.eventTapID, location(t.tapPoint) as NSString, kind, keys, t.enabled ? "on " : "off", t.tappingProcess, processName(t.tappingProcess), t.minUsecLatency / 1000, t.avgUsecLatency / 1000, t.maxUsecLatency / 1000))
}
