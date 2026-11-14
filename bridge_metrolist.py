#!/usr/bin/env python3
"""Metrolist Now Playing bridge for Linux (MPRIS).

Polls the Metrolist desktop player through playerctl and exposes the same
loopback HTTP API and file fallback as bridge_metrolist.ps1.

Requires: python3 and playerctl (sudo apt install playerctl).
"""

import argparse
import json
import mimetypes
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_PORT = 8974
POLL_SECONDS = 0.7
SEPARATOR = "\x1f"
MAX_ART_BYTES = 8 * 1024 * 1024

lock = threading.Lock()
state = {
    "json": '{"title":"","artist":"","album_art_url":"","is_playing":false,"updated_at":0}',
    "cover": None,
    "cover_name": None,
    "cover_type": "image/jpeg",
    "cover_version": 0,
    "last_core": None,
    "last_write": 0.0,
}
index_bytes = None


def playerctl(*args, timeout=3):
    return subprocess.run(
        ["playerctl", *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        check=False,
    )


def find_player():
    result = playerctl("-l")
    for name in result.stdout.splitlines():
        name = name.strip()
        if "metrolist" in name.lower():
            return name
    return None


def read_metadata(player):
    status = playerctl("-p", player, "status").stdout.strip().lower()
    result = playerctl(
        "-p", player, "metadata", "--format",
        "{{title}}" + SEPARATOR + "{{artist}}" + SEPARATOR +
        "{{mpris:artUrl}}" + SEPARATOR + "{{mpris:length}}",
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "playerctl failed")

    parts = result.stdout.rstrip("\n").split(SEPARATOR)
    while len(parts) < 4:
        parts.append("")

    try:
        duration_ms = int(float(parts[3]) / 1000)
    except (TypeError, ValueError):
        duration_ms = 0

    position_ms = 0
    try:
        position = playerctl("-p", player, "position").stdout.strip()
        if position:
            position_ms = int(float(position) * 1000)
    except Exception:
        position_ms = 0

    if duration_ms > 0:
        position_ms = max(0, min(position_ms, duration_ms))
    else:
        position_ms = max(0, position_ms)

    return status == "playing", parts[0], parts[1], parts[2], position_ms, duration_ms


def sniff_type(data, content_type):
    content_type = (content_type or "").split(";")[0].strip().lower()
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return "image/webp"
    if data.startswith(b"GIF8"):
        return "image/gif"
    if data.startswith(b"BM"):
        return "image/bmp"
    if content_type.startswith("image/"):
        return content_type
    return "image/jpeg"


def download_art(url):
    if not url:
        return None

    if url.startswith("file://"):
        path = urllib.parse.unquote(urllib.parse.urlparse(url).path)
        data = Path(path).read_bytes()
        content_type = mimetypes.guess_type(path)[0] or "image/jpeg"
    elif url.startswith(("http://", "https://")):
        request = urllib.request.Request(url, headers={"User-Agent": "MetrolistNowPlaying/1.0"})
        with urllib.request.urlopen(request, timeout=4) as response:
            data = response.read(MAX_ART_BYTES)
            content_type = response.headers.get("Content-Type", "image/jpeg")
    else:
        return None

    if not data:
        return None
    return data, sniff_type(data, content_type)


def write_atomic(path, data):
    temp = path.with_suffix(path.suffix + ".tmp")
    if isinstance(data, str):
        temp.write_text(data, encoding="utf-8")
    else:
        temp.write_bytes(data)
    temp.replace(path)


def extension_for(content_type):
    return {
        "image/png": "png",
        "image/webp": "webp",
        "image/gif": "gif",
        "image/bmp": "bmp",
    }.get(content_type, "jpg")


def clear_cover():
    with lock:
        old_name = state["cover_name"]
        if old_name:
            state["cover_version"] += 1
        state["cover"] = None
        state["cover_name"] = None
        state["cover_type"] = "image/jpeg"
    if old_name:
        (HERE / old_name).unlink(missing_ok=True)


def set_cover(url):
    if not url:
        clear_cover()
        return

    try:
        artwork = download_art(url)
    except Exception as error:
        print(f"Album art unavailable: {error}", flush=True)
        clear_cover()
        return

    if not artwork:
        clear_cover()
        return

    data, content_type = artwork
    ext = extension_for(content_type)
    name = f"current_cover.{ext}"

    write_atomic(HERE / name, data)
    with lock:
        old_name = state["cover_name"]
        state["cover"] = data
        state["cover_name"] = name
        state["cover_type"] = content_type
        state["cover_version"] += 1
    if old_name and old_name != name:
        (HERE / old_name).unlink(missing_ok=True)
    print(f"Album art: {name} ({len(data) / 1024:.0f} KB)", flush=True)


def publish(is_playing, title, artist, position_ms=0, duration_ms=0):
    with lock:
        cover_name = state["cover_name"]
        cover_version = state["cover_version"]

    payload = {
        "title": title,
        "artist": artist,
        "album_art_url": f"{cover_name}?v={cover_version}" if cover_name else "",
        "is_playing": bool(is_playing),
        "position_ms": int(position_ms),
        "duration_ms": int(duration_ms),
        "updated_at": int(time.time() * 1000),
    }
    text = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    js = f"window.METROLIST_NOW_PLAYING = {text};"

    core = (title, artist, bool(is_playing), cover_name, cover_version, int(duration_ms))
    now = time.monotonic()
    with lock:
        state["json"] = text
        changed = core != state["last_core"] or now - state["last_write"] >= 5
        if changed:
            state["last_core"] = core
            state["last_write"] = now

    # Rewrite the fallback files on change and at least every 5 seconds so the
    # widget's stale-data check keeps working without hammering the disk.
    if changed:
        write_atomic(HERE / "current_song.json", text)
        write_atomic(HERE / "current_song.js", js)
    return text


def poll_loop():
    last_key = None
    last_log = None
    player = None

    while True:
        try:
            if not player:
                player = find_player()

            if not player:
                last_key = None
                clear_cover()
                publish(False, "", "")
                time.sleep(POLL_SECONDS)
                continue

            is_playing, title, artist, art_url, position_ms, duration_ms = read_metadata(player)
            key = title + "\x00" + artist
            if key != last_key:
                last_key = key
                set_cover(art_url)
            publish(is_playing, title, artist, position_ms, duration_ms)

            log = (key, is_playing)
            if log != last_log:
                last_log = log
                print(f"Playing: {artist} - {title}" if is_playing else "Paused - widget hidden", flush=True)
        except Exception:
            # Player closed or playerctl hiccup; rediscover on the next tick.
            player = None
            last_key = None
            clear_cover()
            publish(False, "", "")
        time.sleep(POLL_SECONDS)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.close_connection = True
        path = urllib.parse.urlsplit(self.path).path
        with lock:
            body, content_type = self.route(path)

        if body is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Connection", "close")
            self.end_headers()
            return

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def route(self, path):
        if path in ("/", "/index.html"):
            return (index_bytes, "text/html; charset=utf-8") if index_bytes else (None, "")
        if path in ("/nowplaying", "/current_song.json"):
            return state["json"].encode("utf-8"), "application/json; charset=utf-8"
        if path == "/current_song.js":
            return f"window.METROLIST_NOW_PLAYING = {state['json']};".encode("utf-8"), "application/javascript; charset=utf-8"
        if state["cover_name"] and path == "/" + state["cover_name"] and state["cover"]:
            return state["cover"], state["cover_type"]
        return None, ""

    def log_message(self, *args):
        pass


def main():
    global index_bytes

    parser = argparse.ArgumentParser(description="Metrolist Now Playing bridge (Linux/MPRIS)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--no-server", action="store_true", help="Only write current_song.json / current_song.js")
    args = parser.parse_args()

    if sys.platform == "win32":
        print("On Windows use bridge_metrolist.ps1 instead (zero dependencies).", flush=True)
        return 1

    if not shutil.which("playerctl"):
        print("playerctl is required. Install it with: sudo apt install playerctl", flush=True)
        return 1

    index_path = HERE / "index.html"
    if index_path.exists():
        index_bytes = index_path.read_bytes()

    print()
    print("Metrolist Now Playing bridge (MPRIS)")
    print("------------------------------------")

    server = None
    if not args.no_server:
        try:
            server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
            server.daemon_threads = True
            threading.Thread(target=server.serve_forever, daemon=True).start()
            print(f"HTTP server: http://127.0.0.1:{args.port}/nowplaying")
            print(f"Widget preview: http://127.0.0.1:{args.port}/")
        except OSError as error:
            print(f"Could not listen on 127.0.0.1:{args.port} ({error}). Continuing in file-only mode.")
    else:
        print("HTTP server disabled (--no-server). Using file fallback only.")

    print(f"Files: {HERE / 'current_song.json'}")
    print("OBS: add index.html as a Browser Source (suggested 640x160).")
    print("Press Ctrl+C to stop.")
    print()

    try:
        poll_loop()
    except KeyboardInterrupt:
        pass
    finally:
        if server:
            server.shutdown()
        print("Bridge stopped.")


if __name__ == "__main__":
    raise SystemExit(main())
