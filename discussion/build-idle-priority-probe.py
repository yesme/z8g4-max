#!/usr/bin/env python3
"""One CPU shared by an "inference" group (weight 200) and a "build" group that is either weight 100 or idle."""
import os
import subprocess
import sys
import time

ROOT = "/sys/fs/cgroup/cpu"
CPU = 3
SECONDS = 6

# Every job waits for the same start time and counts only the CPU time of its own measured window.
HOG = """
import time
while time.monotonic() < {start}:
    time.sleep(0.001)
used = time.process_time()
while time.monotonic() < {start} + {seconds}:
    pass
print(time.process_time() - used)
"""
# Bursts of work separated by short sleeps, like worker threads waiting for the next graph node.
BURSTY = """
import time
late = []
done = 0
while time.monotonic() < {start}:
    time.sleep(0.001)
while time.monotonic() < {start} + {seconds}:
    stop = time.perf_counter_ns() + 300_000
    while time.perf_counter_ns() < stop:
        done += 1
    before = time.perf_counter_ns()
    time.sleep(0.0003)
    late.append((time.perf_counter_ns() - before) / 1000 - 300)
late.sort()
print(done, late[len(late) // 2], late[int(len(late) * 0.99)], late[-1])
"""


def group(name, shares, idle):
    path = f"{ROOT}/z8t-{name}"
    os.makedirs(path, exist_ok=True)
    with open(f"{path}/cpu.idle", "w") as f:
        f.write(str(idle))
    if not idle:
        with open(f"{path}/cpu.shares", "w") as f:
            f.write(str(shares))
    return path


def spawn(path, code, start):
    enter = f"import os\nopen('{path}/cgroup.procs', 'w').write(str(os.getpid()))\nos.sched_setaffinity(0, {{{CPU}}})\n"
    return subprocess.Popen([sys.executable, "-I", "-c", enter + code.format(seconds=SECONDS, start=start)],
                            stdout=subprocess.PIPE, text=True)


def run(build_mode):
    infer = group("infer", 2048, 0)
    build = group("build", 1024, 1 if build_mode == "idle" else 0)
    results = {}
    for name, infer_code in (("steady", HOG), ("bursty", BURSTY)):
        start = time.monotonic() + 0.5
        jobs = [spawn(infer, infer_code, start)]
        if build_mode != "none":
            jobs.append(spawn(build, HOG, start))
        results[name] = [job.communicate()[0].split() for job in jobs]
    return results


for mode in ("none", "weight", "idle"):
    r = run(mode)
    steady = float(r["steady"][0][0]) / SECONDS
    build = float(r["steady"][1][0]) / SECONDS if mode != "none" else 0.0
    done, p50, p99, worst = (float(x) for x in r["bursty"][0])
    build_bursty = float(r["bursty"][1][0]) / SECONDS if mode != "none" else 0.0
    print(f"{mode:6s} steady: inference {steady:5.1%} build {build:5.1%} | bursty: work {done / 1e6:6.2f}M "
          f"wake late p50 {p50:6.0f} us p99 {p99:7.0f} us max {worst:7.0f} us, build {build_bursty:5.1%}")
for name in ("infer", "build"):
    os.rmdir(f"{ROOT}/z8t-{name}")
