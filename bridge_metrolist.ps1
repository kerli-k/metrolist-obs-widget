[CmdletBinding()]
param(
    [int]$Port = 8974,
    [switch]$NoServer
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)

# ---------- Windows Runtime (SMTC) ----------
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and
    $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await($operation, $resultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($resultType)
    $task = $asTask.Invoke($null, @($operation))
    if (-not $task.Wait(5000)) { throw 'Windows Runtime operation timed out.' }
    $task.Result
}

[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime] | Out-Null

# ---------- Album art helper (reads the SMTC thumbnail stream) ----------
$hasArtHelper = $false
try {
    $helperPath = Join-Path $scriptDir 'MetrolistArtwork.dll'
    if (-not (Test-Path -LiteralPath $helperPath)) { throw "MetrolistArtwork.dll not found next to the script." }
    Unblock-File -LiteralPath $helperPath -ErrorAction SilentlyContinue
    if (-not ('MetrolistArtwork' -as [type])) { Add-Type -Path $helperPath }
    $hasArtHelper = $true
} catch {
    Write-Warning "Album art is unavailable: $($_.Exception.Message)"
}

# ---------- Shared state ----------
$manager = $null
$stateJson = '{"title":"","artist":"","album_art_url":"","is_playing":false,"position_ms":0,"duration_ms":0,"updated_at":0}'
$stateJs = "window.METROLIST_NOW_PLAYING = $stateJson;"
$coverBytes = $null
$coverName = ''
$coverType = 'image/jpeg'
$artVersion = 0
$lastTrackKey = ''
$lastLogKey = ''
$stateWriteCore = ''
$stateWriteAt = [DateTime]::MinValue

$indexBytes = $null
$indexPath = Join-Path $scriptDir 'index.html'
if (Test-Path -LiteralPath $indexPath) {
    $indexBytes = [System.IO.File]::ReadAllBytes($indexPath)
}

function Write-TextAtomic([string]$path, [string]$text) {
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $text, $utf8)
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Write-BytesAtomic([string]$path, [byte[]]$bytes) {
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllBytes($tmp, $bytes)
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Clear-Cover {
    if ($script:coverName) {
        Remove-Item -LiteralPath (Join-Path $script:scriptDir $script:coverName) -Force -ErrorAction SilentlyContinue
    }
    $script:coverBytes = $null
    $script:coverName = ''
    $script:coverType = 'image/jpeg'
}

function Set-Cover($thumbnail) {
    if (-not $script:hasArtHelper -or -not $thumbnail) {
        Clear-Cover
        return
    }

    try {
        $art = [MetrolistArtwork]::Read($thumbnail)
        if (-not $art -or -not $art.Data -or $art.Data.Length -eq 0) {
            Clear-Cover
            return
        }

        $contentType = ([string]$art.ContentType -split ',')[0].Trim().ToLowerInvariant()
        switch ($contentType) {
            'image/png'  { $ext = 'png';  $mime = 'image/png' }
            'image/webp' { $ext = 'webp'; $mime = 'image/webp' }
            'image/gif'  { $ext = 'gif';  $mime = 'image/gif' }
            'image/bmp'  { $ext = 'bmp';  $mime = 'image/bmp' }
            default      { $ext = 'jpg';  $mime = 'image/jpeg' }
        }

        $name = "current_cover.$ext"
        if ($script:coverName -and $script:coverName -ne $name) {
            Remove-Item -LiteralPath (Join-Path $script:scriptDir $script:coverName) -Force -ErrorAction SilentlyContinue
        }

        Write-BytesAtomic (Join-Path $script:scriptDir $name) $art.Data
        $script:coverBytes = $art.Data
        $script:coverName = $name
        $script:coverType = $mime
        $script:artVersion++
        Write-Host ("Album art: {0} ({1:N0} KB)" -f $name, ($art.Data.Length / 1KB)) -ForegroundColor DarkGray
    } catch {
        Write-Warning "Could not read album art: $($_.Exception.Message)"
        Clear-Cover
    }
}

function Update-State {
    $isPlaying = $false
    $title = ''
    $artist = ''
    $positionMs = 0
    $durationMs = 0

    if (-not $script:manager) {
        try {
            $script:manager = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        } catch {
            $script:manager = $null
        }
    }

    if ($script:manager) {
        try {
            $session = @($script:manager.GetSessions()) |
                Where-Object { $_.SourceAppUserModelId -match '(?i)metrolist' } |
                Select-Object -First 1

            if ($session) {
                $info = $session.GetPlaybackInfo()
                $isPlaying = ([string]$info.PlaybackStatus -eq 'Playing')

                $props = Await ($session.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
                $title = [string]$props.Title
                $artist = [string]$props.Artist

                try {
                    $timeline = $session.GetTimelineProperties()
                    $startMs = $timeline.StartTime.TotalMilliseconds
                    $endMs = $timeline.EndTime.TotalMilliseconds
                    if ($endMs -le $startMs) { $endMs = $timeline.MaxSeekTime.TotalMilliseconds }
                    if ($endMs -gt $startMs) {
                        $durationMs = $endMs - $startMs
                        $positionMs = [Math]::Max(0, $timeline.Position.TotalMilliseconds - $startMs)
                        if ($positionMs -gt $durationMs) { $positionMs = $durationMs }
                    }
                } catch {
                    $positionMs = 0
                    $durationMs = 0
                }

                $trackKey = "$title`0$artist"
                if ($trackKey -ne $script:lastTrackKey) {
                    $script:lastTrackKey = $trackKey
                    Set-Cover $props.Thumbnail
                }
            } else {
                $script:lastTrackKey = ''
                Clear-Cover
            }
        } catch {
            # A session can disappear between GetSessions() and reading it, or
            # the manager can go stale after sleep/resume. Rebuild it next tick.
            $script:manager = $null
            $isPlaying = $false
            $script:lastTrackKey = ''
            Clear-Cover
        }
    }

    $state = [ordered]@{
        title         = $title
        artist        = $artist
        album_art_url = if ($script:coverName) { "$($script:coverName)?v=$($script:artVersion)" } else { '' }
        is_playing    = [bool]$isPlaying
        position_ms   = [int64][Math]::Round($positionMs)
        duration_ms   = [int64][Math]::Round($durationMs)
        updated_at    = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }

    $json = $state | ConvertTo-Json -Compress
    $script:stateJson = $json
    $script:stateJs = "window.METROLIST_NOW_PLAYING = $json;"

    # Rewrite the fallback files on change and at least every 5 seconds so the
    # widget's stale-data check keeps working without hammering the disk.
    $core = "$title`0$artist`0$isPlaying`0$($script:coverName)`0$($script:artVersion)`0$([int64][Math]::Round($durationMs))"
    if ($core -ne $script:stateWriteCore -or ([DateTime]::UtcNow - $script:stateWriteAt).TotalSeconds -ge 5) {
        Write-TextAtomic (Join-Path $script:scriptDir 'current_song.json') $json
        Write-TextAtomic (Join-Path $script:scriptDir 'current_song.js') $script:stateJs
        $script:stateWriteCore = $core
        $script:stateWriteAt = [DateTime]::UtcNow
    }

    $logKey = if ($isPlaying) { "playing`0$artist`0$title" } else { 'hidden' }
    if ($logKey -ne $script:lastLogKey) {
        $script:lastLogKey = $logKey
        if ($isPlaying) {
            Write-Host ("Playing: {0} - {1}" -f $artist, $title) -ForegroundColor Green
        } else {
            Write-Host 'Paused or no Metrolist session - widget hidden.' -ForegroundColor DarkGray
        }
    }
}

# ---------- Tiny loopback HTTP server ----------
function Send-Response($stream, [int]$code, [string]$reason, [string]$contentType, [byte[]]$body) {
    if ($null -eq $body) { $body = [byte[]]@() }
    $head = "HTTP/1.1 $code $reason`r`n" +
            "Content-Type: $contentType`r`n" +
            "Content-Length: $($body.Length)`r`n" +
            "Cache-Control: no-store`r`n" +
            "Access-Control-Allow-Origin: *`r`n" +
            "Connection: close`r`n`r`n"
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($headBytes, 0, $headBytes.Length)
    if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
    $stream.Flush()
}

function Handle-Client($client) {
    try {
        $client.NoDelay = $true
        $stream = $client.GetStream()
        $stream.ReadTimeout = 2000
        $stream.WriteTimeout = 2000

        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
        $requestLine = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($requestLine)) { return }

        while ($true) {
            $header = $reader.ReadLine()
            if ($null -eq $header -or $header -eq '') { break }
        }

        $parts = $requestLine -split ' '
        if ($parts.Count -lt 2 -or $parts[0] -ne 'GET') {
            Send-Response $stream 405 'Method Not Allowed' 'text/plain; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes('Method Not Allowed'))
            return
        }

        $path = ($parts[1] -split '\?')[0]

        switch ($path) {
            '/' {
                if ($script:indexBytes) {
                    Send-Response $stream 200 'OK' 'text/html; charset=utf-8' $script:indexBytes
                } else {
                    Send-Response $stream 404 'Not Found' 'text/plain; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes('index.html not found next to the bridge script.'))
                }
            }
            '/index.html' {
                if ($script:indexBytes) {
                    Send-Response $stream 200 'OK' 'text/html; charset=utf-8' $script:indexBytes
                } else {
                    Send-Response $stream 404 'Not Found' 'text/plain; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes('Not Found'))
                }
            }
            '/nowplaying' {
                Send-Response $stream 200 'OK' 'application/json; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes($script:stateJson))
            }
            '/current_song.json' {
                Send-Response $stream 200 'OK' 'application/json; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes($script:stateJson))
            }
            '/current_song.js' {
                Send-Response $stream 200 'OK' 'application/javascript; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes($script:stateJs))
            }
            default {
                if ($script:coverName -and $path -eq "/$($script:coverName)" -and $script:coverBytes) {
                    Send-Response $stream 200 'OK' $script:coverType $script:coverBytes
                } else {
                    Send-Response $stream 404 'Not Found' 'text/plain; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes('Not Found'))
                }
            }
        }
    } catch {
        # Client disconnected or timed out. Nothing to do.
    } finally {
        $client.Close()
    }
}

# ---------- Start ----------
Write-Host ''
Write-Host 'Metrolist Now Playing bridge' -ForegroundColor Cyan
Write-Host 'Windows System Media Transport Controls -> local overlay data' -ForegroundColor DarkGray
Write-Host ''

$listener = $null
if (-not $NoServer) {
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        Write-Host "HTTP server: http://127.0.0.1:$Port/nowplaying" -ForegroundColor Green
        Write-Host "Widget preview: http://127.0.0.1:$Port/" -ForegroundColor Green
    } catch {
        Write-Warning "Could not listen on 127.0.0.1:$Port ($($_.Exception.Message))."
        Write-Warning 'Continuing in file-only mode.'
        $listener = $null
    }
} else {
    Write-Host 'HTTP server disabled (-NoServer). Using file fallback only.' -ForegroundColor Yellow
}

Write-Host ("Files: {0}" -f (Join-Path $scriptDir 'current_song.json')) -ForegroundColor DarkGray
Write-Host 'OBS: add index.html as a Browser Source (suggested 640x160).' -ForegroundColor DarkGray
Write-Host 'Press Ctrl+C to stop.' -ForegroundColor DarkGray
Write-Host ''

$nextPoll = [DateTime]::UtcNow

try {
    while ($true) {
        if ($listener) {
            while ($listener.Pending()) {
                Handle-Client ($listener.AcceptTcpClient())
            }
        }

        if ([DateTime]::UtcNow -ge $nextPoll) {
            try {
                Update-State
            } catch {
                Write-Warning "Could not update playback state: $($_.Exception.Message)"
            }
            $nextPoll = [DateTime]::UtcNow.AddMilliseconds(700)
        }

        Start-Sleep -Milliseconds 100
    }
} finally {
    if ($listener) { $listener.Stop() }
    Write-Host 'Bridge stopped.' -ForegroundColor DarkGray
}
