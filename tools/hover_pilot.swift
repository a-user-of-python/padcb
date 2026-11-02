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
/// hover recognizers see sustained positions, for ~24 seconds —
/// then (part 5.0.3) performs a click, a pan drag, and a
/// best-effort pinch on the canvas (see the gesture phase).

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
// Deliver a mouse-moved at a global point THREE ways: warp the
// real cursor, post to the HID event tap, and post DIRECTLY to
// the Simulator process (postToPid bypasses window-server
// routing — some CI sessions drop tap-posted synthetic events).
func deliver(_ point: CGPoint, pid: pid_t) {
    CGWarpMouseCursorPosition(point)
    if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: point, mouseButton: .left) {
        event.post(tap: .cghidEventTap)
        event.postToPid(pid)
    }
}

// Start OUTSIDE the window and cross the boundary first, so the
// Simulator sees a pointer ENTER, not just positions inside.
deliver(CGPoint(x: frame.minX - 40, y: frame.midY), pid: sim.processIdentifier)
Thread.sleep(forTimeInterval: 1.0)
for round in 0..<3 {
    for i in 0..<xs.count {
        let point = CGPoint(x: frame.minX + frame.width * xs[i],
                            y: frame.minY + frame.height * ys[i])
        deliver(point, pid: sim.processIdentifier)
        log("round \(round) move \(Int(point.x)),\(Int(point.y))")
        Thread.sleep(forTimeInterval: 1.6)
    }
}
log("sweep complete")

// MARK: - Gesture phase (part 5.0.3)
//
// Hover injection into the CI simulator is impossible (proven
// across five v5.0.2 rounds), but CLICKS and DRAGS are ordinary
// mouse events and DO reach the simulated device. v5.0.3's
// interaction view is the hit view for touches too, so this
// phase proves the editor's SwiftUI drag/tap machinery still
// receives them: a click on the canvas (the app logs a
// PADCB-GESTURE "drag ended" with moved < 5 — the tap path) and
// a long drag (moved >> 5, mode pan — the pan path). A pinch is
// attempted best-effort via the Simulator's Option+drag pinch
// emulation; the driver reports its markers but does not gate
// on them.
func postMouse(_ type: CGEventType, _ point: CGPoint, pid: pid_t,
               flags: CGEventFlags = []) {
    CGWarpMouseCursorPosition(point)
    if let event = CGEvent(mouseEventSource: nil, mouseType: type,
                           mouseCursorPosition: point,
                           mouseButton: .left) {
        event.flags = flags
        event.post(tap: .cghidEventTap)
        event.postToPid(pid)
    }
}

func windowPoint(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
    CGPoint(x: frame.minX + frame.width * fx,
            y: frame.minY + frame.height * fy)
}

func click(_ point: CGPoint, pid: pid_t) {
    postMouse(.leftMouseDown, point, pid: pid)
    Thread.sleep(forTimeInterval: 0.3)
    postMouse(.leftMouseUp, point, pid: pid)
}

func drag(from: CGPoint, to: CGPoint, pid: pid_t,
          flags: CGEventFlags = []) {
    postMouse(.leftMouseDown, from, pid: pid, flags: flags)
    Thread.sleep(forTimeInterval: 0.3)
    let steps = 12
    for i in 1...steps {
        let p = CGPoint(
            x: from.x + (to.x - from.x) * CGFloat(i) / CGFloat(steps),
            y: from.y + (to.y - from.y) * CGFloat(i) / CGFloat(steps))
        postMouse(.leftMouseDragged, p, pid: pid, flags: flags)
        Thread.sleep(forTimeInterval: 0.09)
    }
    postMouse(.leftMouseUp, to, pid: pid, flags: flags)
}

let pid = sim.processIdentifier
Thread.sleep(forTimeInterval: 1.0)
click(windowPoint(0.28, 0.50), pid: pid)
log("gesture phase: click done")
Thread.sleep(forTimeInterval: 1.2)
drag(from: windowPoint(0.24, 0.42), to: windowPoint(0.40, 0.58),
     pid: pid)
log("gesture phase: drag done")
Thread.sleep(forTimeInterval: 1.2)
// Best-effort pinch: hold Option (the Simulator's pinch
// emulation shows two mirrored touch points) and drag outward
// from the canvas centre.
if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 58,
                         keyDown: true) {
    keyDown.flags = .maskAlternate
    keyDown.post(tap: .cghidEventTap)
    keyDown.postToPid(pid)
}
drag(from: windowPoint(0.30, 0.50), to: windowPoint(0.38, 0.50),
     pid: pid, flags: .maskAlternate)
if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 58,
                       keyDown: false) {
    keyUp.flags = []
    keyUp.post(tap: .cghidEventTap)
    keyUp.postToPid(pid)
}
log("gesture phase: pinch attempt done")
