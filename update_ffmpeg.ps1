[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# FFmpeg Updater v8-public — works in the folder where update_ffmpeg.ps1 is located

$ErrorActionPreference = "Stop"

# Determine script directory (works in PowerShell 5.1/7+)
$root = $PSScriptRoot
if (-not $root -or $root -eq "") {
    $root = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $root -or $root -eq "") {
    $root = (Get-Location).Path
}

$metaFile = Join-Path $root "metadata.json"
$zipPath  = Join-Path $root "ffmpeg-update.zip"

$assetName = "ffmpeg-master-latest-win64-gpl.zip"
$apiUrl    = "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest"

# ----- Pretty helpers -----

function Write-Status {
    param(
        [string]$tag,
        [string]$message,
        [string]$state = ""
    )
    Write-Host "[" -NoNewline -ForegroundColor White
    Write-Host $tag -NoNewline -ForegroundColor Yellow
    Write-Host "] " -NoNewline -ForegroundColor White
    Write-Host $message -NoNewline -ForegroundColor White
    if ($state) {
        Write-Host " $state" -ForegroundColor Green
    } else {
        Write-Host ""
    }
}

function Draw-Progress {
    param(
        [double]$pct,
        [double]$curMB,
        [double]$totMB,
        [double]$speedMB
    )

    $len    = 30
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 1) { $pct = 1 }
    $filled = [int]($pct * $len)
    if ($pct -gt 0 -and $pct -lt 1 -and $filled -lt 1) {
        $filled = 1  # всегда хотя бы один "=" при ненулевом прогрессе
    }
    $empty  = $len - $filled
    if ($empty -lt 0) { $empty = 0 }

    $barFill  = "=" * $filled
    $barEmpty = " " * $empty

    $pctText = ("{0,3}%" -f [int]($pct * 100))
    $curText = ("{0:N1}" -f $curMB)
    $totText = ("{0:N1}" -f $totMB)
    $spdText = ("{0:N1}" -f $speedMB)

    [Console]::Write("`r")

    Write-Host -NoNewline "[" -ForegroundColor White
    if ($barFill.Length -gt 0) {
        Write-Host -NoNewline $barFill -ForegroundColor Magenta
    }
    if ($barEmpty.Length -gt 0) {
        Write-Host -NoNewline $barEmpty -ForegroundColor DarkGray
    }
    Write-Host -NoNewline "] " -ForegroundColor White

    Write-Host -NoNewline "$pctText " -ForegroundColor Red

    Write-Host -NoNewline $curText -ForegroundColor Blue
    Write-Host -NoNewline " MB / " -ForegroundColor White
    Write-Host -NoNewline $totText -ForegroundColor Blue
    Write-Host -NoNewline " MB @ " -ForegroundColor White

    Write-Host -NoNewline $spdText -ForegroundColor Green
    Write-Host -NoNewline " MB/s" -ForegroundColor White
}

# ----- Load old metadata -----

$old = @{}
if (Test-Path $metaFile) {
    try {
        $old = Get-Content $metaFile -Raw | ConvertFrom-Json
    } catch {
        $old = @{}
    }
}

# ----- Capture old ffmpeg version (if exists) -----

$oldVersionLine = $null
$ffmpegPath = Join-Path $root "ffmpeg.exe"
if (Test-Path $ffmpegPath) {
    try {
        $verOut = & $ffmpegPath -version 2>$null
        if ($verOut -and $verOut.Count -gt 0) {
            $oldVersionLine = $verOut[0]
        }
    } catch {
        $oldVersionLine = $null
    }
}

try {
    Write-Status "CHECK" "Checking GitHub API..."

    $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "PowerShell" }
    $asset   = $release.assets | Where-Object { $_.name -eq $assetName }
    if (-not $asset) {
        Write-Host "Asset not found: $assetName" -ForegroundColor Red
        return
    }

    $buildDate   = $asset.updated_at
    $downloadUrl = $asset.browser_download_url

    Write-Status "CHECK" "Fetching ETag and file size..."

    $head       = Invoke-WebRequest -Uri $downloadUrl -Method Head -Headers @{ "User-Agent"="PowerShell" }
    $etag       = $head.Headers.ETag
    $totalBytes = 0
    if ($head.Headers.'Content-Length') {
        [int64]$totalBytes = $head.Headers.'Content-Length'
    }

    if (-not $etag) {
        Write-Host "Error: GitHub did not return an ETag." -ForegroundColor Red
        return
    }

    if ($old.etag -eq $etag) {
        Write-Host ""
        Write-Host "FFmpeg is already up to date. (ETag match)" -ForegroundColor Green
        Write-Host ""
        Write-Host "ETag: " -NoNewline -ForegroundColor Red
        Write-Host $old.etag -ForegroundColor Cyan
        Write-Host "Build date: " -NoNewline -ForegroundColor White
        Write-Host $old.build_date -ForegroundColor Magenta
        if ($oldVersionLine) {
            Write-Host ""
            Write-Host "Current FFmpeg: " -NoNewline -ForegroundColor White
            Write-Host $oldVersionLine -ForegroundColor Green
        }
        return
    }

    Write-Status "ETAG" "Remote ETag differs from local." "NEW"
    Write-Host ""
    Write-Status "DL" "Starting download to ZIP via curl.exe (fast mode)..."

    if ($totalBytes -le 0) {
        Write-Host "Warning: Content-Length not provided. Progress bar may be inaccurate." -ForegroundColor Yellow
    }

    $thresholdMBps = 1.0
    $sampleBytes   = 3MB
    if ($totalBytes -gt 0 -and $sampleBytes -gt $totalBytes) {
        $sampleBytes = [int64]($totalBytes / 4)
    }

    function Invoke-DownloadToFile {
        param(
            [string]$url,
            [string]$zipPath,
            [int64]$totalBytes,
            [int]$attempt,
            [double]$thresholdMBps,
            [int64]$sampleBytes
        )

        $result = @{
            Success        = $false
            WasSlow        = $false
            AbortedByUser  = $false
            BytesWritten   = 0
            AvgSpeedMBps   = 0.0
            ErrorMessage   = $null
        }

        if (Test-Path $zipPath) {
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        }

        $fs = $null
        try {
            $fs = [System.IO.File]::Create($zipPath)
        } catch {
            $result.ErrorMessage = "Failed to create ZIP file: $($_.Exception.Message)"
            return $result
        }

        $buffer = New-Object byte[] 65536

        $psi                        = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = "curl.exe"
        $psi.Arguments              = "--silent --http1.1 -L `"$url`""
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true

        try {
            $proc   = [System.Diagnostics.Process]::Start($psi)
        } catch {
            if ($fs) { $fs.Dispose() }
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            $result.ErrorMessage = "Failed to start curl.exe: $($_.Exception.Message)"
            return $result
        }

        $stdout = $proc.StandardOutput.BaseStream

        $totalRead     = 0L
        $sw            = [System.Diagnostics.Stopwatch]::StartNew()
        $sampleChecked = $false

        if ($totalBytes -gt 0) {
            Draw-Progress 0 0 ($totalBytes/1MB) 0
        }

        while (-not $proc.HasExited) {
            $read = $stdout.Read($buffer, 0, $buffer.Length)
            if ($read -gt 0) {
                $fs.Write($buffer, 0, $read)
                $totalRead += $read

                if ($totalBytes -gt 0) {
                    $pct    = $totalRead / [double]$totalBytes
                    $curMB  = $totalRead / 1MB
                    $totMB  = $totalBytes / 1MB
                    $speed  = ($totalRead / 1MB) / [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
                    Draw-Progress $pct $curMB $totMB $speed
                }

                if (-not $sampleChecked -and $totalBytes -gt 0 -and $totalRead -ge $sampleBytes) {
                    $sampleChecked = $true
                    $speedSample = ($totalRead / 1MB) / [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
                    if ($speedSample -lt $thresholdMBps) {
                        $result.WasSlow = $true
                        if ($attempt -eq 1) {
                            try { $proc.Kill() } catch {}
                            break
                        } elseif ($attempt -eq 2) {
                            Write-Host ""
                            Write-Host ""
                            Write-Host ("Download speed is low (~{0:N1} MB/s)." -f $speedSample) -ForegroundColor Yellow
                            Write-Host "This is likely due to your network, not GitHub throttling." -ForegroundColor Yellow
                            Write-Host ""
                            Write-Host "1) Continue download at this speed" -ForegroundColor White
                            Write-Host "2) Abort update" -ForegroundColor White
                            $choice = Read-Host "Choose (1 or 2)"
                            if ($choice -eq "2") {
                                $result.AbortedByUser = $true
                                try { $proc.Kill() } catch {}
                                break
                            }
                        }
                    }
                }
            }
        }

        while (($read = $stdout.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fs.Write($buffer, 0, $read)
            $totalRead += $read
            if ($totalBytes -gt 0) {
                $pct    = $totalRead / [double]$totalBytes
                $curMB  = $totalRead / 1MB
                $totMB  = $totalBytes / 1MB
                $speed  = ($totalRead / 1MB) / [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
                Draw-Progress $pct $curMB $totMB $speed
            }
        }

        $proc.WaitForExit()
        $sw.Stop()
        $fs.Flush()
        $fs.Dispose()
        $fs = $null

        if ($result.AbortedByUser) {
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            $result.ErrorMessage = "Aborted by user due to low speed."
            return $result
        }

        if ($attempt -eq 1 -and $result.WasSlow) {
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            $result.ErrorMessage = "First attempt was too slow, will retry."
            return $result
        }

        if ($proc.ExitCode -ne 0) {
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            $result.ErrorMessage = "curl exited with code $($proc.ExitCode)."
            return $result
        }

        if ($totalRead -le 0) {
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            $result.ErrorMessage = "No data downloaded."
            return $result
        }

        $avgSpeed = ($totalRead / 1MB) / [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
        if ($totalBytes -gt 0) {
            $finalMB = $totalBytes / 1MB
            Draw-Progress 1 $finalMB $finalMB $avgSpeed
            Write-Host ""
        } else {
            Write-Host ""
            Write-Host "Download complete (size unknown)." -ForegroundColor Yellow
        }

        $result.Success      = $true
        $result.BytesWritten = $totalRead
        $result.AvgSpeedMBps = $avgSpeed
        return $result
    }

    # ----- Run download with possible retry -----

    $downloadOk = $false

    $firstResult = Invoke-DownloadToFile -url $downloadUrl -zipPath $zipPath -totalBytes $totalBytes -attempt 1 -thresholdMBps $thresholdMBps -sampleBytes $sampleBytes

    if ($firstResult.AbortedByUser) {
        Write-Host ""
        Write-Host $firstResult.ErrorMessage -ForegroundColor Red
        return
    }

    if ($firstResult.Success -and -not $firstResult.WasSlow) {
        $downloadOk = $true
    } else {
        Write-Host ""
        Write-Host "First attempt was slow or failed: $($firstResult.ErrorMessage)" -ForegroundColor Yellow
        Write-Host "Retrying download (attempt 2)..." -ForegroundColor Yellow

        $secondResult = Invoke-DownloadToFile -url $downloadUrl -zipPath $zipPath -totalBytes $totalBytes -attempt 2 -thresholdMBps $thresholdMBps -sampleBytes $sampleBytes

        if ($secondResult.AbortedByUser) {
            Write-Host ""
            Write-Host $secondResult.ErrorMessage -ForegroundColor Red
            return
        }

        if (-not $secondResult.Success) {
            Write-Host ""
            Write-Host "Second attempt failed: $($secondResult.ErrorMessage)" -ForegroundColor Red
            return
        }

        $downloadOk = $true
    }

    if (-not $downloadOk) {
        Write-Host "Download failed." -ForegroundColor Red
        return
    }

    if (-not (Test-Path $zipPath)) {
        Write-Host "Download failed: ZIP file not found." -ForegroundColor Red
        return
    }

    if ($totalBytes -gt 0) {
        $zipLen = (Get-Item $zipPath).Length
        if ($zipLen -ne $totalBytes) {
            Write-Host ""
            Write-Host ("Error: downloaded size ({0:N1} MB) does not match expected Content-Length ({1:N1} MB)." -f ($zipLen/1MB), ($totalBytes/1MB)) -ForegroundColor Red
            Write-Host "Archive appears incomplete or corrupted. Please try again later." -ForegroundColor Red
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            return
        }
    }

    Write-Host ""
    Write-Status "ZIP" "Archive downloaded to file successfully." "OK"

    # ----- Unzip from file -----

    Write-Status "UNZIP" "Extracting ffmpeg/ffprobe/ffplay from archive..."

    try {
        Add-Type -AssemblyName System.IO.Compression | Out-Null
    } catch {}
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    } catch {}

    $fs = $null
    $zip = $null
    try {
        $fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)

        function Extract-EntryToFile {
            param(
                [System.IO.Compression.ZipArchive]$zip,
                [string]$pattern,
                [string]$destPath
            )
            $entry = $zip.Entries | Where-Object { $_.FullName -match $pattern } | Select-Object -First 1
            if (-not $entry) {
                throw "Entry matching pattern '$pattern' not found in archive."
            }
            $inStream  = $entry.Open()
            $outStream = [System.IO.File]::Create($destPath)
            try {
                $inStream.CopyTo($outStream)
            }
            finally {
                $outStream.Close()
                $inStream.Close()
            }
        }

        Extract-EntryToFile -zip $zip -pattern "/bin/ffmpeg\.exe$"  -destPath (Join-Path $root "ffmpeg.exe")
        Extract-EntryToFile -zip $zip -pattern "/bin/ffprobe\.exe$" -destPath (Join-Path $root "ffprobe.exe")
        Extract-EntryToFile -zip $zip -pattern "/bin/ffplay\.exe$"  -destPath (Join-Path $root "ffplay.exe")
    }
    catch {
        Write-Host "Error extracting binaries: $($_.Exception.Message)" -ForegroundColor Red
        if ($zip) { $zip.Dispose() }
        if ($fs)  { $fs.Dispose() }
        if (Test-Path $zipPath) {
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        }
        return
    }
    finally {
        if ($zip) { $zip.Dispose() }
        if ($fs)  { $fs.Dispose() }
        if (Test-Path $zipPath) {
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Status "COPY" "Binaries updated (ffmpeg/ffprobe/ffplay)." "OK"

    @{
        etag       = $etag
        build_date = $buildDate
    } | ConvertTo-Json | Out-File $metaFile -Encoding UTF8

    $newVersionLine = $null
    if (Test-Path $ffmpegPath) {
        try {
            $verOut2 = & $ffmpegPath -version 2>$null
            if ($verOut2 -and $verOut2.Count -gt 0) {
                $newVersionLine = $verOut2[0]
            }
        } catch {
            $newVersionLine = $null
        }
    }

    Write-Host ""
    Write-Host "FFmpeg updated successfully." -ForegroundColor Green
    Write-Host ""
    Write-Host "ETag: " -NoNewline -ForegroundColor Red
    Write-Host $etag -ForegroundColor Cyan
    Write-Host "Build date: " -NoNewline -ForegroundColor White
    Write-Host $buildDate -ForegroundColor Magenta

    Write-Host ""
    if ($oldVersionLine) {
        Write-Host "Old FFmpeg: " -NoNewline -ForegroundColor White
        Write-Host $oldVersionLine -ForegroundColor Yellow
    } else {
        Write-Host "Old FFmpeg: " -NoNewline -ForegroundColor White
        Write-Host "not installed" -ForegroundColor Yellow
    }
    if ($newVersionLine) {
        Write-Host "New FFmpeg: " -NoNewline -ForegroundColor White
        Write-Host $newVersionLine -ForegroundColor Green
    }
}
catch {
    Write-Host ""
    Write-Host "Error during update: $($_.Exception.Message)" -ForegroundColor Red
}