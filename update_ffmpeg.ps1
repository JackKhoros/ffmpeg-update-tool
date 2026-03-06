[CmdletBinding()]
param(
    [double]$SpeedThresholdMBps = 1.0,
    [Int64]$SpeedSampleBytes = 3MB,
    [switch]$Quiet,
    [string]$PreferredAssetName = "ffmpeg-master-latest-win64-gpl.zip",
    [string]$AlternateMasterPattern = "ffmpeg-N-*-win64-gpl.zip"
)

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# FFmpeg Updater v9.0 - works in the folder where update_ffmpeg.ps1 is located

$ErrorActionPreference = "Stop"

if ($SpeedThresholdMBps -lt 0) {
    throw "SpeedThresholdMBps cannot be negative."
}
if ($SpeedSampleBytes -lt 0) {
    throw "SpeedSampleBytes cannot be negative."
}

$script:SpeedThresholdMBps = 0.0
$script:Quiet = [bool]$Quiet

# Detect if Invoke-WebRequest supports -UseBasicParsing (Windows PowerShell 5.1)
$Script:UseBasicParsing = $false
try {
    $iwCmd = Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue
    if ($iwCmd -and $iwCmd.Parameters.ContainsKey('UseBasicParsing')) {
        $Script:UseBasicParsing = $true
    }
} catch {
    $Script:UseBasicParsing = $false
}

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

$assetName        = $PreferredAssetName
$altMasterPattern = $AlternateMasterPattern
$apiLatestUrl     = "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest"
$apiReleasesUrl   = "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases?per_page=10"

# ----- Pretty helpers -----

function Write-Status {
    param(
        [string]$tag,
        [string]$message,
        [string]$state = "",
        [switch]$Always,
        [ConsoleColor]$TagColor = [ConsoleColor]::Yellow,
        [ConsoleColor]$MessageColor = [ConsoleColor]::White,
        [ConsoleColor]$StateColor = [ConsoleColor]::Green
    )

    if ($script:Quiet -and -not $Always) {
        return
    }

    Write-Host "[" -NoNewline -ForegroundColor White
    Write-Host $tag -NoNewline -ForegroundColor $TagColor
    Write-Host "] " -NoNewline -ForegroundColor White
    Write-Host $message -NoNewline -ForegroundColor $MessageColor
    if ($state) {
        Write-Host " $state" -ForegroundColor $StateColor
    } else {
        Write-Host ""
    }
}

function Write-Line {
    param(
        [string]$Message = "",
        [ConsoleColor]$Color = [ConsoleColor]::White,
        [switch]$Always
    )

    if ($script:Quiet -and -not $Always) {
        return
    }

    if ([string]::IsNullOrEmpty($Message)) {
        Write-Host ""
    } else {
        Write-Host $Message -ForegroundColor $Color
    }
}

function Draw-Progress {
    param(
        [double]$pct,
        [double]$curMB,
        [double]$totMB,
        [double]$speedMB
    )

    if ($script:Quiet) {
        return
    }

    $len = 30
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 1) { $pct = 1 }
    $filled = [int]($pct * $len)
    if ($pct -gt 0 -and $pct -lt 1 -and $filled -lt 1) {
        $filled = 1
    }
    $empty = $len - $filled
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

function Invoke-WebRequestCompat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [string]$Method = "Get",
        [string]$OutFile
    )

    $params = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = @{ "User-Agent" = "PowerShell" }
        ErrorAction = "Stop"
    }

    if ($OutFile) {
        $params.OutFile = $OutFile
    }

    if ($Script:UseBasicParsing) {
        $params.UseBasicParsing = $true
    }

    return Invoke-WebRequest @params
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

    $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }

        $parts = $trimmed -split "\s+", 2
        if ($parts.Count -ne 2) { continue }

        $hash = $parts[0].Trim()
        $name = $parts[1].Trim()

        if ($name.StartsWith("*")) {
            $name = $name.Substring(1).Trim()
        }

        if ($name -eq $AssetName) {
            return $hash
        }
    }

    return $null
}

function Build-RemoteIdentity {
    param(
        [string]$ETag,
        $Asset
    )

    if ($ETag) {
        return @{
            Identity = "etag:$ETag"
            Source   = "ETag"
        }
    }

    if ($Asset -and $Asset.id -and $Asset.updated_at -and $Asset.size) {
        return @{
            Identity = ("asset:{0}|updated:{1}|size:{2}" -f $Asset.id, $Asset.updated_at, $Asset.size)
            Source   = "GitHub asset metadata"
        }
    }

    if ($Asset -and $Asset.id -and $Asset.updated_at) {
        return @{
            Identity = ("asset:{0}|updated:{1}" -f $Asset.id, $Asset.updated_at)
            Source   = "GitHub asset metadata"
        }
    }

    if ($Asset -and $Asset.id) {
        return @{
            Identity = ("asset:{0}" -f $Asset.id)
            Source   = "GitHub asset metadata"
        }
    }

    return $null
}

function Get-LocalIdentity {
    param($Metadata)

    if (-not $Metadata) {
        return $null
    }

    if ($Metadata.identity) {
        return [string]$Metadata.identity
    }

    if ($Metadata.etag) {
        return "etag:$($Metadata.etag)"
    }

    return $null
}

function Get-ZipEntryByPattern {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Compression.ZipArchive]$Zip,
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    return $Zip.Entries | Where-Object { $_.FullName -match $Pattern } | Select-Object -First 1
}

function Extract-EntryToTempFile {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Compression.ZipArchive]$Zip,
        [Parameter(Mandatory = $true)]
        [string]$Pattern,
        [Parameter(Mandatory = $true)]
        [string]$TempPath
    )

    $entry = Get-ZipEntryByPattern -Zip $Zip -Pattern $Pattern
    if (-not $entry) {
        throw "Entry matching pattern '$Pattern' not found in archive."
    }

    if (Test-Path $TempPath) {
        Remove-Item $TempPath -Force -ErrorAction SilentlyContinue
    }

    $inStream = $null
    $outStream = $null

    try {
        $inStream = $entry.Open()
        $outStream = [System.IO.File]::Create($TempPath)
        $inStream.CopyTo($outStream)
    }
    finally {
        if ($outStream) { $outStream.Close() }
        if ($inStream)  { $inStream.Close() }
    }

    if (-not (Test-Path $TempPath)) {
        throw "Temporary file was not created: $TempPath"
    }

    $tempInfo = Get-Item $TempPath -ErrorAction Stop
    if ($tempInfo.Length -le 0) {
        throw "Temporary file is empty: $TempPath"
    }

    return $tempInfo
}

function Replace-FileAtomically {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [Parameter(Mandatory = $true)]
        [string]$BackupPath
    )

    if (-not (Test-Path $SourcePath)) {
        throw "Temporary file not found: $SourcePath"
    }

    if (Test-Path $BackupPath) {
        Remove-Item $BackupPath -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $DestinationPath) {
        [System.IO.File]::Replace($SourcePath, $DestinationPath, $BackupPath, $true)
        return "replaced"
    }

    Move-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
    return "created"
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
    $ScriptVersion = "v9.0"

    if (-not $script:Quiet) {
        Write-Host "==============================================="
        Write-Host (" FFmpeg Updater {0}" -f $ScriptVersion) -ForegroundColor Cyan
        Write-Host "==============================================="
        Write-Host ""
    }

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

        $std = $Rel.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
        if ($std) {
            return $std
        }

        $alt = $Rel.assets | Where-Object { $_.name -like $altMasterPattern } | Select-Object -First 1
        if ($alt) {
            return $alt
        }

        return $null
    }

    try {
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
        $latestRelease = Invoke-RestMethod -Uri $apiLatestUrl -Headers $headers
        if ($latestRelease) {
            $latestAsset = Get-MasterAssetFromRelease -Rel $latestRelease
        }
    } catch {
        # Ignore; if this fails, we'll just use whatever we got from the releases list
    }

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

    $usingNonStandardAssetName = $asset.name -ne $assetName
    if ($usingNonStandardAssetName) {
        Write-Status "INFO" ("Using master asset with non-standard name: {0}" -f $asset.name) "" -Always:$false
    }

    $buildDate   = $asset.updated_at
    $downloadUrl = $asset.browser_download_url

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

    Write-Status "CHECK" "Fetching remote identity and file size..."

    $head = $null
    $etag = $null
    $totalBytes = 0
    $headSucceeded = $false

    try {
        $head = Invoke-WebRequestCompat -Uri $downloadUrl -Method Head
        $headSucceeded = $true
    } catch {
        Write-Status "WARN" ("HEAD request failed, falling back to release metadata. Reason: {0}" -f $_.Exception.Message) "" -Always -TagColor Yellow -MessageColor Yellow
    }

    if ($head) {
        $etagHeader = $head.Headers["ETag"]
        if ($etagHeader) {
            $etag = ($etagHeader | Select-Object -First 1)
        }

        $lenHeader = $head.Headers["Content-Length"]
        if ($lenHeader) {
            [int64]$totalBytes = ($lenHeader | Select-Object -First 1)
        }
    }

    if ($totalBytes -le 0 -and $asset.size) {
        [int64]$totalBytes = [int64]$asset.size
    }

    $identityInfo = Build-RemoteIdentity -ETag $etag -Asset $asset
    if (-not $identityInfo) {
        Write-Host "Error: could not determine a stable remote identity for the selected asset." -ForegroundColor Red
        return
    }

    $remoteIdentity = $identityInfo.Identity
    $remoteIdentitySource = $identityInfo.Source
    $localIdentity = Get-LocalIdentity -Metadata $old

    if ($localIdentity -and $localIdentity -eq $remoteIdentity) {
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
            Write-Line ""
            Write-Host ("FFmpeg is already up to date. ({0} match)" -f $remoteIdentitySource) -ForegroundColor Green
            Write-Line ""
            if ($etag) {
                Write-Host "ETag: " -NoNewline -ForegroundColor Red
                Write-Host $etag -ForegroundColor Cyan
            } else {
                Write-Host "Identity source: " -NoNewline -ForegroundColor White
                Write-Host $remoteIdentitySource -ForegroundColor Cyan
            }
            Write-Host "Build date: " -NoNewline -ForegroundColor White
            Write-Host $buildDate -ForegroundColor Magenta
            if ($oldVersionLine) {
                Write-Line ""
                Write-Host "Current FFmpeg: " -NoNewline -ForegroundColor White
                Write-Host $oldVersionLine -ForegroundColor Green
            }
            return
        }

        $missingNames = ($missing | ForEach-Object { $_.Name }) -join ", "
        Write-Status "WARN" ("Identity matches but required binaries are missing: {0}. Re-downloading..." -f $missingNames) "" -Always -TagColor Yellow -MessageColor Yellow
    }

    # ----- Optional SHA256 checksum preparation -----
    $checksumAvailable = $false
    $expectedSha256    = $null
    $checksumPath      = Join-Path $root "checksums.sha256"

    $checksumAsset = $null
    if ($release -and $release.assets) {
        $checksumAsset = $release.assets | Where-Object { $_.name -eq "checksums.sha256" } | Select-Object -First 1
    }

    if ($checksumAsset) {
        try {
            if (Test-Path $checksumPath) {
                Remove-Item $checksumPath -Force -ErrorAction SilentlyContinue
            }

            Invoke-WebRequestCompat -Uri $checksumAsset.browser_download_url -OutFile $checksumPath | Out-Null

            $expectedSha256 = Get-ExpectedSha256FromChecksums -Path $checksumPath -AssetName $asset.name

            Remove-Item $checksumPath -Force -ErrorAction SilentlyContinue

            if ($expectedSha256) {
                $checksumAvailable = $true
            } else {
                Write-Status "WARN" ("SHA256 entry not found for asset {0} in checksums.sha256. Skipping integrity validation." -f $asset.name) "" -Always -TagColor Yellow -MessageColor Yellow
            }
        } catch {
            if (Test-Path $checksumPath) {
                Remove-Item $checksumPath -Force -ErrorAction SilentlyContinue
            }
            Write-Status "WARN" "Failed to download or parse checksums.sha256. Skipping SHA256 validation." "" -Always -TagColor Yellow -MessageColor Yellow
        }
    } else {
        Write-Status "WARN" "SHA256 checksum file (checksums.sha256) is missing for this release. Skipping integrity validation." "" -Always -TagColor Yellow -MessageColor Yellow
    }

    Write-Status "CHECK" ("Remote identity differs from local ({0})." -f $remoteIdentitySource) "NEW"
    Write-Line ""
    Write-Status "DL" "Starting download to ZIP via curl.exe (fast mode)..."

    $curlCmd = Get-Command "curl.exe" -ErrorAction SilentlyContinue
    if (-not $curlCmd) {
        Write-Host "curl.exe not found on PATH. Please install or restore curl.exe (it is bundled with modern Windows)." -ForegroundColor Red
        return
    }
    $curlPath = $curlCmd.Source

    if ($totalBytes -le 0) {
        Write-Status "WARN" "Content-Length is not available. Progress bar may be inaccurate." "" -Always -TagColor Yellow -MessageColor Yellow
    }

    $thresholdMBps = $SpeedThresholdMBps
    $script:SpeedThresholdMBps = $thresholdMBps
    $sampleBytes = $SpeedSampleBytes

    if ($sampleBytes -le 0) {
        $sampleBytes = 0
    } elseif ($totalBytes -gt 0 -and $sampleBytes -gt $totalBytes) {
        $sampleBytes = [int64]([Math]::Max([int64]($totalBytes / 4), 1))
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
            $proc = [System.Diagnostics.Process]::Start($psi)
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
            Draw-Progress 0 0 ($totalBytes / 1MB) 0
        }

        while (-not $proc.HasExited) {
            $read = $stdout.Read($buffer, 0, $buffer.Length)
            if ($read -gt 0) {
                $fs.Write($buffer, 0, $read)
                $totalRead += $read

                if ($totalBytes -gt 0) {
                    $pct   = $totalRead / [double]$totalBytes
                    $curMB = $totalRead / 1MB
                    $totMB = $totalBytes / 1MB
                    $speed = ($totalRead / 1MB) / [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
                    Draw-Progress $pct $curMB $totMB $speed
                }

                if (
                    -not $sampleChecked -and
                    $thresholdMBps -gt 0 -and
                    $sampleBytes -gt 0 -and
                    $totalBytes -gt 0 -and
                    $totalRead -ge $sampleBytes
                ) {
                    $sampleChecked = $true
                    $speedSample = ($totalRead / 1MB) / [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
                    if ($speedSample -lt $thresholdMBps) {
                        $result.WasSlow = $true
                        if ($attempt -eq 1) {
                            try { $proc.Kill() } catch {}
                            break
                        } elseif ($attempt -eq 2) {
                            if (-not $script:Quiet) {
                                Write-Host ""
                                Write-Host ""
                            }
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
                $pct   = $totalRead / [double]$totalBytes
                $curMB = $totalRead / 1MB
                $totMB = $totalBytes / 1MB
                $speed = ($totalRead / 1MB) / [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
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
            if (-not $script:Quiet) {
                Write-Host ""
            }
        } else {
            Write-Line ""
            Write-Status "INFO" "Download complete (size unknown)." "" -Always -TagColor Yellow -MessageColor Yellow
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
            Write-Line ""
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
                Write-Host ("Error: downloaded size ({0:N1} MB) does not match expected size ({1:N1} MB)." -f ($zipLen / 1MB), ($totalBytes / 1MB)) -ForegroundColor Red
                Write-Host "Archive appears incomplete or corrupted. Please try again later." -ForegroundColor Red
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                return
            }
        }

        if ($checksumAvailable -and $expectedSha256) {
            try {
                $fileHash      = Get-FileHash -Algorithm SHA256 -Path $zipPath
                $actualSha256  = $fileHash.Hash.ToLowerInvariant()
                $expectedLower = $expectedSha256.ToLowerInvariant()
                $hashesMatch   = ($actualSha256 -eq $expectedLower)

                Write-Host "[" -NoNewline -ForegroundColor White
                Write-Host "HASH" -NoNewline -ForegroundColor Yellow
                Write-Host "] " -NoNewline -ForegroundColor White
                Write-Host "Verifying SHA256 checksum..." -NoNewline -ForegroundColor White

                if (-not $hashesMatch) {
                    Write-Host " NOT PASSED" -ForegroundColor Red
                    Write-Host ""
                    Write-Status "ERROR" "SHA256 checksum mismatch! The downloaded file is corrupt." "" -Always -TagColor Red -MessageColor Red

                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

                    if ($integrityAttempt -lt $maxIntegrityAttempts) {
                        Write-Status "INFO" "Retrying download due to SHA256 mismatch..." "" -Always
                        continue
                    } else {
                        Write-Status "ERROR" "SHA256 checksum mismatch on second attempt. Update aborted." "" -Always -TagColor Red -MessageColor Red
                        return
                    }
                } else {
                    Write-Host " PASSED" -ForegroundColor Green
                }
            } catch {
                Write-Status "WARN" "Failed to compute SHA256 for the downloaded file. Skipping integrity validation." "" -Always -TagColor Yellow -MessageColor Yellow
            }
        }

        break
    }

    Write-Line ""
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
    $preparedFiles = @()

    try {
        $fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)

        $targets = @(
            @{ Pattern = "/bin/ffmpeg\.exe$";  Destination = (Join-Path $root "ffmpeg.exe")  },
            @{ Pattern = "/bin/ffprobe\.exe$"; Destination = (Join-Path $root "ffprobe.exe") },
            @{ Pattern = "/bin/ffplay\.exe$";  Destination = (Join-Path $root "ffplay.exe")  }
        )

        foreach ($target in $targets) {
            $destPath = $target.Destination
            $tempPath = "$destPath.new"
            $backupPath = "$destPath.bak"

            if (Test-Path $tempPath) {
                Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path $backupPath) {
                Remove-Item $backupPath -Force -ErrorAction SilentlyContinue
            }

            Extract-EntryToTempFile -Zip $zip -Pattern $target.Pattern -TempPath $tempPath | Out-Null

            $preparedFiles += [PSCustomObject]@{
                Destination = $destPath
                TempPath    = $tempPath
                BackupPath  = $backupPath
                Replaced    = $false
                CreatedNew  = $false
            }
        }

        foreach ($item in $preparedFiles) {
            $mode = Replace-FileAtomically -SourcePath $item.TempPath -DestinationPath $item.Destination -BackupPath $item.BackupPath
            if ($mode -eq "replaced") {
                $item.Replaced = $true
            } elseif ($mode -eq "created") {
                $item.CreatedNew = $true
            }
        }

        foreach ($item in $preparedFiles) {
            if (Test-Path $item.BackupPath) {
                Remove-Item $item.BackupPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        foreach ($item in $preparedFiles) {
            if ($item.TempPath -and (Test-Path $item.TempPath)) {
                Remove-Item $item.TempPath -Force -ErrorAction SilentlyContinue
            }

            if ($item.BackupPath -and (Test-Path $item.BackupPath)) {
                try {
                    if (Test-Path $item.Destination) {
                        Remove-Item $item.Destination -Force -ErrorAction SilentlyContinue
                    }
                    Move-Item -LiteralPath $item.BackupPath -Destination $item.Destination -Force -ErrorAction SilentlyContinue
                } catch {
                    # Best effort rollback
                }
            } elseif ($item.CreatedNew -and $item.Destination -and (Test-Path $item.Destination)) {
                Remove-Item $item.Destination -Force -ErrorAction SilentlyContinue
            }
        }

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

        foreach ($item in $preparedFiles) {
            if ($item.TempPath -and (Test-Path $item.TempPath)) {
                Remove-Item $item.TempPath -Force -ErrorAction SilentlyContinue
            }
        }

        if (Test-Path $zipPath) {
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Status "COPY" "Binaries updated (ffmpeg/ffprobe/ffplay)." "OK"

    @{
        script_version   = $ScriptVersion
        etag             = $etag
        identity         = $remoteIdentity
        identity_source  = $remoteIdentitySource
        build_date       = $buildDate
        asset_name       = $asset.name
        asset_id         = $asset.id
        asset_size       = $asset.size
        release_tag      = $releaseTag
        published_at     = $publishedAt
        head_succeeded   = $headSucceeded
        checked_at_utc   = [DateTime]::UtcNow.ToString("o")
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
    if ($etag) {
        Write-Host "ETag: " -NoNewline -ForegroundColor Red
        Write-Host $etag -ForegroundColor Cyan
    } else {
        Write-Host "Identity source: " -NoNewline -ForegroundColor White
        Write-Host $remoteIdentitySource -ForegroundColor Cyan
    }
    Write-Host "Build date: " -NoNewline -ForegroundColor White
    Write-Host $buildDate -ForegroundColor Magenta
    Write-Host "Release: " -NoNewline -ForegroundColor White
    Write-Host $releaseTag -ForegroundColor Cyan

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
