import HijackCore
import AppKit
import ApplicationServices
import Carbon
import ServiceManagement
import os

let appName = "Hijack"
let marker: Int64 = 0x5357_424B  // tags events we post ourselves
let weTypeID = "com.tencent.inputmethod.wetype.pinyin"

// MARK: language  (system by default; config can force English or Chinese)

func zh() -> Bool {
    switch Config.shared.language {
    case "zh": return true
    case "en": return false
    default: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }
}
func L(_ zhText: String, _ en: String) -> String { zh() ? spaced(zhText) : en }

// Review-5 #7 (stale-grant-guidance): the one wording for "Accessibility is not trusted" shared by the
// menu first line, Settings' Try It card and `hijack doctor`. AXIsProcessTrusted() can't tell a first-time
// grant from a signed build replacing an ad-hoc one (or the reverse), which leaves System Settings showing
// the switch already on, so the same wording covers both. The decision to show it lives in
// MenuFaults.showsStaleAccessibilityGuidance (Sources/Core/MenuState.swift) so it is unit-testable.
// `hijack doctor` and the other CLI output stay English-only (keyOrigin, etc. do too), so it gets the
// plain English constant instead of the L()-wrapped one the menu and Settings use.
let staleAccessibilityGuidanceEnglish =
    "Accessibility shows Hijack as allowed but the grant belongs to an older build. Turn it off and on again in System Settings, or remove Hijack from the list and add it again."
var staleAccessibilityGuidance: String {
    L("辅助功能里显示 Hijack 已允许，但这个授权来自旧版本。请在系统设置里把开关关掉再打开，或者先从列表里移除 Hijack 再重新添加。", staleAccessibilityGuidanceEnglish)
}

// Chinese typesetting: one space between CJK and Latin letters/digits, so "按住右 Option用Handy听写"
// reads "按住右 Option 用 Handy 听写". Applied to every Chinese string, so copy never spaces by hand.
func spaced(_ s: String) -> String {
    var out = "", prev: Character?
    func cjk(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }
    func latin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
    for c in s {
        if let p = prev, (cjk(p) && latin(c)) || (latin(p) && cjk(c)) { out.append(" ") }
        out.append(c); prev = c
    }
    while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
    return out
}

// MARK: log  (~/Library/Logs/Hijack.log)

// Two levels. log(): the file — one summary line per dictation, plus errors, settings changes and system
// events; always on, so an intermittent failure is already on record when it happens. trace(): each step
// of a session, to the system log at debug level (kept only while someone watches: `hijack log --live`).
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(appName).log")
let logLimit = 1_000_000  // past this the app moves the file to Hijack.old.log and starts a new one
let tracer = Logger(subsystem: "com.zl190.hijack", category: "session")
func trace(_ msg: @autoclosure @escaping () -> String) { tracer.debug("\(msg(), privacy: .public)") }  // built only while someone watches
var logInApp = false  // the app writes on a background queue and rotates; a CLI process writes directly and exits
private let logQueue = DispatchQueue(label: "com.zl190.hijack.log", qos: .utility)
private let logTime: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
}()
func log(_ msg: String) {
    trace(msg)
    let now = Date()
    func write() {
        if logInApp, let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > logLimit {
            let old = logURL.deletingPathExtension().appendingPathExtension("old.log")
            try? FileManager.default.removeItem(at: old); try? FileManager.default.moveItem(at: logURL, to: old)
        }
        // O_APPEND: the app and a `hijack` command can write at the same time without overwriting each other.
        let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        let line = Array("\(logTime.string(from: now)) \(msg)\n".utf8)
        _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }
    if logInApp { logQueue.async(execute: write) } else { write() }  // never file I/O on the main thread (it serves the key tap)
}
