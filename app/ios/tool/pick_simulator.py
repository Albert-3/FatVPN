#!/usr/bin/env python3
"""Picks an iPhone simulator on the newest iOS runtime and prints its UDID.

Exists because the obvious one-liner is wrong in a way that only fails on the
runner. `simctl list devicetypes` is not ordered by recency, so taking the last
entry hands you something like the iPhone 6s Plus — which `simctl create` then
refuses against a modern runtime with a bare "Incompatible device (code 403)"
and no hint that the *device* was the bad half of the pair. That is exactly how
the first version of the smoke-test step failed.

Prints three tab-separated fields on success: UDID, device name, runtime
identifier. The caller is expected to echo the last two, because "which iOS did
this actually test" is the whole reason the step is worth running — the widget
takes a different code path on 18 and up.

Exits 1 with a readable reason if the runner has no usable simulator at all,
rather than letting the step fail later on an empty UDID.
"""

import json
import re
import subprocess
import sys


def simctl(*args):
    out = subprocess.run(
        ["xcrun", "simctl", *args],
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stdout


def runtime_version(identifier):
    """(major, minor) of an iOS runtime identifier, or None if it is not iOS.

    Matches on the identifier rather than the display name: the name is
    localised and has changed shape between Xcode releases, the identifier has
    not.
    """
    match = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)", identifier)
    return (int(match.group(1)), int(match.group(2))) if match else None


def newest_existing_iphone():
    """An iPhone Xcode has already created, on the newest iOS runtime.

    Preferred over creating one: a preinstalled device is guaranteed to be a
    pairing the runner's Xcode considers valid, which is the exact thing that
    went wrong before.
    """
    devices = json.loads(simctl("list", "devices", "available", "-j"))["devices"]
    best = None
    for runtime, entries in devices.items():
        version = runtime_version(runtime)
        if version is None:
            continue
        for device in entries:
            if not device.get("isAvailable") or "iPhone" not in device["name"]:
                continue
            if best is None or version > best[0]:
                best = (version, device["udid"], device["name"], runtime)
    return best


def newest_runtime():
    runtimes = json.loads(simctl("list", "runtimes", "-j"))["runtimes"]
    usable = [
        (runtime_version(r["identifier"]), r["identifier"])
        for r in runtimes
        if r.get("isAvailable") and runtime_version(r["identifier"])
    ]
    return max(usable)[1] if usable else None


def created_iphone(runtime):
    """Creates an iPhone on [runtime], trying the most recent models first.

    Only reached when the runner ships a runtime with no devices on it. The
    ordering is a heuristic on the model number in the identifier — there is no
    compatibility list in `simctl`, so the only honest test is to try one and
    see whether it is refused.
    """
    types = json.loads(simctl("list", "devicetypes", "-j"))["devicetypes"]

    def rank(device_type):
        match = re.search(r"iPhone-(\d+)", device_type["identifier"])
        return int(match.group(1)) if match else -1

    candidates = sorted(
        (t for t in types if "iPhone" in t["name"]), key=rank, reverse=True
    )
    for device_type in candidates:
        try:
            udid = simctl(
                "create", "fatvpn-widget-test", device_type["identifier"], runtime
            ).strip()
        except subprocess.CalledProcessError:
            continue
        if udid:
            return udid, device_type["name"], runtime
    return None


def main():
    existing = newest_existing_iphone()
    if existing:
        _, udid, name, runtime = existing
        print(f"{udid}\t{name}\t{runtime}")
        return

    runtime = newest_runtime()
    if runtime is None:
        sys.exit("No available iOS simulator runtime on this machine.")
    made = created_iphone(runtime)
    if made is None:
        sys.exit(f"No iPhone device type could be created on {runtime}.")
    udid, name, runtime = made
    print(f"{udid}\t{name}\t{runtime}")


if __name__ == "__main__":
    main()
