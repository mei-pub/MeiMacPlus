import AppKit
import Foundation
import os

/// A headless virtual display ("dummy"), created with CoreGraphics's private
/// CGVirtualDisplay API — the same technique BetterDummy uses (declarations
/// in the bridging header are transcribed from its MIT source).
///
/// Why it matters: the wake-password lock triggers on the internal display's
/// *sleep event*. While a second display exists, closing the lid merely
/// migrates the session onto the virtual display — the internal panel turns
/// off as a display *switch*, not a sleep, so no lock screen is raised.
/// Reopening the lid switches back instantly. This is what makes "lid
/// closed without lock" possible on macOS 26.2, where every lock-setting
/// write path is broken at the OS level.
///
/// The display exists only while this process holds the reference: quitting
/// (or crashing) removes it automatically.
@MainActor
final class VirtualDisplayManager {

    static let shared = VirtualDisplayManager()

    private let log = Logger(subsystem: "com.meimacplus.MeiMacPlus", category: "virtualDisplay")

    private(set) var virtualDisplay: CGVirtualDisplay?

    var isActive: Bool { virtualDisplay != nil }

    /// Creates a 1920×1080 @60Hz HiDPI virtual display. Returns true when a
    /// display is (already) active.
    @discardableResult
    func create() -> Bool {
        guard virtualDisplay == nil else { return true }
        if let descriptor = CGVirtualDisplayDescriptor() {
            descriptor.queue = DispatchQueue.global(qos: .userInteractive)
            descriptor.name = "MeiMacPlus Keep Awake"
            // Chromaticity values from the Generic RGB profile, as in
            // BetterDummy's defaults.
            descriptor.whitePoint = CGPoint(x: 0.950, y: 1.000)
            descriptor.redPrimary = CGPoint(x: 0.454, y: 0.242)
            descriptor.greenPrimary = CGPoint(x: 0.353, y: 0.674)
            descriptor.bluePrimary = CGPoint(x: 0.157, y: 0.084)
            descriptor.maxPixelsWide = 1920
            descriptor.maxPixelsHigh = 1080
            descriptor.sizeInMillimeters = CGSize(width: 518, height: 291) // 24" 16:9
            descriptor.serialNum = 20261110
            descriptor.productID = 0x0780
            descriptor.vendorID = 0xF0F0
            if let display = CGVirtualDisplay(descriptor: descriptor) {
                let mode = CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60)
                if let mode, let settings = CGVirtualDisplaySettings() {
                    settings.hiDPI = 1
                    settings.modes = [mode]
                    if display.applySettings(settings) {
                        virtualDisplay = display
                        log.notice("virtual display created (id \(display.displayID))")
                        return true
                    }
                }
            }
        }
        log.error("virtual display creation failed — lid-close will lock as before")
        return false
    }

    /// Removes the virtual display (releasing the reference tears it down).
    func destroy() {
        guard virtualDisplay != nil else { return }
        virtualDisplay = nil
        log.notice("virtual display removed")
    }
}
