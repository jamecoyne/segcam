import AppKit
import CoreGraphics
import Foundation

// Reads the window server directly, so segment window placement can be checked without
// trusting a screenshot (the photowall tools/windows trick).
setvbuf(stdout, nil, _IOLBF, 0)

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "segcam"
guard let screen = NSScreen.screens.first else { exit(1) }
print("main screen frame \(screen.frame)  visible \(screen.visibleFrame)  scale \(screen.backingScaleFactor)")

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var count = 0
for window in list {
    guard (window[kCGWindowOwnerName as String] as? String) == owner else { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let x = bounds["X"] ?? 0, y = bounds["Y"] ?? 0, w = bounds["Width"] ?? 0, h = bounds["Height"] ?? 0
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    let number = window[kCGWindowNumber as String] as? Int ?? 0
    let name = window[kCGWindowName as String] as? String ?? ""
    let alpha = window[kCGWindowAlpha as String] as? Double ?? -1
    // CGWindow bounds are top-left origin; convert to normalized frame space.
    print(String(format: "  id %-6d %-10s layer %2d  alpha %.2f  %7.1f,%7.1f  %6.1fx%-6.1f   norm x %.3f y %.3f w %.3f h %.3f",
                 number, (name as NSString).utf8String!, layer, alpha, x, y, w, h,
                 x / screen.frame.width, y / screen.frame.height,
                 w / screen.frame.width, h / screen.frame.height))
    count += 1
}
print("\(count) window(s) owned by \(owner)")
