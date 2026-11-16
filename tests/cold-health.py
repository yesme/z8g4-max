#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from unittest import mock

tmp = Path(tempfile.mkdtemp())
os.environ.update(Z8_STORAGE_CONFIG=str(tmp), STATE_DIRECTORY=str(tmp / "state"))
loader = importlib.machinery.SourceFileLoader("health", "z8-kit/storage/z8-cold-health")
spec = importlib.util.spec_from_loader(loader.name, loader)
health = importlib.util.module_from_spec(spec)
loader.exec_module(health)
(tmp / "state").mkdir()
(tmp / "hybrid.tsv").write_text("# comment\n" + "".join(
    f"hc620-{i}\t/dev/disk/by-id/ata-disk{i}\tdmz-sata{i}\n" for i in range(7)))
devices = health.cold_devices()
assert list(devices) == ["sata0", "sata1", "sata2", "sata3"]


def report(pending=0, failures=(), running=False):
    table = [{"status": {"value": 0, "passed": True}, "lifetime_hours": 10}]
    table += [{"status": {"value": 0x70 | 9, "passed": False}, "lifetime_hours": hours, "lba": lba}
              for hours, lba in failures]
    return {
        "ata_smart_attributes": {"table": [{"id": 5, "raw": {"value": 3}}, {"id": 197, "raw": {"value": pending}}]},
        "ata_smart_self_test_log": {"standard": {"table": table}},
        "ata_smart_data": {"self_test": {"status": {"value": 0xF9 if running else 0}}},
    }


# A used disk's old failed self-test is recorded without a scan; current pending sectors are not.
assert health.reasons(report(failures=[(5, 99)]), None, False) == ([], {"pending": 0, "selftests": [[5, 99]]})
assert health.reasons(report(pending=2), None, False)[0] == ["2 pending sectors"]
known = {"pending": 2, "selftests": [[5, 99]]}
assert health.reasons(report(pending=2, failures=[(5, 99)]), known, False)[0] == []
assert health.reasons(report(pending=3, failures=[(5, 99), (20, 7)]), known, True)[0] == [
    "kernel medium error", "self-test read failure", "3 pending sectors"]
assert health.selftest_running(report(running=True)) and not health.selftest_running(report())

reports = {"/dev/disk/by-id/ata-disk0": report(), "/dev/disk/by-id/ata-disk1": report(pending=1),
           "/dev/disk/by-id/ata-disk2": report(), "/dev/disk/by-id/ata-disk3": report(running=True)}
calls = []


def run(command, **kwargs):
    calls.append(command)
    if command[:2] == ["smartctl", "--json=c"]:
        if command[-1].endswith("disk2") and fail_disk2:
            return subprocess.CompletedProcess(command, 2, "", "open failed")
        # Bit 6 only reports an old error log entry.
        return subprocess.CompletedProcess(command, 64, json.dumps(reports[command[-1]]), "")
    return subprocess.CompletedProcess(command, 0, "", "")


journal = "critical medium error, dev sdc, sector 8 op 0x0:(READ)\nI/O error, dev sdd, sector 1\n"
names = {f"/dev/disk/by-id/ata-disk{i}": f"/dev/sd{'cdef'[i]}" for i in range(4)}
with mock.patch.object(health.subprocess, "run", side_effect=run), \
        mock.patch.object(health.subprocess, "check_output", return_value=journal), \
        mock.patch.object(health.os.path, "realpath", side_effect=names.__getitem__):
    fail_disk2 = True
    assert health.check(devices) == 1
    started = [command[-1] for command in calls if command[0] == "systemctl"]
    assert started == ["z8-cold-scan@sata0.service", "z8-cold-scan@sata1.service"], started
    state = json.loads((tmp / "state" / "state.json").read_text())
    assert state["sata1"]["pending"] == 1 and "sata2" not in state
    calls.clear()
    fail_disk2 = False
    journal = ""
with mock.patch.object(health.subprocess, "run", side_effect=run), \
        mock.patch.object(health.subprocess, "check_output", return_value=""), \
        mock.patch.object(health.os.path, "realpath", side_effect=names.__getitem__):
    assert health.check(devices) == 0
    assert not [command for command in calls if command[0] == "systemctl"]
    calls.clear()
    assert health.selftest(devices) == 0
    tests = [command[-1] for command in calls if "-t" in command]
    assert tests == [f"/dev/disk/by-id/ata-disk{i}" for i in range(3)], tests
print("Cold health tests passed: evidence-triggered scans, first-run baseline, and self-test start.")
