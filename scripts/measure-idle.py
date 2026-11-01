#!/usr/bin/env python3
"""Sample an already idle macOS app; RSS is not Instruments physical footprint."""
import argparse
import datetime
import hashlib
import json
import platform
from pathlib import Path
import statistics
import subprocess
import time


def cpu_seconds(value):
    fields = value.split(":")
    return sum(float(part) * 60 ** index for index, part in enumerate(reversed(fields)))


def sample(pid):
    output = subprocess.check_output(
        ["/bin/ps", "-p", str(pid), "-o", "%cpu=,rss=,time="], text=True
    ).split()
    if len(output) != 3:
        raise RuntimeError("The target process is no longer available")
    return {"cpu_percent_ps": float(output[0]), "rss_kib": int(output[1]),
            "cpu_seconds": cpu_seconds(output[2])}


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("pid", type=int)
parser.add_argument("--seconds", type=int, default=30)
parser.add_argument("--warmup", type=int, default=30)
parser.add_argument("--fixture", default="unspecified")
parser.add_argument("--executable", type=Path, help="Record the tested binary's SHA-256")
args = parser.parse_args()
if args.pid <= 0 or not 5 <= args.seconds <= 3600 or not 0 <= args.warmup <= 60:
    parser.error("Use a positive PID, duration 5–3600 seconds, and warmup 0–60 seconds")

sample(args.pid)
time.sleep(args.warmup)
started = time.monotonic()
samples = [sample(args.pid)]
for index in range(1, args.seconds + 1):
    time.sleep(max(0, started + index - time.monotonic()))
    samples.append(sample(args.pid))
elapsed = time.monotonic() - started
cpu_delta = samples[-1]["cpu_seconds"] - samples[0]["cpu_seconds"]
print(json.dumps({
    "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "platform": platform.platform(), "pid": args.pid, "fixture": args.fixture,
    "executable_sha256": hashlib.sha256(args.executable.read_bytes()).hexdigest() if args.executable else None,
    "duration_seconds": elapsed, "sample_count": len(samples),
    "warmup_seconds": args.warmup,
    "cpu_seconds_delta": cpu_delta,
    "average_cpu_percent_one_core": 100 * cpu_delta / elapsed,
    "rss_median_mib": statistics.median(s["rss_kib"] for s in samples) / 1024,
    "rss_peak_mib": max(s["rss_kib"] for s in samples) / 1024,
    "notes": "ps CPU time has limited precision. RSS is resident pages, not physical footprint. Only the app process is sampled; no Git operation should run during sampling.",
    "samples": samples,
}, indent=2))
