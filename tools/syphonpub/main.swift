import Foundation
import IOSurface

// Publishes a Syphon feed of a moving white square, so the receive path can be tested
// without TouchDesigner (or any GPU code): SyphonServerBase's subclassing category hands
// out a BGRA8 IOSurface, and the CPU can draw straight into it.
//
//   swiftc ... tools/syphonpub/main.swift -o build/syphonpub && ./build/syphonpub

setvbuf(stdout, nil, _IOLBF, 0)

let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "segtest"
let width = 1280, height = 720

let server = SyphonServerBase(name: name, options: nil)
print("publishing Syphon feed \"\(name)\" at \(width)x\(height) — ^C to stop")

var step = 0
let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
    guard let surface = server.copySurface(forWidth: width, height: height, options: nil)?
        .takeRetainedValue() else { return }

    IOSurfaceLock(surface, [], nil)
    if let base = IOSurfaceGetBaseAddress(surface) as UnsafeMutableRawPointer? {
        let stride = IOSurfaceGetBytesPerRow(surface)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        // Dark field…
        for y in 0..<height {
            memset(pixels + y * stride, 25, stride)
        }
        // …with a white square tracking left to right, and a bright bar along the top so
        // threshold mode always has something to find.
        let boxW = 220, boxH = 200
        let x0 = (step * 12) % max(1, width - boxW)
        let y0 = height / 2 - boxH / 2
        for y in y0..<(y0 + boxH) {
            let row = pixels + y * stride
            memset(row + x0 * 4, 240, boxW * 4)
        }
        for y in 20..<70 {
            memset(pixels + y * stride + 40 * 4, 250, 300 * 4)
        }
    }
    IOSurfaceUnlock(surface, [], nil)
    server.publish()
    step += 1
    if step % 60 == 0 { print("published \(step) frames, clients: \(server.hasClients)") }
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
