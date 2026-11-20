#!/usr/bin/env python3
"""Generate systemd CPU masks from the running Z8's physical core topology."""

import argparse
from collections import defaultdict
from pathlib import Path


def parse_cpu_list(value):
    cpus = set()
    for item in value.strip().split(","):
        first, sep, last = item.partition("-")
        start = int(first)
        stop = int(last) if sep else start
        if start < 0 or stop < start:
            raise ValueError(f"invalid CPU range: {item}")
        cpus.update(range(start, stop + 1))
    return cpus


def read_cores(cpu_root):
    online = parse_cpu_list((cpu_root / "online").read_text())
    topology = {}
    for cpu in sorted(online):
        path = cpu_root / f"cpu{cpu}" / "topology"
        socket = int((path / "physical_package_id").read_text())
        siblings = tuple(sorted(parse_cpu_list((path / "thread_siblings_list").read_text())))
        if socket < 0 or len(siblings) != 2 or cpu not in siblings or not online.issuperset(siblings):
            raise ValueError(f"CPU {cpu} does not have two online HT siblings in one core")
        topology[cpu] = (socket, siblings)

    by_socket = defaultdict(list)
    for cpu, (socket, siblings) in topology.items():
        if any(topology[sibling] != (socket, siblings) for sibling in siblings):
            raise ValueError(f"inconsistent sibling topology for CPU {cpu}")
        if cpu == siblings[0]:
            by_socket[socket].append(siblings)
    if len(by_socket) != 2:
        raise ValueError(f"expected two sockets, found {len(by_socket)}")
    return by_socket


def cpu_list(cpus):
    return ",".join(str(cpu) for cpu in sorted(cpus))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="new directory for the preview files")
    parser.add_argument("--infer-per-socket", type=int, default=6)
    args = parser.parse_args()

    try:
        by_socket = read_cores(Path("/sys/devices/system/cpu"))
        infer = set()
        infer_siblings = set()
        xolotl_pool = set()
        build = set()
        idle = set()
        for socket, cores in sorted(by_socket.items()):
            count = args.infer_per_socket
            if not 1 < count < len(cores):
                raise ValueError(f"socket {socket} has {len(cores)} cores, invalid inference count {count}")
            inference_cores = cores[-count:]
            for pair in cores:
                idle.update(pair)
            for primary, sibling in inference_cores:
                infer.add(primary)
                infer_siblings.add(sibling)
            xolotl_pool.update(primary for primary, _ in inference_cores[1:])
            for pair in cores[:-count]:
                build.update(pair)
            print(f"socket {socket}: {count} inference cores, {len(cores) - count} build/general cores")

        args.output.mkdir()
        for name, desc, mask, weight in (
            ("z8infer", "DeepSeek inference", infer, 200),
            # cpu-mode.sh turns this into an idle group for as long as builds share the inference CPUs.
            ("z8build", "Buck2 and Buildbarn execution", None, 100),
            ("z8build-local", "Interactive Buck2 builds", None, 200),
            ("z8build-remote", "Buildbarn remote execution", None, 100),
        ):
            allowed = f"AllowedCPUs={cpu_list(mask)}\n" if mask is not None else ""
            memory = "MemoryLow=90G\n" if name == "z8infer" else ""
            (args.output / f"{name}.slice").write_text(
                f"[Unit]\nDescription={desc}\n\n[Slice]\n{allowed}"
                f"CPUWeight={weight}\n{memory}",
                encoding="utf-8",
            )
        (args.output / "z8-infer-cpu.env").write_text(
            f"Z8_BUILD_CPUS={cpu_list(build)}\nZ8_BUILD_SHARED_CPUS={cpu_list(build | infer)}\n"
            f"Z8_IDLE_CPUS={cpu_list(idle)}\n"
            f"Z8_INFER_THREADS={len(infer)}\nZ8_IRQ_BANNED_CPUS={cpu_list(infer | infer_siblings)}\n"
            f"Z8_XOLOTL_POOL_CPUS={cpu_list(xolotl_pool)}\n",
            encoding="utf-8",
        )
        (args.output / "10-z8-cpu.conf").write_text(
            f"[Slice]\nAllowedCPUs={cpu_list(idle)}\n", encoding="utf-8"
        )
        print(f"Inference CPUs: {cpu_list(infer)}")
        print(f"Reserved inference siblings: {cpu_list(infer_siblings)}")
        print(f"General CPUs with local inference running: {cpu_list(build)}")
        print(f"Build CPUs with local inference running, at idle priority: {cpu_list(build | infer)}")
        print(f"Build and general CPUs with local inference stopped: {cpu_list(idle)}")
        print(f"Xolotl CPU expert workers: {cpu_list(xolotl_pool)}")
    except (OSError, ValueError) as exc:
        parser.exit(1, f"{parser.prog}: {exc}\n")


if __name__ == "__main__":
    main()
