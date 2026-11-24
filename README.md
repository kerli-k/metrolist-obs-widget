# Metrolist Now Playing — OBS overlay

A full-bleed "now playing" bar for the [Metrolist](https://github.com/MetrolistGroup/Metrolist) desktop app, styled after the [YouTube Music OBS widget](https://github.com/topik/youtube-music-obs-widget): blurred album-art background, circular cover, large artist name, secondary track title, time, and a live progress bar. It also supports that widget's feature parameters (`right`, `circle-progressbar`, `transparent-background`, and more).

Metrolist desktop already publishes playback through the OS (Windows SMTC / Linux MPRIS). The browser cannot read those sessions, so this package includes a small loopback bridge that polls the session and feeds the HTML.

Tested on Windows 10/11 and on CachyOS/Arch Linux (Metrolist 14.x, KDE Plasma/Wayland).

## What's in the box

| File | Purpose |
| --- | --- |
| `index.html` | The overlay. All HTML/CSS/JS in one file, plus URL parameters. |
| `start_bridge.bat` | Double-click launcher for the Windows bridge. |
| `start_bridge.sh` | One-command launcher for the Linux bridge. |
| `install_linux_autostart.sh` | Optional systemd user service so the Linux bridge starts at login. |
| `bridge_metrolist.ps1` | Windows bridge: SMTC → JSON on `127.0.0.1:8974`, plus fallback files. |
| `bridge_metrolist.py` | Linux bridge: MPRIS through `playerctl`, same API and files. |
| `MetrolistArtwork.dll` | Tiny helper that extracts the SMTC artwork stream (source below). |
| `MetrolistArtwork.cs` | Source for the helper, if you want to rebuild or audit it. |

## Quick start (Windows)

1. Start **Metrolist for desktop** and play something once. (The Android/iOS app does not broadcast to your PC; use the desktop app.)
2. Double-click **`start_bridge.bat`**. Leave the console window open.
3. Preview <http://127.0.0.1:8974/> and check the JSON at <http://127.0.0.1:8974/nowplaying>.
4. In OBS: **Sources → + → Browser**, tick **Local file**, select `index.html`, set **Width 640** and **Height 160**. Leave **Shutdown source when not visible** unchecked.

The overlay hides while paused by default. Add `?features=not-hide-on-pause` to the URL to keep the paused track visible.

> The batch file uses Windows PowerShell 5.1 (`powershell.exe`), not PowerShell 7. The SMTC/WinRT APIs and the artwork helper are built for 5.1.

## Quick start (Linux)

Metrolist for Linux publishes a standard MPRIS session (`org.mpris.MediaPlayer2.metrolist`). The bundled Python bridge reads it with `playerctl` and serves the same endpoints as the Windows bridge.

1. Install the one dependency:

   | Distro | Command |
   | --- | --- |
   | Arch / CachyOS / Manjaro | `sudo pacman -S playerctl` |
   | Debian / Ubuntu / Mint | `sudo apt install playerctl` |
   | Fedora | `sudo dnf install playerctl` |
   | openSUSE | `sudo zypper install playerctl` |

2. Start **Metrolist for desktop** and play something. Check that the session is visible:

   ```bash
   playerctl -l          # should list: metrolist
   playerctl -p metrolist metadata
   ```

3. From this folder, start the bridge:

   ```bash
   ./start_bridge.sh
   ```

   If the file is not executable after unzipping: `chmod +x start_bridge.sh install_linux_autostart.sh`.

4. Verify:

   ```bash
   curl http://127.0.0.1:8974/nowplaying
   ```

   Or open <http://127.0.0.1:8974/> in a browser. Leave the terminal open.

5. In OBS: **Sources → + → Browser**, set **URL** to `http://127.0.0.1:8974/`, **Width 640**, **Height 160**. Leave **Shutdown source when not visible** unchecked.

> **Flatpak OBS:** use the `http://127.0.0.1:8974/` URL, not a `file://` path. The Flatpak sandbox may not be allowed to read your home folder, but loopback HTTP works. The same advice applies if local-file artwork is blocked.

To start the bridge automatically at login, run the included installer once:

```bash
./install_linux_autostart.sh
journalctl --user -u metrolist-obs-bridge -f
```

It creates `~/.config/systemd/user/metrolist-obs-bridge.service`, enables it, and starts it. Stop it with `systemctl --user disable --now metrolist-obs-bridge.service`.

## OBS settings

- **Size:** 640×160 is a good default. The reference widget's 400×120 also works, as does a 1920×150 footer. The layout is responsive: under 101 px tall it switches to a single-line `Artist - Title` text-only bar.
- **Local file:** yes, unless you prefer `http://127.0.0.1:8974/`.
- **Shutdown source when not visible:** off. The widget keeps polling while you are on another scene.
- **Refresh browser when scene becomes active:** optional; off avoids a reload flash.
- **Custom CSS:** leave empty. The page is transparent outside the artwork/background.

## Widget parameters

Parameters are read from the browser-source URL. Combine them with `+` (the reference syntax) or spaces:

```text
index.html?features=right+circle-progressbar
index.html?features=transparent-background+disable-time
```

Direct flags also work (`?right=1`, `?transparent-background`). Feature names are case-sensitive.

> OBS's **Local file** picker cannot carry a query string. To use parameters with a local file, uncheck **Local file** and enter a `file:///C:/path/to/index.html?features=...` URL, or use the bridge's own page: `http://127.0.0.1:8974/?features=...`.

| Parameter | Effect |
| --- | --- |
| `right` | Puts the album art on the right and the text/time on the left. |
| `disable-progressbar` | Hides the time and the bottom progress bar. |
| `disable-albumimage` | Hides the circular album art (the blurred background remains). |
| `transparent-background` | Hides the blurred artwork and dark overlay; only the text, art, and controls remain. |
| `circle-progressbar` | Hides the bottom time/progress bar and draws progress as a ring around the album art. |
| `disable-time` | Hides the `0:00 / 0:00` text but keeps the progress bar/ring. |
| `album-spin` | Rotates the album art while playing; pauses the rotation when paused. |
| `not-hide-on-pause` | Keeps the overlay visible while playback is paused. |
| `blink-pause` | Shows a pulsing pause icon over the album art when paused. This implies `not-hide-on-pause`. |
| `url` | Uses a different bridge base URL, e.g. `?url=http://127.0.0.1:9000`. |
| `port` | Shortcut for a different local port, e.g. `?port=9000`. |

The parameters only affect the HTML; no bridge restart is needed.

## How it works

```text
Metrolist desktop
   │  Windows SMTC / Linux MPRIS
   ▼
bridge_metrolist.ps1 / .py
   │  GET /nowplaying              (polled every 1 s)
   │  GET /current_song.js         (fallback when fetch is blocked)
   │  GET /current_cover.*         (artwork)
   │  current_song.json / .js      (file fallback)
   ▼
index.html (OBS Browser Source)
```

The bridge polls the media session every 700 ms and exposes:

- `GET /nowplaying` → JSON
- `GET /current_song.json` → same JSON
- `GET /current_song.js` → `window.METROLIST_NOW_PLAYING = { ... };`
- `GET /` or `/index.html` → the widget
- `GET /current_cover.jpg` (or `.png` / `.webp`) → artwork

Payload:

```json
{
  "title": "Track title",
  "artist": "Artist name",
  "album_art_url": "current_cover.jpg?v=3",
  "is_playing": true,
  "position_ms": 63000,
  "duration_ms": 252000,
  "updated_at": 1760000000000
}
```

`album_art_url` is relative so it works both over HTTP and with a local `file://` page. `updated_at` is used for the stale-data check (15 s) and to estimate the current position between bridge updates.

**Smooth progress:** the widget anchors to the bridge's `position_ms` and advances the bar/time locally every 250 ms while `is_playing` is true. Each new payload resynchronizes it; small differences under 1.5 s are ignored so the bar does not jump every second. In file-fallback mode the bridge rewrites the position at least every 5 s, and the widget interpolates in between.

Position and duration come from the SMTC timeline (Windows) or MPRIS `Position` / `mpris:length` (Linux). If a source provides no duration (for example a live stream), the time/progress UI hides itself.

## File fallback (no HTTP server)

Run:

```bat
start_bridge.bat -NoServer
```

On Linux:

```bash
./start_bridge.sh --no-server
```

The bridge still polls and writes `current_song.json`, `current_song.js`, and the current cover into this folder. The widget reads `current_song.js` with a `<script>` tag because Chromium blocks `fetch()` of local JSON from a `file://` page. Keep `index.html`, the bridge files, and the generated files in the same folder.

Any other tool can drive the widget by writing the same `current_song.js` format.

## Linux notes (MPRIS)

- The bridge auto-detects the player whose MPRIS name contains `metrolist`. Metrolist 14.x uses `org.mpris.MediaPlayer2.metrolist`, which `playerctl` shows as `metrolist`.
- You can run the Python script directly if you prefer: `python3 bridge_metrolist.py`, or with a custom port: `python3 bridge_metrolist.py --port 9000`.
- File-only mode (no HTTP server): `python3 bridge_metrolist.py --no-server`.
- Album art comes from the `mpris:artUrl` metadata. Metrolist normally publishes a YouTube Music HTTPS URL; the bridge downloads it once per track and serves it locally. If the network blocks it, the widget shows the music-note placeholder.
- The AppImage and the `metrolist-desktop-bin` AUR package publish MPRIS; no special Metrolist setting is needed. Metrolist must be running as your desktop user (not as root).
- If `playerctl -l` is empty while Metrolist is playing, check D-Bus directly:

  ```bash
  busctl --user list | grep -i mpris
  busctl --user introspect org.mpris.MediaPlayer2.metrolist /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player
  ```

  If the name is missing, the app did not register its media session (restart Metrolist and play a track).

- Multiple players are fine: only the `metrolist` session is used.
- `playerctl` reads the session of the same user. If you launch Metrolist through a Flatpak or a different user/session, MPRIS may not be visible.

## Customizing

Design tokens are at the top of `index.html`:

```css
--white: #fff;
--muted: rgba(255,255,255,.78);
--subtle: rgba(255,255,255,.62);
--bar-a: #09c;              /* progress gradient start */
--bar-b: #f44;              /* progress gradient end */
--artist-size: clamp(18px, 20vh, 34px);
--title-size: clamp(12px, 13vh, 20px);
--time-size: clamp(10px, 12vh, 16px);
--subtitle-size: clamp(9px, 10vh, 14px);
--gap: clamp(10px, 2.8vh, 20px);
--side: clamp(12px, 2.6vw, 24px);
--bottom: clamp(20px, 13vh, 28px);
--time-reserve: clamp(70px, 15vw, 150px);
```

Fonts use a system UI stack. The original reference uses YouTube Sans (not bundled here); if you have a licensed copy, add an `@font-face` and put it first in the `body` font stack.

To change the bridge port, use `?port=9000` on the widget and start the bridge with `-Port 9000` (PowerShell) or `--port 9000` (Python, for example `./start_bridge.sh --port 9000`).

## Troubleshooting

**The overlay is invisible.**
- Is Metrolist desktop actually playing? By default the widget hides while paused. Add `?features=not-hide-on-pause`.
- Does Metrolist appear in the Windows media flyout? If not, the app has no active SMTC session yet.
- Check the bridge console for `Paused or no Metrolist session - widget hidden.`
- Is the bridge running, and is port 8974 free? Open <http://127.0.0.1:8974/nowplaying>.
- If the JSON is older than 15 seconds, the widget hides itself.

**The progress bar/time is missing.**
- The source must provide `duration_ms`. Live streams and some players do not publish a duration.
- `?features=disable-progressbar` or `?features=circle-progressbar` also hides the bottom bar by design.
- If you use a third-party writer for `current_song.js`, include `position_ms`, `duration_ms`, and `updated_at`.

**The bar is not moving.**
- `position_ms`/`duration_ms` must be present in the JSON.
- The widget advances the bar locally between updates; after 15 s without a fresh `updated_at` it hides.
- Windows SMTC only updates the timeline when the player publishes it; Metrolist does.

**No album art.**
- `MetrolistArtwork.dll` must sit next to the PowerShell script. If Windows blocked it after unzipping, run `Unblock-File .\MetrolistArtwork.dll` once, or use `start_bridge.bat` (it unblocks automatically).
- Some tracks have no thumbnail; the music-note placeholder is shown.
- On Linux, the art URL may be unreachable or require the player's session.

**`start_bridge.bat` closes immediately.**
Run it from a terminal to see the error. Usual causes: missing `MetrolistArtwork.dll`, an old PowerShell, or an execution policy. The batch file already uses `-ExecutionPolicy Bypass`.

**`start_bridge.sh: Permission denied` (Linux).**
The executable bit was lost when the files were copied or unzipped:

```bash
chmod +x start_bridge.sh install_linux_autostart.sh
```

**Linux: `playerctl -l` shows no players.**
Start Metrolist desktop, play a track, and run `playerctl -l` again. If it is still empty, check `busctl --user list | grep -i mpris`. On AppImage builds, make sure you launched the app from the same graphical session, not through `sudo` or a different user. The bridge keeps polling, so it will pick the player up when it appears.

**Linux: the bridge is running but the overlay stays hidden.**
That is expected while paused. Use `?features=not-hide-on-pause` in the browser-source URL to keep the paused track visible. Also confirm `curl http://127.0.0.1:8974/nowplaying` returns a recent `updated_at`.

**Flatpak OBS shows a blank page.**
Use `http://127.0.0.1:8974/` as the browser-source URL instead of a `file://` path, and keep the bridge running. The Flatpak sandbox can reach loopback HTTP but may not have permission to read arbitrary files in your home directory.

**Linux autostart service is not running.**

```bash
systemctl --user status metrolist-obs-bridge
journalctl --user -u metrolist-obs-bridge -n 50
```

Re-run `./install_linux_autostart.sh` after moving the folder; the unit stores the folder's absolute path.

**OBS shows a blank/transparent area.**
- Keep all files in one folder.
- Try `http://127.0.0.1:8974/` as the browser-source URL instead of the local file; that avoids `file://` restrictions entirely.
- Make sure "Shutdown source when not visible" is off.

**Port 8974 is in use.**
Start the bridge with `-Port 9000` (or `--port 9000`) and append `?port=9000` to the widget URL. Alternatively use `?url=http://127.0.0.1:9000`.

## Rebuilding the artwork helper (optional)

The helper source is `MetrolistArtwork.cs`. It needs the Windows SDK union metadata:

```bat
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /target:library /out:MetrolistArtwork.dll ^
  /reference:System.Runtime.WindowsRuntime.dll ^
  /reference:"C:\Program Files (x86)\Windows Kits\10\UnionMetadata\<version>\Windows.winmd" ^
  /reference:"%WINDIR%\Microsoft.NET\assembly\GAC_MSIL\System.Runtime\v4.0_4.0.0.0__b03f5f7f11d50a3a\System.Runtime.dll" ^
  MetrolistArtwork.cs
```

The DLL is original code and only reads the thumbnail Metrolist already handed to Windows.

## Notes

- The bridge listens on **127.0.0.1 only**. Nothing is exposed to your network or the internet.
- No Metrolist code or API is used; the bridge reads the OS media session that the app publishes.
- Metrolist is GPL-3.0; this overlay is a separate program that talks to the operating system.
- The visual layout is inspired by [topik/youtube-music-obs-widget](https://github.com/topik/youtube-music-obs-widget); no code from that project is bundled.
