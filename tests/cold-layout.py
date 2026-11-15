#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest import mock

loader = importlib.machinery.SourceFileLoader("cold", "z8-kit/storage/z8-cold")
spec = importlib.util.spec_from_loader(loader.name, loader)
cold = importlib.util.module_from_spec(spec)
loader.exec_module(cold)

data_bytes = 1_749_930_737_664
index_bytes = 28_454_158_336
assert cold.DATA_BYTES == data_bytes and cold.INDEX_BYTES == index_bytes
for kind, length in [("z8-cold-", data_bytes), ("z8-index-", index_bytes)]:
    offsets = [(parent, off, size) for name, parent, off, size in cold.slice_specs(cold.DISKS)
               if name.startswith(kind)]
    for parent in {p for p, _, _ in offsets}:
        slices = [(off, size) for p, off, size in offsets if parent == p]
        assert slices == [(i * length, length) for i in range(len(slices))]
        assert all(off % (256 * 1024**2) == 0 for off, _ in slices)
assert 8 * data_bytes == 13_999_445_901_312
assert 32 * index_bytes == 910_533_066_752

with TemporaryDirectory() as temp:
    root = Path(temp)
    cold.CONFIG = root / "etc"
    cold.RUNTIME = root / "run"
    cold.STORE = root / "tiered"
    for parent in (cold.CONFIG, cold.RUNTIME, cold.STORE):
        parent.mkdir()
    layout = cold.CONFIG / "cold-layout.json"
    args = lambda action, disk=None: SimpleNamespace(action=action, disk=disk)

    cold.main(args("init"))
    assert cold.load(layout)["active"] == []
    cold.write_json(layout, {**cold.GEOMETRY, "active": list(cold.SHARDS)})
    cold.main(args("init"))
    assert cold.load(layout)["active"] == list(cold.SHARDS)
    with mock.patch.object(cold, "available_disks", return_value=["sata0", "sata2", "sata3"]), \
            mock.patch.object(cold, "check_devices") as devices:
        cold.main(args("map"))
        active = cold.load(cold.RUNTIME / "cold-layout.json")["active"]
        assert len(active) == 24 and all(not s.startswith("sata1-") for s in active)
        configured = json.loads((cold.RUNTIME / "compose.json").read_text())
        mapped = configured["services"]["cache"]["devices"]
        assert len(mapped) == 48 and all("sata1-" not in x for x in mapped)
        devices.assert_called_once_with(["sata0", "sata2", "sata3"], create=True)
        cold.main(args("check"))
        cold.write_json(cold.RUNTIME / "compose.json", {})
        try:
            cold.main(args("check"))
        except ValueError as exc:
            assert "inventory changed" in str(exc)
        else:
            raise AssertionError("Startup accepted an altered Compose device list")

    def interrupted(command, **kwargs):
        if command[0] == "blkdiscard":
            raise OSError("simulated interrupted write")

    with mock.patch.object(cold, "available_disks", return_value=list(cold.DISKS)), \
            mock.patch.object(cold, "check_devices"), \
            mock.patch.object(cold, "require_cache_stopped"), \
            mock.patch.object(cold, "run", return_value="/ xfs"), \
            mock.patch.object(cold.subprocess, "run", side_effect=interrupted):
        # Simulate interruption after writing the disabled manifest.
        try:
            cold.main(args("reset", "sata2"))
        except OSError:
            assert all(not s.startswith("sata2-") for s in cold.load(layout)["active"])
        else:
            raise AssertionError("Interrupted reset unexpectedly succeeded")

    table = "0 3417833472 linear 253:2 0"
    with mock.patch.object(cold, "backing_name", return_value="253:2"), \
            mock.patch.object(cold, "dm_uuid", return_value="z8-cold-sata0-0"), \
            mock.patch.object(cold, "run", side_effect=[table, str(cold.DATA_BYTES - 4096)]):
        try:
            cold.check_devices(["sata0"])
        except ValueError as exc:
            assert "Unexpected device" in str(exc)
        else:
            raise AssertionError("Startup accepted mismatched mapper geometry")

print("Cold layout tests passed: slices, degraded mapping, recovery ordering and startup geometry guards.")
