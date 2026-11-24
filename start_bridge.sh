#!/usr/bin/env bash
# Metrolist Now Playing bridge launcher for Linux.
# Run from a terminal: ./start_bridge.sh
set -u

cd -- "$(dirname -- "$(readlink -f -- "$0")")" || exit 1

pause_on_error() {
  if [ -t 0 ]; then
    printf '\nPress Enter to close...'
    read -r _
  fi
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is required but was not found."
  echo "Install it with your package manager, then run this script again."
  pause_on_error
  exit 1
fi

if ! command -v playerctl >/dev/null 2>&1; then
  cat <<'EOF'
playerctl is required to read Metrolist's MPRIS session.

  Arch / CachyOS / Manjaro:  sudo pacman -S playerctl
  Debian / Ubuntu / Mint:    sudo apt install playerctl
  Fedora:                    sudo dnf install playerctl
  openSUSE:                  sudo zypper install playerctl

Then run this script again.
EOF
  pause_on_error
  exit 1
fi

exec python3 bridge_metrolist.py "$@"
