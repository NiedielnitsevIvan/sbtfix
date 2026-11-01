// Renders AppIcon.svg into AppIcon.icns: swift Resources/make-icon.swift
import AppKit

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
guard let svg = NSImage(contentsOf: dir.appendingPathComponent("AppIcon.svg")) else { fatalError("can't read AppIcon.svg") }
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}

let iconutil = try Process.run(URL(fileURLWithPath: "/usr/bin/iconutil"),
                               arguments: ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path])
iconutil.waitUntilExit()
