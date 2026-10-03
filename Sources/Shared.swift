import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

let appName = "Hijack"
let capsuleGrace = 0.15  // after its voice window disappears, wait this long, then switch back
let maxSwitchWait = 1.0  // give up waiting for the input source switch after this long
let marker: Int64 = 0x5357424B               // tags events we post ourselves
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

// Chinese typesetting: one space between CJK and Latin letters/digits, so "按住右 Option用Handy听写"
// reads "按住右 Option 用 Handy 听写". Applied to every Chinese string, so copy never spaces by hand.
func spaced(_ s: String) -> String {
    var out = "", prev: Character?
    func cjk(_ c: Character) -> Bool { c.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) } }
    func latin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
    for c in s {
        if let p = prev, (cjk(p) && latin(c)) || (latin(p) && cjk(c)) { out.append(" ") }
        out.append(c); prev = c
    }
    while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
    return out
}

// MARK: log  (~/Library/Logs/Hijack.log)

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(appName).log")
func log(_ msg: String) {
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"
    let line = "\(f.string(from: Date())) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}
