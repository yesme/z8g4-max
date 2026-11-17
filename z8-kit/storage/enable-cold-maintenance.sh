#!/usr/bin/env bash
set -euo pipefail

# Older kits installed this timer directly into /etc. Keep its service for manual scans.
legacy=/etc/systemd/system/z8-cold-scan.timer
if [[ -f "$legacy" ]]; then
    systemctl disable --now z8-cold-scan.timer
    rm -- "$legacy"
fi
systemctl daemon-reload
/usr/local/sbin/z8-cold-health remember
systemctl enable --now z8-cold-health.timer z8-cold-selftest.timer
