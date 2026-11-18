#!/usr/bin/env python3
"""Check the patched bb-storage image wiring and the I4 interleaved-append plan against the cold shard geometry."""

from collections import defaultdict
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "z8-kit/buildbarn"
ZONE = 256 << 20
GIB = 1 << 30


def cold_geometry():
    """Return blocks old/current/new/spare of a cold shard and the size of a shard and a block."""
    jsonnet = (BASE / "tiered-cache.jsonnet").read_text()
    new, old, current = map(int, re.search(
        r"disk\('/store/cold/' \+ name,[^)]*?,\s*(\d+), chunking, (\d+), (\d+),", jsonnet, re.S).groups())
    spare = int(re.search(r"spareBlocks: (\d+)", (BASE / "disk.libsonnet").read_text()).group(1))
    cold = (ROOT / "z8-kit/storage/z8-cold").read_text()
    zones, shards_per_disk = (int(re.search(pattern, cold).group(1)) for pattern in (
        r"DATA_BYTES = (\d+) \* 256 \* 1024\*\*2", r"SHARDS_PER_DISK = (\d+)"))
    blocks = old + current + new + spare
    assert zones % blocks == 0, "A block must be a whole number of zones."
    return old, current, new, shards_per_disk, zones * ZONE, zones // blocks * ZONE


def image():
    old, current, new, _, _, _ = cold_geometry()
    compose = (BASE / "compose.tiered.yaml").read_text()
    tag = re.search(r"^    image: (\S+)$", compose, re.M).group(1)
    commit = re.fullmatch(r"z8/bb-storage:([0-9a-f]{7})-sequential-fill", tag).group(1)
    assert "pull_policy: never" in compose and "dockerfile: Dockerfile.storage" in compose

    dockerfile = (BASE / "Dockerfile.storage").read_text()
    fetched = re.search(r"git fetch --depth=1 https://github.com/buildbarn/bb-storage.git ([0-9a-f]{40}) ", dockerfile)
    assert fetched.group(1).startswith(commit)
    # The final stage starts from the image the unpatched caches of this kit run.
    upstream = re.search(r"^    image: (ghcr\.io/buildbarn/bb-storage:\S+)$", (BASE / "compose.yaml").read_text(), re.M).group(1)
    assert f"-{commit}@sha256:" in upstream and f"\nFROM {upstream}\n" in dockerfile
    for line in ("COPY storage-sequential-fill.patch /tmp/",
                 "COPY storage-sequential-fill_test.go z8/sequential_fill_test.go",
                 "git apply /tmp/storage-sequential-fill.patch", "go test ./z8/"):
        assert line in dockerfile, line
    assert dockerfile.index("go test ./z8/") < dockerfile.index("go build")

    patch = (BASE / "storage-sequential-fill.patch").read_text()
    assert re.findall(r"^\+\+\+ b/(\S+)$", patch, re.M) == [
        "pkg/blobstore/configuration/cs_blob_access_creator.go",
        "pkg/blobstore/local/block_list_growth_policy.go"]
    removed = [line for line in patch.splitlines() if line.startswith("-") and not line.startswith("---")]
    assert removed == ["-\treturn local.NewImmutableBlockListGrowthPolicy(currentBlocks, newBlocks), nil"]

    test = (BASE / "storage-sequential-fill_test.go").read_text()
    constants = dict(re.findall(r"^\t(oldBlocks|currentBlocks|newBlocks)\s+= (\d+)$", test, re.M))
    assert {name: int(value) for name, value in constants.items()} == {
        "oldBlocks": old, "currentBlocks": current, "newBlocks": new}


def interleaved_plan():
    _, _, new, shards_per_disk, shard_bytes, block = cold_geometry()
    plan = subprocess.check_output(["bash", ROOT / "z8-kit/storage/cas-aging.sh", "plan"], text=True)
    jobs = defaultdict(list)
    for line in plan.splitlines():
        phase, slot, name, device, offset, size, flow = line.split("\t")
        jobs[phase, int(slot)].append((name, device, int(offset), int(size), int(flow)))
    assert set(jobs) == {(phase, slot) for phase in ("baseline", "interleaved") for slot in range(4)}

    script = (ROOT / "z8-kit/storage/cas-aging.sh").read_text()
    first, count = (int(re.search(pattern, script, re.M).group(1))
                    for pattern in (r"^first_block=(\d+)$", r"^test_blocks=(\d+)$"))
    window = range(first * block, (first + count) * block)
    assert window.start >= 128 * GIB, "The window must clear the range the sequential test overwrites."
    assert window.stop <= shard_bytes

    for slot in range(4):
        devices = [f"/dev/mapper/z8-cold-sata{slot}-{shard}" for shard in range(shards_per_disk)]
        baseline, interleaved = jobs["baseline", slot], jobs["interleaved", slot]
        # One writable position per new block of every shard, in three different blocks, 4:2:1.
        assert len(interleaved) == shards_per_disk * new == 24
        assert [job[1] for job in baseline] == devices
        assert [job[1] for job in interleaved] == [device for device in devices for _ in range(new)]
        for shard in range(shards_per_disk):
            heads = interleaved[shard * new:(shard + 1) * new]
            assert [offset // block for _, _, offset, _, _ in heads] == [first, first + 1, first + 2]
            assert [flow for *_, flow in heads] == [4, 2, 1]
            assert [size * 4 // heads[0][3] for _, _, _, size, _ in heads] == [4, 2, 1]
            ranges = sorted((offset, offset + size) for _, _, offset, size, _ in heads + [baseline[shard]])
            for (start, stop), (following, _) in zip(ranges, ranges[1:] + [(window.stop, 0)]):
                assert start % ZONE == 0 and (stop - start) % ZONE == 0
                assert window.start <= start < stop <= following, "Ranges must not overlap or leave the window."
            assert all(stop - start <= block for start, stop in ranges[:new]), "A head must stay inside its block."
            assert baseline[shard][4] == 0 and baseline[shard][3] == sum(size for _, _, _, size, _ in heads)


if __name__ == "__main__":
    image()
    interleaved_plan()
    print("Cold sequential-fill tests passed.")
