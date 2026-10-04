import CoreGraphics
import Foundation

// MARK: keys — any key plus modifiers; a bare modifier key is a "modifier-only" key

public enum Mod: String, CaseIterable {
    case ctrl
    case option
    case shift
    case command
    case fn
    public var flag: CGEventFlags {
        switch self {
        case .ctrl: .maskControl;
        case .option: .maskAlternate;
        case .shift: .maskShift
        case .command: .maskCommand;
        case .fn: .maskSecondaryFn
        }
    }
    public var symbol: String {
        switch self {
        case .ctrl: "⌃";
        case .option: "⌥";
        case .shift: "⇧";
        case .command: "⌘";
        case .fn: "fn "
        }
    }
    // NSEvent.ModifierFlags bits, as WeType stores them
    public var nsBit: Int {
        switch self {
        case .shift: 1 << 17;
        case .ctrl: 1 << 18;
        case .option: 1 << 19;
        case .command: 1 << 20;
        case .fn: 1 << 23
        }
    }
}

public struct NamedKey {
    public let id: String
    public let code: Int
    public let zh: String
    public let en: String
    public let device: UInt64
    public let flag: CGEventFlags?
    public init(id: String, code: Int, zh: String, en: String, device: UInt64, flag: CGEventFlags?) {
        self.id = id; self.code = code; self.zh = zh; self.en = en; self.device = device; self.flag = flag
    }
}

public let namedKeys: [NamedKey] =
    [
        NamedKey(id: "right_option", code: 61, zh: "右 Option", en: "Right Option", device: 0x40, flag: .maskAlternate),
        NamedKey(id: "left_option", code: 58, zh: "左 Option", en: "Left Option", device: 0x20, flag: .maskAlternate),
        NamedKey(id: "right_command", code: 54, zh: "右 Command", en: "Right Command", device: 0x10, flag: .maskCommand),
        NamedKey(id: "left_command", code: 55, zh: "左 Command", en: "Left Command", device: 0x08, flag: .maskCommand),
        NamedKey(id: "right_control", code: 62, zh: "右 Control", en: "Right Control", device: 0x2000, flag: .maskControl),
        NamedKey(id: "left_control", code: 59, zh: "左 Control", en: "Left Control", device: 0x01, flag: .maskControl),
        NamedKey(id: "right_shift", code: 60, zh: "右 Shift", en: "Right Shift", device: 0x04, flag: .maskShift),
        NamedKey(id: "left_shift", code: 56, zh: "左 Shift", en: "Left Shift", device: 0x02, flag: .maskShift),
        NamedKey(id: "fn", code: 63, zh: "Fn", en: "Fn", device: 0, flag: .maskSecondaryFn),
    ]
    + [
        ("f13", 105), ("f14", 107), ("f15", 113), ("f16", 106), ("f17", 64), ("f18", 79), ("f19", 80), ("f20", 90), ("space", 49),
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9), ("b", 11),
        ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34), ("p", 35),
        ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46), ("return", 36), ("tab", 48), ("escape", 53),
    ]
    .map { NamedKey(id: $0.0, code: $0.1, zh: $0.0.uppercased(), en: $0.0.uppercased(), device: 0, flag: nil) }

// Menu quick picks; anything else goes in the config file.
public let quickKeys = ["right_option", "left_option", "right_command", "fn"]

public struct KeySpec: Equatable {
    public var code: Int
    public var mods: Set<Mod> = []
    public var named: NamedKey? { namedKeys.first { $0.code == code } }
    public var modifierOnly: Bool { mods.isEmpty && named?.flag != nil }
    public var name: String {
        let base = named.map { localize($0.zh, $0.en) } ?? "keyCode \(code)"
        return Mod.allCases.filter { mods.contains($0) }.map(\.symbol).joined() + base
    }
    /// A stable identifier for logs and stats (review-5 #17): never runs through `localize`, unlike `name`.
    /// Same shape `hijack set` and `KeySpec(binding:)` parse: a named key's id, or "mod+mod+base".
    public var logID: String {
        let base = named?.id ?? "keyCode\(code)"
        return (Mod.allCases.filter { mods.contains($0) }.map(\.rawValue) + [base]).joined(separator: "+")
    }
    public var flags: CGEventFlags { mods.reduce(into: CGEventFlags()) { $0.insert($1.flag) } }
    public static func named(_ id: String) -> KeySpec? { namedKeys.first { $0.id == id }.map { KeySpec(code: $0.code) } }

    // JSON: "right_option" | {"keyCode": 49, "modifiers": ["ctrl", "option"]}
    public init(code: Int, mods: Set<Mod> = []) { self.code = code; self.mods = mods }
    public init?(json: Any?) {
        if let s = json as? String, let k = KeySpec.named(s) { self = k; return }
        guard let d = json as? [String: Any] else { return nil }
        let code = (d["keyCode"] as? Int) ?? (d["key"] as? String).flatMap { KeySpec.named($0)?.code }
        guard let code else { return nil }
        self.code = code
        self.mods = Set(((d["modifiers"] as? [String]) ?? []).compactMap(Mod.init(rawValue:)))
    }
    public var json: Any {
        if mods.isEmpty, let n = named { return n.id }
        var d: [String: Any] = named.map { ["key": $0.id] } ?? ["keyCode": code]
        d["modifiers"] = Mod.allCases.filter { mods.contains($0) }.map(\.rawValue)
        return d
    }
    public var quickID: String? { mods.isEmpty ? named.map(\.id) : nil }

    // "option_left+space", "ctrl+shift+d" (Handy / Tauri-style bindings)
    public init?(binding: String) {
        var mods: Set<Mod> = [], code: Int?
        for raw in binding.lowercased().split(separator: "+").map(String.init) {
            let base = raw.replacingOccurrences(of: "_left", with: "").replacingOccurrences(of: "_right", with: "")
            switch base {
            case "option", "alt": mods.insert(.option)
            case "command", "cmd", "super", "meta": mods.insert(.command)
            case "ctrl", "control": mods.insert(.ctrl)
            case "shift": mods.insert(.shift)
            case "fn": mods.insert(.fn)
            default: code = KeySpec.named(raw)?.code ?? KeySpec.named(base)?.code
            }
        }
        if let code { self.init(code: code, mods: mods); return }
        // "fn" is a literal id in namedKeys (quickKeys); see KeysTests.testW5_QuickKeysAlwaysResolveToANamedKey.
        // swift-format-ignore: NeverForceUnwrap
        if binding.lowercased() == "fn" { self = KeySpec.named("fn")!; return }
        // A lone side-specific modifier, e.g. "option_right" → right_option
        let parts = binding.lowercased().split(separator: "_").map(String.init)
        guard parts.count == 2, ["left", "right"].contains(parts[1]) else { return nil }
        let base = ["alt": "option", "cmd": "command", "ctrl": "control"][parts[0]] ?? parts[0]
        guard let k = KeySpec.named("\(parts[1])_\(base)") else { return nil }
        self = k
    }
}
