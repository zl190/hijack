import HijackCore
import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

// MARK: input sources

func currentID() -> String? {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
        let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
    else { return nil }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func source(_ id: String) -> TISInputSource? {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    return (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first
}
func prop(_ src: TISInputSource, _ key: CFString) -> String? {
    guard let raw = TISGetInputSourceProperty(src, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}
func sourceName(_ id: String) -> String { source(id).flatMap { prop($0, kTISPropertyLocalizedName) } ?? id }
func select(_ id: String) -> Bool {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
        let src = list.first
    else { return false }
    return TISSelectInputSource(src) == noErr
}

// Select and confirm: re-read the current source a moment later and retry once if it didn't stick.
func switchTo(_ id: String, _ label: String) {
    let ok = select(id)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        if currentID() == id { trace("\(label) \(id) ok=\(ok)") } else { log("\(label) \(id) didn't stick, retry ok=\(select(id))") }
    }
}
