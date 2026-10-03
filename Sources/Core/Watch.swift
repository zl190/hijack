import Foundation
import CoreServices

// MARK: settings watch — re-read settings when their files change, instead of checking every second.
// FSEvents with file-level events: catches the config file (written by replacing it) and a voice tool's
// settings written in place (WeType's MMKV is memory-mapped). Idle: no timers, no wake-ups.
// This is the one live system service inside Core: the test drives it with a temporary folder.

final class SettingsWatch {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    /// The folders whose changes count, resolved (FSEvents reports /private/var for /var).
    let folders: [String]
    /// The folders FSEvents watches: for each wanted folder, the nearest one that exists (FM-18).
    let roots: [String]

    init(paths: [URL], latency: Double = 0.3, onChange: @escaping () -> Void) {
        self.onChange = onChange
        // Watch each file's folder (a file replaced on save gets a new identity; the folder stays).
        folders = Array(Set(paths.map { SettingsWatch.resolve($0.deletingLastPathComponent().path) })).sorted()
        roots = Array(Set(folders.map(SettingsWatch.nearestExisting))).sorted()
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            let watch = Unmanaged<SettingsWatch>.fromOpaque(info!).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            guard count > 0, paths.contains(where: watch.counts) else { return }
            watch.onChange()
        }
        // UseCFTypes: the callback gets a CFArray of paths. NoDefer: FSEvents sends the first change after a quiet period immediately (FSEvents.h).
        // Measured on 2026-10-03, 8 config writes for each setting, 1.2 s apart:
        //   With NoDefer: 11 ms to 13 ms.
        //   Without NoDefer: 317 ms for the first write, then 14 ms to 82 ms.
        // FSEvents.h does not explain the short delays without NoDefer.
        // Keep NoDefer. It gives a stable delay.
        stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    /// An event path counts when it is one of our folders, or inside one.
    func counts(_ path: String) -> Bool {
        folders.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// The path with symlinks resolved. The components that do not exist yet stay as written.
    static func resolve(_ path: String) -> String {
        var existing = path, rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/" {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        // realpath, not NSString.resolvingSymlinksInPath: the latter strips /private, FSEvents reports it.
        var base = existing
        if let real = realpath(existing, nil) { base = String(cString: real); free(real) }
        return rest.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// The folder itself when it exists, else its nearest ancestor that does.
    static func nearestExisting(_ folder: String) -> String {
        var f = folder
        while !FileManager.default.fileExists(atPath: f), f != "/" { f = (f as NSString).deletingLastPathComponent }
        return f
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
