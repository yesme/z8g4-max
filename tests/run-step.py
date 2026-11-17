from pathlib import Path
import os
import re
import signal
import subprocess
from tempfile import TemporaryDirectory
import time


def stub(path, body):
    path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body + "\n")
    path.chmod(0o755)


script = Path("z8-kit/host/run-step.sh").resolve()
with TemporaryDirectory() as directory:
    root = Path(directory)
    fake_bin = root / "bin"
    fake_bin.mkdir()
    checks = root / "z8-burnin/cuda-check"
    checks.mkdir(parents=True)
    logs = root / "logs"
    env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}", "HOME": str(root),
           "Z8_LOG_DIR": str(logs), "Z8_FIXTURE": str(root)}
    stub(fake_bin / "sudo", 'exec "$@"')
    stub(fake_bin / "systemctl", ":")
    stub(fake_bin / "numactl", ":")
    stub(fake_bin / "ras-mc-ctl", 'printf "RAS %s\\n" "$1"')
    stub(fake_bin / "journalctl", "echo kernel-capture")
    stub(fake_bin / "nvidia-smi", """
case "$*" in
    *--query-gpu=name*) echo 'Tesla V100-SXM2-16GB' ;;
    '-q -d ECC,POWER,TEMPERATURE,PAGE_RETIREMENT') echo gpu-snapshot ;;
    '--query-gpu=uuid,pci.bus_id,pcie.link.gen.current,pcie.link.width.current --format=csv') echo pcie-link ;;
    *) printf 'Unexpected nvidia-smi arguments: %s\\n' "$*" >&2; exit 2 ;;
esac
""")
    stub(checks / "gpu_burn", 'printf "Burn: %s %s\\n" "$CUDA_VISIBLE_DEVICES" "$*"')

    def run(*args, target=script):
        return subprocess.run(["bash", str(target), *args], env=env, text=True, capture_output=True, timeout=20)

    public = set(re.findall(r"^  ([ti]\d-[\w-]+)\s", run("--help").stdout, re.M))
    dispatch, allowed = script.read_text().split('case "$step" in')[1:]
    steps = lambda body: set(re.findall(r"\b[ti]\d-[\w-]+(?=[|)])", body.split("\nesac")[0]))
    assert public == steps(dispatch) == steps(allowed)
    invalid = run("i4-cold-aging")
    assert invalid.returncode == 2 and "Supply an existing log directory" in invalid.stdout

    result = run("t5-gpu-burn", "GPU-abcd")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Burn: GPU-abcd -m 80% -tc 900" in result.stdout
    assert result.stdout.count("\ngpu-snapshot\n") == result.stdout.count("\npcie-link\n") == 2
    result = run("t5-gpu-burn", "GPU-abcd,GPU-ef01")
    assert result.returncode == 0 and "Burn: GPU-abcd,GPU-ef01 -m 80% -tc 900" in result.stdout
    result = run("t5-gpu-burn", "GPU-abcd,GPU-ef01,GPU-2345")
    assert result.returncode == 2 and "\nBurn:" not in result.stdout
    result = run("t5-gpu-burn", "GPU-abcd,GPU-ef01,GPU-2345,GPU-6789")
    assert result.returncode == 0 and "-tc 3600" in result.stdout, result.stdout
    result = run("t5-gpu-burn", "GPU-abcd,GPU-abcd,GPU-2345,GPU-6789")
    assert result.returncode == 2 and "Duplicate GPU" in result.stdout and "\nBurn:" not in result.stdout

    # Treat disposable files as block devices only in this temporary script copy.
    fixture_host = root / "kit/host"
    fixture_host.mkdir(parents=True)
    fixture = fixture_host / script.name
    diskdir = root / "dev/disk/by-id"
    diskdir.mkdir(parents=True)
    fixture.write_text(script.read_text().replace("/dev/disk/by-id/", f"{diskdir}/").replace(" -b ", " -f ")
                       .replace("/sys/class/hwmon/", f"{root}/hwmon/"))
    disks = [diskdir / f"nvme-{name}" for name in ("P4618-a", "P4618-b", "D4800X")]
    for disk in disks:
        disk.touch()
    stub(fake_bin / "lsblk", '[[ "$*" == "-dnro TYPE -- "* ]]; echo disk')
    stub(fake_bin / "smartctl", '[[ "$1" == -x ]]; exit 4')
    stub(fake_bin / "fio", '[[ "$1" == --readonly ]]; printf "%s\\n" "$*" >> "$Z8_FIXTURE/fio.log"')
    result = run("t4-nvme-read", *map(str, disks), target=fixture)
    assert result.returncode == 1, result.stdout + result.stderr
    assert result.stdout.count("(bitmask)") >= 6
    calls = (root / "fio.log").read_text().splitlines()
    assert len(calls) == 3 and all(str(disk) in call for disk, call in zip(disks, calls))
    result = run("t4-nvme-read", str(disks[0]), str(disks[0]), str(disks[2]), target=fixture)
    assert result.returncode == 2 and "Duplicate disk" in result.stdout

    net = root / "net"
    nic = net / "enp1s0"
    (nic / "device").mkdir(parents=True)
    (nic / "device/driver").symlink_to("/driver/e1000e")
    (nic / "address").write_text("00:11:22:33:44:55\n")
    (nic / "speed").write_text("1000\n")
    (nic / "duplex").write_text("full\n")
    inv = script.with_name("inventory.sh").read_text()
    (fixture_host / "inventory.sh").write_text(inv.replace("/sys/class/net/", f"{net}/"))
    stub(fake_bin / "lspci", "echo 'Ethernet controller: Intel I219-LM'")
    stub(fake_bin / "nmcli", "echo enp1s0")
    stub(fake_bin / "ethtool", """printf 'Supported link modes: 100baseT/Full\\n    1000baseT/Full\\nSupported pause frame use: No\\n'""")
    stub(fake_bin / "ip", "echo default via 192.0.2.1")
    stub(fake_bin / "getent", "echo archive.ubuntu.com")
    stub(fake_bin / "apt-get", '[[ "$*" == "-o APT::Update::Error-Mode=any update" ]]')
    result = run("t1-network", target=fixture)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "driver=e1000e" in result.stdout and "negotiated speed=1000 Mb/s" in result.stdout
    assert "Supported link modes: 100baseT/Full" in result.stdout and "1000baseT/Full" in result.stdout

    # The CPU steps warm up at half load and go to full load only past the package temperature gate.
    workload = fake_bin / "stress-ng"
    stub(fake_bin / "lscpu", 'if [[ "$*" == "--online --physical --parse=SOCKET" ]]; then printf "# Socket\\n0\\n1\\n0\\n"; fi')
    # Speed up the periodic sampler, keeping the first sample inside the workload.
    stub(fake_bin / "sleep", 'exec /bin/sleep 0.05')
    workload.write_text("""#!/usr/bin/env python3
from pathlib import Path
import os
import sys
from time import sleep
room = Path(os.environ["Z8_FIXTURE"])
stage = "warm-up" if "--cpu-load" in sys.argv else "full"
with (room / "stress.log").open("a") as log:
    print(stage, *sys.argv[1:], file=log)
if os.environ.get("Z8_HOLD") == stage:
    (room / "under-load").touch()
    sleep(30)
if stage == "warm-up" and "Z8_HEAT" in os.environ:
    # Hot only while the load runs; the reading is back to normal when the workers stop.
    sensor = room / "hwmon/hwmon0/temp1_input"
    sensor.write_text(os.environ["Z8_HEAT"] + "000\\n")
    sleep(3)
    sensor.write_text("64000\\n")
elif stage == "warm-up":
    sleep(0.4)
""")
    workload.chmod(0o755)
    stress_log = root / "stress.log"

    def packages(*temperatures):
        for index, temperature in enumerate(temperatures):
            sensor = root / f"hwmon/hwmon{index}"
            sensor.mkdir(parents=True, exist_ok=True)
            (sensor / "temp1_label").write_text(f"Package id {index}\n")
            (sensor / "temp1_input").write_text(f"{temperature}000\n")
            (sensor / "temp1_crit").write_text("93000\n")
            (sensor / "temp2_label").write_text("Core 0\n")
            (sensor / "temp2_input").write_text("99000\n")

    def cpu_step(*temperatures, **extra):
        packages(*temperatures)
        stress_log.unlink(missing_ok=True)
        env.update(extra)
        try:
            result = run("t1-cpu", target=fixture)
        finally:
            for name in extra:
                del env[name]
        return result, [line.split()[0] for line in stress_log.read_text().splitlines()]

    result, stages = cpu_step(64, 60)
    assert result.returncode == 0 and stages == ["warm-up", "full"], result.stdout + result.stderr
    assert "--cpu-load 50" in stress_log.read_text().splitlines()[0]
    assert "Package id 0: peak 64 °C, limit 93 °C" in result.stdout and "\nCore 0: " not in result.stdout, result.stdout
    for temperatures, problem in (((79, 76), "within 15 °C of its limit"), ((72, 60), "differ by 12 °C")):
        result, stages = cpu_step(*temperatures)
        assert result.returncode == 1 and stages == ["warm-up"], result.stdout + result.stderr
        assert "Full load skipped: " in result.stdout and problem in result.stdout, result.stdout
        assert "RAS --error-count" in result.stdout.split("\n[RAS after stress]\n")[1], result.stdout
    result, stages = cpu_step(64, 60, Z8_HEAT="85")
    assert result.returncode == 1 and stages == ["warm-up"], result.stdout + result.stderr
    assert "Package id 0: peak 85 °C" in result.stdout, result.stdout
    result, stages = cpu_step(72, 60, Z8_THERMAL_GATE="off")
    assert result.returncode == 0 and stages == ["warm-up", "full"], result.stdout + result.stderr
    assert "Thermal gate overridden" in result.stdout
    for sensor in (root / "hwmon").glob("hwmon*/temp1_label"):
        sensor.unlink()
    result, stages = cpu_step(63, Z8_THERMAL_GATE="off")
    assert result.returncode == 1 and stages == ["warm-up"] and "no warm-up sample for Package id 1" in result.stdout
    (root / "hwmon/hwmon0/temp1_label").unlink()
    result, stages = cpu_step()
    assert result.returncode == 1 and stages == ["warm-up"] and "no warm-up sample for Package id 0" in result.stdout

    # Ctrl+C from a terminal signals every process in the foreground group.
    def interrupt(stage):
        packages(64, 60)
        stress_log.unlink(missing_ok=True)
        (root / "under-load").unlink(missing_ok=True)
        step_logs = logs / stage
        with (root / "terminal.log").open("w+") as terminal:
            process = subprocess.Popen(
                ["bash", str(fixture), "t1-cpu"], env={**env, "Z8_HOLD": stage, "Z8_LOG_DIR": str(step_logs)},
                stdout=terminal, stderr=subprocess.STDOUT, start_new_session=True,
            )
            try:
                until = time.monotonic() + 10
                while not (root / "under-load").exists() and time.monotonic() < until:
                    if process.poll() is not None:
                        break
                    time.sleep(0.05)
                assert (root / "under-load").exists(), "test did not reach the workload"
                os.killpg(process.pid, signal.SIGINT)
                status = process.wait(timeout=10)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            terminal.seek(0)
            output = terminal.read()
        saved = next(step_logs.glob("t1-cpu-*.log")).read_text()
        assert status == 130, output
        for transcript in (output, saved):
            assert "\n[RAS after stress]\n" in transcript, transcript
            assert "RAS --error-count" in transcript.split("\n[RAS after stress]\n")[1], transcript
            assert "Finished t1-cpu: exit 130, logger exit 0" in transcript, transcript
        return [line.split()[0] for line in stress_log.read_text().splitlines()]

    # An interrupted warm-up must not continue into full load.
    assert interrupt("warm-up") == ["warm-up"]
    assert interrupt("full") == ["warm-up", "full"]

print("Step runner tests passed: GPU arguments, SMART errors, Ethernet-only setup, the CPU thermal gate "
      "and Ctrl+C with post-stress RAS.")
