#!/usr/bin/env bash
# Install (or remove) a systemd --user timer that refreshes ./context daily.
#
# The units are generated rather than shipped because WorkingDirectory and
# ExecStart must be absolute, and this repo can live anywhere.
#
# Manual refresh never needs any of this: ./bin/context-refresh.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
NAME=marveen-context
TIME="${TIME:-04:30}"

if [ "${1:-install}" = "uninstall" ]; then
  systemctl --user disable --now "${NAME}.timer" 2>/dev/null || true
  rm -f "$UNIT_DIR/${NAME}.service" "$UNIT_DIR/${NAME}.timer"
  systemctl --user daemon-reload
  echo "  removed ${NAME}.timer"
  exit 0
fi

command -v systemctl >/dev/null 2>&1 || { echo "no systemctl -- use cron, or run bin/context-refresh.sh by hand" >&2; exit 1; }
mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/${NAME}.service" <<UNIT
[Unit]
Description=Refresh the curated context Marveen is allowed to read

[Service]
Type=oneshot
WorkingDirectory=${ROOT}
ExecStart=${ROOT}/bin/context-refresh.sh
# Reads private repos and transcripts; writes only into ${ROOT}/context.
Nice=10
IOSchedulingClass=idle
UNIT

cat > "$UNIT_DIR/${NAME}.timer" <<UNIT
[Unit]
Description=Daily refresh of Marveen's curated context

[Timer]
OnCalendar=*-*-* ${TIME}:00
# Catch up after the machine was off overnight instead of silently skipping --
# a stale digest is the failure mode this guards against.
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now "${NAME}.timer"
echo "  installed ${NAME}.timer (daily at ${TIME}, catches up after downtime)"
systemctl --user list-timers "${NAME}.timer" --no-pager | sed -n '1,3p'
