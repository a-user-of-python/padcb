import AppKit
import CoreGraphics
import Foundation

/// Hover pilot (part 5.0.2): moves the HOST mouse over the iOS
/// Simulator window so the simulated iPad receives real pointer
/// hover events — the closest off-device exercise of the UIKit
/// hover delivery path (mouse hover in the simulator travels the
/// same UIHoverGestureRecognizer / onContinuousHover plumbing as
/// Pencil hover on hardware; the input DEVICE differs, the
/// delivery path does not).
///
/// Compiled standalone by tools/hover_check.py on the CI runner:
///   xcrun swiftc -O -o /tmp/hover_pilot tools/hover_pilot.swift
/// Sweeps a grid over the simulator window's central band (where
/// the PCB canvas sits in the editor), pausing at each point so
/// hover recognizers see sustained positions, for ~24 seconds.

func log(_ message: String) {
    print("PILOT: \(message)")
    fflush(stdout)
}

// Bring the Simulator to the front — it only forwards the host
// pointer while it is the active app. The driver opens the app
// first (a headless `simctl boot` starts no GUI); wait for it.
var simApp: NSRunningApplication? = nil
for _ in 0..<30 {
    simApp = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
        .first
    if simApp != nil { break }
    Thread.sleep(forTimeInterval: 2.0)
}
guard let sim = simApp else {
    log("Simulator app not running")
    exit(1)
}
sim.activate(options: [.activateAllWindows])
log("activated Simulator (pid \(sim.processIdentifier))")

// Find the device window: the largest on-screen window owned by
// the Simulator. The window can take seconds to appear after the
// app opens — poll for up to a minute.
func deviceWindow() -> CGRect? {
    guard let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] else { return nil }
    var best: CGRect? = nil
    for window in windows {
        guard let owner = window[kCGWindowOwnerName as String] as? String,
              owner == "Simulator",
              let layer = window[kCGWindowLayer as String] as? Int,
              layer == 0,
              let boundsDict = window[kCGWindowBounds as String]
                as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation:
                                    boundsDict as CFDictionary)
        else { continue }
        if best == nil
            || bounds.width * bounds.height > best!.width * best!.height {
            best = bounds
        }
    }
    return best
}
var found: CGRect? = nil
for _ in 0..<30 {
    if let w = deviceWindow(), w.width > 200, w.height > 200 {
        found = w
        break
    }
    Thread.sleep(forTimeInterval: 2.0)
}
guard let frame = found else {
    log("no Simulator device window found")
    exit(1)
}
log("device window: \(frame)")

// Sweep the canvas area (right of the 96 pt tool rail, left of
// the 320 pt right panel, below the menu strips) — fractions
// chosen to stay on the canvas in portrait AND landscape.
let xs: [CGFloat] = [0.16, 0.24, 0.32, 0.40, 0.28]
let ys: [CGFloat] = [0.35, 0.50, 0.65, 0.55, 0.45]
for round in 0..<3 {
    for i in 0..<xs.count {
        let point = CGPoint(x: frame.minX + frame.width * xs[i],
                            y: frame.minY + frame.height * ys[i])
        CGWarpMouseCursorPosition(point)
        if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
        log("round \(round) move \(Int(point.x)),\(Int(point.y))")
        Thread.sleep(forTimeInterval: 1.6)
    }
}
log("sweep complete")
