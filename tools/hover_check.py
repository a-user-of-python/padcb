#!/usr/bin/env python3
"""Hover exercise (part 5.0.2): boot an iPad simulator, install the
Debug build of PadCB (compiled with the DEBUG compilation
condition so the -padcbHoverCheck seed is live), launch it into
the PCB editor on the seeded fixture board, then sweep the HOST
mouse over the simulator window with tools/hover_pilot.swift so
the app receives real pointer hover events. The app's PADCB-HOVER
log markers report the per-channel counters (channel 1 = overlay
recognizer, 2 = ancestor recognizer, 3 = SwiftUI
.onContinuousHover); this script parses the final counts and
fails if the channels never armed or every counter stayed at 0.

Usage: hover_check.py <PadCB.app> <output-dir>
"""
import json
import os
import re
import subprocess
import sys
import time

APP_ID = "com.user.padcb"
SUMMARY_RE = re.compile(r"Hover 1: (\d+) · 2: (\d+) · 3: (\d+)")


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
    print(f"runtime: {ios[-1]['name']} ({runtime})")

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
            print(f"device: {dtype['name']} ({udid})")
            break
        print(f"{dtype['name']} refused: {r.stderr.strip()[:120]}")
    if not udid:
        raise SystemExit("could not create an iPad simulator")

    try:
        simctl("boot", udid)
        simctl("bootstatus", udid, "-b")
        simctl("install", udid, app_path)
        print("app installed")

        # Compile the host-mouse pilot.
        pilot = "/tmp/hover_pilot"
        run("xcrun", "swiftc", "-O", "-o", pilot,
            os.path.join(tools_dir, "hover_pilot.swift"))
        print("pilot compiled")

        log_path = os.path.join(out_dir, "app-console.log")
        log_file = open(log_path, "w")
        proc = subprocess.Popen(
            ["xcrun", "simctl", "launch", "--console", udid, APP_ID,
             "-padcbHoverCheck"],
            stdout=log_file, stderr=subprocess.STDOUT, text=True)
        print(f"app launched (console pid {proc.pid})")

        def log_text():
            log_file.flush()
            try:
                with open(log_path) as f:
                    return f.read()
            except OSError:
                return ""

        # Wait for the hover channels to arm (the canvas appeared).
        armed = False
        deadline = time.time() + 120
        while time.time() < deadline:
            if "PADCB-HOVER armed" in log_text():
                armed = True
                break
            if proc.poll() is not None:
                break
            time.sleep(2)
        print(f"channels armed: {armed}")
        if not armed:
            print("---- app console log ----")
            print(log_text()[-4000:])
            raise SystemExit("hover channels never armed "
                             "(canvas never appeared?)")

        # Let the board finish loading, then sweep the host mouse.
        time.sleep(5)
        pilot_run = subprocess.run([pilot], capture_output=True,
                                   text=True, timeout=120)
        with open(os.path.join(out_dir, "pilot.log"), "w") as f:
            f.write(pilot_run.stdout + pilot_run.stderr)
        print(f"pilot exit: {pilot_run.returncode}")
        time.sleep(3)

        shot = os.path.join(out_dir, "hover.png")
        simctl("io", udid, "screenshot", shot, check=False)
        simctl("terminate", udid, APP_ID, check=False)
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
        log_file.close()

        text = log_text()
        summaries = SUMMARY_RE.findall(text)
        counts = tuple(int(v) for v in summaries[-1]) if summaries else (0, 0, 0)
        armed_channels = sorted(set(re.findall(
            r"PADCB-HOVER armed ch=(\d)", text)))
        print(f"armed markers: channels {armed_channels}")
        print(f"final hover counts: ch1={counts[0]} ch2={counts[1]} "
              f"ch3={counts[2]} (from {len(summaries)} summaries)")
        with open(os.path.join(out_dir, "verdict.txt"), "w") as f:
            f.write(f"armed={armed_channels}\n"
                    f"counts ch1={counts[0]} ch2={counts[1]} "
                    f"ch3={counts[2]}\n")
        if counts == (0, 0, 0):
            print("---- app console log (tail) ----")
            print(text[-4000:])
            raise SystemExit("ZERO hover events on every channel")
        print("HOVER EXERCISE: at least one channel delivered "
              "events in the simulator")
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", udid],
                       capture_output=True)
        subprocess.run(["xcrun", "simctl", "delete", udid],
                       capture_output=True)


if __name__ == "__main__":
    main()
