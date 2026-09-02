import CoreVideo
import Foundation
import IOSurface

// Connects to a Syphon feed and reports exactly what the shared IOSurface looks like, so
// surface-format problems can be diagnosed without rebuilding the app.
setvbuf(stdout, nil, _IOLBF, 0)

let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "segtest"

func fourCC(_ value: OSType) -> String {
    guard value != 0 else { return "0 (none)" }
    let bytes = [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                 UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    return "'" + String(bytes: bytes, encoding: .ascii)! + "' (\(value))"
}

var client: SyphonClientBase?
var reported = false

func attach() {
    let servers = (SyphonServerDirectory.shared().servers as? [[String: Any]]) ?? []
    print("servers: \(servers.map { ($0[SyphonServerDescriptionAppNameKey] as? String ?? "?") + " — " + ($0[SyphonServerDescriptionNameKey] as? String ?? "") })")
    guard let match = servers.first(where: {
        (($0[SyphonServerDescriptionNameKey] as? String ?? "") + ($0[SyphonServerDescriptionAppNameKey] as? String ?? ""))
            .lowercased().contains(wanted.lowercased())
    }) else { return }

    client = SyphonClientBase(serverDescription: match, options: nil) { _ in
        guard !reported, let surface = client?.newSurface().takeRetainedValue() else { return }
        reported = true
        print("--- surface ---")
        print("  size            \(IOSurfaceGetWidth(surface)) x \(IOSurfaceGetHeight(surface))")
        print("  pixel format    \(fourCC(IOSurfaceGetPixelFormat(surface)))")
        print("  bytes per row   \(IOSurfaceGetBytesPerRow(surface))")
        print("  bytes per elem  \(IOSurfaceGetBytesPerElement(surface))")
        print("  plane count     \(IOSurfaceGetPlaneCount(surface))")
        print("  alloc size      \(IOSurfaceGetAllocSize(surface))")

        var unmanaged: Unmanaged<CVPixelBuffer>?
        let plain = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &unmanaged)
        print("  CVPixelBufferCreateWithIOSurface -> \(plain)")
        _ = unmanaged?.takeRetainedValue()

        // Does declaring the format explicitly help?
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        var second: Unmanaged<CVPixelBuffer>?
        let typed = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, attributes as CFDictionary, &second)
        print("  …with BGRA attributes            -> \(typed)")
        _ = second?.takeRetainedValue()
        exit(0)
    }
    print("attached: \(client?.isValid == true)")
}

attach()
DispatchQueue.main.asyncAfter(deadline: .now() + 3) { attach() }
DispatchQueue.main.asyncAfter(deadline: .now() + 8) { print("no frame seen"); exit(1) }
RunLoop.main.run()
