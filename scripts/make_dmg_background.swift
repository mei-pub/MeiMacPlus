#!/usr/bin/env swift
//
// make_dmg_background.swift — renders the DMG installer background
// (1440×800 PNG matching a 720×400 Finder window at 2x).
//
// Usage: swift make_dmg_background.swift <output.png> <appicon.png>

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: swift make_dmg_background.swift <output.png> <appicon.png>\n".data(using: .utf8)!)
    exit(64)
}
let outputURL = URL(fileURLWithPath: arguments[1])
let appIcon = NSImage(contentsOfFile: arguments[2])
    ?? NSImage(systemSymbolName: "q.circle", accessibilityDescription: nil)!

let width = 1440.0, height = 800.0

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width), pixelsHigh: Int(height),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else {
    FileHandle.standardError.write("failed to create bitmap\n".data(using: .utf8)!)
    exit(1)
}
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
guard let nsContext = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write("failed to create context\n".data(using: .utf8)!)
    exit(1)
}
NSGraphicsContext.current = nsContext

// Base gradient — the icon's frosted-blue family, slightly deeper.
let base = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.955, green: 0.968, blue: 0.992, alpha: 1),
        NSColor(calibratedRed: 0.878, green: 0.910, blue: 0.972, alpha: 1),
        NSColor(calibratedRed: 0.802, green: 0.850, blue: 0.952, alpha: 1),
    ]
)!
base.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -70)

let ctx = nsContext.cgContext

// Giant ghost ring, echoing the countdown motif.
ctx.saveGState()
let ghost = NSBezierPath(ovalIn: NSRect(x: 220, y: -160, width: 1000, height: 1000))
ghost.lineWidth = 90
NSColor(calibratedRed: 0.42, green: 0.55, blue: 0.85, alpha: 0.10).setStroke()
ghost.stroke()
ctx.restoreGState()

// Small satellite ring bottom-right.
ctx.saveGState()
let satellite = NSBezierPath(ovalIn: NSRect(x: 1130, y: 60, width: 240, height: 240))
satellite.lineWidth = 26
NSColor(calibratedRed: 0.42, green: 0.55, blue: 0.85, alpha: 0.14).setStroke()
satellite.stroke()
ctx.restoreGState()

// Title + tagline.
let title = NSAttributedString(string: "MeiQuitManage", attributes: [
    .font: NSFont.systemFont(ofSize: 46, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.30, alpha: 1),
])
title.draw(at: NSPoint(x: 90, y: height - 110))

let tagline = NSAttributedString(string: L0("meiquit.dmg.tagline"), attributes: [
    .font: NSFont.systemFont(ofSize: 22, weight: .regular),
    .foregroundColor: NSColor(calibratedRed: 0.24, green: 0.31, blue: 0.47, alpha: 0.85),
])
tagline.draw(at: NSPoint(x: 92, y: height - 150))

// Drop-zones: app on the left, Applications folder on the right.
// Finder icon positions are set in make_dmg.sh to match these frames.
let zoneRect1 = NSRect(x: 170, y: 210, width: 380, height: 380)
let zoneRect2 = NSRect(x: 830, y: 210, width: 380, height: 380)

for (zone, label) in [(zoneRect1, L0("meiquit.dmg.dropApp")), (zoneRect2, L0("meiquit.dmg.dropApplications"))] {
    let plate = NSBezierPath(roundedRect: zone, xRadius: 44, yRadius: 44)
    NSColor(calibratedWhite: 1, alpha: 0.45).setFill()
    plate.fill()
    plate.lineWidth = 2
    NSColor(calibratedWhite: 1, alpha: 0.75).setStroke()
    plate.stroke()

    let caption = NSAttributedString(string: label, attributes: [
        .font: NSFont.systemFont(ofSize: 19, weight: .medium),
        .foregroundColor: NSColor(calibratedRed: 0.22, green: 0.28, blue: 0.42, alpha: 0.8),
    ])
    let s = caption.size()
    caption.draw(at: NSPoint(x: zone.midX - s.width / 2, y: zone.minY - 40))
}

// Arrow between the zones.
ctx.saveGState()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 585, y: 400))
arrow.line(to: NSPoint(x: 800, y: 400))
arrow.lineWidth = 6
arrow.lineCapStyle = .round
NSColor(calibratedRed: 0.30, green: 0.45, blue: 0.80, alpha: 0.7).setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 778, y: 416))
head.line(to: NSPoint(x: 806, y: 400))
head.line(to: NSPoint(x: 778, y: 384))
head.close()
NSColor(calibratedRed: 0.30, green: 0.45, blue: 0.80, alpha: 0.7).setFill()
head.fill()
ctx.restoreGState()

// Decorative app icon preview between title and first zone.
let previewRect = NSRect(x: 1080, y: 560, width: 150, height: 150)
appIcon.draw(in: previewRect)

NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.current = nil

// Localized caption helper (falls back to English when system locale differs).
func L0(_ key: String) -> String {
    let preferred = Bundle.preferredLocalizations(from: ["en", "zh-Hans"])
    let value: String
    switch preferred.first {
    case "zh-Hans":
        value = [
            "meiquit.dmg.tagline": "按住 ⌘Q，告别误触退出",
            "meiquit.dmg.dropApp": "拖动应用",
            "meiquit.dmg.dropApplications": "到此处安装",
        ][key] ?? key
    default:
        value = [
            "meiquit.dmg.tagline": "Hold ⌘Q — no more accidental quits",
            "meiquit.dmg.dropApp": "Drag the app",
            "meiquit.dmg.dropApplications": "into Applications",
        ][key] ?? key
    }
    return value
}

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
