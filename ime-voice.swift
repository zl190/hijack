// ime-voice — switch to WeType only while its push-to-talk voice key is held, then switch back.
// Driven by a Karabiner rule on right_option (see karabiner-rule.json).
//   ime-voice begin [id]   save the current input source, select WeType (or `id`: unmaintained hatch for other IMEs)
//   ime-voice end [secs]   after a delay (default 2.5s, lets WeType commit its text) restore the saved
//                          source — only if WeType is still current and no newer `begin` happened
//   ime-voice current      print the current input source id
// Build: ./install.sh
import Carbon
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let weType = (args.first == "begin" && args.count > 1) ? args[1]
    : (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/ime-voice/target"), encoding: .utf8)) ?? "com.tencent.inputmethod.wetype.pinyin"
let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/ime-voice")
let prevFile = stateDir.appendingPathComponent("prev")
let genFile = stateDir.appendingPathComponent("generation")

func currentID() -> String? {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func select(_ id: String) -> Bool {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
          let src = list.first else { return false }
    return TISSelectInputSource(src) == noErr
}

func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
func write(_ s: String, _ url: URL) { try? s.write(to: url, atomically: true, encoding: .utf8) }

try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

switch args.first {
case "begin":
    write(weType, stateDir.appendingPathComponent("target"))
    let gen = String(Int(Date().timeIntervalSince1970 * 1000))
    write(gen, genFile)
    if let cur = currentID(), cur != weType { write(cur, prevFile) }
    if !select(weType) { FileHandle.standardError.write("ime-voice: cannot select \(weType)\n".data(using: .utf8)!); exit(1) }
case "end":
    let delay = args.dropFirst().first.flatMap(Double.init) ?? 2.5
    let gen = read(genFile)
    Thread.sleep(forTimeInterval: delay)
    guard read(genFile) == gen else { exit(0) }          // a newer recording started: leave WeType on
    guard currentID() == weType else { exit(0) }         // user already switched away by hand
    if let prev = read(prevFile), !prev.isEmpty { _ = select(prev) }
case "current":
    print(currentID() ?? "?")
default:
    print("usage: ime-voice begin | end [secs] | current"); exit(2)
}
