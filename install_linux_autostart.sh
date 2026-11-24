#!/usr/bin/env bash
# Optional: run the Metrolist -> OBS bridge automatically at login.
set -euo pipefail

DIR="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
PYTHON="$(command -v python3 || true)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/metrolist-obs-bridge.service"

if [ -z "$PYTHON" ]; then
  echo "Python 3 is required but was not found." >&2
  exit 1
fi

if ! command -v playerctl >/dev/null 2>&1; then
  echo "playerctl is required. Install it first (for example: sudo pacman -S playerctl)." >&2
  exit 1
fi

mkdir -p "$UNIT_DIR"

cat >"$UNIT" <<EOF
[Unit]
Description=Metrolist Now Playing bridge for OBS
After=graphical-session.target

[Service]
Type=simple
ExecStart="$PYTHON" "$DIR/bridge_metrolist.py"
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable metrolist-obs-bridge.service
systemctl --user restart metrolist-obs-bridge.service

echo
echo "Installed and started: $UNIT"
echo "Widget:  http://127.0.0.1:8974/"
echo "Logs:    journalctl --user -u metrolist-obs-bridge -f"
echo "Stop:    systemctl --user disable --now metrolist-obs-bridge.service"
