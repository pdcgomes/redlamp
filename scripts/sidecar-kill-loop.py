#!/usr/bin/env python3
"""Kills a sidecar writer at random moments and checks what each kill left (a manual stress check).

Builds scripts/sidecar-kill-save.swift against the Debug RedlampDocument framework in DERIVED_DATA
(build/DerivedData), then for each kill starts the writer, sends SIGKILL 30-250 ms later and runs
the checker. Prints the verdicts and the hidden leftovers in the folder at the end; exits 1 when a
kill left anything but the old or new edit, whole.

usage: scripts/sidecar-kill-loop.py [update|fresh|convert] [kills] [seed]
"""
import collections
import os
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRODUCTS = os.path.join(os.environ.get("DERIVED_DATA", os.path.join(ROOT, "build/DerivedData")),
                        "Build/Products/Debug")
ACCEPTED = ("ok", "ok-absent", "ok-history-ahead")

mode = sys.argv[1] if len(sys.argv) > 1 else "update"
kills = int(sys.argv[2]) if len(sys.argv) > 2 else 200
random.seed(int(sys.argv[3]) if len(sys.argv) > 3 else 1)

work = tempfile.mkdtemp(prefix="sidecar-kill-")
binary = os.path.join(work, "sidecar-kill-save")
subprocess.run(["xcrun", "swiftc", "-O", os.path.join(ROOT, "scripts/sidecar-kill-save.swift"), "-o", binary,
                "-F", PRODUCTS, "-framework", "RedlampDocument", "-framework", "RedlampEngineAPI",
                "-Xlinker", "-rpath", "-Xlinker", PRODUCTS], check=True)
folder = os.path.join(work, mode)
os.makedirs(folder)
image = os.path.join(folder, "IMG_0001.ARW")
with open(image, "w") as raw:
    raw.write("raw")

verdicts = collections.Counter()
problems = []
for kill in range(kills):
    writer = subprocess.Popen([binary, "writer", image, mode], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    time.sleep(random.uniform(0.03, 0.25))
    writer.send_signal(signal.SIGKILL)
    writer.wait()
    result = subprocess.run([binary, "check", image], capture_output=True, text=True).stdout.strip()
    verdict = result.split(" ")[0]
    verdicts[verdict] += 1
    if verdict not in ACCEPTED:
        problems.append(f"{kill}: {result}")

leftovers = [name for name in os.listdir(folder) if name.startswith(".")]
print(f"mode={mode} kills={kills} {dict(verdicts)}; hidden leftovers at the end: {len(leftovers)}")
for line in problems[:10]:
    print("  ", line)
shutil.rmtree(work, ignore_errors=True)
sys.exit(1 if problems or leftovers else 0)
