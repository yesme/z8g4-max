from io import BytesIO
from pathlib import Path
import os
import re
import subprocess
import tarfile
from tempfile import TemporaryDirectory


def stub(path, body):
    path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body + "\n")
    path.chmod(0o755)


hooks = subprocess.check_output(
    ["apt-config", "-c", "z8-kit/host/99z8-fit-boot.example", "dump"], text=True
)
assert 'DPkg::Pre-Invoke:: "/usr/local/sbin/z8-recovery-backup --apt-pre' in hooks
assert 'DPkg::Post-Invoke:: "/usr/local/sbin/z8-recovery-backup --apt-post' in hooks


with TemporaryDirectory() as directory:
    root = Path(directory)
    volume = root / "recovery"
    boot = root / "boot"
    fake_bin = root / "bin"
    devices = root / "dev"
    for folder in (volume, boot / "grub", boot / "efi", fake_bin, devices / "disk/by-id", root / "run"):
        folder.mkdir(parents=True)
    history = root / "var/log/apt/history.log"
    history.parent.mkdir(parents=True)
    history.touch()
    (boot / "vmlinuz").write_text("known kernel")
    (boot / "efi/boot.efi").write_text("known EFI")
    (boot / "grub/grubenv").write_text("next_entry=1")
    for name in ("recovery", "nvme0", "nvme1"):
        (devices / name).touch()
    infer = root / "home/jackywang/.config/z8-infer"
    infer.mkdir(parents=True)
    (infer / "env.sh").write_text("export SLOTS=2\nexport KV_TYPE=q8_0\nexport KV_OFFLOAD=0\nexport DEEPSEEK_API_KEY=fixture-secret\n")
    (root / "etc/ssh").mkdir(parents=True)
    (root / "etc/ssh/ssh_host_ed25519_key").write_text("fixture-secret")
    wifi = root / "etc/NetworkManager/system-connections"
    wifi.mkdir(parents=True)
    (wifi / "wifi.nmconnection").write_text("psk=fixture-secret")

    original = Path("z8-kit/host/z8-recovery-backup.sh").read_text()
    fixture = root / "backup"
    text = original.replace("EUID == 0", "0 == 0").replace(" -b ", " -f ")
    text = text.replace("boot_dir=/boot", f"boot_dir={root}/boot")
    for path in ("/run/z8-recovery-backup.lock", "/run/z8-fit-apt.state", "/var/log/apt/",
                 "/etc/", "/opt/", "/srv/", "/home/", "/dev/disk/by-id/"):
        text = text.replace(path, f"{root}{path}")
    fixture.write_text(text)
    env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}", "TMPDIR": str(root),
           "Z8_FIXTURE": str(root)}
    stub(fake_bin / "findmnt", """
if [[ "$2" == -S ]]; then exit 1; fi
case "$3" in
    "$Z8_FIXTURE/boot") echo /dev/test2 ;;
    "$Z8_FIXTURE/boot/efi") echo /dev/test1 ;;
    /) echo /dev/test-md ;;
    *) exit 2 ;;
esac
""")
    stub(fake_bin / "blkid", """
if [[ $# == 0 ]]; then
    echo mock-blkid
elif [[ -e "$Z8_FIXTURE/no-label" ]]; then
    exit 2
else
    echo "$Z8_FIXTURE/dev/recovery"
fi
""")
    stub(fake_bin / "lsblk", """
case "${2:-}" in
    PKNAME)
        if [[ "$4" == "$Z8_FIXTURE/dev/recovery" && -e "$Z8_FIXTURE/foreign" ]]; then echo another; else echo testdisk; fi
        ;;
    TYPE,FSTYPE) echo 'part ext4' ;;
    MAJ:MIN) if [[ "$4" == /dev/test2 ]]; then echo '8:2'; else echo '8:4'; fi ;;
    TYPE,PATH) printf 'disk %s/dev/nvme0\\ndisk %s/dev/nvme1\\n' "$Z8_FIXTURE" "$Z8_FIXTURE" ;;
    *) echo mock-lsblk ;;
esac
""")
    stub(fake_bin / "mount", """
target=${@: -1}
rmdir -- "$target"
ln -s -- "$Z8_FIXTURE/recovery" "$target"
echo mounted >> "$Z8_FIXTURE/mount.log"
""")
    stub(fake_bin / "umount", """
[[ -L "$1" ]]
unlink "$1"
mkdir "$1"
echo unmounted >> "$Z8_FIXTURE/mount.log"
""")
    stub(fake_bin / "sgdisk", 'echo fixture-gpt > "${1#--backup=}"')
    for name in ("mdadm", "xfs_info", "efibootmgr", "apt-mark", "dpkg", "sync", "logger"):
        stub(fake_bin / name, "echo fixture-output")
    # Keep test stages independent of which host tools happen to be installed.
    for name in ("zpool", "ndctl", "ipmctl", "nvidia-smi"):
        stub(fake_bin / name, "exit 1" if name == "zpool" else "echo fixture-optional")

    def run(*args):
        return subprocess.run(["bash", str(fixture), *args], env=env, capture_output=True, timeout=15)

    def reject(message, *args):
        result = run(*args)
        assert result.returncode != 0 and message in result.stdout + result.stderr, result.stderr.decode()

    (root / "no-label").touch()
    reject(b"No partition labelled Z8RECOVERY")
    (root / "no-label").unlink()
    (root / "foreign").touch()
    reject(b"ext4 partition on the FIT boot disk")
    (root / "foreign").unlink()
    assert not (root / "mount.log").exists()
    reject(b"FIT boot check: missing-baseline")
    missing = volume / (volume / "latest").readlink()
    assert b"status=missing-baseline" in (missing / "boot-check.txt").read_bytes()
    assert (missing / "storage/mdadm-scan.txt").is_file()

    initialized = run("--refresh-boot")
    assert initialized.returncode == 0, initialized.stderr.decode()
    old = (volume / "latest").readlink()
    assert (volume / old / "SHA256SUMS").is_file()
    assert b"grubenv" not in (volume / "boot.sha256").read_bytes()
    (boot / "grub/grubenv").write_text("next_entry=2")
    result = run()
    assert result.returncode == 0, result.stderr.decode()
    latest = (volume / "latest").readlink()

    baseline = (volume / "boot.sha256").read_bytes()
    (boot / "vmlinuz").write_text("different kernel")
    reject(b"FIT boot check: mismatch")
    mismatch = (volume / "latest").readlink()
    assert mismatch != latest
    latest = mismatch
    snapshot = volume / latest
    assert b"status=mismatch" in (snapshot / "boot-check.txt").read_bytes()
    assert (snapshot / "boot-baseline.sha256").read_bytes() == baseline
    assert (snapshot / "boot.sha256").read_bytes() != baseline
    assert (volume / "boot.sha256").read_bytes() == baseline
    assert (snapshot / "storage/mdadm-scan.txt").is_file()
    subprocess.run(["sha256sum", "--check", "--strict", "--quiet", "SHA256SUMS"], cwd=snapshot, check=True)
    assert (root / "mount.log").read_text().splitlines()[-1] == "unmounted"
    (boot / "vmlinuz").write_text("known kernel")

    cp = Path("/bin/cp")
    assert cp.is_file()
    stub(fake_bin / "cp", """
/bin/cp "$@"
target=${@: -1}
case "$target" in
    */.staging.*/*) echo tampered >> "$target/boot.sha256" ;;
esac
""")
    reject(b"FAILED", "--refresh-boot")
    assert (volume / "latest").readlink() == latest
    (fake_bin / "cp").unlink()

    conf = root / "etc/default/grub"
    conf.parent.mkdir(parents=True)
    conf.write_text("API_KEY=fixture-secret\n")
    reject(b"Inline credentials detected", "--stdout")
    conf.unlink()

    exported = run("--stdout")
    assert exported.returncode == 0, exported.stderr.decode()
    with tarfile.open(fileobj=BytesIO(exported.stdout)) as archive:
        assert all(b"fixture-secret" not in archive.extractfile(m).read() for m in archive if m.isfile())
        env_file = next(name for name in archive.getnames() if name.endswith("z8-infer/env.sh"))
        assert archive.extractfile(env_file).read() == b"export SLOTS=2\nexport KV_TYPE=q8_0\nexport KV_OFFLOAD=0\n"

    def history_entry(package, *, failed=False):
        with history.open("a") as log:
            log.write(f"\nStart-Date: 2026-11-16  02:01:02\n"
                      f"Commandline: apt upgrade\nUpgrade: {package}:amd64 (1, 2)\n")
            if failed:
                log.write("Error: Sub-process /usr/bin/dpkg returned an error code (1)\n")
            log.write("End-Date: 2026-11-16  02:01:03\n")

    def require_success(result):
        assert result.returncode == 0, result.stdout + result.stderr

    healthy_baseline = (volume / "boot.sha256").read_bytes()
    require_success(run("--apt-pre"))
    history_entry("unrelated")
    require_success(run("--apt-post"))
    assert not (volume / "boot-baseline-apt.txt").exists()
    assert (volume / "boot.sha256").read_bytes() == healthy_baseline

    require_success(run("--apt-pre"))
    (boot / "efi/boot.efi").write_text("APT updated EFI")
    (boot / "initrd.img-test").write_text("APT generated initramfs")
    history_entry("grub-efi-amd64-signed")
    require_success(run("--apt-post"))
    apt_baseline = (volume / "boot.sha256").read_bytes()
    receipt = (volume / "boot-baseline-apt.txt").read_text()
    assert apt_baseline != healthy_baseline and b"./initrd.img-test" in apt_baseline
    assert "updated_at_utc=" in receipt and "grub-efi-amd64-signed:amd64 (1, 2)" in receipt
    assert "Commandline:" not in receipt
    assert (volume / "latest").readlink() == latest
    require_success(run())
    assert (volume / (volume / "latest").readlink() / "boot-baseline-apt.txt").read_text() == receipt

    require_success(run("--apt-pre"))
    (boot / "initrd.img-test").write_text("partially generated after a failed transaction")
    history_entry("dracut", failed=True)
    reject(b"No successful, complete package transaction", "--apt-post")
    assert (volume / "boot.sha256").read_bytes() == apt_baseline
    assert (volume / "boot-baseline-apt.txt").read_text() == receipt

    (root / "run/z8-fit-apt.state").write_text("stale transaction")
    reject(b"Pre-APT boot comparison failed", "--apt-pre")
    assert not (root / "run/z8-fit-apt.state").exists()
    history_entry("unrelated")
    require_success(run("--apt-post"))
    assert (volume / "boot.sha256").read_bytes() == apt_baseline

    (boot / "initrd.img-test").write_text("APT generated initramfs")
    require_success(run("--apt-pre"))
    (boot / "efi/boot.efi").write_text("changed during a rotated history")
    history.rename(history.with_suffix(".old"))
    history.touch()
    history_entry("shim-signed")
    reject(b"history changed identity", "--apt-post")
    assert (volume / "boot.sha256").read_bytes() == apt_baseline

    (boot / "efi/boot.efi").write_text("APT updated EFI")
    stub(fake_bin / "sha256sum", """
if [[ "$PWD" == "$Z8_FIXTURE/boot" && ${1:-} == -- ]]; then
    echo 'fixture boot I/O error' >&2
    exit 1
fi
exec /usr/bin/sha256sum "$@"
""")
    reject(b"FIT boot check: unreadable", "--refresh-boot")
    unreadable = volume / (volume / "latest").readlink()
    assert b"status=unreadable" in (unreadable / "boot-check.txt").read_bytes()
    assert b"fixture boot I/O error" in (unreadable / "boot-read-errors.txt").read_bytes()
    assert (volume / "boot.sha256").read_bytes() == apt_baseline
    (fake_bin / "sha256sum").unlink()

    for day in range(1, 14):
        (volume / f"202001{day:02}T000000.000000000Z").mkdir()
    (volume / "untouched").mkdir()
    result = run("--refresh-boot")
    assert result.returncode == 0, result.stderr.decode()
    assert sum(bool(re.fullmatch(r"\d{8}T\d{6}\.\d{9}Z", d.name)) for d in volume.iterdir()) == 12
    assert (volume / "untouched").is_dir()

print("FIT backup tests passed: label guards, durable health alerts, APT baseline and history guards, tar, and retention.")
