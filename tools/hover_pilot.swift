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
// pointer while it is the active app.
if let sim = NSRunningApplication
    .runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
    .first {
    sim.activate(options: [.activateAllWindows])
    log("activated Simulator (pid \(sim.processIdentifier))")
} else {
    log("Simulator app not running")
}
Thread.sleep(forTimeInterval: 1.0)

// Find the device window: the largest on-screen window owned by
// the Simulator.
guard let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID) as? [[String: Any]] else {
    log("cannot list windows")
    exit(1)
}
var best: CGRect? = nil
for window in windows {
    guard let owner = window[kCGWindowOwnerName as String] as? String,
          owner == "Simulator",
          let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
          let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
          let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    else { continue }
    if best == nil || bounds.width * bounds.height > best!.width * best!.height {
        best = bounds
    }
}
guard let frame = best, frame.width > 200, frame.height > 200 else {
    log("no Simulator device window found")
    exit(1)
}
log("device window: \(frame)")

// Sweep the central band (the PCB canvas area: right of the tool
// rail, left of the right panel, below the menu strips).
let xs: [CGFloat] = [0.30, 0.42, 0.54, 0.46, 0.34]
let ys: [CGFloat] = [0.40, 0.52, 0.64, 0.58, 0.46]
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
