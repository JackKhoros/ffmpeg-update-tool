[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# FFmpeg Updater v8.6.1 вЂ” works in the folder where update_ffmpeg.ps1 is located

$ErrorActionPreference = "Stop"

$script:SpeedThresholdMBps = 0.0


# Determine script directory (works in PowerShell 5.1/7+)
$root = $PSScriptRoot
if (-not $root -or $root -eq "") {
    if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
        $root = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $root = (Get-Location).Path
    }
}

$metaFile = Join-Path $root "metadata.json"
$zipPath  = Join-Path $root "ffmpeg-update.zip"

$assetName      = "ffmpeg-master-latest-win64-gpl.zip"
$altMasterPattern = "ffmpeg-N-*-win64-gpl.zip"
$apiLatestUrl   = "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest"
$apiReleasesUrl = "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases?per_page=10"

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
        $filled = 1  # РІСЃРµРіРґР° С…РѕС‚СЏ Р±С‹ РѕРґРёРЅ "=" РїСЂРё РЅРµРЅСѓР»РµРІРѕРј РїСЂРѕРіСЂРµСЃСЃРµ
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
        Write-Host -NoNewline $barFill -ForegroundColor White
    }
    if ($barEmpty.Length -gt 0) {
        Write-Host -NoNewline $barEmpty -ForegroundColor White
    }
    Write-Host -NoNewline "] " -ForegroundColor White

    Write-Host -NoNewline "$pctText " -ForegroundColor Red

    Write-Host -NoNewline $curText -ForegroundColor Blue
    Write-Host -NoNewline " MB / " -ForegroundColor White
    Write-Host -NoNewline $totText -ForegroundColor Blue
    Write-Host -NoNewline " MB @ " -ForegroundColor White

    if ($script:SpeedThresholdMBps -gt 0 -and $speedMB -gt 0 -and $speedMB -lt $script:SpeedThresholdMBps) {
        Write-Host -NoNewline $spdText -ForegroundColor DarkRed
    } else {
        Write-Host -NoNewline $spdText -ForegroundColor Green
    }
    Write-Host -NoNewline " MB/s" -ForegroundColor White
}

function Get-ExpectedSha256FromChecksums {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$AssetName
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    # checksums.sha256 in BtbN/FFmpeg-Builds is plain ASCII/UTF-8 without BOM.
    # Read as UTF8 explicitly so PowerShell does not guess a wider encoding.
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }

        # Each line has the form:
        #   <sha256>  <filename>
        # Split into two parts: hash and filename.
        $parts = $trimmed -split "\s+", 2
        if ($parts.Count -ne 2) { continue }

        $hash = $parts[0].Trim()
        $name = $parts[1].Trim()

        # Some checksum formats prefix filenames with "*" (binary mode).
        if ($name.StartsWith("*")) {
            $name = $name.Substring(1).Trim()
        }

        if ($name -eq $AssetName) {
            return $hash
        }
    }

    return $null
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
    # Script version
$ScriptVersion = "v8.6.1"

Write-Host "==============================================="
Write-Host (" FFmpeg Updater {0}" -f $ScriptVersion) -ForegroundColor Cyan
Write-Host "==============================================="
Write-Host ""

Write-Status "CHECK" "Checking GitHub API..."

    $headers = @{ "User-Agent" = "PowerShell" }

    $release       = $null
    $asset         = $null
    $releases      = $null
    $latestRelease = $null
    $latestAsset   = $null
    $newest        = $null
    $newestAsset   = $null
    $usingNonStandardAssetName = $false

    function Get-MasterAssetFromRelease {
        param(
            [Parameter(Mandatory = $true)]
            $Rel
        )

        if (-not $Rel -or -not $Rel.assets) {
            return $null
        }

        # 1) Try canonical master asset name first
        $std = $Rel.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
        if ($std) {
            return $std
        }

        # 2) Try snapshot-style master name (e.g. ffmpeg-N-121951-g7043522fe0-win64-gpl.zip)
        $alt = $Rel.assets | Where-Object { $_.name -like $altMasterPattern } | Select-Object -First 1
        if ($alt) {
            return $alt
        }

        return $null
    }

    try {
        # 1) Query a page of releases and find the newest one that contains a master build (standard or snapshot name)
        $releases = Invoke-RestMethod -Uri $apiReleasesUrl -Headers $headers

        if ($releases) {
            $candidates = @()

            foreach ($rel in $releases) {
                $candidateAsset = Get-MasterAssetFromRelease -Rel $rel
                if ($candidateAsset) {
                    $candidates += [PSCustomObject]@{
                        Release = $rel
                        Asset   = $candidateAsset
                    }
                }
            }

            if ($candidates.Count -gt 0) {
                $selected = $candidates |
                    Sort-Object -Property { [DateTime]$_.Release.published_at } -Descending |
                    Select-Object -First 1

                $newest      = $selected.Release
                $newestAsset = $selected.Asset
            }
        }
    } catch {
        # Ignore errors here; we'll try /latest below if needed
    }

    try {
        # 2) Also query /releases/latest (GitHub's idea of "latest") and look for master there
        $latestRelease = Invoke-RestMethod -Uri $apiLatestUrl -Headers $headers
        if ($latestRelease) {
            $latestAsset = Get-MasterAssetFromRelease -Rel $latestRelease
        }
    } catch {
        # Ignore; if this fails, we'll just use whatever we got from the releases list
    }

    # 3) Decide which release to use
    if ($newest -and $newestAsset -and $latestRelease -and $latestAsset) {
        $newestDate = [DateTime]$newest.published_at
        $latestDate = [DateTime]$latestRelease.published_at

        if ($latestDate -ge $newestDate) {
            $release = $latestRelease
            $asset   = $latestAsset
        } else {
            $release = $newest
            $asset   = $newestAsset
        }
    } elseif ($newest -and $newestAsset) {
        $release = $newest
        $asset   = $newestAsset
    } elseif ($latestRelease -and $latestAsset) {
        $release = $latestRelease
        $asset   = $latestAsset
    } elseif ($latestRelease) {
        # Fallback: try to use /latest with the canonical name only
        if ($latestRelease.assets) {
            $asset = $latestRelease.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
            if ($asset) {
                $release = $latestRelease
            }
        }
    }

    if (-not $asset) {
        Write-Host "Asset not found: $assetName (or snapshot pattern $altMasterPattern)" -ForegroundColor Red
        return
    }

    # Detect if the selected master asset uses a non-standard name
    $usingNonStandardAssetName = $asset.name -ne $assetName
    if ($usingNonStandardAssetName) {
        # [INFO] prefix styled like Write-Status (white brackets, yellow tag)
        Write-Host "[" -NoNewline -ForegroundColor White
        Write-Host "INFO" -NoNewline -ForegroundColor Yellow
        Write-Host "] " -NoNewline -ForegroundColor White

        # Emphasize the descriptive part of the message in bright yellow,
        # but keep the package name in the same yellow as INFO/CHECK tags.
        Write-Host "Using master asset with non-standard name: " -NoNewline -ForegroundColor Yellow
        Write-Host $asset.name -ForegroundColor Yellow
    }

    $buildDate   = $asset.updated_at
    $downloadUrl = $asset.browser_download_url

    # Log which release/tag we are using
    $releaseTag = $null
    if ($release -and $release.tag_name) {
        $releaseTag = $release.tag_name
    } elseif ($release -and $release.name) {
        $releaseTag = $release.name
    } else {
        $releaseTag = "latest"
    }

    $publishedAt = $null
    if ($release -and $release.published_at) {
        $publishedAt = [string]$release.published_at
    } else {
        $publishedAt = "unknown"
    }

    Write-Status "CHECK" ("Selected build: {0} (published {1})" -f $releaseTag, $publishedAt)

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
        $ffmpegPath  = Join-Path $root "ffmpeg.exe"
        $ffprobePath = Join-Path $root "ffprobe.exe"
        $ffplayPath  = Join-Path $root "ffplay.exe"

        $required = @(
            @{ Name = "ffmpeg.exe";  Path = $ffmpegPath  },
            @{ Name = "ffprobe.exe"; Path = $ffprobePath },
            @{ Name = "ffplay.exe";  Path = $ffplayPath  }
        )

        $missing = $required | Where-Object { -not (Test-Path $_.Path) }

        if ($missing.Count -eq 0) {
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

        $missingNames = ($missing | ForEach-Object { $_.Name }) -join ", "
        Write-Host "[" -NoNewline -ForegroundColor White
        Write-Host "WARN" -NoNewline -ForegroundColor Yellow
        Write-Host "] " -NoNewline -ForegroundColor White
        Write-Host ("ETag matches but required binaries are missing: {0}. Re-downloading..." -f $missingNames) -ForegroundColor Yellow
        # Fall through to download logic
    }

    # ----- Optional SHA256 checksum preparation -----
    $checksumAvailable = $false
    $expectedSha256    = $null

    $checksumAsset = $null
    if ($release -and $release.assets) {
        $checksumAsset = $release.assets | Where-Object { $_.name -eq "checksums.sha256" } | Select-Object -First 1
    }

    if ($checksumAsset) {
        try {
            $checksumPath = Join-Path $root "checksums.sha256"
            if (Test-Path $checksumPath) {
                Remove-Item $checksumPath -Force -ErrorAction SilentlyContinue
            }

            Invoke-WebRequest -Uri $checksumAsset.browser_download_url -OutFile $checksumPath -Headers @{ "User-Agent" = "PowerShell" }

            $expectedSha256 = Get-ExpectedSha256FromChecksums -Path $checksumPath -AssetName $asset.name

            Remove-Item $checksumPath -Force -ErrorAction SilentlyContinue

            if ($expectedSha256) {
                $checksumAvailable = $true
            } else {
                Write-Host "[" -NoNewline -ForegroundColor White
                Write-Host "WARN" -NoNewline -ForegroundColor Yellow
                Write-Host "] " -NoNewline -ForegroundColor White
                Write-Host ("SHA256 entry not found for asset {0} in checksums.sha256. Skipping integrity validation." -f $asset.name) -ForegroundColor Yellow
            }
        } catch {
            if (Test-Path $checksumPath) {
                Remove-Item $checksumPath -Force -ErrorAction SilentlyContinue
            }
            Write-Host "[" -NoNewline -ForegroundColor White
            Write-Host "WARN" -NoNewline -ForegroundColor Yellow
            Write-Host "] " -NoNewline -ForegroundColor White
            Write-Host "Failed to download or parse checksums.sha256. Skipping SHA256 validation." -ForegroundColor Yellow
        }
    } else {
        Write-Host "[" -NoNewline -ForegroundColor White
        Write-Host "WARN" -NoNewline -ForegroundColor Yellow
        Write-Host "] " -NoNewline -ForegroundColor White
        Write-Host "SHA256 checksum file (checksums.sha256) is missing for this release. Skipping integrity validation." -ForegroundColor Yellow
    }

    Write-Status "ETAG" "Remote ETag differs from local." "NEW"
    Write-Host ""
    Write-Status "DL" "Starting download to ZIP via curl.exe (fast mode)..."

    $curlCmd = Get-Command "curl.exe" -ErrorAction SilentlyContinue
    if (-not $curlCmd) {
        Write-Host "curl.exe not found on PATH. Please install or restore curl.exe (it is bundled with modern Windows)." -ForegroundColor Red
        return
    }
    $curlPath = $curlCmd.Source


    if ($totalBytes -le 0) {
        Write-Host "Warning: Content-Length not provided. Progress bar may be inaccurate." -ForegroundColor Yellow
    }

    $thresholdMBps = 1.0
    $script:SpeedThresholdMBps = $thresholdMBps
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
        $psi.FileName               = $curlPath
        $psi.Arguments              = "--silent --show-error --fail-with-body --http1.1 -L `"$url`""
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
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

        $errText = ""
        try {
            $errText = $proc.StandardError.ReadToEnd().Trim()
        } catch {
            $errText = ""
        }

        if ($proc.ExitCode -ne 0) {
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            $result.ErrorMessage = "curl exited with code $($proc.ExitCode)."
            if (-not [string]::IsNullOrWhiteSpace($errText)) {
                $result.ErrorMessage += " Details: $errText"
            }
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

    # ----- Run download with possible retry (speed + SHA256) -----

    $maxIntegrityAttempts = 2
    $integrityAttempt     = 0
    $downloadOk           = $false

    while ($integrityAttempt -lt $maxIntegrityAttempts) {
        $integrityAttempt++

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
                Write-Host ("Error: downloaded size ({0:N1} MB) does not match expected size ({1:N1} MB)." -f ($zipLen/1MB), ($totalBytes/1MB)) -ForegroundColor Red
                Write-Host "Archive appears incomplete or corrupted. Please try again later." -ForegroundColor Red
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                return
            }
        }

        # Optional SHA256 validation
        if ($checksumAvailable -and $expectedSha256) {
            try {
                $fileHash      = Get-FileHash -Algorithm SHA256 -Path $zipPath
                $actualSha256  = $fileHash.Hash.ToLowerInvariant()
                $expectedLower = $expectedSha256.ToLowerInvariant()
                $hashesMatch   = ($actualSha256 -eq $expectedLower)

                # Report HASH status with explicit PASS/FAIL
                Write-Host "[" -NoNewline -ForegroundColor White
                Write-Host "HASH" -NoNewline -ForegroundColor Yellow
                Write-Host "] " -NoNewline -ForegroundColor White
                Write-Host "Verifying SHA256 checksum..." -NoNewline -ForegroundColor White

                if (-not $hashesMatch) {
                    Write-Host " NOT PASSED" -ForegroundColor Red
                    Write-Host ""
                    Write-Host "[" -NoNewline -ForegroundColor White
                    Write-Host "ERROR" -NoNewline -ForegroundColor Red
                    Write-Host "] " -NoNewline -ForegroundColor White
                    Write-Host "SHA256 checksum mismatch! The downloaded file is corrupt." -ForegroundColor Red

                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

                    if ($integrityAttempt -lt $maxIntegrityAttempts) {
                        Write-Host "[" -NoNewline -ForegroundColor White
                        Write-Host "INFO" -NoNewline -ForegroundColor Yellow
                        Write-Host "] " -NoNewline -ForegroundColor White
                        Write-Host "Retrying download due to SHA256 mismatch..." -ForegroundColor White
                        continue
                    } else {
                        Write-Host "[" -NoNewline -ForegroundColor White
                        Write-Host "ERROR" -NoNewline -ForegroundColor Red
                        Write-Host "] " -NoNewline -ForegroundColor White
                        Write-Host "SHA256 checksum mismatch on second attempt. Update aborted." -ForegroundColor Red
                        return
                    }
                } else {
                    Write-Host " PASSED" -ForegroundColor Green
                }
            } catch {
                Write-Host "[" -NoNewline -ForegroundColor White
                Write-Host "WARN" -NoNewline -ForegroundColor Yellow
                Write-Host "] " -NoNewline -ForegroundColor White
                Write-Host "Failed to compute SHA256 for the downloaded file. Skipping integrity validation." -ForegroundColor Yellow
            }
        }

        # If we reach here, download and (optional) SHA256 validation succeeded
        break
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

            # Ensure Explorer and the filesystem see a real replacement:
            # delete old file (if it exists) before creating the new one.
            if (Test-Path $destPath) {
                Remove-Item $destPath -Force
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

    if ($oldVersionLine -and $newVersionLine) {
        if ($oldVersionLine -ne $newVersionLine) {
            Write-Status "CHECK" "ffmpeg -version changed after update." "OK"
        } else {
            Write-Status "CHECK" "ffmpeg -version did not change after update (version line is the same as before)." ""
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
