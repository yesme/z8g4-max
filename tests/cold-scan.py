#!/usr/bin/env python3
import errno
import importlib.machinery
import importlib.util
from unittest import mock

loader = importlib.machinery.SourceFileLoader("scanner", "z8-kit/storage/z8-cold-scan")
spec = importlib.util.spec_from_loader(loader.name, loader)
scanner = importlib.util.module_from_spec(spec)
loader.exec_module(scanner)
sector = scanner.SECTOR
size = 2 * scanner.READ_SIZE
bad = 5 * sector
transient = 7 * sector
fd = 123
failures = {bad: 2, transient: 1}
writes = []
logs = []


def read(handle, buffers, offset):
    assert handle == fd
    buffer, = buffers
    assert offset % sector == 0
    if len(buffer) > sector and offset == 0:
        raise OSError(errno.EIO, "Injected coarse read error")
    if len(buffer) == sector and failures.get(offset, 0):
        failures[offset] -= 1
        raise OSError(errno.EIO, "Injected sector read error")
    buffer[:] = bytes(len(buffer)) if offset == bad else b"a" * len(buffer)
    return len(buffer)


def write(handle, data, offset):
    assert handle == fd and len(data) == sector and data[:] == bytes(sector)
    writes.append(offset)
    return sector


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

print("Cold scan tests passed: persistent EIO, transient failure, write target, readback and device loss.")
