// Draws the OpenPlaySync app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repo root)
//
// Design: a play triangle with matching sound waves on both sides,
// meaning one source playing in sync on several speakers.

import AppKit
import CoreGraphics

func renderIcon(size: Int) -> Data {
    let s = CGFloat(size)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: 824pt body centred on a 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(shape); ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    // Background gradient: deep indigo -> teal
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.16, green: 0.12, blue: 0.42, alpha: 1),
        CGColor(red: 0.20, green: 0.30, blue: 0.78, alpha: 1),
        CGColor(red: 0.05, green: 0.72, blue: 0.74, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 160, y: 924), end: CGPoint(x: 864, y: 100), options: [])

    // Soft top highlight
    let hi = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.18), CGColor(red: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hi, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    let center = CGPoint(x: 512, y: 512)
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    // Sound waves, mirrored left and right
    ctx.setLineCap(.round)
    let waves: [(radius: CGFloat, width: CGFloat, alpha: CGFloat)] = [
        (190, 34, 0.95), (268, 30, 0.7), (346, 26, 0.45),
    ]
    let span = CGFloat.pi / 4.2
    for w in waves {
        ctx.setStrokeColor(white.copy(alpha: w.alpha)!)
        ctx.setLineWidth(w.width)
        ctx.addArc(center: center, radius: w.radius, startAngle: -span, endAngle: span, clockwise: false)
        ctx.strokePath()
        ctx.addArc(center: center, radius: w.radius, startAngle: .pi - span, endAngle: .pi + span, clockwise: false)
        ctx.strokePath()
    }

    // Play triangle (rounded), optically centred
    let tri = CGMutablePath()
    let h: CGFloat = 200, w: CGFloat = 176
    let ox: CGFloat = 512 - w / 2 + 14
    let p1 = CGPoint(x: ox, y: 512 + h / 2)
    let p2 = CGPoint(x: ox + w, y: 512)
    let p3 = CGPoint(x: ox, y: 512 - h / 2)
    tri.move(to: CGPoint(x: (p1.x + p3.x) / 2, y: (p1.y + p3.y) / 2))
    tri.addArc(tangent1End: p1, tangent2End: p2, radius: 26)
    tri.addArc(tangent1End: p2, tangent2End: p3, radius: 26)
    tri.addArc(tangent1End: p3, tangent2End: p1, radius: 26)
    tri.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18,
                  color: CGColor(red: 0.05, green: 0.05, blue: 0.2, alpha: 0.35))
    ctx.addPath(tri); ctx.setFillColor(white); ctx.fillPath()
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! renderIcon(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! renderIcon(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try! renderIcon(size: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
