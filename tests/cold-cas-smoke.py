#!/usr/bin/env python3
"""Exercise the pinned cache on disposable bare devices or probe I5 degradation."""

import argparse
from contextlib import ExitStack
from hashlib import sha256
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "z8-kit/buildbarn"
CAS = "build.bazel.remote.execution.v2.ContentAddressableStorage"


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def vint(number):
    result = bytearray()
    while number >= 128:
        result.append((number % 128) + 128)
        number //= 128
    result.append(number)
    return bytes(result)


def unpack_int(data, position):
    value = 0
    for shift in range(0, 70, 7):
        byte = data[position]
        position += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, position
    raise ValueError("Invalid protobuf varint")


def fields(data):
    position = 0
    while position < len(data):
        tag, position = unpack_int(data, position)
        wire = tag % 8
        number, position = unpack_int(data, position)
        if wire == 0:
            yield tag // 8, number
        elif wire == 2:
            yield tag // 8, data[position:position + number]
            position += number
        else:
            raise ValueError(f"Unexpected protobuf wire type {wire}")


def part(tag, data):
    return vint(tag * 8 + 2) + vint(len(data)) + data


def digest(data):
    return part(1, sha256(data).hexdigest().encode()) + b"\x10" + vint(len(data))


def rpc(port, method, payload):
    result = subprocess.run(
        ["curl", "--http2-prior-knowledge", "--silent", "--show-error", "--fail",
         "--max-time", "15", "-H", "Content-Type: application/grpc", "-H", "TE: trailers",
         "--data-binary", "@-", f"http://127.0.0.1:{port}/{CAS}/{method}"],
        input=struct.pack(">BI", 0, len(payload)) + payload, capture_output=True, check=True,
    ).stdout
    if len(result) < 5 or result[0] != 0 or int.from_bytes(result[1:5], "big") != len(result) - 5:
        raise RuntimeError(f"Invalid gRPC response to {method}: {result[:64]!r}")
    return result[5:]


def update(port, blobs):
    response = rpc(port, "BatchUpdateBlobs", b"".join(part(2, part(1, digest(x)) + part(2, x)) for x in blobs))
    entries = [dict(fields(item)) for _, item in fields(response)]
    assert len(entries) == len(blobs)
    assert {(entry.get(1), dict(fields(entry.get(2, b""))).get(1, 0))
            for entry in entries} == {(digest(x), 0) for x in blobs}


def read(port, blob, expected):
    response = dict(fields(rpc(port, "BatchReadBlobs", part(2, digest(blob)))))
    row = dict(fields(response[1]))
    assert dict(fields(row.get(3, b""))).get(1, 0) == expected, row
    if expected == 0:
        assert row.get(2) == blob


def missing(port, blobs):
    return {value for tag, value in fields(rpc(port, "FindMissingBlobs", b"".join(part(2, digest(x)) for x in blobs))) if tag == 2}


def live_degradation(token=None):
    if token is None:
        token = uuid.uuid4().hex
        blobs = [f"z8-cas-check/{token}/{i}".encode() for i in range(64)]
        update(8980, blobs)
        assert not missing(8980, blobs)
        print(f"Seeded 64 cold objects. Save this token for --degraded: {token}")
        return
    blobs = [f"z8-cas-check/{token}/{i}".encode() for i in range(64)]
    absent = missing(8980, blobs)
    assert 0 < len(absent) < len(blobs), absent
    for blob in blobs:
        read(8980, blob, 5 if digest(blob) in absent else 0)
    update(8980, [blob for blob in blobs if digest(blob) in absent])
    assert not missing(8980, blobs)
    print(f"PASS: {len(absent)}/64 missing objects returned NotFound, other objects remained readable, refill succeeded.")


def lab():
    if os.geteuid():
        raise SystemExit("Run the disposable bare-device lab as root.")
    image = next(line.split()[1] for line in (BASE / "compose.tiered.yaml").read_text().splitlines()
                 if line.strip().startswith("image:"))
    run("docker", "image", "inspect", image)
    name = "z8-cas-test-" + uuid.uuid4().hex
    with ExitStack() as cleanup:
        work = Path(cleanup.enter_context(tempfile.TemporaryDirectory()))
        devices = []
        for kind, size in (("cold", 32 << 20), ("index", 8 << 20)):
            backing = work / kind
            with backing.open("wb") as file:
                file.truncate(size)
            dev = run("losetup", "--find", "--show", "--sector-size", "4096", backing)
            cleanup.callback(run, "losetup", "-d", dev)
            devices.append(dev)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]

        config = work / "config"
        config.mkdir()
        for src in (BASE / "tiered-cache.jsonnet", BASE / "cache.jsonnet", BASE / "disk.libsonnet"):
            (config / src.name).write_bytes(src.read_bytes())
        (work / "cold-layout.json").write_text('{"active":["sata0-0"]}')
        conf = json.loads(run("jsonnet", config / "tiered-cache.jsonnet"))
        for key in ("global", "schedulers", "executeAuthorizer"):
            conf.pop(key)
        conf["grpcServers"][0]["listenAddresses"] = [f"127.0.0.1:{port}"]
        storage = conf["contentAddressableStorageServer"]["contentAddressableStorage"]
        file_stores = [
            storage["chunkStorage"]["readCaching"]["fast"]["local"],
            storage["chunkMappingStorage"]["chunkMappingValidating"]["backend"]["local"],
            conf["actionCache"]["backend"]["completenessChecking"]["backend"]["local"],
        ]
        for store in file_stores:
            store["blocksOnBlockDevice"]["source"]["file"]["sizeBytes"] = 32 << 20
            store["keyLocationMap"]["onBlockDevice"]["file"]["sizeBytes"] = 8 << 20
        for directory in ("cs-hot", "cms", "ac", "cold/sata0-0"):
            (work / "store" / directory / "persistent_state").mkdir(parents=True)
        (work / "hot-index").mkdir()
        # The image also listens on the UNIX socket that the worker and scheduler use.
        unix_socket = work / "bb-cache/cache.sock"
        unix_socket.parent.mkdir()
        (config / "test.json").write_text(json.dumps(conf))

        run("docker", "run", "-d", "--name", name, "--network", "host", "--pull", "never",
            "--device", f"{devices[0]}:/dev/z8-cold-sata0-0:rw",
            "--device", f"{devices[1]}:/dev/z8-index-sata0-0:rw",
            "-v", f"{config}:/config:ro", "-v", f"{work / 'store'}:/store",
            "-v", f"{work / 'hot-index'}:/hot-index",
            "-v", f"{unix_socket.parent}:/run/bb-cache",
            image, "/config/test.json")
        cleanup.callback(run, "docker", "rm", "-f", name)
        try:
            for attempt in range(50):
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                        if unix_socket.is_socket():
                            break
                except OSError:
                    pass
                time.sleep(0.1)
            else:
                raise RuntimeError("Disposable cache did not start.")

            blob = b"z8 isolated corrupt object test" * 73
            update(port, [blob])
            with open(devices[1], "rb", buffering=0) as index:
                records = index.read(8 << 20)
            locations = [struct.unpack_from("<QQ", records, off + 42)
                         for off in range(0, len(records) - 65, 66)
                         if records[off + 58:off + 66] != bytes(8)]
            assert len(locations) == 1, locations
            offset, length = locations[0]
            assert 0 < length <= (32 << 20) - offset
            with open(devices[0], "r+b", buffering=0) as device:
                assert os.pwrite(device.fileno(), bytes(length), offset) == length
                os.fsync(device.fileno())
            read(port, blob, 5)
            assert missing(port, [blob]) == {digest(blob)}
            update(port, [blob])
            read(port, blob, 0)
            logs = subprocess.run(["docker", "logs", name], text=True, capture_output=True, check=True)
            assert "blocks due to a data integrity error" in logs.stdout + logs.stderr
            print(f"PASS: spoiled cold blob at {offset}+{length}, returned NotFound, refilled and read back.")
        except (AssertionError, OSError, RuntimeError, subprocess.CalledProcessError):
            subprocess.run(["docker", "logs", name], check=False)
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--seed", action="store_true", help="Seed the live cache before the I5 missing-disk drill.")
    modes.add_argument("--degraded", metavar="SEED", help="Check routing, NotFound and refill in the I5 drill.")
    args = parser.parse_args()
    if args.seed or args.degraded:
        live_degradation(args.degraded)
    else:
        lab()
