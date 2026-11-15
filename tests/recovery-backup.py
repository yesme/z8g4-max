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


with TemporaryDirectory() as directory:
    root = Path(directory)
    volume = root / "recovery"
    boot = root / "boot"
    fake_bin = root / "bin"
    devices = root / "dev"
    for folder in (volume, boot / "grub", boot / "efi", fake_bin, devices / "disk/by-id", root / "run"):
        folder.mkdir(parents=True)
    (boot / "vmlinuz").write_text("known kernel")
    (boot / "efi/boot.efi").write_text("known EFI")
    (boot / "grub/grubenv").write_text("next_entry=1")
    for name in ("recovery", "nvme0", "nvme1"):
        (devices / name).touch()
    infer = root / "home/jackywang/.config/z8-infer"
    infer.mkdir(parents=True)
    (infer / "env.sh").write_text("export SLOTS=2\nexport DEEPSEEK_API_KEY=fixture-secret\n")
    (root / "etc/ssh").mkdir(parents=True)
    (root / "etc/ssh/ssh_host_ed25519_key").write_text("fixture-secret")
    wifi = root / "etc/NetworkManager/system-connections"
    wifi.mkdir(parents=True)
    (wifi / "wifi.nmconnection").write_text("psk=fixture-secret")

    original = Path("z8-kit/host/z8-recovery-backup.sh").read_text()
    fixture = root / "backup"
    text = original.replace("EUID == 0", "0 == 0").replace(" -b ", " -f ")
    text = text.replace("boot_dir=/boot", f"boot_dir={root}/boot")
    for path in ("/run/z8-recovery-backup.lock", "/etc/", "/opt/", "/srv/", "/home/", "/dev/disk/by-id/"):
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
    for name in ("mdadm", "xfs_info", "efibootmgr", "apt-mark", "dpkg", "sync"):
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
    reject(b"no baseline")

    initialized = run("--refresh-boot")
    assert initialized.returncode == 0, initialized.stderr.decode()
    old = (volume / "latest").readlink()
    assert (volume / old / "SHA256SUMS").is_file()
    assert b"grubenv" not in (volume / "boot.sha256").read_bytes()
    (boot / "grub/grubenv").write_text("next_entry=2")
    result = run()
    assert result.returncode == 0, result.stderr.decode()
    latest = (volume / "latest").readlink()

    (boot / "vmlinuz").write_text("different kernel")
    reject(b"Boot checksum mismatch")
    assert (volume / "latest").readlink() == latest
    assert (root / "mount.log").read_text().splitlines()[-1] == "unmounted"

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
        assert archive.extractfile(env_file).read() == b"export SLOTS=2\n"

    for day in range(1, 14):
        (volume / f"202001{day:02}T000000.000000000Z").mkdir()
    (volume / "untouched").mkdir()
    result = run("--refresh-boot")
    assert result.returncode == 0, result.stderr.decode()
    assert sum(bool(re.fullmatch(r"\d{8}T\d{6}\.\d{9}Z", d.name)) for d in volume.iterdir()) == 12
    assert (volume / "untouched").is_dir()

print("FIT backup tests passed: label and disk guards, corrupt boot/backup data, verified tar, secret exclusion and retention.")
