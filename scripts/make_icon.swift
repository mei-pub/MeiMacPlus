#!/usr/bin/env swift
//
// make_icon.swift — renders the MeiQuitManage app icon (1024×1024 PNG).
//
// Design: minimal "liquid glass" — a light frosted plate, a thin progress
// ring echoing the hold-to-quit countdown, and a small rounded "Q".
//
// Usage: swift make_icon.swift <output.png>

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift make_icon.swift <output.png>\n".data(using: .utf8)!)
    exit(64)
}
let outputURL = URL(fileURLWithPath: arguments[1])

let canvas = 1024.0

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else {
    FileHandle.standardError.write("failed to create bitmap\n".data(using: .utf8)!)
    exit(1)
}
rep.size = NSSize(width: canvas, height: canvas)

NSGraphicsContext.saveGraphicsState()
guard let nsContext = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write("failed to create graphics context\n".data(using: .utf8)!)
    exit(1)
}
NSGraphicsContext.current = nsContext
let ctx = nsContext.cgContext

// MARK: Geometry (macOS icon grid: 824pt artwork on a 1024 canvas)

let margin = 100.0
let plateRect = NSRect(x: margin, y: margin, width: canvas - margin * 2, height: canvas - margin * 2)
let plateRadius = 186.0
let platePath = NSBezierPath(roundedRect: plateRect, xRadius: plateRadius, yRadius: plateRadius)

let center = NSPoint(x: canvas / 2, y: canvas / 2 + 14)
let ringRadius = 232.0

// MARK: 1. Plate drop shadow

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 30,
              color: CGColor(red: 0.28, green: 0.36, blue: 0.55, alpha: 0.30))
NSColor(calibratedWhite: 1, alpha: 1).setFill()
platePath.fill()
ctx.restoreGState()

// MARK: 2. Frosted plate gradient

let plateGradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.985, green: 0.992, blue: 1.000, alpha: 1),
        NSColor(calibratedRed: 0.918, green: 0.940, blue: 0.984, alpha: 1),
        NSColor(calibratedRed: 0.845, green: 0.886, blue: 0.965, alpha: 1),
        NSColor(calibratedRed: 0.790, green: 0.836, blue: 0.945, alpha: 1),
    ],
    atLocations: [0.0, 0.42, 0.80, 1.0],
    colorSpace: NSColorSpace.deviceRGB
)!
plateGradient.draw(in: platePath, angle: -78)

// MARK: 3. Top glass sheen

ctx.saveGState()
platePath.addClip()
let sheenRect = NSRect(x: plateRect.minX, y: plateRect.midY, width: plateRect.width, height: plateRect.height / 2)
let sheen = NSGradient(
    colors: [
        NSColor(calibratedWhite: 1, alpha: 0.55),
        NSColor(calibratedWhite: 1, alpha: 0.12),
        NSColor(calibratedWhite: 1, alpha: 0.0),
    ]
)!
sheen.draw(in: sheenRect, angle: -90)

// Diagonal light streak across the upper-left of the plate.
ctx.saveGState()
let streak = NSBezierPath()
streak.move(to: NSPoint(x: plateRect.minX, y: plateRect.maxY - 210))
streak.line(to: NSPoint(x: plateRect.minX + 330, y: plateRect.maxY))
streak.line(to: NSPoint(x: plateRect.minX + 520, y: plateRect.maxY))
streak.line(to: NSPoint(x: plateRect.minX, y: plateRect.maxY - 400))
streak.close()
let streakGradient = NSGradient(
    colors: [
        NSColor(calibratedWhite: 1, alpha: 0.30),
        NSColor(calibratedWhite: 1, alpha: 0.0),
    ]
)!
ctx.setAlpha(0.8)
streakGradient.draw(in: streak, angle: -30)
ctx.restoreGState()
ctx.restoreGState()

// MARK: 4. Bottom inner rim

ctx.saveGState()
platePath.addClip()
let rim = NSBezierPath(roundedRect: plateRect.insetBy(dx: 2, dy: 2), xRadius: plateRadius, yRadius: plateRadius)
rim.lineWidth = 8
NSColor(calibratedRed: 0.45, green: 0.53, blue: 0.72, alpha: 0.16).setStroke()
rim.stroke()
ctx.restoreGState()

// MARK: 5. Hairline highlights

let innerLine = NSBezierPath(roundedRect: plateRect.insetBy(dx: 1.5, dy: 1.5), xRadius: plateRadius - 1.5, yRadius: plateRadius - 1.5)
innerLine.lineWidth = 3
NSColor(calibratedWhite: 1, alpha: 0.65).setStroke()
innerLine.stroke()

// MARK: 6. Progress ring — track

let trackColor = NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.63, alpha: 0.14)
let track = NSBezierPath(ovalIn: NSRect(
    x: center.x - ringRadius, y: center.y - ringRadius,
    width: ringRadius * 2, height: ringRadius * 2
))
track.lineWidth = 30
trackColor.setStroke()
track.stroke()

// MARK: 7. Progress ring — arc with soft glow

func ringArcPath(startAngle: CGFloat, endAngle: CGFloat) -> NSBezierPath {
    // AppKit angles are degrees, counter-clockwise, 0° at 3 o'clock.
    // We want a clockwise sweep starting at 12 o'clock.
    let path = NSBezierPath()
    path.appendArc(
        withCenter: center, radius: ringRadius,
        startAngle: startAngle, endAngle: endAngle, clockwise: true
    )
    return path
}

let arc = ringArcPath(startAngle: 90, endAngle: 90 - 268)

ctx.saveGState()
ctx.addPath(arc.cgPath)
ctx.setLineCap(.round)
ctx.setLineWidth(30)

// Stroke the arc with a vertical gradient by clipping to it and drawing
// gradient-filled copies (simplest: emulate with two passes).
let ringBounds = arc.bounds.insetBy(dx: -20, dy: -20)
let arcClip = arc.copy() as! NSBezierPath
arcClip.lineWidth = 34
arcClip.lineCapStyle = .round
ctx.saveGState()
arcClip.addClip()

// Glow beneath.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 34, color: CGColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 0.65))
NSColor(calibratedRed: 0.30, green: 0.50, blue: 0.95, alpha: 1).setStroke()
arc.lineWidth = 30
arc.stroke()
ctx.restoreGState()

// Gradient over the glow.
let ringGradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.52, green: 0.71, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.33, green: 0.53, blue: 0.97, alpha: 1),
        NSColor(calibratedRed: 0.24, green: 0.40, blue: 0.90, alpha: 1),
    ],
    atLocations: [0.0, 0.55, 1.0],
    colorSpace: NSColorSpace.deviceRGB
)!
ringGradient.draw(in: ringBounds, angle: -90)

ctx.restoreGState() // arc clip
ctx.restoreGState() // glow save

// Round end caps on top of the gradient.
for angle in [90.0, 90.0 - 268.0] {
    let rad = angle * .pi / 180
    let dotCenter = NSPoint(x: center.x + cos(rad) * ringRadius, y: center.y + sin(rad) * ringRadius)
    let dot = NSBezierPath(ovalIn: NSRect(x: dotCenter.x - 15, y: dotCenter.y - 15, width: 30, height: 30))
    NSColor(calibratedRed: 0.50, green: 0.69, blue: 1.00, alpha: 1).setFill()
    dot.fill()
}

// MARK: 8. The "Q"

let qDescriptor = NSFont.systemFont(ofSize: 1, weight: .semibold)
    .fontDescriptor
    .withDesign(.rounded)
let qFont = qDescriptor.flatMap { NSFont(descriptor: $0, size: 236) }
let qAttributes: [NSAttributedString.Key: Any] = [
    .font: qFont ?? NSFont.systemFont(ofSize: 236, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.29, alpha: 0.93),
]
let qString = NSAttributedString(string: "Q", attributes: qAttributes)
let qSize = qString.size()
// Optical centering: nudge right/down a touch to account for the Q's bowl.
qString.draw(at: NSPoint(
    x: center.x - qSize.width / 2 + 7,
    y: center.y - qSize.height / 2 - 10
))

// MARK: 9. Export

NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.current = nil

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode png\n".data(using: .utf8)!)
    exit(1)
}
do {
    try png.write(to: outputURL)
    print("wrote \(outputURL.path)")
} catch {
    FileHandle.standardError.write("failed to write \(outputURL.path): \(error)\n".data(using: .utf8)!)
    exit(1)
}
