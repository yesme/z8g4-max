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
    return subprocess.CompletedProcess(command, int(command[0] == "systemctl" and fail_start), "", "")


boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip().replace("-", "")
cursor = tmp / "state/journal.cursor"


def check(journal="", boot=None, next_cursor="next"):
    """Run one daily check and return its status, the scans it requested and the open requests."""
    calls.clear()
    def run_with_journal(command, **kwargs):
        if command[0] != "journalctl":
            return run(command, **kwargs)
        assert "_TRANSPORT=kernel" in command and "-k" not in command and "-b" not in command
        candidate = Path(next(arg.split("=", 1)[1] for arg in command if arg.startswith("--cursor-file=")))
        assert candidate != cursor
        if cursor.exists():
            assert candidate.read_text() == cursor.read_text()
        candidate.write_text(next_cursor)
        for message in journal.splitlines():
            print(json.dumps({"MESSAGE": message, "_BOOT_ID": boot or boot_id}), file=kwargs["stdout"])
        return subprocess.CompletedProcess(command, 0)

    with mock.patch.object(health.subprocess, "run", side_effect=run_with_journal), \
            mock.patch.object(health.os.path, "realpath", side_effect=names.__getitem__):
        status = health.check(devices)
    started = [command[-1].removeprefix("z8-cold-scan@").removesuffix(".service")
               for command in calls if command[0] == "systemctl"]
    return status, started, sorted(path.name.removeprefix("scan-owed-") for path in (tmp / "state").glob("scan-owed-*"))


names = {f"/dev/disk/by-id/ata-disk{i}": f"/dev/sd{'cdef'[i]}" for i in range(4)}
fail_disk2, fail_start = True, False
assert check("critical medium error, dev sdc, sector 8 op 0x0:(READ)\nI/O error, dev sdd, sector 1\n") == (
    1, ["sata0", "sata1"], ["sata0", "sata1"])
state = json.loads((tmp / "state" / "state.json").read_text())
assert state["sata1"]["pending"] == 1 and "sata2" not in state

# The evidence is spent, but a request stays open until z8-cold-scan has covered the disk.
fail_disk2 = False
assert check() == (0, ["sata0", "sata1"], ["sata0", "sata1"])
health.scan_request("sata0").unlink()
health.scan_request("sata1").unlink()
assert check() == (0, [], [])

# A durable marker survives an unreadable SMART report and a scan that systemd refused to queue.
fail_disk2 = fail_start = True
assert check("critical medium error, dev sde, sector 8 op 0x0:(READ)\n") == (1, ["sata2"], ["sata2"])
fail_disk2 = fail_start = False
assert check() == (0, ["sata2"], ["sata2"])

# A replacement disk is a first run: its pending sectors count even below the old disk's baseline,
# and the old disk's open request is dropped.
health.scan_request("sata0").write_text("old disk\n")  # Legacy marker with no by-id.
reports["/dev/disk/by-id/ata-disk0"] = {**report(), "serial_number": "NEW0"}
reports["/dev/disk/by-id/ata-disk1"] = {**report(pending=1), "serial_number": "NEW1"}
assert check() == (0, ["sata1", "sata2"], ["sata1", "sata2"])
assert json.loads((tmp / "state" / "state.json").read_text())["sata1"]["serial"] == "NEW1"

# Yesterday's sdc was sata3. Today it is sata0. A failed marker write must leave the cursor intact.
old_boot = "1" * 32
(health.STATE / f"devices-{old_boot}.json").write_text(json.dumps({"sdc": devices["sata3"]}))
previous_cursor = cursor.read_text()
disk_error = "critical medium error, dev sdc, sector 8"
publish = health.publish


def full_disk(path, content):
    if path == health.scan_request("sata3"):
        raise OSError("fixture disk full")
    publish(path, content)


with mock.patch.object(health, "publish", side_effect=full_disk):
    try:
        check(disk_error, old_boot, "later")
    except OSError as error:
        assert "fixture disk full" in str(error)
    else:
        raise AssertionError("Expected failed marker write")
assert cursor.read_text() == previous_cursor
assert check(disk_error, old_boot, "later") == (0, ["sata1", "sata2", "sata3"], ["sata1", "sata2", "sata3"])
assert cursor.read_text() == "later"
assert "sata0" not in check(disk_error, "2" * 32)[1]

# A new disk can report a kernel error while SMART is unavailable. When its new
# serial first becomes readable, preserve the pending request for that same by-id.
reports[devices["sata2"]]["serial_number"] = "NEW2"
assert "sata2" in check()[1]

calls.clear()
with mock.patch.object(health.subprocess, "run", side_effect=run):
    assert health.selftest(devices) == 0
tests = [command[-1] for command in calls if "-t" in command]
assert tests == [f"/dev/disk/by-id/ata-disk{i}" for i in range(3)], tests
print("Cold health tests passed: evidence-triggered scans, open scan requests, first-run baseline and self-test start.")
