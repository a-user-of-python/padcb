#!/usr/bin/env python3
"""Device-gate proof (v3.1): boot an iPhone-idiom and an iPad-idiom
simulator, install the simulator build of PadCB on both, launch it, and
screenshot the first screen of each.

Expected result:
- iPhone: ONLY the notice — "You need an iPad for this to work".
- iPad:   the normal PadCB home screen (Schematic Editor / PCB Editor).

Usage: device_gate_check.py <PadCB.app> <output-dir>
"""
import json
import os
import subprocess
import sys
import time

APP_ID = "com.user.padcb"


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

    runtimes = json.loads(simctl("list", "runtimes", "-j"))["runtimes"]
    ios = [r for r in runtimes
           if r["name"].startswith("iOS") and r.get("isAvailable", True)]
    if not ios:
        raise SystemExit("no available iOS simulator runtime")
    runtime = ios[-1]["identifier"]
    print(f"runtime: {ios[-1]['name']} ({runtime})")

    types = json.loads(simctl("list", "devicetypes", "-j"))["devicetypes"]

    def pick(substr):
        cands = [t for t in types if substr in t["name"]]
        if not cands:
            raise SystemExit(f"no simulator device type matching {substr!r}")
        return cands[-1]

    for label, dtype in (("iphone", pick("iPhone")), ("ipad", pick("iPad"))):
        print(f"{label}: device type {dtype['name']}")
        udid = simctl("create", f"Gate-{label}", dtype["identifier"], runtime)
        print(f"{label}: created {udid}")
        simctl("boot", udid)
        simctl("bootstatus", udid, "-b")
        simctl("install", udid, app_path)
        simctl("launch", udid, APP_ID)
        # Give the first screen time to settle (on iPad the home screen
        # renders immediately; library indexing continues in background).
        time.sleep(10)
        shot = os.path.join(out_dir, f"{label}.png")
        simctl("io", udid, "screenshot", shot)
        print(f"{label}: screenshot -> {shot}")
        simctl("shutdown", udid, check=False)


if __name__ == "__main__":
    main()
