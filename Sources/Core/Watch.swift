import Foundation
import CoreServices

// MARK: settings watch — re-read settings when their files change, instead of checking every second.
// FSEvents with file-level events: catches the config file (written by replacing it) and a voice tool's
// settings written in place (WeType's MMKV is memory-mapped). Idle: no timers, no wake-ups.
// Only folders that exist are watched; the watch never climbs to a parent, which would be a busy folder
// such as ~/Library/Application Support (review-4 S4). The app creates the config folder before this starts
// (FM-18). A voice tool's folder that is missing means the tool is not installed: skipped.
// This is the one live system service inside Core: the test drives it with a temporary folder.

final class SettingsWatch {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    /// The folders FSEvents watches: each file's folder, when it exists.
    let roots: [String]
    var isWatching: Bool { stream != nil }

    init(paths: [URL], latency: Double = 0.3, onChange: @escaping () -> Void) {
        self.onChange = onChange
        // Watch each file's folder (a file replaced on save gets a new identity; the folder stays).
        roots = Array(Set(paths.map { $0.deletingLastPathComponent().path }))
            .filter { FileManager.default.fileExists(atPath: $0) }.sorted()
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            Unmanaged<SettingsWatch>.fromOpaque(info!).takeUnretainedValue().onChange()
        }
        // NoDefer: FSEvents sends the first change after a quiet period immediately (FSEvents.h).
        // Measured on 2026-10-03, 8 config writes for each setting, 1.2 s apart:
        //   With NoDefer: 11 ms to 13 ms.
        //   Without NoDefer: 317 ms for the first write, then 14 ms to 82 ms.
        // FSEvents.h does not explain the short delays without NoDefer.
        // Keep NoDefer. It gives a stable delay.
        stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
