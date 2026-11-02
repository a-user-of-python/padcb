#!/usr/bin/env python3
"""Hover exercise (parts 5.0.2–5.0.3): boot an iPad simulator,
install the Debug build of PadCB (compiled with the DEBUG
compilation condition so the -padcbHoverCheck seed is live),
launch it into the PCB editor on the seeded fixture board, then
sweep the HOST mouse over the simulator window with
tools/hover_pilot.swift.

What this exercise can and cannot prove (measured, part 5.0.2):
synthetic HOVER never enters the CI simulator as hover events —
five rounds, three injection methods, and not even SwiftUI's
own .onContinuousHover received a single event. Hover counts
are therefore REPORTED here, never gated. What the simulator
CAN prove, and this script gates on (part 5.0.3):

  - the interaction view arms (its PADCB-HOVER marker);
  - the hit-test probe: the interaction view IS the window's
    hit-test result at the canvas centre, with the
    UIHoverGestureRecognizer attached to it (PADCB-PROBE);
  - the SwiftUI canvas gestures still receive touches whose hit
    view is the frontmost interaction view: the pilot's click
    produces a "drag ended" marker with moved < 5 (the tap
    path) and its long drag one with moved >= 20 and mode pan
    (the pan path). A pinch is attempted best-effort and its
    markers are reported, not gated.

The app mirrors its markers to Documents/hover-markers.txt
inside its container (the console stream is stdio-buffered and
cannot be trusted live); channel 1 = interaction-view
recognizer, 2 = SwiftUI .onContinuousHover.

Usage: hover_check.py <PadCB.app> <output-dir>
"""
import json
import os
import re
import subprocess
import sys
import time

APP_ID = "com.user.padcb"
SUMMARY_RE = re.compile(r"Hover 1: (\d+) · 2: (\d+) ·")
PROBE_RE = re.compile(
    r"PADCB-PROBE hitTest\(centre\)=(\S+)"
    r" isInteractionView=(true|false) recognizers=\[(.*?)\]")
DRAG_END_RE = re.compile(
    r"PADCB-GESTURE drag ended moved=([\d.]+) mode=(\w+)")


def run(*args, check=True):
    r = subprocess.run(args, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(
            f"command failed: {' '.join(args)}\n{r.stdout}\n{r.stderr}")
    return r.stdout.strip()


def simctl(*args, check=True):
    return run("xcrun", "simctl", *args, check=check)


def main():
    app_path, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    tools_dir = os.path.dirname(os.path.abspath(__file__))

    runtimes = json.loads(simctl("list", "runtimes", "-j"))["runtimes"]
    ios = [r for r in runtimes
           if r["name"].startswith("iOS") and r.get("isAvailable", True)]
    if not ios:
        raise SystemExit("no available iOS simulator runtime")
    runtime = ios[-1]["identifier"]
    print(f"runtime: {ios[-1]['name']} ({runtime})", flush=True)

    types = json.loads(simctl("list", "devicetypes", "-j"))["devicetypes"]
    by_name = {t["name"]: t for t in types}
    candidates = [by_name[n] for n in (
        "iPad Pro 13-inch (M4)", "iPad Pro 13-inch (M5)",
        "iPad Air 13-inch (M3)", "iPad Air 11-inch (M3)",
        "iPad Pro (12.9-inch) (6th generation)",
        "iPad (10th generation)") if n in by_name]
    if not candidates:
        raise SystemExit("no iPad device type available")

    # Clean slate (a previous failed run may have left the device).
    existing = json.loads(simctl("list", "devices", "-j"))["devices"]
    for devs in existing.values():
        for d in devs:
            if d["name"] == "HoverCheck-iPad":
                simctl("delete", d["udid"], check=False)

    udid = None
    for dtype in candidates:
        r = subprocess.run(
            ["xcrun", "simctl", "create", "HoverCheck-iPad",
             dtype["identifier"], runtime],
            capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            udid = r.stdout.strip()
            print(f"device: {dtype['name']} ({udid})", flush=True)
            break
        print(f"{dtype['name']} refused: {r.stderr.strip()[:120]}",
              flush=True)
    if not udid:
        raise SystemExit("could not create an iPad simulator")

    failure = None
    counts = (0, 0)
    armed_channels = []
    probe = None
    drag_ends = []
    magnify_count = 0
    try:
        simctl("boot", udid)
        simctl("bootstatus", udid, "-b")
        simctl("install", udid, app_path)
        print("app installed", flush=True)

        container = simctl("get_app_container", udid, APP_ID, "data")
        marker_file = os.path.join(
            container, "Documents", "hover-markers.txt")
        print(f"marker file: {marker_file}", flush=True)

        def markers():
            try:
                with open(marker_file) as f:
                    return f.read()
            except OSError:
                return ""

        # Compile the host-mouse pilot.
        pilot = "/tmp/hover_pilot"
        run("xcrun", "swiftc", "-O", "-o", pilot,
            os.path.join(tools_dir, "hover_pilot.swift"))
        print("pilot compiled", flush=True)

        log_path = os.path.join(out_dir, "app-console.log")
        log_file = open(log_path, "w")
        proc = subprocess.Popen(
            ["xcrun", "simctl", "launch", "--console-pty", udid,
             APP_ID, "-padcbHoverCheck"],
            stdout=log_file, stderr=subprocess.STDOUT, text=True)
        print(f"app launched (console pid {proc.pid})", flush=True)

        # Wait for the hover channels to arm (the canvas appeared)
        # — the seed + library bootstrap can take a while in the
        # simulator, so allow 4 minutes.
        deadline = time.time() + 240
        while time.time() < deadline:
            if "PADCB-HOVER armed" in markers():
                break
            if proc.poll() is not None:
                failure = (f"app process exited early "
                           f"(code {proc.returncode})")
                break
            time.sleep(3)
        armed_channels = sorted(set(re.findall(
            r"PADCB-HOVER armed ch=(\d)", markers())))
        print(f"armed markers: channels {armed_channels}", flush=True)
        if "1" not in armed_channels and failure is None:
            failure = ("interaction view never armed "
                       "(canvas never appeared?)")

        if failure is None:
            # Open the Simulator GUI: `simctl boot` runs the device
            # headless (no window, no host pointer, no hover at
            # all). The pilot waits for the window to appear.
            subprocess.run(["open", "-a", "Simulator"],
                           capture_output=True)
            # Let the board settle, then sweep the host mouse.
            time.sleep(5)
            pilot_run = subprocess.run([pilot], capture_output=True,
                                       text=True, timeout=300)
            with open(os.path.join(out_dir, "pilot.log"), "w") as f:
                f.write(pilot_run.stdout + pilot_run.stderr)
            print(f"pilot exit: {pilot_run.returncode}", flush=True)
            time.sleep(3)

        # Evidence either way: what the simulator actually shows.
        shot = os.path.join(out_dir, "hover.png")
        simctl("io", udid, "screenshot", shot, check=False)

        text = markers()
        with open(os.path.join(out_dir, "hover-markers.txt"), "w") as f:
            f.write(text)
        summaries = SUMMARY_RE.findall(text)
        if summaries:
            counts = tuple(int(v) for v in summaries[-1])
        print(f"final hover counts: ch1={counts[0]} ch2={counts[1]} "
              f"(from {len(summaries)} summaries; reported only — "
              f"the CI input layer cannot inject hover)", flush=True)

        # Structural gates (part 5.0.3): the probe line and the
        # gesture-delivery markers are what the simulator CAN
        # settle.
        probe_match = PROBE_RE.search(text)
        if probe_match:
            probe = (probe_match.group(1),
                     probe_match.group(2) == "true",
                     probe_match.group(3))
        drag_ends = [(float(m), mode)
                     for m, mode in DRAG_END_RE.findall(text)]
        magnify_count = text.count("PADCB-GESTURE magnify began")
        taps = [m for m, _ in drag_ends if m < 5]
        pans = [(m, mode) for m, mode in drag_ends
                if m >= 20 and mode == "pan"]
        print(f"probe: {probe}", flush=True)
        print(f"drag ends: {drag_ends} (taps={len(taps)}, "
              f"pans={len(pans)}), magnify began x{magnify_count}",
              flush=True)

        if failure is None:
            if probe is None:
                failure = "no PADCB-PROBE hit-test line recorded"
            elif not probe[1]:
                failure = (f"hit-test probe: the interaction view "
                           f"is NOT the hit view at the canvas "
                           f"centre (hit={probe[0]})")
            elif "UIHoverGestureRecognizer" not in probe[2]:
                failure = ("hit-test probe: no "
                           "UIHoverGestureRecognizer attached to "
                           f"the hit view (recognizers={probe[2]})")
            elif not taps:
                failure = ("gesture exercise: no tap reached the "
                           "canvas drag gesture (no drag-ended "
                           "marker with moved < 5)")
            elif not pans:
                failure = ("gesture exercise: no pan reached the "
                           "canvas drag gesture (no drag-ended "
                           "marker with moved >= 20, mode pan)")

        with open(os.path.join(out_dir, "verdict.txt"), "w") as f:
            f.write(f"armed={armed_channels}\n"
                    f"counts ch1={counts[0]} ch2={counts[1]}\n"
                    f"probe={probe}\n"
                    f"drag_ends={drag_ends}\n"
                    f"magnify_began={magnify_count}\n"
                    f"failure={failure}\n")

        simctl("terminate", udid, APP_ID, check=False)
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
        log_file.close()

        if failure is not None:
            print("---- markers ----", flush=True)
            print(text[-2000:] or "(no marker file content)", flush=True)
            raise SystemExit(failure)
        print("HOVER EXERCISE: interaction view is the hit view "
              "with its recognizer attached; tap + pan delivered "
              "to the SwiftUI canvas gestures; hover counts "
              "reported above (device-judged)", flush=True)
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", udid],
                       capture_output=True)
        subprocess.run(["xcrun", "simctl", "delete", udid],
                       capture_output=True)


if __name__ == "__main__":
    main()
