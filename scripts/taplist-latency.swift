// How long one CGGetEventTapList call takes on this Mac: the Engine reads the key-listener chain with it once per
// dictation, off the main thread (docs/adr/0023). Run: swift scripts/taplist-latency.swift
import CoreGraphics
import Foundation

var tb = mach_timebase_info(); mach_timebase_info(&tb)
var samples: [Double] = []
for _ in 0..<200 {
    var count: UInt32 = 0
    var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: 128)
    let t0 = mach_absolute_time()
    _ = CGGetEventTapList(128, &taps, &count)
    samples.append(Double(mach_absolute_time() - t0) * Double(tb.numer) / Double(tb.denom) / 1e6)
    usleep(5000)
}
samples.sort()
print(String(format: "CGGetEventTapList x200: p50 %.3f ms  p95 %.3f ms  max %.3f ms", samples[100], samples[190], samples[199]))
