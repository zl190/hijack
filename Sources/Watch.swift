import Foundation

// MARK: settings watch — re-read settings when their files change, instead of checking every second.
// FSEvents with file-level events: catches the config file (written by replacing it) and a voice tool's
// settings written in place (WeType's MMKV is memory-mapped). Idle: no timers, no wake-ups.

final class SettingsWatch {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(paths: [URL], latency: Double = 0.3, onChange: @escaping () -> Void) {
        self.onChange = onChange
        // Watch each file's folder (a file replaced on save gets a new identity; the folder stays).
        let folders = Array(Set(paths.map { $0.deletingLastPathComponent().path }))
            .filter { FileManager.default.fileExists(atPath: $0) }.sorted()
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            Unmanaged<SettingsWatch>.fromOpaque(info!).takeUnretainedValue().onChange()
        }
        // NoDefer (FSEvents.h): a change after a quiet spell is delivered at once (measured: 12-14 ms after a
        // config write); only changes within `latency` of a delivery are batched. Without it, every change would
        // wait `latency` first.
        stream = FSEventStreamCreate(nil, callback, &context, folders as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        trace("watching settings in \(folders.joined(separator: ", "))")
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
