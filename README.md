# FFmpeg Auto-Updater for Windows (PowerShell)

This repository contains a fully automatic FFmpeg updater for Windows.  
It downloads the latest official FFmpeg build from the BtbN GitHub releases,
verifies changes using ETag, and updates only when needed.

## Usage
Place `update_ffmpeg.ps1` in the same folder as your FFmpeg binaries  
(`ffmpeg.exe`, `ffprobe.exe`, `ffplay.exe`) and run the script:

```
powershell -ExecutionPolicy Bypass -File "path\to\update_ffmpeg.ps1"
```

Replace `path\to\update_ffmpeg.ps1` with the full path to your script, e.g.:

```
powershell -ExecutionPolicy Bypass -File "D:\Tools\ffmpeg\update_ffmpeg.ps1"
```

The script will:
- Check for the latest FFmpeg build (via ETag)
- Avoid redundant downloads
- Detect rate-limited throttled speeds and retry intelligently
- Download the ZIP via curl.exe (fast mode) to `ffmpeg-update.zip` in the current directory
- Remove the downloaded archive after extracting only the required binaries
- Show detailed colorized progress bars and logs

## Features
- ⚡ **Fast download via curl (RAM/Direct ZIP modes)**
- 🧠 **Intelligent retry when GitHub throttles bandwidth**
- 🟣 **Beautiful colored progress bar**
- 🔍 **Version comparison via `ffmpeg -version`**
- 📦 **ZIP extraction without writing temp folders**
- 🔄 **Only updates when a new build is available**
- 🛡️ **Safe — never overwrites unrelated files**

## Requirements
- Windows 10/11
- PowerShell 5+ (default)
- curl.exe (bundled in Windows)

---

Enjoy the tool!
