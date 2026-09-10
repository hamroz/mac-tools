// Read-only diagnostic: only Dock-owned window layers, no images, titles, or
// other-app contents. Does not modify or re-sign the authorized test app.
import AppKit

let duration: TimeInterval = 60
let start = Date()
let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
var lastLayers: [Int] = []
print("Tracing Dock layer changes for 60 seconds. Try Mission Control, exit, then Show Desktop and exit.")
let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    guard let dockPID,
          let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return }
    let layers = windows.compactMap { info -> Int? in
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == dockPID else { return nil }
        return (info[kCGWindowLayer as String] as? NSNumber)?.intValue
    }.sorted()
    if layers != lastLayers {
        print(String(format: "%.3fs Dock layers: %@", Date().timeIntervalSince(start), String(describing: layers)))
        fflush(stdout)
        lastLayers = layers
    }
}
RunLoop.main.run(until: start.addingTimeInterval(duration))
timer.invalidate()
print("Trace finished. No settings or windows were changed.")
