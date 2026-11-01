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

    def try_create(label, candidates):
        """First candidate (in preference order) the runtime accepts.
        The device-type list includes legacy types (e.g. iPhone 6s)
        that current runtimes refuse as 'Incompatible device', so
        creation itself is the compatibility test."""
        for dtype in candidates:
            r = subprocess.run(
                ["xcrun", "simctl", "create", f"Gate-{label}",
                 dtype["identifier"], runtime],
                capture_output=True, text=True)
            if r.returncode == 0 and r.stdout.strip():
                print(f"{label}: device type {dtype['name']}")
                return r.stdout.strip()
            print(f"{label}: {dtype['name']} refused: "
                  f"{(r.stderr or r.stdout).strip().splitlines()[-1] if (r.stderr or r.stdout).strip() else 'unknown error'}")
        raise SystemExit(f"no usable {label} device type for this runtime")

    def iphone_candidates():
        import re
        cands = [t for t in types if t["name"].startswith("iPhone")]
        def model(t):
            m = re.search(r"iPhone\s+(\d+)", t["name"])
            return int(m.group(1)) if m else -1
        # Newest model first — those are the types a current runtime
        # is guaranteed to accept.
        return sorted(cands, key=model, reverse=True)

    def ipad_candidates():
        cands = [t for t in types if t["name"].startswith("iPad")]
        def family_rank(t):
            for rank, marker in enumerate(("Pro", "Air", "mini")):
                if marker in t["name"]:
                    return rank
            return 3
        return sorted(cands, key=family_rank)

    for label, candidates in (("iphone", iphone_candidates()),
                              ("ipad", ipad_candidates())):
        if not candidates:
            raise SystemExit(f"no simulator device types for {label}")
        udid = try_create(label, candidates)
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
