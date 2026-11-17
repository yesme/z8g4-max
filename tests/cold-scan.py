#!/usr/bin/env python3
import errno
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import tempfile
from unittest import mock

requests = Path(tempfile.mkdtemp())
os.environ["Z8_COLD_HEALTH_STATE"] = str(requests)
loader = importlib.machinery.SourceFileLoader("scanner", "z8-kit/storage/z8-cold-scan")
spec = importlib.util.spec_from_loader(loader.name, loader)
scanner = importlib.util.module_from_spec(spec)
loader.exec_module(scanner)
sector = scanner.SECTOR
size = 2 * scanner.READ_SIZE
bad = 5 * sector
transient = 7 * sector
fd = 123
failures = {}
writes = []
logs = []


def read(handle, buffers, offset):
    assert handle == fd
    buffer, = buffers
    assert offset % sector == 0
    if len(buffer) > sector and offset == 0:
        raise OSError(media_errno, "Injected coarse read error")
    if len(buffer) == sector and failures.get(offset, 0):
        failures[offset] -= 1
        raise OSError(media_errno, "Injected sector read error")
    buffer[:] = bytes(len(buffer)) if offset == bad else b"a" * len(buffer)
    return len(buffer)


def write(handle, data, offset):
    assert handle == fd and len(data) == sector and data[:] == bytes(sector)
    writes.append(offset)
    return sector


for media_errno in (errno.EIO, errno.ENODATA):
    failures.update({bad: 2, transient: 1})
    writes.clear()
    logs.clear()
    with mock.patch.object(scanner.os, "preadv", side_effect=read), \
            mock.patch.object(scanner.os, "pwrite", side_effect=write), \
            mock.patch.object(scanner.os, "fsync") as flush:
        assert scanner.scan(fd, size, logs.append) == 1
        assert writes == [bad]
        assert logs == [f"logical_offset={bad} bytes_zeroed={sector}"]
        flush.assert_called_once_with(fd)

with mock.patch.object(scanner.os, "preadv", side_effect=OSError(errno.ENODEV, "device removed")), \
        mock.patch.object(scanner.os, "pwrite") as writes:
    try:
        scanner.scan(fd, size)
    except OSError as exc:
        assert exc.errno == errno.ENODEV
    else:
        raise AssertionError("Device removal should fail the scan")
    writes.assert_not_called()

with mock.patch.object(scanner.os, "preadv", side_effect=OSError(errno.EIO, "persistent EIO")), \
        mock.patch.object(scanner.os, "pwrite", return_value=sector), \
        mock.patch.object(scanner.os, "fsync"):
    try:
        scanner.scan(fd, sector)
    except OSError as exc:
        assert exc.errno == errno.EIO
    else:
        raise AssertionError("Failed readback should fail the scan")

# A finished scan closes the health check's request only if no newer evidence touched it meanwhile.
request = requests / "scan-owed-sata1"
assert scanner.request_stamp("sata1") is None
scanner.settle("sata1", None)
request.write_text("2 pending sectors\n")
os.utime(request, ns=(1_000, 1_000))
stamp = scanner.request_stamp("sata1")
os.utime(request, ns=(2_000, 2_000))
scanner.settle("sata1", stamp)
assert request.exists()
scanner.settle("sata1", scanner.request_stamp("sata1"))
assert not request.exists()


def run_scan(outcome, shards=range(8), evidence=False):
    """Scan sata1 with an open request; return the exit status and whether the request is still open."""
    def scan_disk(group):
        assert group == [f"sata1-{i}" for i in range(8)]
        if evidence:
            os.utime(request, ns=(3_000, 3_000))
        return outcome

    request.write_text("2 pending sectors\n")
    listing = "".join(f"sata1-{i}\n" for i in shards) + "sata0-0\n"
    with mock.patch.object(scanner.subprocess, "check_output", return_value=listing), \
            mock.patch.object(scanner, "scan_disk", side_effect=scan_disk):
        return scanner.main("sata1"), request.exists()


assert run_scan(0) == (0, False)
assert run_scan(1) == (1, False)
assert run_scan(2) == (2, True)
assert run_scan(0, shards=range(7)) == (2, True)
assert run_scan(1, evidence=True) == (1, True)

print("Cold scan tests passed: persistent EIO, transient failure, write target, readback, device loss "
      "and scan requests.")
